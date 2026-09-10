import Foundation
import SwiftUI
@preconcurrency import Virtualization

/// Orchestrates the engine VM lifecycle and the current playback session.
@MainActor
final class AppModel: ObservableObject {
    enum EngineState: Equatable {
        case idle
        case installing(progressBytes: Int64)
        case booting
        case waitingForEngine
        case ready(version: String)
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Engine off"
            case .installing(let b): return "Preparing engine (first launch)… \(b / (1 << 20)) MB"
            case .booting: return "Starting engine VM…"
            case .waitingForEngine: return "Waiting for Ace Stream engine…"
            case .ready(let v): return "Engine ready · \(v)"
            case .failed(let e): return "Engine failed: \(e)"
            }
        }
        var isReady: Bool { if case .ready = self { return true } else { return false } }

        var shortLabel: String {
            switch self {
            case .idle: return "Starting engine"
            case .installing: return "Preparing engine"
            case .booting: return "Starting engine"
            case .waitingForEngine: return "Waiting for engine"
            case .ready: return "Contacting engine"
            case .failed(let e): return e
            }
        }
    }

    enum PlaybackState: Equatable {
        case stopped
        case starting
        case prebuffering(percent: Int?)
        case playing
        case error(String)
    }

    @Published var engineState: EngineState = .idle

    var installProgress: Double? {
        if case .installing(let b) = engineState {
            return min(1, Double(b) / Double(4 * 1024 * 1024 * 1024))
        }
        return nil
    }
    @Published var playbackState: PlaybackState = .stopped
    @Published var currentLink: AceLink?
    @Published var playbackURL: URL?
    @Published var playbackAttempt = 0
    @Published var stats: AceStreamAPI.Stats?
    /// Snapshot of the log for the UI; refreshed at most a few times per second (the engine
    /// logs dozens of lines per second, and publishing each one would saturate the main thread).
    @Published var consoleLines: [String] = []
    private var logBuffer: [String] = []
    private var logDirty = false
    private var logFlushTask: Task<Void, Never>?
    @Published var linkText: String = ""
    @Published var pendingLink: AceLink?   // opened before engine was ready
    @Published var showLog = false
    @Published var showHelp = false

    // Audio / transport, driven by the toolbar and keyboard shortcuts.
    @Published var volume: Double = 100
    @Published var muted = false
    @Published var isPaused = false

    /// Space: pause/resume if a stream is up; otherwise start the current link.
    func togglePlayPause() {
        if playbackURL != nil {
            isPaused.toggle()
        } else if let link = currentLink {
            play(link)
        } else {
            let t = linkText.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { open(t) }
        }
    }

    func toggleMute() { muted.toggle() }

    func nudgeVolume(_ delta: Double) {
        muted = false
        volume = min(150, max(0, volume + delta))
    }

    let api = AceStreamAPI()
    private let vm = VMController()
    private var proxy: VsockProxy?
    private var network: GvproxyNetwork?
    private var session: AceStreamAPI.PlaybackInfo?
    private var relay: StreamRelay?
    private var statsTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private let maxLogLines = 2000

    init() {
        VLCLogBridge.sink = { [weak self] line in Task { @MainActor in self?.appendLog(line) } }
        vm.onConsoleLine = { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }
        vm.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.appendLog("[vm] state: \(Self.describe(state))")
                if state == .stopped || state == .error, self.engineState.isReady || self.engineState == .waitingForEngine || self.engineState == .booting {
                    self.engineState = .failed("virtual machine stopped unexpectedly")
                }
            }
        }
    }

    private static func describe(_ s: VZVirtualMachine.State) -> String {
        switch s {
        case .stopped: return "stopped"
        case .running: return "running"
        case .paused: return "paused"
        case .error: return "error"
        case .starting: return "starting"
        case .pausing: return "pausing"
        case .resuming: return "resuming"
        case .stopping: return "stopping"
        case .saving: return "saving"
        case .restoring: return "restoring"
        @unknown default: return "unknown"
        }
    }

    func appendLog(_ line: String) {
        FileLog.shared.write(line)
        logBuffer.append(line)
        if logBuffer.count > maxLogLines { logBuffer.removeFirst(logBuffer.count - maxLogLines) }
        logDirty = true
        if logFlushTask == nil {
            logFlushTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self else { return }
                self.logFlushTask = nil
                if self.logDirty && self.showLog {
                    self.logDirty = false
                    self.consoleLines = self.logBuffer
                }
            }
        }
    }

    func refreshLogSnapshot() {
        consoleLines = logBuffer
        logDirty = false
    }

    // MARK: Engine lifecycle

    func startEngine(reinstall: Bool = false) {
        guard startTask == nil else { return }
        startTask = Task { [weak self] in
            guard let self else { return }
            await self.runEngineStartup(reinstall: reinstall)
            self.startTask = nil
        }
    }

    private func runEngineStartup(reinstall: Bool) async {
        do {
            if reinstall { try RootfsInstaller.removeInstalled() }
            if !RootfsInstaller.isInstalled {
                engineState = .installing(progressBytes: 0)
                appendLog("[app] installing rootfs \(RootfsInstaller.bundledVersion) to \(RootfsInstaller.diskImageURL.path)")
                try await Task.detached(priority: .userInitiated) {
                    try RootfsInstaller.install { bytes in
                        Task { @MainActor [weak self] in self?.engineState = .installing(progressBytes: bytes) }
                    }
                }.value
            }
            guard let kernel = RootfsInstaller.bundledKernelURL else {
                throw NSError(domain: "KakaPlayer", code: 10, userInfo: [NSLocalizedDescriptionKey: "Kernel (vmlinux-arm64) missing from app bundle."])
            }
            engineState = .booting
            try await VMController.ensureRosetta()
            let memory: UInt64 = 2 * 1024 * 1024 * 1024
            let cpus = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
            let network = GvproxyNetwork { [weak self] l in Task { @MainActor in self?.appendLog(l) } }
            let netHandle = try network.start()
            self.network = network
            let config = try vm.makeConfiguration(kernelURL: kernel, diskURL: RootfsInstaller.diskImageURL, networkHandle: netHandle, cpus: cpus, memoryBytes: memory)
            try await vm.start(configuration: config)
            appendLog("[app] VM started (\(cpus) CPUs, \(memory >> 20) MB)")

            let proxy = VsockProxy(hostPort: 6878, guestPort: 6878, vm: vm) { [weak self] l in
                Task { @MainActor in self?.appendLog(l) }
            }
            try proxy.start()
            self.proxy = proxy

            engineState = .waitingForEngine
            let deadline = Date().addingTimeInterval(180)
            var version: String?
            while Date() < deadline {
                if let v = try? await api.version() { version = v.version; break }
                try await Task.sleep(for: .seconds(1))
                if !vm.isRunning { throw NSError(domain: "KakaPlayer", code: 11, userInfo: [NSLocalizedDescriptionKey: "VM exited during engine startup (see log)."]) }
            }
            guard let version else { throw VMController.VMError.timeout("engine did not answer within 3 minutes (see log)") }
            engineState = .ready(version: version)
            appendLog("[app] engine ready, version \(version)")
            if let link = pendingLink {
                pendingLink = nil
                play(link)
            }
        } catch {
            engineState = .failed(error.localizedDescription)
            appendLog("[app] startup failed: \(error.localizedDescription)")
        }
    }

    func shutdown() {
        stopPlayback()
        proxy?.stop()
        proxy = nil
        vm.shutdown()
        network?.stop()
        network = nil
        engineState = .idle
    }

    // MARK: Playback

    func open(_ raw: String) {
        guard let link = AceLink.parse(raw) else {
            playbackState = .error("Not a valid Ace Stream link: \(raw)")
            return
        }
        linkText = link.canonical
        play(link)
    }

    func play(_ link: AceLink) {
        currentLink = link
        guard engineState.isReady else {
            pendingLink = link
            playbackState = .starting
            if case .failed = engineState { startEngine() }
            if case .idle = engineState { startEngine() }
            return
        }
        let previous = session
        session = nil
        isPaused = false
        statsTask?.cancel()
        relay?.stop(); relay = nil
        playbackURL = nil
        playerHasPlayed = false
        playerRetries = 0
        playerWatchdog?.cancel(); playerWatchdog = nil
        stats = nil
        playbackState = .starting
        statsTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let previous { await api.stop(previous); try? await Task.sleep(for: .milliseconds(400)) }
                guard !Task.isCancelled else { return }
                // The engine can be briefly busy right after switching torrents; retry the start.
                var info: AceStreamAPI.PlaybackInfo?
                var lastErr: Error?
                for attempt in 0..<3 {
                    do { info = try await api.startStream(link); break }
                    catch {
                        lastErr = error
                        appendLog("[play] start attempt \(attempt + 1) failed: \(error.localizedDescription)")
                        if Task.isCancelled { return }
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
                guard let info else { throw lastErr ?? AceStreamAPI.APIError.badResponse }
                guard !Task.isCancelled else { await api.stop(info); return }
                session = info
                appendLog("[play] session \(info.playback_session_id ?? "?") live=\(info.is_live ?? -1) url=\(info.playback_url)")
                playbackState = .prebuffering(percent: nil)
                // Wait until the engine reports it is downloading before opening the player,
                // so VLC doesn't sit on an idle HTTP connection and give up.
                var started = false
                var lastStatus = ""
                let startDeadline = Date().addingTimeInterval(90)
                while !Task.isCancelled {
                    if let s = try? await api.stats(info) {
                        stats = s
                        let st = s.status ?? ""
                        if st != lastStatus { lastStatus = st; appendLog("[play] status=\(st) peers=\(s.peers ?? 0) down=\(s.speed_down ?? 0)KB/s") }
                        if !started {
                            if st == "dl" || (st == "prebuf" && (s.total_progress ?? 0) >= 100) || Date() > startDeadline {
                                started = true
                                playerHasPlayed = false
                                if let upstream = URL(string: info.playback_url) {
                                    let relay = StreamRelay { [weak self] l in Task { @MainActor in self?.appendLog(l) } }
                                    relay.onUpstreamEnded = { [weak self] err in
                                        Task { @MainActor in
                                            guard let self, self.relay === relay else { return }
                                            self.playbackState = .error(err == nil ? "The engine closed the stream." : "Engine connection lost: \(err!.localizedDescription)")
                                        }
                                    }
                                    try relay.start(upstream: upstream)
                                    self.relay = relay
                                    playbackURL = relay.localURL
                                }
                                playbackState = .prebuffering(percent: nil)
                            } else if st == "prebuf" {
                                playbackState = .prebuffering(percent: s.total_progress)
                            } else if st == "err" {
                                throw AceStreamAPI.APIError.engine("stream error reported by engine")
                            }
                        }
                    }
                    try await Task.sleep(for: .seconds(1))
                }
            } catch is CancellationError {
            } catch {
                playbackState = .error(error.localizedDescription)
                appendLog("[play] failed: \(error.localizedDescription)")
            }
        }
    }

    func stopPlayback(keepLink: Bool = false) {
        statsTask?.cancel()
        statsTask = nil
        playbackURL = nil
        relay?.stop()
        relay = nil
        playerHasPlayed = false
        playerRetries = 0
        playerWatchdog?.cancel()
        playerWatchdog = nil
        stats = nil
        isPaused = false
        if let s = session {
            session = nil
            Task { await api.stop(s) }
        }
        playbackState = .stopped
        if !keepLink { currentLink = nil }
    }

    private var playerHasPlayed = false
    private var playerWatchdog: Task<Void, Never>?
    private var playerRetries = 0

    func playerEvent(_ event: PlayerEvent) {
        guard playbackURL != nil else { return }
        switch event {
        case .opening, .buffering:
            break
        case .playing:
            playerHasPlayed = true
            playerRetries = 0
            playerWatchdog?.cancel()
            playbackState = .playing
        case .error, .ended:
            appendLog("[vlc] player reported \(event)")
            // libvlc emits an error while it reconnects after the engine's redirect; only act
            // if no video shows up within a few seconds.
            if playerWatchdog == nil {
                playerWatchdog = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(6))
                    guard let self, !Task.isCancelled else { return }
                    self.playerWatchdog = nil
                    guard self.playbackURL != nil, self.playbackState != .playing else { return }
                    if self.playerRetries < 2 {
                        self.playerRetries += 1
                        self.appendLog("[vlc] no video yet, reopening stream (attempt \(self.playerRetries + 1))")
                        self.playbackAttempt += 1
                    } else {
                        self.playbackState = .error(event == .ended ? "The stream ended." : "VLC could not open the stream (see log).")
                    }
                }
            } else if playerHasPlayed {
                // Real end/error after playback had started.
                playbackState = .error(event == .ended ? "The stream ended." : "VLC could not decode the stream.")
            }
        }
    }
}

/// Mirrors the in-app log to ~/Library/Logs/KakaPlayer/kakaplayer.log.
final class FileLog {
    static let shared = FileLog()
    private let handle: FileHandle?
    private let queue = DispatchQueue(label: "dev.kakaplayer.filelog")
    private let formatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
    private init() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/KakaPlayer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("kakaplayer.log")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), (attrs[.size] as? Int ?? 0) > 20_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }
    func write(_ line: String) {
        let stamped = "\(formatter.string(from: Date())) \(line)\n"
        queue.async { [handle] in handle?.write(stamped.data(using: .utf8) ?? Data()) }
    }
}

import AVFoundation
import Foundation
import SwiftUI
import UIKit

/// Drives the iPhone/iPad client: which engine to talk to, the current playback session,
/// and the local relay that feeds VLCKit.
///
/// Unlike the Mac app there is no engine to boot here — the engine lives on another
/// device (a Mac running KakaPlayer, or any reachable Ace Stream engine) and its
/// `host:port` is typed in Settings.
@MainActor
final class MobileModel: ObservableObject {

    // MARK: State

    enum EngineStatus: Equatable {
        case notConfigured
        case checking
        case reachable(version: String)
        case unreachable(String)

        var label: String {
            switch self {
            case .notConfigured: return "No engine configured"
            case .checking: return "Contacting engine…"
            case .reachable(let v): return "Engine ready · \(v)"
            case .unreachable(let e): return "Engine unreachable: \(e)"
            }
        }
        var isReachable: Bool { if case .reachable = self { return true } else { return false } }
    }

    enum MobileError: LocalizedError {
        case engineUnreachable(String)
        var errorDescription: String? {
            switch self {
            case .engineUnreachable(let detail): return "Engine unreachable: \(detail)"
            }
        }
    }

    enum PlaybackState: Equatable {
        case stopped
        case starting
        case prebuffering(percent: Int?)
        case playing
        case error(String)

        var label: String {
            switch self {
            case .stopped: return "Idle"
            case .starting: return "Starting…"
            case .prebuffering(let pct): return pct.map { "Buffering \($0)%" } ?? "Buffering…"
            case .playing: return "Playing"
            case .error(let msg): return msg
            }
        }
    }

    @Published private(set) var engineStatus: EngineStatus = .notConfigured
    @Published private(set) var playbackState: PlaybackState = .stopped
    @Published private(set) var currentLink: AceLink?
    @Published private(set) var playbackURL: URL?
    /// Bumped to make the player reopen the same URL after a stall.
    @Published private(set) var playbackAttempt = 0
    @Published private(set) var stats: AceStreamAPI.Stats?
    /// Last `maxLogLines` log lines, refreshed at most a few times a second.
    @Published private(set) var logLines: [String] = []
    @Published var linkText: String = ""
    @Published var showSettings = false

    // MARK: Audio / transport
    //
    // Mirrors the Mac app's `AppModel`: the floating controls and the hardware keyboard
    // drive these, and `PlayerView` hands them to VLCKit.

    /// Software volume, 0…100. Persisted, so the level survives a relaunch.
    /// The Mac app allows up to 150; iOS keeps to 100 because the hardware keys and the
    /// Control Centre slider sit on top of it, and amplified output just clips.
    @Published var volume: Double {
        didSet { defaults.set(volume, forKey: Self.volumeDefaultsKey) }
    }
    @Published var muted = false
    @Published var isPaused = false

    static let maxVolume: Double = 100
    static let volumeDefaultsKey = "player.volume"

    /// Space / the play-pause button: resume or pause a live stream, otherwise start one.
    func togglePlayPause() {
        if playbackURL != nil {
            isPaused.toggle()
        } else if let link = currentLink {
            play(link)
        } else {
            let text = linkText.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { open(text) }
        }
    }

    func toggleMute() { muted.toggle() }

    /// Nudges the volume and un-mutes, so pressing "louder" while muted does the obvious thing.
    func nudgeVolume(_ delta: Double) {
        muted = false
        volume = min(Self.maxVolume, max(0, volume + delta))
    }

    // Engine address, persisted in UserDefaults.
    @Published private(set) var engineHost: String
    @Published private(set) var enginePort: Int

    static let hostDefaultsKey = "engine.host"
    static let portDefaultsKey = "engine.port"
    static let defaultPort = 6878

    /// `nil` until an engine host has been entered.
    var engineURL: URL? {
        let host = engineHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }
        // Bare IPv6 literals need brackets before they can be spelled in a URL.
        let literal = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return URL(string: "http://\(literal):\(enginePort)")
    }

    /// A client of the engine, or `nil` while no engine is configured. Kept as stored
    /// state rather than rebuilt per call: each `AceStreamAPI` carries its own URLSession,
    /// and a fresh one per request would pile up connections to the engine.
    private(set) var api: AceStreamAPI?

    /// Stable per-device pid so the engine does not treat every reconnect — or the Mac
    /// app sharing the same engine — as the same client.
    static let clientPID = "kakaplayer-ios-" + (UIDevice.current.identifierForVendor?.uuidString ?? "unknown")

    private let defaults: UserDefaults
    private var session: AceStreamAPI.PlaybackInfo?
    private var relay: StreamRelay?
    private var statsTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private let maxLogLines = 500
    private var logBuffer: [String] = []
    private var logFlushTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        engineHost = defaults.string(forKey: Self.hostDefaultsKey) ?? ""
        let storedPort = defaults.integer(forKey: Self.portDefaultsKey)
        enginePort = storedPort > 0 ? storedPort : Self.defaultPort
        // `object(forKey:)`, not `double(forKey:)`: the latter cannot tell "never set"
        // from a deliberate 0, and would start every fresh install silent.
        let storedVolume = defaults.object(forKey: Self.volumeDefaultsKey) as? Double
        volume = storedVolume.map { min(Self.maxVolume, max(0, $0)) } ?? Self.maxVolume
        api = engineURL.map { AceStreamAPI(baseURL: $0, pid: Self.clientPID) }
        engineStatus = api == nil ? .notConfigured : .checking
        VLCLogBridge.sink = { [weak self] line in Task { @MainActor in self?.appendLog(line) } }
        observeAudioInterruptions()
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    // MARK: Engine settings

    /// Stores a new engine address and re-checks it. Empty hosts clear the setting.
    func setEngine(host: String, port: Int) {
        let host = host.trimmingCharacters(in: .whitespaces)
        let port = (1...65535).contains(port) ? port : Self.defaultPort
        let previousURL = engineURL
        let previousAPI = api
        engineHost = host
        enginePort = port
        defaults.set(host, forKey: Self.hostDefaultsKey)
        defaults.set(port, forKey: Self.portDefaultsKey)
        // Saving the same address again (the common case: open Settings, look, Save) must
        // not churn the client — a rebuilt one would drop the engine's keep-alive
        // connections and give the stream a stall for nothing.
        if engineURL != previousURL {
            // The old client is obsolete, and a URLSession that is merely dropped keeps
            // itself (and its connections to the old engine) alive.
            previousAPI?.invalidate()
            api = engineURL.map { AceStreamAPI(baseURL: $0, pid: Self.clientPID) }
            appendLog("[app] engine set to \(engineURL?.absoluteString ?? "none")")
        }
        checkEngine()
    }

    /// Asks the engine for its version and publishes the outcome.
    func checkEngine() {
        checkTask?.cancel()
        guard let api else {
            engineStatus = .notConfigured
            return
        }
        engineStatus = .checking
        checkTask = Task { [weak self] in
            guard let self else { return }
            let result = await Self.probe(api)
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let version):
                self.engineStatus = .reachable(version: version)
                self.appendLog("[app] engine \(api.baseURL.absoluteString) answered version \(version)")
            case .failure(let error):
                self.engineStatus = .unreachable(error.localizedDescription)
                self.appendLog("[app] engine \(api.baseURL.absoluteString) unreachable: \(error.localizedDescription)")
            }
            self.checkTask = nil
        }
    }

    /// One-shot reachability probe used by `checkEngine` and by Settings' "Test connection",
    /// which needs the result without disturbing the published status.
    ///
    /// Pass `disposable: true` for a client built only for this probe — a typed-but-unsaved
    /// address, say — and the probe finishes its URLSession afterwards. Without that,
    /// testing an address a dozen times leaves a dozen live sessions behind. The model's
    /// own long-lived client must never be probed that way.
    static func probe(_ api: AceStreamAPI, disposable: Bool = false) async -> Result<String, Error> {
        defer { if disposable { api.invalidate() } }
        do { return .success(try await api.version().version) } catch { return .failure(error) }
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
        guard let api else {
            currentLink = link
            playbackState = .error("Set the engine address in Settings first.")
            showSettings = true
            return
        }
        currentLink = link
        // Claim the audio route before anything opens the player, so the first frames are
        // audible and the [audio] background mode keeps the stream alive behind the lock
        // screen rather than being cut off mid-handshake.
        activateAudioSession()
        isPaused = false
        let previous = session
        session = nil
        statsTask?.cancel()
        relay?.stop(); relay = nil
        playbackURL = nil
        upstreamDied = false
        playerHasPlayed = false
        // A restarted session has to earn `wasPlaying` again: until video shows, an
        // inactive→active hop must not mistake "still starting" for "died in the
        // background" and cancel the start that is already in flight.
        wasPlaying = false
        playerRetries = 0
        playerWatchdog?.cancel(); playerWatchdog = nil
        stats = nil
        playbackState = .starting
        statsTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let previous { await api.stop(previous); try? await Task.sleep(for: .milliseconds(400)) }
                guard !Task.isCancelled else { return }
                // The engine can be briefly busy right after switching torrents; retry the
                // start. A transport failure is different: the engine is not there at all
                // (wrong address, wrong Wi-Fi), and three 30-second connect timeouts would
                // leave the user staring at "Starting…" for a minute and a half.
                var info: AceStreamAPI.PlaybackInfo?
                var lastErr: Error?
                for attempt in 0..<3 {
                    do { info = try await api.startStream(link); break }
                    catch let error as URLError {
                        // URLSession reports a cancelled task as URLError(.cancelled), not
                        // CancellationError, so stopping or switching links mid-start would
                        // otherwise look like an unreachable engine and overwrite the state
                        // the caller just set.
                        if Task.isCancelled || error.code == .cancelled { return }
                        lastErr = error
                        appendLog("[play] start failed to reach the engine: \(error.localizedDescription)")
                        break
                    }
                    catch {
                        lastErr = error
                        appendLog("[play] start attempt \(attempt + 1) failed: \(error.localizedDescription)")
                        if Task.isCancelled { return }
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
                guard !Task.isCancelled else { return }
                guard let info else {
                    if let transport = lastErr as? URLError {
                        engineStatus = .unreachable(transport.localizedDescription)
                        throw MobileError.engineUnreachable(transport.localizedDescription)
                    }
                    throw lastErr ?? AceStreamAPI.APIError.badResponse
                }
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
                                            let reason = err == nil ? "The engine closed the stream." : "Engine connection lost: \(err!.localizedDescription)"
                                            self.appendLog("[play] upstream ended: \(reason)")
                                            // In the foreground this is usually the engine dropping the
                                            // reader mid-stream, and one silent restart beats an error
                                            // card; it also covers a socket iOS killed while suspended,
                                            // which is only reported once we are back. `wasPlaying` is
                                            // the cap — play() clears it, so the restarted session has
                                            // to show video again before it earns another restart.
                                            // Deaths noticed before that go to `upstreamDied`, which
                                            // `sceneDidBecomeActive` picks up.
                                            if self.sceneActive, self.wasPlaying, let link = self.currentLink {
                                                self.appendLog("[play] restarting \(link.displayName) after the upstream died")
                                                self.play(link)
                                                return
                                            }
                                            self.upstreamDied = true
                                            self.playbackState = .error(reason)
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
        upstreamDied = false
        wasPlaying = false
        playerHasPlayed = false
        playerRetries = 0
        playerWatchdog?.cancel()
        playerWatchdog = nil
        stats = nil
        if let s = session, let api { Task { await api.stop(s) } }
        session = nil
        isPaused = false
        pausedByInterruption = false
        deactivateAudioSession()
        playbackState = .stopped
        if !keepLink { currentLink = nil }
    }

    // MARK: Audio session

    /// Whether this app currently holds an active audio session, so it is deactivated
    /// exactly once and other apps are not told to resume when nothing was playing.
    private var audioSessionActive = false
    /// Set when an interruption (a call, Siri, another player) paused us, so only a pause
    /// *we* caused is undone when the interruption ends.
    private var pausedByInterruption = false
    private var interruptionObserver: NSObjectProtocol?

    /// `.playback` / `.moviePlayback`: audio keeps going when the ringer switch is silent
    /// or the screen locks, which is the whole point of the `audio` background mode.
    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            audioSessionActive = true
        } catch {
            appendLog("[audio] could not activate the audio session: \(error.localizedDescription)")
        }
    }

    /// `.notifyOthersOnDeactivation` hands the route back, so music that was ducked or
    /// paused for us starts again instead of leaving the device silent.
    private func deactivateAudioSession() {
        guard audioSessionActive else { return }
        audioSessionActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            appendLog("[audio] could not deactivate the audio session: \(error.localizedDescription)")
        }
    }

    private func observeAudioInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] note in
            // Read the payload here — the notification itself does not cross to the actor.
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            let shouldResume = options.contains(.shouldResume)
            Task { @MainActor in self?.audioInterrupted(type, shouldResume: shouldResume) }
        }
    }

    private func audioInterrupted(_ type: AVAudioSession.InterruptionType, shouldResume: Bool) {
        switch type {
        case .began:
            guard playbackURL != nil, !isPaused else { return }
            appendLog("[audio] interrupted, pausing playback")
            pausedByInterruption = true
            isPaused = true
        case .ended:
            guard pausedByInterruption else { return }
            pausedByInterruption = false
            guard shouldResume else {
                appendLog("[audio] interruption ended without shouldResume, staying paused")
                return
            }
            // The system deactivated our session for the duration; claim it again before
            // telling the player to run, or the picture resumes with no sound.
            appendLog("[audio] interruption ended, resuming playback")
            audioSessionActive = false
            activateAudioSession()
            isPaused = false
        @unknown default:
            break
        }
    }

    private var playerHasPlayed = false
    private var playerWatchdog: Task<Void, Never>?
    private var playerRetries = 0
    /// Set when the relay's upstream connection to the engine dropped — typically while
    /// the app was backgrounded and iOS tore the socket down.
    private var upstreamDied = false
    /// A session got as far as showing video, so resuming should try to bring it back.
    private var wasPlaying = false
    /// Whether the scene is in the foreground, so an upstream death can be told apart from
    /// one that happened while suspended. Published because the UI stops its auto-hide
    /// timer (and anything else that only makes sense on screen) while we are away.
    @Published private(set) var sceneActive = true

    func playerEvent(_ event: PlayerEvent) {
        guard playbackURL != nil else { return }
        switch event {
        case .opening, .buffering:
            break
        case .playing:
            playerHasPlayed = true
            wasPlaying = true
            playerRetries = 0
            playerWatchdog?.cancel()
            playerWatchdog = nil
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

    // MARK: Scene lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        sceneActive = phase == .active
        switch phase {
        case .active: sceneDidBecomeActive()
        case .background: appendLog("[app] entered background")
        default: break
        }
    }

    /// iOS closes idle sockets while an app is suspended, which kills the relay's upstream
    /// connection to the engine. If a session that had been playing lost its upstream,
    /// restart it from scratch on the way back in — the engine session is cheap to re-open
    /// and the alternative is a frozen picture.
    ///
    /// Only a *confirmed* death restarts: a live relay on an inactive→active hop (Control
    /// Centre, the notification shade, a call) must be left alone, and so must a session
    /// that is still starting.
    func sceneDidBecomeActive() {
        if engineURL != nil, !engineStatus.isReachable { checkEngine() }
        guard wasPlaying, upstreamDied, let link = currentLink else { return }
        appendLog("[app] resumed with a dead stream, restarting \(link.displayName)")
        play(link)
    }

    // MARK: Logging

    func appendLog(_ line: String) {
        FileLog.shared.write(line)
        logBuffer.append(line)
        if logBuffer.count > maxLogLines { logBuffer.removeFirst(logBuffer.count - maxLogLines) }
        // libvlc logs in bursts; publish at most a few times a second.
        if logFlushTask == nil {
            logFlushTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self else { return }
                self.logFlushTask = nil
                self.logLines = self.logBuffer
            }
        }
    }
}

/// Mirrors the in-app log to <caches>/kakaplayer.log, so a stuck session can be inspected
/// from the container without a debugger attached.
final class FileLog {
    static let shared = FileLog()
    private let handle: FileHandle?
    private let queue = DispatchQueue(label: "dev.kakaplayer.filelog")
    private let formatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    private init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("kakaplayer.log")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), (attrs[.size] as? Int ?? 0) > 5_000_000 {
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

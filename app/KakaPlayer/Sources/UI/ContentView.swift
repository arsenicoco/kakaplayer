import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var volume: Double = 100
    @State private var muted = false
    @State private var showChrome = true
    @State private var hideWork: DispatchWorkItem?
    @State private var showVolume = false
    @FocusState private var linkFocused: Bool

    private var isPlaying: Bool { if case .playing = model.playbackState { return true } else { return false } }

    var body: some View {
        VStack(spacing: 0) {
            topChrome
            Spacer(minLength: 0)
            bottomChrome
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .center) {
            ZStack {
                Theme.bg
                PlayerView(url: model.playbackURL, attempt: model.playbackAttempt, volume: muted ? 0 : Int32(volume)) { event in
                    model.playerEvent(event)
                }
                .opacity(model.playbackURL == nil ? 0 : 1)
                .onTapGesture(count: 2) { toggleFullScreen() }
                centerState.padding(.horizontal, 40)
            }
        }
        .overlay {
            if model.showLog {
                logPanel.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .ignoresSafeArea()
        .background(WindowConfigurator())
        .preferredColorScheme(.dark)
        .onContinuousHover { phase in
            if case .active = phase { bumpChrome() }
        }
        .onChange(of: model.playbackState) { _, new in
            if case .playing = new { linkFocused = false }
            bumpChrome()
        }
        .onChange(of: linkFocused) { _, f in if f { bumpChrome() } }
        .onChange(of: model.showLog) { _, on in if on { model.refreshLogSnapshot() }; bumpChrome() }
        .onAppear {
            linkFocused = model.currentLink == nil
            bumpChrome()
        }
    }

    // MARK: Chrome (scrim + bars), fades together on idle

    private var topChrome: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.72), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 132)
                .allowsHitTesting(false)
            topBar
                .padding(.horizontal, 14)
                .padding(.top, 46)   // sit below the floating traffic lights, not under them
        }
        .opacity(showChrome ? 1 : 0)
        .animation(.easeInOut(duration: 0.35), value: showChrome)
    }

    private var bottomChrome: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                .frame(height: 112)
                .allowsHitTesting(false)
            bottomBar
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
        .opacity(showChrome ? 1 : 0)
        .animation(.easeInOut(duration: 0.35), value: showChrome)
    }

    // MARK: Top control bar

    private var topBar: some View {
        HStack(spacing: 10) {

            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                TextField("", text: $model.linkText, prompt: Text("Paste an acestream:// link or 40-character ID").foregroundColor(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(Theme.rounded(14))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($linkFocused)
                    .onSubmit { play() }
                if !model.linkText.isEmpty {
                    Button { model.linkText = ""; linkFocused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(linkFocused ? Theme.accent.opacity(0.8) : Theme.stroke, lineWidth: 1))

            primaryButton
            iconButton(isPlaying || model.playbackState == .starting ? "stop.fill" : "play.fill",
                       active: isPlaying) {
                if model.playbackState == .stopped { play() } else { model.stopPlayback() }
            }
            .opacity(0)   // spacer to balance; real stop is in primaryButton menu below
            .frame(width: 0)

            volumeControl
            iconButton("arrow.up.left.and.arrow.down.right") { toggleFullScreen() }
            iconButton("terminal", active: model.showLog) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { model.showLog.toggle() }
            }
        }
        .frame(height: 52)
    }

    private var primaryButton: some View {
        Button { model.playbackState == .stopped ? play() : model.stopPlayback() } label: {
            HStack(spacing: 7) {
                Image(systemName: model.playbackState == .stopped ? "play.fill" : "stop.fill")
                    .font(.system(size: 12, weight: .bold))
                Text(model.playbackState == .stopped ? "Play" : "Stop")
                    .font(Theme.rounded(13, .semibold))
            }
            .foregroundStyle(.white)
            .frame(height: 40)
            .padding(.horizontal, 18)
            .background {
                if model.playbackState == .stopped {
                    Theme.accentGradient
                } else {
                    Color.white.opacity(0.14)
                }
            }
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.playbackState == .stopped && model.linkText.trimmingCharacters(in: .whitespaces).isEmpty)
        .opacity(model.playbackState == .stopped && model.linkText.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
    }

    private var volumeControl: some View {
        iconButton(muted || volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", active: showVolume) {
            showVolume.toggle()
        }
        .popover(isPresented: $showVolume, arrowEdge: .bottom) {
            HStack(spacing: 12) {
                Button { muted.toggle() } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(Theme.textSecondary)
                }.buttonStyle(.plain)
                Slider(value: $volume, in: 0...150) { editing in if editing { muted = false } }
                    .frame(width: 160)
                Text("\(Int(volume))")
                    .font(Theme.rounded(12, .medium).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 30, alignment: .trailing)
            }
            .padding(14)
            .frame(width: 260)
        }
    }

    private func iconButton(_ symbol: String, active: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
                .frame(width: 40, height: 40)
                .background(Color.white.opacity(active ? 0.12 : 0.001), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(HoverScaleStyle())
    }

    // MARK: Bottom status bar

    private var bottomBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(engineColor).frame(width: 8, height: 8)
                    .shadow(color: engineColor.opacity(0.7), radius: 4)
                Text(model.engineState.label)
                    .font(Theme.rounded(12, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if case .failed = model.engineState {
                Button("Retry") { model.startEngine() }
                    .buttonStyle(PillButtonStyle())
                Button("Reset image") { model.startEngine(reinstall: true) }
                    .buttonStyle(PillButtonStyle())
            }
            Spacer()
            if isPlaying, let link = model.currentLink {
                liveBadge
                Text(link.displayName)
                    .font(Theme.rounded(12, .medium).monospaced())
                    .foregroundStyle(Theme.textTertiary)
            }
            if let s = model.stats, (s.speed_down ?? 0) > 0 || isPlaying {
                statChip("arrow.down", "\(s.speed_down ?? 0) KB/s")
                statChip("person.2.fill", "\(s.peers ?? 0)")
            }
        }
        .frame(height: 34)
    }

    private var liveBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.live).frame(width: 6, height: 6)
            Text("LIVE").font(Theme.rounded(10, .bold)).tracking(0.5)
        }
        .foregroundStyle(Theme.live)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Theme.live.opacity(0.14), in: Capsule())
    }

    private func statChip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(text).font(Theme.rounded(11, .medium).monospacedDigit())
        }
        .foregroundStyle(Theme.textSecondary)
    }

    // MARK: Center states

    @ViewBuilder
    private var centerState: some View {
        switch model.playbackState {
        case .stopped where model.playbackURL == nil:
            idleCard
        case .starting:
            loadingCard(title: model.engineState.isReady ? "Contacting engine" : model.engineState.shortLabel, subtitle: nil, progress: model.installProgress)
        case .prebuffering(let pct):
            loadingCard(title: model.playbackURL == nil ? "Buffering" : "Opening stream", subtitle: statsSubtitle, progress: pct.map { Double($0) / 100 })
        case .error(let msg):
            errorCard(msg)
        default:
            EmptyView()
        }
    }

    private var idleCard: some View {
        VStack(spacing: 18) {
            appMark
                .frame(width: 116, height: 116)
                .shadow(color: .black.opacity(0.45), radius: 14, y: 4)
            VStack(spacing: 6) {
                Text("KakaPlayer").font(Theme.rounded(22, .bold)).foregroundStyle(Theme.textPrimary)
                Text("Paste an Ace Stream link and press Play,\nor click any acestream:// link.")
                    .font(Theme.rounded(13))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// The app's pixel-art mark, kept crisp when scaled.
    @ViewBuilder private var appMark: some View {
        if let url = Bundle.main.url(forResource: "AppMark", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            Image(nsImage: img)
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "play.tv.fill").font(.system(size: 44)).foregroundStyle(Theme.accentGradient)
        }
    }

    private func loadingCard(title: String, subtitle: String?, progress: Double?) -> some View {
        VStack(spacing: 16) {
            ZStack {
                if let progress, progress > 0 {
                    Circle().stroke(Color.white.opacity(0.10), lineWidth: 3).frame(width: 48, height: 48)
                    Circle().trim(from: 0, to: progress)
                        .stroke(Theme.accentGradient, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 48, height: 48)
                        .animation(.easeOut, value: progress)
                } else {
                    RingSpinner(size: 48)
                }
            }
            VStack(spacing: 5) {
                Text(title).font(Theme.rounded(16, .semibold)).foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle).font(Theme.rounded(12).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(30)
        .frame(minWidth: 240)
        .glass(cornerRadius: 22, strong: true)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34)).foregroundStyle(Theme.warn)
            Text("Playback stopped").font(Theme.rounded(16, .semibold)).foregroundStyle(Theme.textPrimary)
            Text(message).font(Theme.rounded(12)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
            if let link = model.currentLink {
                Button {
                    model.play(link)
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(Theme.rounded(13, .semibold))
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .padding(.top, 2)
            }
        }
        .padding(30)
        .frame(minWidth: 260)
        .glass(cornerRadius: 22, strong: true)
    }

    private var statsSubtitle: String? {
        guard let s = model.stats else { return nil }
        if (s.peers ?? 0) == 0 { return "Finding peers…" }
        return "\(s.peers ?? 0) peers · \(s.speed_down ?? 0) KB/s"
    }

    // MARK: Log panel

    private var logPanel: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) {
                HStack {
                    Text("Engine log").font(Theme.rounded(12, .semibold)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { model.showLog = false } } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textTertiary)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                Divider().overlay(Theme.stroke)
                LogView(lines: model.consoleLines)
                    .frame(height: 200)
            }
            .glass(cornerRadius: 20, strong: true)
            .padding(.horizontal, 14)
            .padding(.bottom, 66)
        }
    }

    // MARK: Actions

    private func play() {
        let text = model.linkText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        linkFocused = false
        model.open(text)
    }

    private func toggleFullScreen() { NSApp.keyWindow?.toggleFullScreen(nil) }

    private func bumpChrome() {
        showChrome = true
        NSCursor.unhide()
        hideWork?.cancel()
        // Re-check conditions when the timer fires (3.2s later) rather than now, so a
        // just-changed focus state has settled and we hide only when idle over playback
        // or in full screen.
        let work = DispatchWorkItem {
            let fullscreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false
            guard (self.isPlaying || fullscreen), !self.linkFocused, !self.showVolume, !self.model.showLog else { return }
            withAnimation(.easeInOut(duration: 0.4)) { self.showChrome = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: work)
    }

    private var engineColor: Color {
        switch model.engineState {
        case .ready: return Theme.ok
        case .failed: return Theme.live
        case .idle: return Theme.textTertiary
        default: return Theme.warn
        }
    }
}

// MARK: - Button styles

struct HoverScaleStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : (hover ? 1.08 : 1))
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hover)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
            .onHover { hover = $0 }
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent = false
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? .white : Theme.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background {
                if prominent { Theme.accentGradient }
                else { Color.white.opacity(hover ? 0.16 : 0.09) }
            }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: prominent ? 0 : 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .onHover { hover = $0 }
            .font(Theme.rounded(12, .medium))
    }
}

// MARK: - Log view

struct LogView: View {
    let lines: [String]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(line.contains("error") || line.contains("WARNING") ? Theme.warn.opacity(0.9) : Theme.textSecondary)
                            .textSelection(.enabled)
                            .id(i)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lines.count) { _, n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
        }
    }
}

// MARK: - Window chrome

/// Reaches the hosting NSWindow once and gives it a transparent, full-size-content
/// title bar so the video runs edge to edge behind the floating controls.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { configure(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }
    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        if #available(macOS 11.4, *) { window.titlebarSeparatorStyle = .none }
        window.isMovableByWindowBackground = false
        window.backgroundColor = NSColor(Theme.bg)
        window.appearance = NSAppearance(named: .darkAqua)
        if let toolbar = window.toolbar { toolbar.isVisible = false }
    }
}

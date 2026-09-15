import SwiftUI
import UIKit

/// The iOS half of KakaPlayer's visual language: the same dark, cinematic palette as the
/// Mac app's `Theme`, kept as a separate copy so the two targets share no AppKit-bound code.
enum MobileTheme {
    static let bg = Color(red: 0.043, green: 0.043, blue: 0.063)      // #0B0B10
    static let bgElevated = Color(red: 0.078, green: 0.078, blue: 0.106)
    static let stroke = Color.white.opacity(0.10)
    static let strokeStrong = Color.white.opacity(0.18)
    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.32)

    static let accent = Color(red: 0.44, green: 0.36, blue: 0.98)     // indigo
    static let accent2 = Color(red: 0.92, green: 0.30, blue: 0.62)    // magenta

    static let accentGradient = LinearGradient(
        colors: [accent, accent2],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let live = Color(red: 0.98, green: 0.28, blue: 0.34)
    static let ok = Color(red: 0.30, green: 0.85, blue: 0.55)
    static let warn = Color(red: 0.98, green: 0.72, blue: 0.24)

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// Frosted surface with a hairline stroke for the floating bars — the iOS copy of the
/// Mac app's `GlassSurface`.
///
/// The Mac's plain `.ultraThinMaterial` is not enough here: these bars float over live
/// video, and a saturated frame shows straight through the blur and takes the white
/// glyphs with it. A black wash *over* the blur keeps them readable on any picture while
/// the material still carries the frosted look.
private struct MobileGlass: ViewModifier {
    var cornerRadius: CGFloat = 20
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Color.black.opacity(0.52)
                }
                .clipShape(shape)
            }
            .overlay(shape.strokeBorder(MobileTheme.strokeStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
    }
}

private extension View {
    func mobileGlass(cornerRadius: CGFloat = 20) -> some View {
        modifier(MobileGlass(cornerRadius: cornerRadius))
    }
}

struct ContentView: View {
    @EnvironmentObject var model: MobileModel

    @State private var showControls = true
    /// Crop the video to fill the screen instead of letterboxing it. Double tap toggles it;
    /// it is deliberately per-session rather than persisted, because it only ever makes
    /// sense for the stream currently on screen.
    @State private var aspectFill = false
    @State private var adjustingVolume = false
    @State private var hideTask: Task<Void, Never>?
    @FocusState private var linkFocused: Bool

    /// Widest the floating controls are allowed to get. Without it an iPad stretches a bar
    /// of four buttons and a slider across eleven inches of glass.
    private static let controlsMaxWidth: CGFloat = 540
    private static let controlsHideDelay: Duration = .seconds(3)

    private var isPlaying: Bool { model.playbackState == .playing }
    private var hasVideo: Bool { model.playbackURL != nil }
    private var isIdle: Bool { model.playbackState == .stopped && !hasVideo }

    var body: some View {
        GeometryReader { geo in
            // Size, not the size class: an iPad is `.regular` in both orientations, and a
            // Split View pane is compact while still being wider than it is tall.
            let landscape = geo.size.width > geo.size.height
            Group {
                if landscape { landscapeLayout } else { portraitLayout }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(MobileTheme.bg.ignoresSafeArea())
        .statusBarHidden(hasVideo)
        .persistentSystemOverlays(hasVideo && !showControls ? .hidden : .automatic)
        .sheet(isPresented: $model.showSettings) {
            SettingsView().environmentObject(model)
        }
        .background { hardwareKeyboardShortcuts }
        .onAppear { bumpControls() }
        .onChange(of: model.playbackState) { _, _ in bumpControls() }
        .onChange(of: model.isPaused) { _, _ in bumpControls() }
        .onChange(of: model.showSettings) { _, _ in bumpControls() }
        .onChange(of: linkFocused) { _, _ in bumpControls() }
        .onChange(of: model.sceneActive) { _, _ in bumpControls() }
        .onDisappear { hideTask?.cancel() }
    }

    // MARK: Layouts

    /// Header, a 16:9 stage, then the link field and status lines underneath.
    private var portraitLayout: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                videoLayer(showsPlaceholder: true)
                controlsOverlay(landscape: false)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    linkRow
                    transportRow
                    engineRow
                    statusRow
                }
                .frame(maxWidth: Self.controlsMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    /// Video edge to edge, everything else floating on top of it and inside the safe area.
    private var landscapeLayout: some View {
        ZStack {
            videoLayer(showsPlaceholder: false)
                .ignoresSafeArea()
            if !hasVideo {
                // While there is nothing to watch the stage doubles as the entry form. Once
                // the stream is up this disappears, so the link field never sits over video.
                VStack(spacing: 16) {
                    placeholder
                    linkRow
                    transportRow
                    engineRow
                }
                .frame(maxWidth: Self.controlsMaxWidth)
                .padding(20)
                .mobileGlass(cornerRadius: 24)
                .padding(.horizontal, 24)
            }
            controlsOverlay(landscape: true)
        }
    }

    // MARK: Header (portrait only — landscape has the floating gear instead)

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.tv.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MobileTheme.accentGradient)
            Text("KakaPlayer")
                .font(MobileTheme.rounded(18, .bold))
                .foregroundStyle(MobileTheme.textPrimary)
            Spacer()
            Button { model.showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MobileTheme.textSecondary)
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: The stage

    /// Black, the video, the state placeholder and the scrims the floating bars sit on.
    /// Everything here is one tap target: a tap toggles the controls, a double tap
    /// switches between letterbox and fill.
    private func videoLayer(showsPlaceholder: Bool) -> some View {
        ZStack {
            Color.black
            PlayerView(url: model.playbackURL,
                       attempt: model.playbackAttempt,
                       volume: model.muted ? 0 : Int32(model.volume),
                       paused: model.isPaused,
                       aspectFill: aspectFill) { event in
                model.playerEvent(event)
            }
            .opacity(hasVideo ? 1 : 0)
            if showsPlaceholder && !hasVideo { placeholder }
            scrims
            if model.isPaused && hasVideo { pausedGlyph }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { toggleAspectFill() }
        .onTapGesture { toggleControls() }
    }

    /// Dark gradients top and bottom so white control glyphs stay legible over bright video.
    private var scrims: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.72), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 100)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
                .frame(height: 148)
        }
        .allowsHitTesting(false)
        .opacity(showControls && hasVideo ? 1 : 0)
        .animation(.easeInOut(duration: 0.28), value: showControls)
        .animation(.easeInOut(duration: 0.28), value: hasVideo)
    }

    private var pausedGlyph: some View {
        Image(systemName: "pause.fill")
            .font(.system(size: 34, weight: .bold))
            .foregroundStyle(.white)
            .padding(22)
            .background {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    Circle().fill(Color.black.opacity(0.5))
                }
            }
            .overlay(Circle().strokeBorder(MobileTheme.strokeStrong, lineWidth: 1))
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    @ViewBuilder
    private var placeholder: some View {
        switch model.playbackState {
        case .starting, .prebuffering:
            VStack(spacing: 12) {
                ProgressView().tint(MobileTheme.accent)
                Text(model.playbackState.label)
                    .font(MobileTheme.rounded(13, .medium))
                    .foregroundStyle(MobileTheme.textSecondary)
            }
        case .error(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(MobileTheme.warn)
                Text(message)
                    .font(MobileTheme.rounded(12))
                    .foregroundStyle(MobileTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
        default:
            VStack(spacing: 8) {
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(MobileTheme.accentGradient)
                Text("Paste an Ace Stream link,\nor open an acestream:// link.")
                    .font(MobileTheme.rounded(12))
                    .foregroundStyle(MobileTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: Floating controls

    /// Transport, volume, stats and the gear, laid over the video and auto-hidden while
    /// playing. It is a sibling of the (full-bleed) video rather than a child of it, so the
    /// bars stay inside the safe area — clear of the notch, the home indicator and the
    /// rounded corners in landscape.
    @ViewBuilder
    private func controlsOverlay(landscape: Bool) -> some View {
        if hasVideo || landscape {
            VStack(spacing: 0) {
                overlayTopBar
                Spacer(minLength: 0)
                if hasVideo { overlayBottomBar(landscape: landscape) }
            }
            .padding(.horizontal, landscape ? 20 : 10)
            .padding(.vertical, landscape ? 12 : 8)
            .opacity(showControls ? 1 : 0)
            .animation(.easeInOut(duration: 0.28), value: showControls)
            // Hidden controls must not swallow the tap that brings them back.
            .allowsHitTesting(showControls)
        }
    }

    private var overlayTopBar: some View {
        HStack(spacing: 10) {
            if hasVideo {
                // One dark capsule rather than bare text: over a bright frame the label
                // would otherwise disappear where the scrim has already faded out.
                HStack(spacing: 8) {
                    if isPlaying { liveBadge }
                    if let link = model.currentLink {
                        Text(link.displayName)
                            .font(MobileTheme.rounded(11, .medium).monospaced())
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.5), in: Capsule())
            }
            Spacer(minLength: 0)
            if hasVideo {
                overlayButton(aspectFill ? "rectangle.arrowtriangle.2.inward" : "rectangle.arrowtriangle.2.outward",
                              label: aspectFill ? "Fit video" : "Fill screen") {
                    toggleAspectFill()
                }
            }
            overlayButton("gearshape.fill", label: "Settings") {
                model.showSettings = true
            }
        }
    }

    private func overlayBottomBar(landscape: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            statsLine
            HStack(spacing: landscape ? 14 : 10) {
                overlayButton(model.isPaused ? "play.fill" : "pause.fill",
                              label: model.isPaused ? "Resume" : "Pause",
                              prominent: true) {
                    model.togglePlayPause()
                }
                overlayButton("stop.fill", label: "Stop") { model.stopPlayback() }
                overlayButton(model.muted || model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                              label: model.muted ? "Unmute" : "Mute") {
                    model.toggleMute()
                }
                Slider(value: $model.volume, in: 0...MobileModel.maxVolume) { editing in
                    adjustingVolume = editing
                    if editing { model.muted = false }
                    bumpControls()
                }
                .tint(MobileTheme.accent)
                .accessibilityLabel("Volume")
                .accessibilityValue("\(Int(model.volume)) percent")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: Self.controlsMaxWidth)
        .mobileGlass(cornerRadius: 22)
        .frame(maxWidth: .infinity)   // centred once the cap bites, i.e. on an iPad
    }

    /// One line of what the engine is doing, so the stats are readable without leaving
    /// full screen.
    private var statsLine: some View {
        HStack(spacing: 8) {
            // "Playing" next to a pause glyph reads as a contradiction; say what the
            // transport is actually doing.
            Text(model.isPaused ? "Paused" : model.playbackState.label)
                .font(MobileTheme.rounded(11, .medium))
                .foregroundStyle(isPlaying ? .white.opacity(0.8) : playbackColor)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let s = model.stats {
                statChip("arrow.down", "\(s.speed_down ?? 0) KB/s", tint: .white.opacity(0.8))
                statChip("person.2.fill", "\(s.peers ?? 0)", tint: .white.opacity(0.8))
            }
        }
        .padding(.horizontal, 4)
    }

    private func overlayButton(_ symbol: String, label: String, prominent: Bool = false,
                               _ action: @escaping () -> Void) -> some View {
        Button {
            action()
            bumpControls()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 17 : 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)   // the 44pt minimum touch target
                .background {
                    if prominent { MobileTheme.accentGradient } else { Color.black.opacity(0.5) }
                }
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(prominent ? 0 : 0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Link + transport (portrait column, and the landscape idle card)

    private var linkRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MobileTheme.textTertiary)
            TextField("", text: $model.linkText,
                      prompt: Text("acestream:// link or 40-character ID")
                        .foregroundColor(MobileTheme.textTertiary))
                .font(MobileTheme.rounded(14))
                .foregroundStyle(MobileTheme.textPrimary)
                .focused($linkFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit { play() }
            if model.linkText.isEmpty {
                Button { paste() } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MobileTheme.textSecondary)
                }
                .accessibilityLabel("Paste link")
            } else {
                Button { model.linkText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(MobileTheme.textTertiary)
                }
                .accessibilityLabel("Clear link")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(MobileTheme.bgElevated, in: Capsule())
        .overlay(Capsule().strokeBorder(linkFocused ? MobileTheme.accent.opacity(0.8) : MobileTheme.stroke, lineWidth: 1))
    }

    private var transportRow: some View {
        Button { model.playbackState == .stopped ? play() : model.stopPlayback() } label: {
            HStack(spacing: 8) {
                Image(systemName: model.playbackState == .stopped ? "play.fill" : "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                Text(model.playbackState == .stopped ? "Play" : "Stop")
                    .font(MobileTheme.rounded(15, .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background {
                if model.playbackState == .stopped {
                    MobileTheme.accentGradient
                } else {
                    Color.white.opacity(0.14)
                }
            }
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(playDisabled)
        .opacity(playDisabled ? 0.5 : 1)
    }

    private var playDisabled: Bool {
        model.playbackState == .stopped && model.linkText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Status

    private var engineRow: some View {
        Button { model.showSettings = true } label: {
            HStack(spacing: 10) {
                Circle().fill(engineColor).frame(width: 8, height: 8)
                    .shadow(color: engineColor.opacity(0.7), radius: 4)
                Text(model.engineStatus.label)
                    .font(MobileTheme.rounded(13, .medium))
                    .foregroundStyle(MobileTheme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MobileTheme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .background(MobileTheme.bgElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(MobileTheme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var engineColor: Color {
        switch model.engineStatus {
        case .reachable: return MobileTheme.ok
        case .checking: return MobileTheme.warn
        case .unreachable: return MobileTheme.live
        case .notConfigured: return MobileTheme.textTertiary
        }
    }

    private var statusRow: some View {
        HStack(spacing: 12) {
            if isPlaying { liveBadge }
            Text(model.playbackState.label)
                .font(MobileTheme.rounded(13, .medium))
                .foregroundStyle(playbackColor)
                .lineLimit(2)
            Spacer(minLength: 6)
            if let s = model.stats, (s.speed_down ?? 0) > 0 || isPlaying || !isIdle {
                statChip("arrow.down", "\(s.speed_down ?? 0) KB/s")
                statChip("person.2.fill", "\(s.peers ?? 0)")
            }
        }
    }

    private var playbackColor: Color {
        if case .error = model.playbackState { return MobileTheme.warn }
        return MobileTheme.textSecondary
    }

    private var liveBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(MobileTheme.live).frame(width: 6, height: 6)
            Text("LIVE").font(MobileTheme.rounded(10, .bold)).tracking(0.5)
        }
        .foregroundStyle(MobileTheme.live)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(MobileTheme.live.opacity(0.14), in: Capsule())
    }

    private func statChip(_ symbol: String, _ text: String,
                          tint: Color = MobileTheme.textSecondary) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(text).font(MobileTheme.rounded(11, .medium).monospacedDigit())
        }
        .foregroundStyle(tint)
    }

    // MARK: Hardware keyboard (iPad, or an iPhone with a keyboard attached)

    /// Invisible, zero-size buttons: on iOS `.keyboardShortcut` only exists on a control, and
    /// these give an attached keyboard the Mac app's Space / S / M keys without putting
    /// anything on screen. They are dropped entirely while a text field has focus or the
    /// Settings sheet is up, so a bare "s" types an "s" rather than stopping the stream.
    @ViewBuilder
    private var hardwareKeyboardShortcuts: some View {
        if !linkFocused && !model.showSettings {
            VStack {
                Button("Play or pause") { model.togglePlayPause(); bumpControls() }
                    .keyboardShortcut(.space, modifiers: [])
                    .accessibilityHidden(true)
                Button("Stop") { model.stopPlayback(); bumpControls() }
                    .keyboardShortcut("s", modifiers: [])
                    .accessibilityHidden(true)
                Button("Mute") { model.toggleMute(); bumpControls() }
                    .keyboardShortcut("m", modifiers: [])
                    .accessibilityHidden(true)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    // MARK: Actions

    private func play() {
        let text = model.linkText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        linkFocused = false
        model.open(text)
    }

    private func paste() {
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        model.linkText = text
    }

    private func toggleControls() {
        if showControls {
            hideTask?.cancel()
            hideTask = nil
            withAnimation(.easeInOut(duration: 0.28)) { showControls = false }
        } else {
            bumpControls()
        }
    }

    private func toggleAspectFill() {
        guard hasVideo else { return }
        aspectFill.toggle()
        bumpControls()
    }

    /// Shows the controls and restarts the idle timer. They only ever hide over live video:
    /// with nothing playing there is nothing to look at underneath them.
    private func bumpControls() {
        hideTask?.cancel()
        hideTask = nil
        if !showControls { withAnimation(.easeInOut(duration: 0.28)) { showControls = true } }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: Self.controlsHideDelay)
            guard !Task.isCancelled else { return }
            // Re-checked now rather than when the timer was armed, so a state that changed
            // in the meantime (paused, a focused field, a finger on the slider) wins.
            guard isPlaying, !model.isPaused, model.sceneActive,
                  !model.showSettings, !linkFocused, !adjustingVolume else { return }
            withAnimation(.easeInOut(duration: 0.35)) { showControls = false }
        }
    }
}

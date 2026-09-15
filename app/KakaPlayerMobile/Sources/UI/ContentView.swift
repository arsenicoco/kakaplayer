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

struct ContentView: View {
    @EnvironmentObject var model: MobileModel

    private var isPlaying: Bool { model.playbackState == .playing }
    private var isIdle: Bool { model.playbackState == .stopped && model.playbackURL == nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            playerArea
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    linkRow
                    transportRow
                    engineRow
                    statusRow
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(MobileTheme.bg.ignoresSafeArea())
        .sheet(isPresented: $model.showSettings) {
            SettingsView().environmentObject(model)
        }
    }

    // MARK: Header

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

    // MARK: Player

    private var playerArea: some View {
        ZStack {
            Color.black
            PlayerView(url: model.playbackURL,
                       attempt: model.playbackAttempt,
                       volume: 100,
                       paused: false) { event in
                model.playerEvent(event)
            }
            .opacity(model.playbackURL == nil ? 0 : 1)
            if model.playbackURL == nil { placeholder }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 0, style: .continuous))
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
                Text("Paste an Ace Stream link below,\nor open an acestream:// link.")
                    .font(MobileTheme.rounded(12))
                    .foregroundStyle(MobileTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: Link + transport

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
        .overlay(Capsule().strokeBorder(MobileTheme.stroke, lineWidth: 1))
    }

    private var transportRow: some View {
        HStack(spacing: 12) {
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
            .disabled(playDisabled)
            .opacity(playDisabled ? 0.5 : 1)
        }
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

    private func statChip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(text).font(MobileTheme.rounded(11, .medium).monospacedDigit())
        }
        .foregroundStyle(MobileTheme.textSecondary)
    }

    // MARK: Actions

    private func play() {
        let text = model.linkText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        model.open(text)
    }

    private func paste() {
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        model.linkText = text
    }
}

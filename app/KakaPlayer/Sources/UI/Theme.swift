import SwiftUI

/// Visual language for KakaPlayer: a dark, cinematic palette with a single
/// indigo→magenta accent used sparingly for the play affordance and live cues.
enum Theme {
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

/// A frosted-glass surface with a hairline stroke, used for the floating bars and cards.
struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 16
    var strong: Bool = false
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(strong ? Theme.strokeStrong : Theme.stroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 8)
    }
}

extension View {
    func glass(cornerRadius: CGFloat = 16, strong: Bool = false) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, strong: strong))
    }
}

/// A soft, animated spinner ring used in loading states.
struct RingSpinner: View {
    var size: CGFloat = 40
    var lineWidth: CGFloat = 3
    @State private var spin = false
    var body: some View {
        Circle()
            .trim(from: 0.06, to: 0.72)
            .stroke(Theme.accentGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

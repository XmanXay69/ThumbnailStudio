import SwiftUI

/// Cinema-dark palette, v2. The chrome dropped to near-black and lost its
/// hairline borders — elevation now comes from tone, the way Resolve and
/// Premiere do it, so the footage and waveforms are the only bright things
/// on screen and panels read as surfaces instead of outlined boxes.
enum Theme {
    static let background = Color(red: 0.027, green: 0.027, blue: 0.035)
    static let surface = Color(red: 0.055, green: 0.055, blue: 0.071)
    static let surfaceRaised = Color(red: 0.090, green: 0.090, blue: 0.114)
    /// Kept for focus rings and genuine separators — panels no longer use it.
    static let border = Color(red: 0.20, green: 0.20, blue: 0.26)

    static let accent = Color(red: 0.569, green: 0.275, blue: 1.0)     // Twitch purple
    static let accentDim = Color(red: 0.569, green: 0.275, blue: 1.0).opacity(0.35)
    /// The CTA gradient — one per screen, so it stays special.
    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.569, green: 0.275, blue: 1.0),
                 Color(red: 0.42, green: 0.36, blue: 1.0)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let positive = Color(red: 0.25, green: 0.80, blue: 0.55)
    static let warning = Color(red: 0.98, green: 0.72, blue: 0.30)
    static let danger = Color(red: 0.95, green: 0.35, blue: 0.40)

    static let textPrimary = Color(red: 0.925, green: 0.929, blue: 0.945)
    static let textSecondary = Color(red: 0.60, green: 0.62, blue: 0.68)
    static let textFaint = Color(red: 0.38, green: 0.40, blue: 0.46)

    static let waveform = Color(red: 0.62, green: 0.45, blue: 1.0)
    static let waveformDim = Color(red: 0.30, green: 0.26, blue: 0.44)
    static let playhead = Color(red: 1.0, green: 0.85, blue: 0.35)
}

/// The one gradient-filled call to action per screen.
struct HeroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Theme.accentGradient)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: Theme.accent.opacity(configuration.isPressed ? 0 : 0.35),
                    radius: 8, y: 2)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension View {
    /// Standard panel treatment: borderless surface, elevation by tone.
    func panel(padding: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    func monoDigits() -> some View {
        font(.system(.body, design: .monospaced).monospacedDigit())
    }
}

// MARK: - Type scale
//
// The audio panel's big monospace number was the best-looking thing in the
// app, so it became the system: hero numbers for what a panel measures,
// one quiet label beside them. Numbers are what this app produces.

/// A measured value at hero size: `StatText(value: "6.0 dB", label: "voice
/// above game", tint: Theme.positive)`.
struct StatText: View {
    var value: String
    var label: String = ""
    var tint: Color = Theme.textPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(value)
                .font(.system(size: 22, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(tint)
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// The ⓘ affordance that replaced the walls of standing body copy: the
/// writing survives, but it speaks when asked instead of continuously.
struct InfoTip: View {
    let text: String
    @State private var shown = false

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textFaint)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .frame(width: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
        .help(text)
    }
}

/// A section header with its explainer folded into a tip.
struct SectionHeader: View {
    let title: String
    var tip: String?

    var body: some View {
        HStack(spacing: 5) {
            SectionLabel(text: title)
            if let tip { InfoTip(tip) }
            Spacer()
        }
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.textFaint)
    }
}

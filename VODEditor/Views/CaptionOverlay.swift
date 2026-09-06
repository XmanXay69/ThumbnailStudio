import SwiftUI

/// Live caption preview drawn over the player using the project's real style.
///
/// This is what makes captions visible at all: the styling values are otherwise
/// abstract numbers that only become real at export. Everything here mirrors
/// what `ASSBuilder` writes, so the preview and the burned-in result agree.
struct CaptionOverlay: View {
    let line: CaptionLine?
    let style: CaptionStyle
    let time: Double
    /// Height of the frame the style was authored against — 1920 for vertical
    /// shorts, 1080 for the horizontal long-form cut.
    let referenceHeight: CGFloat

    var body: some View {
        GeometryReader { geometry in
            if let line, !line.text.isEmpty {
                let scale = geometry.size.height / referenceHeight
                let size = max(9, CGFloat(style.fontSize) * scale)
                let margin = CGFloat(style.marginVertical) * scale

                caption(size: size, scale: scale)
                    .frame(maxWidth: geometry.size.width * 0.86)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: alignment)
                    .padding(.bottom, style.position == .bottom ? margin : 0)
                    .padding(.top, style.position == .top ? margin : 0)
            }
        }
        .allowsHitTesting(false)
    }

    private var alignment: Alignment {
        switch style.position {
        case .top: return .top
        case .center: return .center
        case .bottom: return .bottom
        }
    }

    @ViewBuilder
    private func caption(size: CGFloat, scale: CGFloat) -> some View {
        let content = text(size: size)
            .multilineTextAlignment(.center)
            .lineLimit(nil)

        if style.useBox {
            content
                .padding(.horizontal, 10 * scale)
                .padding(.vertical, 5 * scale)
                .background(style.boxColor.swiftUIColor)
        } else {
            // libass strokes an outline around the glyphs; approximate it by
            // stamping the text in the outline colour behind itself.
            content.background(outline(size: size, scale: scale))
        }
    }

    private func outline(size: CGFloat, scale: CGFloat) -> some View {
        let width = max(0, style.outlineWidth * scale)
        return ZStack {
            if width > 0 {
                ForEach(0..<8, id: \.self) { index in
                    let angle = Double(index) / 8 * 2 * .pi
                    text(size: size, forceColor: style.outline)
                        .multilineTextAlignment(.center)
                        .offset(x: CGFloat(cos(angle)) * width,
                                y: CGFloat(sin(angle)) * width)
                }
            }
        }
    }

    /// Word-by-word highlighting when karaoke is on, matching the per-word
    /// events `ASSBuilder` emits.
    private func text(size: CGFloat, forceColor: CaptionColor? = nil) -> Text {
        guard let line else { return Text("") }
        let font = Font.custom(style.fontName, size: size)

        if let forceColor {
            return Text(line.text).font(font).foregroundColor(forceColor.swiftUIColor)
        }

        guard style.karaoke, !line.words.isEmpty else {
            return Text(line.text).font(font).foregroundColor(style.fill.swiftUIColor)
        }

        return line.words.reduce(Text("")) { partial, word in
            let active = time >= word.start && time < word.end
            return partial + Text(word.text)
                .font(font)
                .foregroundColor(active ? style.highlightColor.swiftUIColor : style.fill.swiftUIColor)
        }
    }
}

/// Looks up the cue under a source timestamp — used by Browse, where there's no
/// clip to rebase against.
enum CaptionPreview {
    /// Binary search over the pre-grouped cue list. Cues are ordered and
    /// disjoint, so the last one that has started is the only candidate.
    static func line(at time: Double, in cues: [CaptionLine]) -> CaptionLine? {
        guard let first = cues.first, time >= first.start else { return nil }
        var low = 0, high = cues.count - 1, found = 0
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        let cue = cues[found]
        return time < cue.end ? cue : nil
    }
}

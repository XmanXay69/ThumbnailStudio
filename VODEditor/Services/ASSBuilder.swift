import Foundation

/// Generates ASS subtitle files for burn-in.
///
/// ASS is used rather than SRT because it carries the styling natively — font,
/// fill, outline, box, alignment, margins — so what the review UI previews is
/// what libass renders into the export.
enum ASSBuilder {
    static let renderWidth = 1080
    static let renderHeight = 1920

    static func makeFile(lines: [CaptionLine], style: CaptionStyle,
                         width: Int = renderWidth, height: Int = renderHeight) -> String {
        var output = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: \(width)
        PlayResY: \(height)
        WrapStyle: 2
        ScaledBorderAndShadow: yes
        YCbCr Matrix: TV.709

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        \(styleLine(style))

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """

        for line in lines {
            output += events(for: line, style: style)
        }
        return output
    }

    private static func styleLine(_ style: CaptionStyle) -> String {
        // BorderStyle 3 draws an opaque box behind the text; 1 is outline only.
        let borderStyle = style.useBox ? 3 : 1
        let back = style.useBox ? style.boxColor : CaptionColor(red: 0, green: 0, blue: 0, alpha: 0.5)
        let fields: [String] = [
            "Default",
            style.fontName,
            String(style.fontSize),
            style.fill.assValue,
            style.highlightColor.assValue,
            style.outline.assValue,
            back.assValue,
            "0", "0", "0", "0",          // bold, italic, underline, strikeout
            "100", "100", "0", "0",      // scaleX, scaleY, spacing, angle
            String(borderStyle),
            String(format: "%.1f", style.outlineWidth),
            String(format: "%.1f", style.shadow),
            String(style.position.assAlignment),
            "60", "60",                  // marginL, marginR
            String(style.marginVertical),
            "1",
        ]
        return "Style: " + fields.joined(separator: ",")
    }

    /// In karaoke mode each word gets its own event so exactly one word is
    /// highlighted at a time — `\k` would progressively fill the line instead,
    /// which is not the look shorts use.
    private static func events(for line: CaptionLine, style: CaptionStyle) -> String {
        let tokens = displayTokens(for: line, style: style)
        guard !tokens.isEmpty else { return "" }

        let rows = wrap(tokens.map(\.text), limit: style.maxCharactersPerLine)

        guard style.karaoke, tokens.count > 1 else {
            let text = rows
                .map { row in row.map(escape).joined(separator: " ") }
                .joined(separator: "\\N")
            return dialogue(start: line.start, end: line.end, text: text)
        }

        var output = ""
        for (index, token) in tokens.enumerated() {
            let start = index == 0 ? line.start : token.start
            let end = index == tokens.count - 1 ? line.end : tokens[index + 1].start
            guard end > start else { continue }
            output += dialogue(start: start, end: end,
                               text: highlighted(rows: rows, activeIndex: index, style: style))
        }
        return output
    }

    private struct DisplayToken {
        var text: String
        var start: Double
    }

    private static func displayTokens(for line: CaptionLine, style: CaptionStyle) -> [DisplayToken] {
        let words = line.words
            .map { DisplayToken(text: $0.text.trimmingCharacters(in: .whitespaces), start: $0.start) }
            .filter { !$0.text.isEmpty }
        if !words.isEmpty { return words }

        // No word timings (a retyped line with no split): fall back to a static
        // line spanning the whole caption.
        let plain = line.text.split(separator: " ").map(String.init)
        guard !plain.isEmpty else { return [] }
        return plain.map { DisplayToken(text: $0, start: line.start) }
    }

    /// Rebuilds the wrapped rows with one word wrapped in colour overrides.
    private static func highlighted(rows: [[String]], activeIndex: Int, style: CaptionStyle) -> String {
        var flatIndex = 0
        var renderedRows: [String] = []
        for row in rows {
            var pieces: [String] = []
            for word in row {
                if flatIndex == activeIndex {
                    pieces.append("{\\c\(style.highlightColor.assValue)}\(escape(word)){\\c\(style.fill.assValue)}")
                } else {
                    pieces.append(escape(word))
                }
                flatIndex += 1
            }
            renderedRows.append(pieces.joined(separator: " "))
        }
        return renderedRows.joined(separator: "\\N")
    }

    private static func wrap(_ words: [String], limit: Int) -> [[String]] {
        guard limit > 0 else { return [words] }
        var rows: [[String]] = []
        var current: [String] = []
        var length = 0
        for word in words {
            let addition = current.isEmpty ? word.count : word.count + 1
            if !current.isEmpty, length + addition > limit {
                rows.append(current)
                current = [word]
                length = word.count
            } else {
                current.append(word)
                length += addition
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    private static func dialogue(start: Double, end: Double, text: String) -> String {
        "Dialogue: 0,\(timecode(start)),\(timecode(end)),Default,,0,0,0,,\(text)\n"
    }

    /// ASS wants H:MM:SS.cc with exactly two centisecond digits.
    ///
    /// Derived from one rounded centisecond count — splitting seconds from the
    /// fraction and truncating drops a centisecond on values stored just below
    /// their decimal form.
    static func timecode(_ seconds: Double) -> String {
        let total = max(0, Int((max(0, seconds) * 100).rounded()))
        return String(format: "%d:%02d:%02d.%02d",
                      total / 360_000,
                      (total % 360_000) / 6000,
                      (total % 6000) / 100,
                      total % 100)
    }

    /// Braces start override blocks and backslashes start tags, so both have to
    /// be neutralised in user-supplied caption text.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\u{200B}")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

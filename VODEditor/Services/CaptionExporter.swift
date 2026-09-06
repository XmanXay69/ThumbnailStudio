import Foundation

/// How captions reach the viewer.
///
/// Burned-in captions are "open" — pixels, always visible, and what shorts
/// platforms expect since their players don't surface subtitle tracks. A soft
/// track is what "closed captions" actually means: a separate stream the viewer
/// can switch off, which YouTube reads and indexes.
enum CaptionMode: String, Codable, CaseIterable {
    case none
    case burned
    case soft
    case both

    var label: String {
        switch self {
        case .none: return "None"
        case .burned: return "Burned in"
        case .soft: return "Closed (toggleable)"
        case .both: return "Both"
        }
    }

    var burnsIn: Bool { self == .burned || self == .both }
    var embedsTrack: Bool { self == .soft || self == .both }
}

enum CaptionFileFormat: String, Codable, CaseIterable {
    case srt
    case vtt

    var fileExtension: String { rawValue }
    var label: String { rawValue.uppercased() }
}

/// Writes caption sidecar files. Separate from `ASSBuilder`: ASS carries the
/// styling for burn-in, whereas SRT/VTT are plain text that players style
/// themselves.
enum CaptionExporter {
    static func contents(lines: [CaptionLine], format: CaptionFileFormat) -> String {
        switch format {
        case .srt: return srt(lines: lines)
        case .vtt: return vtt(lines: lines)
        }
    }

    static func srt(lines: [CaptionLine]) -> String {
        var output = ""
        for (index, line) in lines.enumerated() {
            output += "\(index + 1)\n"
            output += "\(timecode(line.start, separator: ",")) --> \(timecode(line.end, separator: ","))\n"
            output += "\(wrap(line.text))\n\n"
        }
        return output
    }

    static func vtt(lines: [CaptionLine]) -> String {
        var output = "WEBVTT\n\n"
        for line in lines {
            output += "\(timecode(line.start, separator: ".")) --> \(timecode(line.end, separator: "."))\n"
            output += "\(wrap(line.text))\n\n"
        }
        return output
    }

    /// `HH:MM:SS,mmm` for SRT, `HH:MM:SS.mmm` for VTT.
    ///
    /// Derived from a single rounded millisecond count. Splitting the seconds
    /// and the fraction separately and truncating loses a millisecond whenever
    /// the value is stored just below its decimal form — 1.039 becomes `,038` —
    /// and rounding the fraction on its own can carry to `,1000`.
    static func timecode(_ seconds: Double, separator: String) -> String {
        let total = max(0, Int((max(0, seconds) * 1000).rounded()))
        return String(format: "%02d:%02d:%02d%@%03d",
                      total / 3_600_000,
                      (total % 3_600_000) / 60_000,
                      (total % 60_000) / 1000,
                      separator,
                      total % 1000)
    }

    /// Subtitle convention is at most two lines per cue.
    private static func wrap(_ text: String, limit: Int = 42) -> String {
        let words = text.split(separator: " ").map(String.init)
        guard words.count > 1 else { return text }

        var rows: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if candidate.count > limit, !current.isEmpty {
                rows.append(current)
                current = word
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { rows.append(current) }

        // Collapse to two lines; anything longer reads worse than a wide line.
        if rows.count > 2 {
            let midpoint = (rows.count + 1) / 2
            rows = [rows.prefix(midpoint).joined(separator: " "),
                    rows.suffix(from: midpoint).joined(separator: " ")]
        }
        return rows.joined(separator: "\n")
    }
}

import CoreGraphics
import Foundation

enum ShortStatus: String, Codable {
    case candidate
    case accepted
    case discarded
}

struct CaptionColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    static let white = CaptionColor(red: 1, green: 1, blue: 1)
    static let black = CaptionColor(red: 0, green: 0, blue: 0)
    static let highlight = CaptionColor(red: 1, green: 0.85, blue: 0.2)

    /// ASS colours are `&HAABBGGRR` — alpha inverted (00 opaque) and BGR order.
    var assValue: String {
        func channel(_ value: Double) -> Int { Int((max(0, min(1, value)) * 255).rounded()) }
        let inverseAlpha = 255 - channel(alpha)
        return String(format: "&H%02X%02X%02X%02X",
                      inverseAlpha, channel(blue), channel(green), channel(red))
    }
}

enum CaptionPosition: String, Codable, CaseIterable {
    case top, center, bottom

    var label: String { rawValue.capitalized }

    /// ASS numpad alignment, centred horizontally.
    var assAlignment: Int {
        switch self {
        case .bottom: return 2
        case .center: return 5
        case .top: return 8
        }
    }
}

struct CaptionStyle: Codable, Equatable {
    var fontName: String = "Impact"
    var fontSize: Int = 76
    var fill: CaptionColor = .white
    var outline: CaptionColor = .black
    var outlineWidth: Double = 4
    var shadow: Double = 0
    var useBox: Bool = false
    var boxColor: CaptionColor = CaptionColor(red: 0, green: 0, blue: 0, alpha: 0.6)
    var position: CaptionPosition = .bottom
    var marginVertical: Int = 220
    var karaoke: Bool = true
    var highlightColor: CaptionColor = .highlight
    var uppercase: Bool = true
    var maxCharactersPerLine: Int = 24

    /// Whisper's segments are whole sentences — 15 to 25 words is normal, which
    /// is unreadable burned into a short. Phrase grouping recuts them.
    var grouping: CaptionGrouping = .phrase
    var wordsPerCue: Int = 7

    static let standard = CaptionStyle()

    /// Fonts that read well burned into vertical video. Availability is checked
    /// at runtime — most of these are not installed by default on macOS.
    static let suggestedFonts = [
        "Impact", "Anton", "Montserrat", "Bangers", "Futura",
        "Helvetica Neue", "Avenir Next Condensed", "Arial Black", "SF Pro Display",
    ]
}

/// A rectangle in a source frame, stored as fractions so it survives a change
/// of resolution — the same webcam box works whether the source is 1080p or
/// 720p.
struct NormalizedRect: Codable, Equatable {
    var x: Double       // left edge, 0…1
    var y: Double       // top edge, 0…1
    var width: Double   // 0…1
    var height: Double  // 0…1

    /// A cam-sized box in the top-right corner, where overlays usually sit.
    static let defaultCam = NormalizedRect(x: 0.72, y: 0.04, width: 0.26, height: 0.26)

    /// A tall centred slice of the source, for the gameplay box.
    static let defaultGameplay = NormalizedRect(x: 0.28, y: 0, width: 0.44, height: 1)

    /// A full-height, centred 9:16 window of a 16:9 source — the classic single
    /// crop. 607.5 px wide of 1920 is exactly 9:16 at full height. Correct for
    /// 16:9; other aspects are cover-fit to 9:16 on export.
    static let defaultFill = NormalizedRect(x: 0.3418, y: 0, width: 0.31641, height: 1)

    var centerX: Double { x + width / 2 }
    var centerY: Double { y + height / 2 }

    func clamped() -> NormalizedRect {
        let w = min(1, max(0.05, width))
        let h = min(1, max(0.05, height))
        return NormalizedRect(x: min(1 - w, max(0, x)), y: min(1 - h, max(0, y)),
                              width: w, height: h)
    }
}

/// A corner of a box, for resize handles. The resize maths lives here rather
/// than in the view so it can be tested.
enum BoxCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    /// Resizes `base` by dragging this corner, keeping the opposite corner
    /// fixed. `dx`/`dy` are fractions of the frame.
    func resize(_ base: NormalizedRect, dx: Double, dy: Double) -> NormalizedRect {
        var r = base
        switch self {
        case .bottomRight:
            r.width = base.width + dx; r.height = base.height + dy
        case .bottomLeft:
            r.x = base.x + dx; r.width = base.width - dx; r.height = base.height + dy
        case .topRight:
            r.y = base.y + dy; r.width = base.width + dx; r.height = base.height - dy
        case .topLeft:
            r.x = base.x + dx; r.y = base.y + dy
            r.width = base.width - dx; r.height = base.height - dy
        }
        return r
    }

    /// Resizes with the height locked to the width by `heightPerWidth`, so the
    /// rectangle keeps a fixed shape — the single crop stays exactly 9:16, which
    /// is what makes the box on screen equal to the exported frame. Width comes
    /// from the horizontal drag; the opposite corner stays fixed.
    func resizeLocked(_ base: NormalizedRect, dx: Double, heightPerWidth: Double,
                      maxWidth: Double) -> NormalizedRect {
        let anchorRight = self == .topLeft || self == .bottomLeft
        let anchorBottom = self == .topLeft || self == .topRight
        let signedWidth = anchorRight ? base.width - dx : base.width + dx
        let width = min(max(0.05, signedWidth), maxWidth)
        let height = width * heightPerWidth
        let rightEdge = base.x + base.width
        let bottomEdge = base.y + base.height
        let x = anchorRight ? rightEdge - width : base.x
        let y = anchorBottom ? bottomEdge - height : base.y
        return NormalizedRect(x: x, y: y, width: width, height: height)
    }
}

enum ShortLayoutMode: String, Codable, CaseIterable {
    /// One 9:16 crop filling the whole frame — the original behaviour.
    case fill
    /// Two stacked boxes: the gameplay, and the webcam on its own.
    case split

    var label: String {
        switch self {
        case .fill: return "Single"
        case .split: return "Cam + gameplay"
        }
    }
}

/// How a short frames the 1080×1920 output.
///
/// `split` is the layout Twitch's portrait clips use: the webcam gets its own
/// box so the face isn't buried in a corner of a shrunk-down gameplay crop, and
/// the gameplay fills the rest.
struct ShortLayout: Codable, Equatable {
    var mode: ShortLayoutMode = .fill
    /// Which part of the source the single crop shows. A resizable rectangle,
    /// locked to 9:16 in the editor, so it can be zoomed and repositioned — not
    /// only slid sideways.
    var fillRect: NormalizedRect = .defaultFill
    /// Where the webcam sits in the *source* frame.
    var camRect: NormalizedRect = .defaultCam
    /// Which part of the source fills the gameplay box. A free rectangle so it
    /// can be moved and cropped like the cam, rather than only slid sideways.
    var gameRect: NormalizedRect = .defaultGameplay
    /// Fraction of the 1920-tall output given to the cam box.
    var camFraction: Double = 0.34
    /// Cam box on top (true) or bottom (false).
    var camOnTop: Bool = true

    static let fill = ShortLayout()

    init(mode: ShortLayoutMode = .fill, fillRect: NormalizedRect = .defaultFill,
         camRect: NormalizedRect = .defaultCam, gameRect: NormalizedRect = .defaultGameplay,
         camFraction: Double = 0.34, camOnTop: Bool = true) {
        self.mode = mode
        self.fillRect = fillRect
        self.camRect = camRect
        self.gameRect = gameRect
        self.camFraction = camFraction
        self.camOnTop = camOnTop
    }

    /// Hand-written so a layout saved by an earlier build (which had no
    /// `fillRect` or `gameRect`) still loads with sensible defaults rather than
    /// collapsing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        mode = value(.mode, ShortLayoutMode.fill)
        fillRect = value(.fillRect, .defaultFill)
        camRect = value(.camRect, .defaultCam)
        gameRect = value(.gameRect, .defaultGameplay)
        camFraction = value(.camFraction, 0.34)
        camOnTop = value(.camOnTop, true)
    }
}

struct ShortCandidate: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var start: Double
    var end: Double
    var peakTime: Double
    var score: Double
    var components: [String: Double] = [:]
    var title: String = ""
    var status: ShortStatus = .candidate

    /// Horizontal centre of the vertical crop, 0…1 across the source width.
    var cropCenterX: Double = 0.5

    /// How this clip frames the 1080×1920 output.
    var layout: ShortLayout = .fill

    /// Transcript segment id → replacement text. Whisper will mishear slang and
    /// usernames; fixing one has to be a text edit, not a re-run.
    var captionEdits: [String: String] = [:]

    var styleOverride: CaptionStyle?
    var exportedPath: String?
    /// When this clip actually went up — per candidate, because one VOD
    /// feeds many posts across many days.
    var postedAt: Date?
    /// The banger pass's 0-100 "would this stop a scroll" — heuristic
    /// blended with the local model's read when one ran.
    var marketability: Double?
    /// The line the clip should open on, from the model.
    var hookLine: String?

    var duration: Double { end - start }

    func overlap(with other: ShortCandidate) -> Double {
        max(0, min(end, other.end) - max(start, other.start))
    }

    /// Restores the memberwise initializer that the custom decoder below would
    /// otherwise suppress.
    init(id: UUID = UUID(), start: Double, end: Double, peakTime: Double, score: Double,
         components: [String: Double] = [:], title: String = "",
         status: ShortStatus = .candidate, cropCenterX: Double = 0.5,
         layout: ShortLayout = .fill, captionEdits: [String: String] = [:],
         styleOverride: CaptionStyle? = nil, exportedPath: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.peakTime = peakTime
        self.score = score
        self.components = components
        self.title = title
        self.status = status
        self.cropCenterX = cropCenterX
        self.layout = layout
        self.captionEdits = captionEdits
        self.styleOverride = styleOverride
        self.exportedPath = exportedPath
    }

    /// Hand-written so a new field never invalidates a `shorts.json` already on
    /// disk. The synthesized decoder ignores property defaults and treats every
    /// non-optional key as required, which made `layout` a breaking change for
    /// clips saved by an earlier build.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        id = value(.id, UUID())
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decode(Double.self, forKey: .end)
        peakTime = value(.peakTime, (start + end) / 2)
        score = value(.score, 0)
        components = value(.components, [String: Double]())
        title = value(.title, "")
        status = value(.status, ShortStatus.candidate)
        cropCenterX = value(.cropCenterX, 0.5)
        layout = value(.layout, ShortLayout.fill)
        captionEdits = value(.captionEdits, [String: String]())
        styleOverride = try? container.decodeIfPresent(CaptionStyle.self, forKey: .styleOverride)
        exportedPath = try? container.decodeIfPresent(String.self, forKey: .exportedPath)
        postedAt = try? container.decodeIfPresent(Date.self, forKey: .postedAt)
        marketability = try? container.decodeIfPresent(Double.self, forKey: .marketability)
        hookLine = try? container.decodeIfPresent(String.self, forKey: .hookLine)
    }
}

/// One rendered caption line, with times relative to the clip's own start.
struct CaptionLine: Identifiable, Equatable {
    var id: Int
    var start: Double
    var end: Double
    var text: String
    var words: [TranscriptWord]
}

enum CaptionBuilder {
    /// The cues that actually get rendered — phrase-length by default.
    static func lines(for candidate: ShortCandidate,
                      transcript: Transcript,
                      style: CaptionStyle) -> [CaptionLine] {
        CaptionPhraser.regroup(editableLines(for: candidate, transcript: transcript, style: style),
                               style: style)
    }

    /// One line per transcript segment, with the user's text edits applied and
    /// all times rebased to the clip.
    ///
    /// Kept separate from `lines` because corrections belong at sentence
    /// granularity: a mistranscribed username is fixed once, and the phrase
    /// splitting happens downstream of it.
    static func editableLines(for candidate: ShortCandidate,
                              transcript: Transcript,
                              style: CaptionStyle) -> [CaptionLine] {
        func cased(_ value: String) -> String { style.uppercase ? value.uppercased() : value }

        var lines = transcript.segments
            .filter { $0.end > candidate.start && $0.start < candidate.end }
            .map { segment -> CaptionLine in
                let edited = candidate.captionEdits[String(segment.id)]
                let text = edited ?? segment.text
                let start = max(0, segment.start - candidate.start)
                let end = min(candidate.duration, segment.end - candidate.start)

                // Word timings only survive if the line wasn't retyped; a rough
                // even split is better than dropping karaoke entirely.
                let words: [TranscriptWord]
                if edited == nil {
                    words = segment.words.map {
                        TranscriptWord(text: cased($0.text),
                                       start: max(0, $0.start - candidate.start),
                                       end: min(candidate.duration, $0.end - candidate.start),
                                       probability: $0.probability)
                    }
                } else {
                    words = redistribute(text: cased(text), from: start, to: end)
                }

                return CaptionLine(id: segment.id, start: start, end: max(start, end),
                                   text: cased(text), words: words)
            }
            .sorted { $0.start < $1.start }

        // whisper's segments overlap in time, and libass stacks overlapping
        // events — two captions on screen at once. One line at a time.
        for index in lines.indices.dropLast() where lines[index].end > lines[index + 1].start {
            lines[index].end = lines[index + 1].start
        }

        return lines.filter { $0.end > $0.start }
    }

    /// Cues for the whole transcript in source time, for the Browse preview.
    ///
    /// The preview has to show exactly what the export will burn in, and a
    /// phrase can run across a segment boundary — so it can't be derived from
    /// the segment under the playhead alone. Grouping the whole transcript once
    /// and looking the answer up is both exact and cheaper than re-deriving a
    /// window on every frame.
    static func lines(transcript: Transcript, style: CaptionStyle) -> [CaptionLine] {
        func cased(_ value: String) -> String { style.uppercase ? value.uppercased() : value }

        var lines = transcript.segments.map { segment in
            CaptionLine(id: segment.id, start: segment.start, end: segment.end,
                        text: cased(segment.text),
                        words: segment.words.map {
                            TranscriptWord(text: cased($0.text), start: $0.start, end: $0.end,
                                           probability: $0.probability)
                        })
        }
        for index in lines.indices.dropLast() where lines[index].end > lines[index + 1].start {
            lines[index].end = lines[index + 1].start
        }
        return CaptionPhraser.regroup(lines.filter { $0.end > $0.start }, style: style)
    }

    /// Even split across the line's span — used when text was retyped and the
    /// original per-word timings no longer correspond to anything.
    static func redistribute(text: String, from start: Double, to end: Double) -> [TranscriptWord] {
        let tokens = text.split(separator: " ").map(String.init)
        guard !tokens.isEmpty, end > start else { return [] }
        let step = (end - start) / Double(tokens.count)
        return tokens.enumerated().map { index, token in
            TranscriptWord(text: (index == 0 ? "" : " ") + token,
                           start: start + step * Double(index),
                           end: start + step * Double(index + 1),
                           probability: 1)
        }
    }
}

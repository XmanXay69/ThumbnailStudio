import Foundation

/// How caption cues get cut up.
enum CaptionGrouping: String, Codable, CaseIterable {
    /// Whisper's own segments — whole sentences, frequently 15–25 words. Right
    /// for a subtitle track, far too much text for a short.
    case sentence
    /// Fixed-length phrases. What short-form captions actually look like.
    case phrase

    var label: String {
        switch self {
        case .sentence: return "Sentences"
        case .phrase: return "Phrases"
        }
    }
}

/// Recuts sentence-length caption lines into short phrases.
///
/// The word timings come from whisper's DTW pass, so a phrase's in and out
/// points are the real first and last word — no interpolation, no drift. The
/// splitting itself is deliberately not purely arithmetic: cutting strictly
/// every N words lands mid-clause about as often as not, so a break is pulled
/// forward or pushed back a word or two to land on punctuation or a pause.
enum CaptionPhraser {
    /// A gap this long between words always forces a break. Below it, two
    /// segments are treated as continuous speech and can share a cue.
    static let breakGap: Double = 0.65

    /// Cues shorter than this flash by unreadably; they're held longer when
    /// there's room before the next one.
    static let minimumOnScreen: Double = 0.55

    /// A cue is extended to meet the next one when the hole between them is
    /// smaller than this, so captions don't strobe between phrases.
    static let bridgeGap: Double = 0.35

    static func regroup(_ lines: [CaptionLine], style: CaptionStyle) -> [CaptionLine] {
        guard style.grouping == .phrase, style.wordsPerCue > 0, !lines.isEmpty else { return lines }

        let words = flatten(lines)
        guard !words.isEmpty else { return lines }

        let target = max(1, style.wordsPerCue)
        var cues: [CaptionLine] = []
        var current: [TranscriptWord] = []

        for (index, word) in words.enumerated() {
            current.append(word)

            let isLast = index == words.count - 1
            let nextStartsAfterPause = !isLast && words[index + 1].start - word.end > breakGap
            if isLast || nextStartsAfterPause || shouldBreak(after: word, count: current.count, target: target) {
                cues.append(cue(from: current, id: cues.count))
                current = []
            }
        }
        if !current.isEmpty { cues.append(cue(from: current, id: cues.count)) }

        // Holding a cue longer must never push it past the end of the clip it
        // belongs to — the exporter bounds the render at exactly that point.
        return settle(cues, limit: lines.map(\.end).max() ?? .greatestFiniteMagnitude)
    }

    /// Break decision for a cue that already contains `count` words.
    ///
    /// A cue never spans two sentences: a full stop always ends it, however few
    /// words it holds. A comma only breaks once the cue is nearly full, and past
    /// the target everything breaks regardless.
    private static func shouldBreak(after word: TranscriptWord, count: Int, target: Int) -> Bool {
        if count >= target { return true }
        guard let last = word.text.trimmingCharacters(in: .whitespaces).last else { return false }
        if endsSentence(last) { return true }
        if ",;:—".contains(last) { return count >= max(2, target - 2) }
        return false
    }

    private static func endsSentence(_ character: Character) -> Bool {
        ".?!…".contains(character)
    }

    /// One cue from its words, with the leading-space convention `ASSBuilder`
    /// and the preview overlay both rely on: first word bare, the rest prefixed.
    private static func cue(from words: [TranscriptWord], id: Int) -> CaptionLine {
        let normalized = words.enumerated().map { index, word -> TranscriptWord in
            let text = word.text.trimmingCharacters(in: .whitespaces)
            return TranscriptWord(text: index == 0 ? text : " " + text,
                                  start: word.start, end: word.end,
                                  probability: word.probability)
        }
        let text = normalized.map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let start = normalized.first?.start ?? 0
        let end = max(start, normalized.last?.end ?? start)
        return CaptionLine(id: id, start: start, end: end, text: text, words: normalized)
    }

    /// Holds short cues on screen longer and closes small holes, without ever
    /// letting one cue reach into the next.
    private static func settle(_ cues: [CaptionLine], limit: Double) -> [CaptionLine] {
        var output = cues
        for index in output.indices {
            let ceiling = index + 1 < output.count ? output[index + 1].start : limit
            output[index].start = min(output[index].start, limit)
            if output[index].end - output[index].start < minimumOnScreen {
                output[index].end = min(ceiling, output[index].start + minimumOnScreen)
            }
            if ceiling - output[index].end < bridgeGap {
                output[index].end = max(output[index].end, min(ceiling, output[index].end + bridgeGap))
            }
            output[index].end = min(output[index].end, ceiling)
        }
        return output.filter { $0.end > $0.start && !$0.text.isEmpty }
    }

    /// Words across every line, in order and disjoint. A line whose text was
    /// retyped has no usable per-word timing, so it gets an even split across
    /// its own span — the same fallback the karaoke renderer uses.
    ///
    /// Whisper's segments overlap each other in time — 465 of them on the test
    /// VOD — and so, at the seams, do their words. A cue takes its in and out
    /// points from its own first and last word, so the stream has to be made
    /// strictly disjoint first. Overlaps are resolved by nudging the later word
    /// forward rather than clamping the earlier one, which would collapse it to
    /// zero length and drop it.
    private static func flatten(_ lines: [CaptionLine]) -> [TranscriptWord] {
        var words: [TranscriptWord] = []
        for line in lines {
            let named = line.words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            let usable = named.filter { $0.end > $0.start }
            if !usable.isEmpty, usable.count == named.count {
                words.append(contentsOf: usable)
            } else {
                words.append(contentsOf: CaptionBuilder.redistribute(text: line.text,
                                                                     from: line.start, to: line.end))
            }
        }
        // Sorted globally, not per line. Because segments overlap, a word from
        // the next one can start before the last word of this one — sorting is
        // what stops a karaoke highlight jumping backwards mid-cue. The cost is
        // that such a pair reads in time order rather than in the transcript's
        // order; that is the right trade for something drawn on screen.
        words.sort { $0.start < $1.start }

        var cursor = -Double.greatestFiniteMagnitude
        for index in words.indices {
            let start = max(words[index].start, cursor)
            words[index].start = start
            words[index].end = max(words[index].end, start + 0.02)
            cursor = words[index].end
        }
        return words
    }
}

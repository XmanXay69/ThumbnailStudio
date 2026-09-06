import Foundation

struct TranscriptWord: Codable, Equatable {
    var text: String
    var start: Double
    var end: Double
    var probability: Double
}

struct TranscriptSegment: Codable, Equatable, Identifiable {
    var id: Int
    var start: Double
    var end: Double
    var text: String
    var words: [TranscriptWord]

    func contains(_ time: Double) -> Bool { time >= start && time < end }
}

struct Transcript: Codable, Equatable {
    var segments: [TranscriptSegment] = []

    var isEmpty: Bool { segments.isEmpty }
    var duration: Double { segments.last?.end ?? 0 }

    var plainText: String {
        segments.map(\.text).joined(separator: " ")
    }

    /// Index of the last segment that has started by `time`.
    ///
    /// Binary search on `start` only — whisper's segments genuinely overlap
    /// (a segment's end routinely runs past the next one's start), so a search
    /// that assumed disjoint `start..<end` ranges could land on a stale line
    /// mid-overlap. Starts are non-decreasing, so this stays well-defined.
    ///
    /// During a gap it keeps reporting the preceding segment, which is what
    /// makes the transcript view hold position through silence.
    func indexOfSegment(at time: Double) -> Int? {
        guard !segments.isEmpty, time >= segments[0].start else { return nil }
        var low = 0
        var high = segments.count - 1
        var found = 0
        while low <= high {
            let mid = (low + high) / 2
            if segments[mid].start <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    func segment(at time: Double) -> TranscriptSegment? {
        indexOfSegment(at: time).map { segments[$0] }
    }

    func activeWordIndex(in segment: TranscriptSegment, at time: Double) -> Int? {
        segment.words.firstIndex { time >= $0.start && time < $0.end }
    }
}

// MARK: - whisper-cli JSON

/// Decoder for `whisper-cli -oj -ojf` output. Written defensively: field
/// presence varies with whisper.cpp version and with whether `-dtw` produced
/// usable token timings.
enum WhisperJSON {
    private struct Root: Decodable {
        let transcription: [Entry]?
    }

    private struct Offsets: Decodable {
        let from: Double?
        let to: Double?
    }

    private struct Token: Decodable {
        let text: String?
        let offsets: Offsets?
        let p: Double?
        let t_dtw: Double?
    }

    private struct Entry: Decodable {
        let text: String?
        let offsets: Offsets?
        let tokens: [Token]?
    }

    /// Special tokens whisper emits inline, e.g. `[_BEG_]`, `[_TT_120]`.
    private static func isSpecial(_ text: String) -> Bool {
        text.hasPrefix("[_") || text.hasPrefix("<|")
    }

    /// Fills in word starts that DTW couldn't place (~13% of tokens in
    /// practice) by spreading them evenly between the nearest known
    /// neighbours, then forces the result to be non-decreasing.
    static func interpolate(_ starts: [Double?], segmentStart: Double, segmentEnd: Double) -> [Double] {
        guard !starts.isEmpty else { return [] }
        var result = [Double](repeating: segmentStart, count: starts.count)

        var previousIndex: Int?
        for index in starts.indices {
            guard let value = starts[index] else { continue }
            if let previous = previousIndex, index - previous > 1 {
                let from = result[previous]
                let steps = Double(index - previous)
                for gap in (previous + 1)..<index {
                    result[gap] = from + (value - from) * Double(gap - previous) / steps
                }
            } else if previousIndex == nil, index > 0 {
                // Leading run with no DTW anchor.
                for gap in 0..<index {
                    result[gap] = segmentStart + (value - segmentStart) * Double(gap) / Double(index)
                }
            }
            result[index] = value
            previousIndex = index
        }

        if let last = previousIndex {
            // Trailing run: spread out to the segment end.
            if last < starts.count - 1 {
                let from = result[last]
                let steps = Double(starts.count - last)
                for gap in (last + 1)..<starts.count {
                    result[gap] = from + (segmentEnd - from) * Double(gap - last) / steps
                }
            }
        } else {
            // No DTW at all — distribute evenly across the segment so the
            // highlight still tracks roughly with speech.
            let span = max(segmentEnd - segmentStart, 0)
            for index in starts.indices {
                result[index] = segmentStart + span * Double(index) / Double(starts.count)
            }
        }

        for index in 1..<result.count where result[index] < result[index - 1] {
            result[index] = result[index - 1]
        }
        return result
    }

    /// Spreads runs of identical start times across the gap up to the next
    /// distinct timestamp, so every word ends up with a non-zero span.
    static func spreadCollisions(_ starts: inout [Double], segmentEnd: Double) {
        guard starts.count > 1 else { return }
        var index = 0
        while index < starts.count {
            var runEnd = index
            while runEnd + 1 < starts.count, starts[runEnd + 1] == starts[index] { runEnd += 1 }

            if runEnd > index {
                let from = starts[index]
                let next = runEnd + 1 < starts.count ? starts[runEnd + 1] : segmentEnd
                let span = max(next - from, 0)
                let steps = Double(runEnd - index + 1)
                for offset in 1...(runEnd - index) {
                    starts[index + offset] = from + span * Double(offset) / steps
                }
            }
            index = runEnd + 1
        }
    }

    /// Parses one chunk's JSON, shifting every timestamp by the chunk's offset
    /// into the full VOD.
    static func parse(data: Data, timeOffset: Double, startingID: Int) throws -> [TranscriptSegment] {
        let root = try JSONDecoder().decode(Root.self, from: data)
        guard let entries = root.transcription else { return [] }

        // Pass 1: pull out text and DTW anchors. Per-token `offsets` are
        // unusable here — every token repeats the segment start and `to` is
        // frequently smaller than `from` — so only `t_dtw` is trusted.
        //
        // whisper also emits *subword* tokens ("don" + "'t") and standalone
        // punctuation. A leading space marks a real word boundary; anything
        // else continues the previous word.
        struct RawEntry {
            var start: Double
            var end: Double
            var text: String
            var texts: [String]
            var starts: [Double?]
            var probabilities: [Double]
        }

        var raws: [RawEntry] = []
        raws.reserveCapacity(entries.count)

        for entry in entries {
            let text = (entry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            var raw = RawEntry(
                start: (entry.offsets?.from ?? 0) / 1000 + timeOffset,   // ms
                end: (entry.offsets?.to ?? 0) / 1000 + timeOffset,
                text: text, texts: [], starts: [], probabilities: []
            )

            for token in entry.tokens ?? [] {
                guard let tokenText = token.text, !isSpecial(tokenText) else { continue }
                guard !tokenText.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

                let anchor: Double? = (token.t_dtw ?? -1) >= 0
                    ? token.t_dtw! / 100 + timeOffset       // t_dtw is in 10ms units
                    : nil

                if !tokenText.hasPrefix(" "), let last = raw.texts.indices.last {
                    raw.texts[last] += tokenText
                    if raw.starts[last] == nil { raw.starts[last] = anchor }
                    raw.probabilities[last] = min(raw.probabilities[last], token.p ?? 0)
                } else {
                    raw.texts.append(tokenText)
                    raw.starts.append(anchor)
                    raw.probabilities.append(token.p ?? 0)
                }
            }
            raws.append(raw)
        }

        // The full large-v3 model (not turbo) emits roughly half its segments
        // TWICE: a zero-length entry carrying the segment's own text, then a
        // full-length entry carrying that text plus the next segment's.
        // Keeping both doubles every word in the merged transcript, so the
        // pair collapses to one segment — the pure text, spanning to where
        // the doubled entry ended. Turbo never produces the pattern, so this
        // never fires on its output.
        var deduped: [RawEntry] = []
        deduped.reserveCapacity(raws.count)
        var rawIndex = 0
        while rawIndex < raws.count {
            var raw = raws[rawIndex]
            var consumed = rawIndex + 1
            if consumed < raws.count {
                let next = raws[consumed]
                let zeroLength = raw.end - raw.start < 0.02
                let sameStart = abs(next.start - raw.start) < 0.02
                let extended = next.text.hasPrefix(raw.text) && next.text.count > raw.text.count
                if zeroLength, sameStart, extended {
                    raw.end = max(next.end, raw.start + 0.05)
                    consumed += 1
                }
            }
            // It also stutters: the same short text emitted repeatedly over
            // the *identical* span. Two segments can't genuinely occupy the
            // same instant saying the same thing, so exact repeats collapse.
            while consumed < raws.count,
                  raws[consumed].text == raw.text,
                  abs(raws[consumed].start - raw.start) < 0.02,
                  abs(raws[consumed].end - raw.end) < 0.02 {
                consumed += 1
            }
            deduped.append(raw)
            rawIndex = consumed
        }
        raws = deduped

        // Pass 2: resolve word timings. DTW routinely places a segment's last
        // words *after* that segment's own `offsets.to` (it did so for more
        // than half the segments on a real 4-hour VOD), so the terminal bound
        // comes from the next segment's start rather than the stale `to`.
        var segments: [TranscriptSegment] = []
        segments.reserveCapacity(raws.count)
        var nextID = startingID

        for (index, raw) in raws.enumerated() {
            let lastAnchor = raw.starts.compactMap { $0 }.last ?? raw.end
            var terminal = max(raw.end, lastAnchor + 0.3)
            if index + 1 < raws.count, raws[index + 1].start > lastAnchor + 0.05 {
                terminal = min(terminal, raws[index + 1].start)
            }
            terminal = max(terminal, lastAnchor + 0.05)

            var resolved = Self.interpolate(raw.starts, segmentStart: raw.start, segmentEnd: terminal)
            // Neighbouring words often land on the same 10 ms DTW frame; left
            // alone they'd have zero duration and never highlight.
            Self.spreadCollisions(&resolved, segmentEnd: terminal)
            // DTW tends to anchor the first word up to a second after the
            // segment's own start, which would leave a stretch of each line
            // with nothing highlighted. The segment start is the better
            // estimate of when the line begins.
            if !resolved.isEmpty { resolved[0] = min(resolved[0], raw.start) }

            var words: [TranscriptWord] = []
            words.reserveCapacity(raw.texts.count)
            for (wordIndex, text) in raw.texts.enumerated() {
                let wordStart = resolved[wordIndex]
                let wordEnd = wordIndex + 1 < resolved.count ? resolved[wordIndex + 1] : terminal
                words.append(TranscriptWord(text: text, start: wordStart,
                                            end: max(wordStart, wordEnd),
                                            probability: raw.probabilities[wordIndex]))
            }

            // Keep the segment's own span covering its words, or the transcript
            // view would stop highlighting before the line finishes.
            let segmentEnd = max(raw.end, words.last?.end ?? raw.end)
            segments.append(TranscriptSegment(id: nextID, start: raw.start,
                                              end: max(segmentEnd, raw.start),
                                              text: raw.text, words: words))
            nextID += 1
        }

        // The full model's DTW tails spill past the next segment's start far
        // more often than turbo's, which would leave overlapping caption
        // cues. Final sweep: each segment — words included — is clamped to
        // where the next one begins, so the timeline is strictly disjoint.
        for index in segments.indices.dropLast() {
            let limit = segments[index + 1].start
            guard segments[index].end > limit,
                  limit > segments[index].start + 0.05 else { continue }
            segments[index].end = limit
            for wordIndex in segments[index].words.indices {
                let word = segments[index].words[wordIndex]
                let start = min(word.start, limit - 0.02)
                segments[index].words[wordIndex] = TranscriptWord(
                    text: word.text, start: start,
                    end: min(max(start, word.end), limit),
                    probability: word.probability)
            }
        }
        return segments
    }
}

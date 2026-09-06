import Foundation

/// The free signals — no model, no network, milliseconds of work. They feed
/// the analysis prompt as hints, and they're also the working fallback when
/// the local model isn't available. For Twitch specifically they're strong:
/// a KEKW wall IS a funny moment, whoever's counting.
enum ClipSignals {
    // MARK: Emote spikes

    struct EmoteSpike: Equatable {
        var time: Double
        var categoryID: UUID
        /// Matching messages inside the window — bigger wall, stronger signal.
        var strength: Int
    }

    /// Windows where a category's emotes spike well above that VOD's own
    /// baseline. Thresholding against the baseline matters: a chat that types
    /// KEKW constantly says nothing when it does it once more.
    static func emoteSpikes(chat: [ChatMessage], categories: [ClipCategory],
                            window: Double = 10) -> [EmoteSpike] {
        guard !chat.isEmpty else { return [] }
        var spikes: [EmoteSpike] = []
        for category in categories where !category.emoteHints.isEmpty {
            let hints = category.emoteHints.map { $0.lowercased() }
            let hits = chat.compactMap { message -> Double? in
                let lowered = message.body.lowercased()
                return hints.contains(where: { lowered.contains($0) }) ? message.offset : nil
            }
            guard hits.count >= 6 else { continue }
            // Baseline: matching messages per window across the whole VOD.
            let span = max(1, (chat.last!.offset - chat.first!.offset))
            let baseline = Double(hits.count) * window / span
            let threshold = max(4, baseline * 3)

            var index = 0
            while index < hits.count {
                var end = index
                while end + 1 < hits.count, hits[end + 1] - hits[index] <= window { end += 1 }
                let count = end - index + 1
                if Double(count) >= threshold {
                    spikes.append(EmoteSpike(time: hits[index], categoryID: category.id,
                                             strength: count))
                    index = end + 1
                } else {
                    index += 1
                }
            }
        }
        return spikes.sorted { $0.time < $1.time }
    }

    // MARK: Chat reading

    /// Moments where the streamer echoes text that appeared in chat 2–15
    /// seconds earlier — chat interaction identified with no semantics at all.
    /// Fuzzy: enough of the message's words, in the transcript, shortly after.
    static func chatReadingMoments(transcript: Transcript, chat: [ChatMessage],
                                   minWords: Int = 4, overlap: Double = 0.7) -> [Double] {
        guard !chat.isEmpty, !transcript.isEmpty else { return [] }
        var moments: [Double] = []
        var segmentIndex = 0
        let segments = transcript.segments

        for message in chat {
            let words = significantWords(message.body)
            guard words.count >= minWords else { continue }
            // Advance to segments that could echo this message (2–15s later).
            while segmentIndex < segments.count,
                  segments[segmentIndex].end < message.offset + 2 { segmentIndex += 1 }
            var probe = segmentIndex
            var spoken = ""
            while probe < segments.count, segments[probe].start <= message.offset + 15 {
                spoken += " " + segments[probe].text.lowercased()
                probe += 1
            }
            guard !spoken.isEmpty else { continue }
            let matched = words.filter { spoken.contains($0) }.count
            if Double(matched) / Double(words.count) >= overlap {
                moments.append(message.offset + 2)
            }
        }
        // Collapse bursts — reading one message word by word is one moment.
        var collapsed: [Double] = []
        for moment in moments where collapsed.last.map({ moment - $0 > 20 }) ?? true {
            collapsed.append(moment)
        }
        return collapsed
    }

    private static func significantWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
    }

    // MARK: Monologues

    struct Monologue: Equatable {
        var start: Double
        var end: Double
    }

    /// Long stretches of continuous speech with few pauses and quiet chat —
    /// the story-time signature. These are exactly the moments a pure energy
    /// filter throws away, which is why they get their own path.
    static func monologues(transcript: Transcript, chat: [ChatMessage],
                           minDuration: Double = 45, maxGap: Double = 2.5) -> [Monologue] {
        guard !transcript.isEmpty else { return [] }
        var runs: [Monologue] = []
        var runStart = transcript.segments[0].start
        var runEnd = transcript.segments[0].end

        func close() {
            if runEnd - runStart >= minDuration {
                runs.append(Monologue(start: runStart, end: runEnd))
            }
        }
        for segment in transcript.segments.dropFirst() {
            if segment.start - runEnd <= maxGap {
                runEnd = max(runEnd, segment.end)
            } else {
                close()
                runStart = segment.start
                runEnd = segment.end
            }
        }
        close()

        guard !chat.isEmpty else { return runs }
        // Busy chat means it's a bit, not a story. Keep runs whose chat rate
        // is below the VOD's own average.
        let span = max(1, chat.last!.offset - chat.first!.offset)
        let averageRate = Double(chat.count) / span
        return runs.filter { run in
            let inRun = chat.lazy.filter { $0.offset >= run.start && $0.offset < run.end }.count
            let rate = Double(inRun) / max(1, run.end - run.start)
            return rate <= averageRate * 1.1
        }
    }

    // MARK: Pre-filter

    /// The interesting slices of the VOD — roughly the top quarter by the
    /// existing score curve, PLUS every long monologue even when quiet. This
    /// is what keeps a six-hour VOD from going through the model whole, and
    /// the monologue path is what keeps story time from being filtered out.
    static func interestWindows(curve: ScoreCurve, duration: Double,
                                monologues: [Monologue],
                                keepFraction: Double = 0.25,
                                pad: Double = 45) -> [ClosedRange<Double>] {
        var windows: [ClosedRange<Double>] = []
        if !curve.isEmpty {
            let sorted = curve.values.sorted(by: >)
            let cutIndex = min(sorted.count - 1, max(0, Int(Double(sorted.count) * keepFraction)))
            // The percentile alone degenerates when most of the VOD is flat
            // dead air — the cut lands on the flat value and keeps all of it.
            // Requiring at least the curve's own mean drops that floor while
            // leaving a uniformly-interesting curve fully kept.
            let mean = curve.values.reduce(0, +) / Double(curve.values.count)
            let threshold = max(sorted[cutIndex], mean)
            var index = 0
            let values = curve.values
            while index < values.count {
                if values[index] >= threshold {
                    var end = index
                    while end + 1 < values.count, values[end + 1] >= threshold { end += 1 }
                    let start = max(0, Double(index) * curve.windowSeconds - pad)
                    let stop = min(duration, Double(end + 1) * curve.windowSeconds + pad)
                    windows.append(start...stop)
                    index = end + 1
                } else {
                    index += 1
                }
            }
        } else {
            windows.append(0...duration)
        }
        for monologue in monologues {
            windows.append(max(0, monologue.start - 10)...min(duration, monologue.end + 10))
        }
        return merge(windows)
    }

    static func merge(_ windows: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        guard !windows.isEmpty else { return [] }
        let sorted = windows.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = [sorted[0]]
        for window in sorted.dropFirst() {
            if window.lowerBound <= merged[merged.count - 1].upperBound + 1 {
                let last = merged.removeLast()
                merged.append(last.lowerBound...max(last.upperBound, window.upperBound))
            } else {
                merged.append(window)
            }
        }
        return merged
    }

    // MARK: Chunk planning

    /// Analysis windows over the interesting slices: ~10 minutes each with
    /// 2.5 minutes of overlap. Local models degrade with long context, so the
    /// chunks stay small and numerous rather than long and few.
    static func planChunks(windows: [ClosedRange<Double>],
                           chunkSeconds: Double = 600,
                           overlap: Double = 150) -> [AutoClipChunk] {
        var chunks: [AutoClipChunk] = []
        var index = 0
        for window in windows {
            var start = window.lowerBound
            repeat {
                let end = min(window.upperBound, start + chunkSeconds)
                chunks.append(AutoClipChunk(index: index, start: start, end: end))
                index += 1
                if end >= window.upperBound { break }
                start = end - overlap
            } while true
        }
        return chunks
    }
}

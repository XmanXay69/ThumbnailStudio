import Foundation

/// A voice-match guess, not diarization: the streamer's mic sits hotter in
/// the mix than voices coming through game audio (the audio tuner measures
/// exactly this gap), so two level clusters over the transcript segments
/// separate "you" from "someone else" — usually right, occasionally
/// confidently wrong, and it says which it is via `reliable`.
enum SpeakerLabelService {
    struct Result: Equatable {
        /// Segment id → true when the guess is "you".
        var isYou: [Int: Bool] = [:]
        /// How far apart the two level clusters sit, in cluster-σ units.
        var separation: Double = 0
        /// False when the mix doesn't split into two levels — one person
        /// talking, or a bed that swallows the gap. UI hides guesses then.
        var reliable: Bool = false
    }

    /// Median waveform peak per segment → 2-means in log level → the hotter
    /// cluster is the mic. Pure; the session feeds it what it already holds.
    static func classify(segments: [(id: Int, start: Double, end: Double)],
                         peaks: [UInt8], peaksPerSecond: Double) -> Result {
        guard peaksPerSecond > 0, !peaks.isEmpty, segments.count >= 6 else { return Result() }

        var levels: [(id: Int, level: Double)] = []
        for segment in segments {
            let lower = max(0, Int(segment.start * peaksPerSecond))
            let upper = min(peaks.count, Int(segment.end * peaksPerSecond))
            guard upper > lower + 1 else { continue }
            let slice = peaks[lower..<upper].sorted()
            let median = Double(slice[slice.count / 2])
            guard median > 2 else { continue }
            levels.append((segment.id, log(median)))
        }
        guard levels.count >= 6 else { return Result() }

        // 2-means over the log levels, seeded at the quartiles.
        let sorted = levels.map(\.level).sorted()
        var low = sorted[sorted.count / 4]
        var high = sorted[(sorted.count * 3) / 4]
        for _ in 0..<24 {
            var lowSum = 0.0, lowN = 0.0, highSum = 0.0, highN = 0.0
            for entry in levels {
                if abs(entry.level - low) <= abs(entry.level - high) {
                    lowSum += entry.level; lowN += 1
                } else {
                    highSum += entry.level; highN += 1
                }
            }
            guard lowN > 0, highN > 0 else { return Result() }
            let newLow = lowSum / lowN
            let newHigh = highSum / highN
            if abs(newLow - low) < 1e-6, abs(newHigh - high) < 1e-6 { break }
            low = newLow
            high = newHigh
        }

        var result = Result()
        var spreadSum = 0.0
        var lowCount = 0
        for entry in levels {
            let you = abs(entry.level - high) < abs(entry.level - low)
            result.isYou[entry.id] = you
            let centre = you ? high : low
            spreadSum += (entry.level - centre) * (entry.level - centre)
            if !you { lowCount += 1 }
        }
        let sigma = (spreadSum / Double(levels.count)).squareRoot()
        // Zero spread means the clusters are perfectly tight — the split is
        // as reliable as it gets, not division-by-zero unreliable.
        result.separation = sigma > 0.0001
            ? (high - low) / sigma
            : (high - low > 0.2 ? 99 : 0)
        // Two real speakers: clusters far apart AND both actually populated.
        let minority = min(lowCount, levels.count - lowCount)
        result.reliable = result.separation > 1.6
            && minority >= max(2, levels.count / 10)
        return result
    }
}

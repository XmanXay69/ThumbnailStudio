import Foundation

struct CandidateOptions: Codable, Equatable {
    var minDuration: Double = 15
    var maxDuration: Double = 60
    var targetCount: Int = 30
    /// Peak threshold, in standard deviations above the mean score.
    var thresholdSigma: Double = 1.0
    /// Two clips of the same moment are the same clip; reject above this.
    var maxOverlapRatio: Double = 0.15

    static let standard = CandidateOptions()
}

enum CandidateService {
    /// Picks shorts candidates from the score curve: local maxima above
    /// threshold, expanded to a self-contained window, snapped to speech
    /// boundaries, then deduplicated so one loud moment yields one clip.
    static func generate(curve: ScoreCurve,
                         transcript: Transcript,
                         silence: [SilenceInterval],
                         duration: Double,
                         options: CandidateOptions = .standard) -> [ShortCandidate] {
        guard !curve.isEmpty, duration > 0 else { return [] }

        let values = curve.values
        let mean = values.reduce(0, +) / Double(values.count)
        let standardDeviation = sqrt(values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count))
        let threshold = mean + options.thresholdSigma * standardDeviation

        // A peak must dominate its neighbourhood, otherwise a broad loud
        // stretch produces dozens of adjacent "peaks".
        let neighbourhood = Int(6 / curve.windowSeconds)
        var peaks: [(index: Int, value: Double)] = []
        for index in values.indices where values[index] >= threshold {
            let lower = max(0, index - neighbourhood)
            let upper = min(values.count - 1, index + neighbourhood)
            var isPeak = true
            for other in lower...upper where values[other] > values[index] { isPeak = false; break }
            if isPeak { peaks.append((index, values[index])) }
        }

        peaks.sort { $0.value > $1.value }

        var accepted: [ShortCandidate] = []

        for peak in peaks {
            guard accepted.count < options.targetCount else { break }
            let peakTime = Double(peak.index) * curve.windowSeconds

            // The floor has to sit above the curve's mean, or the window grows
            // straight through ordinary content until it hits the 60s cap.
            // Tying it to the peak keeps each clip on its own elevated region.
            let floor = max(mean + 0.25 * standardDeviation, peak.value * 0.65)

            var (start, end) = expand(around: peak.index, values: values,
                                      floor: floor, window: curve.windowSeconds,
                                      options: options)
            (start, end) = snapToSpeech(start: start, end: end, peakTime: peakTime,
                                        silence: silence, duration: duration, options: options)

            let candidate = ShortCandidate(
                start: start, end: end, peakTime: peakTime, score: peak.value,
                components: curve.breakdown(from: start, to: end),
                title: title(for: start, to: end, peakTime: peakTime, transcript: transcript)
            )

            let clashes = accepted.contains { existing in
                let shared = candidate.overlap(with: existing)
                return shared > options.maxOverlapRatio * min(candidate.duration, existing.duration)
            }
            if !clashes { accepted.append(candidate) }
        }

        return accepted.sorted { $0.start < $1.start }
    }

    /// Grows outward from the peak while the curve stays interesting, bounded
    /// by the platform-friendly 15–60s range.
    private static func expand(around peakIndex: Int, values: [Double], floor: Double,
                               window: Double, options: CandidateOptions) -> (Double, Double) {
        var lower = peakIndex
        var upper = peakIndex
        let maxBins = Int(options.maxDuration / window)

        while upper - lower < maxBins {
            let canGrowDown = lower > 0 && values[lower - 1] >= floor
            let canGrowUp = upper < values.count - 1 && values[upper + 1] >= floor
            if !canGrowDown && !canGrowUp { break }
            // Prefer whichever side is still stronger, so the clip follows the
            // moment rather than drifting arbitrarily.
            if canGrowDown && (!canGrowUp || values[lower - 1] >= values[upper + 1]) {
                lower -= 1
            } else {
                upper += 1
            }
        }

        var start = Double(lower) * window
        var end = Double(upper + 1) * window

        // Always give the moment a little run-up.
        start = max(0, start - 1.5)
        if end - start < options.minDuration {
            let deficit = options.minDuration - (end - start)
            start = max(0, start - deficit * 0.6)
            end += deficit * 0.4
        }
        return (start, end)
    }

    /// Nudges the in/out points onto silence so a clip doesn't open or close
    /// mid-word.
    private static func snapToSpeech(start: Double, end: Double, peakTime: Double,
                                     silence: [SilenceInterval], duration: Double,
                                     options: CandidateOptions) -> (Double, Double) {
        let searchWindow = 4.0
        var newStart = start
        var newEnd = end

        if let gap = silence
            .filter({ abs($0.end - start) <= searchWindow })
            .min(by: { abs($0.end - start) < abs($1.end - start) }) {
            newStart = max(0, gap.end - 0.25)
        }
        if let gap = silence
            .filter({ abs($0.start - end) <= searchWindow })
            .min(by: { abs($0.start - end) < abs($1.start - end) }) {
            newEnd = gap.start + 0.35
        }

        newStart = max(0, min(newStart, peakTime - 2))
        newEnd = min(duration, max(newEnd, peakTime + 2))

        // Re-clamp: snapping can push the clip outside the allowed range.
        if newEnd - newStart > options.maxDuration {
            newEnd = newStart + options.maxDuration
        }
        if newEnd - newStart < options.minDuration {
            newEnd = min(duration, newStart + options.minDuration)
            if newEnd - newStart < options.minDuration {
                newStart = max(0, newEnd - options.minDuration)
            }
        }
        return (newStart, newEnd)
    }

    /// Uses the line spoken nearest the peak as the clip's working title.
    private static func title(for start: Double, to end: Double, peakTime: Double,
                              transcript: Transcript) -> String {
        let inRange = transcript.segments.filter { $0.end > start && $0.start < end }
        guard !inRange.isEmpty else { return "Untitled moment" }
        let nearest = inRange.min {
            abs(($0.start + $0.end) / 2 - peakTime) < abs(($1.start + $1.end) / 2 - peakTime)
        }
        let text = (nearest?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Untitled moment" }
        return text.count > 70 ? String(text.prefix(70)) + "…" : text
    }
}

import Foundation

/// Detects the moments worth a punch-in — loudness peaks, reinforced by
/// emphasized words — and writes the subtle zoom-push envelopes that make a
/// static webcam shot feel cut. Pure math over data already in memory:
/// waveform peaks and transcript words. No model, no network.
enum PunchInService {
    struct Options: Equatable {
        /// The push at full strength. 1.12 reads as energy without the
        /// viewer clocking the zoom itself.
        var intensity: Double = 1.12
        /// Minimum spacing between pushes, in effective seconds. Wider than
        /// a full envelope, so pushes never overlap by construction.
        var minGap: Double = 2.5
        /// Envelope shape: quick push, hold through the moment, ease out.
        var pushIn: Double = 0.25
        var hold: Double = 0.9
        var release: Double = 0.45

        init(intensity: Double = 1.12) {
            self.intensity = intensity
        }
    }

    /// One detected moment, in the clip's source time.
    struct Moment: Equatable {
        var time: Double
        var prominence: Double
        var onWord: Bool
    }

    /// The full pass: peaks + words in → zoom keys out, in effective time.
    /// `peaks` is the clip's own slice (index 0 = clip start).
    static func detect(peaks: [UInt8], perSecond: Double,
                       words: [(t: Double, text: String)] = [],
                       clipSourceDuration: Double, speed: Double = 1,
                       options: Options = Options()) -> [MotionKey] {
        let chosen = moments(peaks: peaks, perSecond: perSecond, words: words,
                             options: options)
        let clampedSpeed = min(3, max(0.25, speed))
        let effectiveDuration = clipSourceDuration / clampedSpeed
        return envelopes(for: chosen.map { $0.time / clampedSpeed },
                         effectiveDuration: effectiveDuration, options: options)
    }

    /// Peak-picking: smooth the envelope, threshold well above baseline,
    /// keep local maxima, spread by minGap, loudest first. A word landing
    /// on a peak (±0.4s) raises its prominence — an emphasized word over a
    /// loud moment is exactly what deserves the push.
    static func moments(peaks: [UInt8], perSecond: Double,
                        words: [(t: Double, text: String)],
                        options: Options) -> [Moment] {
        guard peaks.count > 4, perSecond > 0 else { return [] }
        let smoothWindow = max(1, Int(perSecond * 0.15))
        var smoothed = [Double](repeating: 0, count: peaks.count)
        for index in peaks.indices {
            let lower = max(0, index - smoothWindow)
            let upper = min(peaks.count - 1, index + smoothWindow)
            var sum = 0.0
            for j in lower...upper { sum += Double(peaks[j]) }
            smoothed[index] = sum / Double(upper - lower + 1)
        }
        let mean = smoothed.reduce(0, +) / Double(smoothed.count)
        let top = smoothed.max() ?? 0
        guard top > 8 else { return [] }
        let threshold = max(mean + 0.55 * (top - mean), mean * 1.25)

        let emphatic = words.filter { word in
            word.text.contains("!")
                || (word.text.count >= 4 && word.text == word.text.uppercased()
                    && word.text.rangeOfCharacter(from: .letters) != nil)
        }

        var found: [Moment] = []
        for index in 1..<(smoothed.count - 1)
        where smoothed[index] >= threshold
            && smoothed[index] >= smoothed[index - 1]
            && smoothed[index] >= smoothed[index + 1] {
            let time = Double(index) / perSecond
            let onWord = emphatic.contains { abs($0.t - time) < 0.4 }
            found.append(Moment(time: time,
                                prominence: smoothed[index] / top + (onWord ? 0.3 : 0),
                                onWord: onWord))
        }

        // Loudest first, then greedy spacing in source time.
        var kept: [Moment] = []
        for moment in found.sorted(by: { $0.prominence > $1.prominence })
        where !kept.contains(where: { abs($0.time - moment.time) < options.minGap }) {
            kept.append(moment)
        }
        return kept.sorted { $0.time < $1.time }
    }

    /// Push envelopes around each moment, clipped to the clip and returned
    /// sorted. Moments are pre-spaced, so envelopes never collide.
    static func envelopes(for times: [Double], effectiveDuration: Double,
                          options: Options) -> [MotionKey] {
        var keys: [MotionKey] = []
        for moment in times {
            let start = moment - options.pushIn
            let holdEnd = moment + options.hold
            let end = holdEnd + options.release
            guard moment > 0.1, moment < effectiveDuration - 0.2 else { continue }
            keys.append(MotionKey(t: max(0, start), v: 1))
            keys.append(MotionKey(t: moment, v: options.intensity))
            keys.append(MotionKey(t: min(holdEnd, effectiveDuration - 0.1),
                                  v: options.intensity))
            keys.append(MotionKey(t: min(end, effectiveDuration - 0.05), v: 1))
        }
        return keys.sorted { $0.t < $1.t }
    }
}

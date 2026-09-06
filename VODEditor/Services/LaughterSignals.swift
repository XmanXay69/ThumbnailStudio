import Foundation

/// Laughter, heard in the envelope. A laugh is loud AND pulsed — bursts at
/// roughly 4–8 Hz, which is faster than speech syllables and much deeper in
/// modulation. Both are visible in the 20/s waveform peaks the app already
/// keeps, so this costs nothing to run and nothing is decoded.
///
/// Usually right, occasionally fooled by rapid gunfire or stutter edits —
/// which is why it feeds a score instead of making decisions alone.
enum LaughterSignals {
    struct Window: Equatable {
        var start: Double
        var end: Double
        /// How laugh-like the stretch is, 0–1.
        var confidence: Double

        var duration: Double { end - start }
    }

    /// Slides a 1.6s window over the envelope looking for loud, deeply and
    /// quickly modulated stretches; adjacent hits merge.
    static func detect(peaks: [UInt8], perSecond: Double) -> [Window] {
        guard perSecond > 0, peaks.count > Int(perSecond * 3) else { return [] }
        let n = peaks.count
        let global = peaks.reduce(0.0) { $0 + Double($1) } / Double(n)
        guard global > 4 else { return [] }

        let windowSamples = max(8, Int(perSecond * 1.6))
        let hop = max(2, windowSamples / 4)
        var hits: [(index: Int, confidence: Double)] = []

        var index = 0
        while index + windowSamples <= n {
            let slice = Array(peaks[index..<(index + windowSamples)]).map(Double.init)
            let mean = slice.reduce(0, +) / Double(slice.count)
            // Loud enough to be someone actually laughing into the mic.
            if mean > global * 1.25, mean > 24 {
                let rate = modulationRate(slice, perSecond: perSecond)
                let depth = modulationDepth(slice, mean: mean)
                if (3.2...9.5).contains(rate), depth > 0.30 {
                    let rateFit = 1 - abs(rate - 5.5) / 5.5
                    let confidence = min(1, max(0, 0.5 * rateFit + 0.5 * min(1, depth / 0.6)))
                    hits.append((index, confidence))
                }
            }
            index += hop
        }
        guard !hits.isEmpty else { return [] }

        // Merge overlapping hits into windows.
        var windows: [Window] = []
        var currentStart = hits[0].index
        var currentEnd = hits[0].index + windowSamples
        var best = hits[0].confidence
        for hit in hits.dropFirst() {
            if hit.index <= currentEnd {
                currentEnd = hit.index + windowSamples
                best = max(best, hit.confidence)
            } else {
                windows.append(Window(start: Double(currentStart) / perSecond,
                                      end: Double(currentEnd) / perSecond,
                                      confidence: best))
                currentStart = hit.index
                currentEnd = hit.index + windowSamples
                best = hit.confidence
            }
        }
        windows.append(Window(start: Double(currentStart) / perSecond,
                              end: Double(currentEnd) / perSecond,
                              confidence: best))
        return windows
    }

    /// Zero-crossing rate of the detrended envelope — two crossings per
    /// modulation cycle, so rate = crossings / 2 / seconds.
    static func modulationRate(_ slice: [Double], perSecond: Double) -> Double {
        guard slice.count > 4, perSecond > 0 else { return 0 }
        let mean = slice.reduce(0, +) / Double(slice.count)
        var crossings = 0
        for (a, b) in zip(slice, slice.dropFirst())
        where (a - mean) * (b - mean) < 0 {
            crossings += 1
        }
        let seconds = Double(slice.count) / perSecond
        return Double(crossings) / 2 / seconds
    }

    /// Coefficient of variation — how deep the pulsing is relative to level.
    static func modulationDepth(_ slice: [Double], mean: Double) -> Double {
        guard mean > 0.0001 else { return 0 }
        let variance = slice.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(slice.count)
        return variance.squareRoot() / mean
    }

    /// Seconds of laughter inside a candidate's span, confidence-weighted —
    /// the number the banger score consumes.
    static func laughSeconds(in windows: [Window], from start: Double, to end: Double) -> Double {
        windows.reduce(0) { total, window in
            let overlap = min(window.end, end) - max(window.start, start)
            return overlap > 0 ? total + overlap * window.confidence : total
        }
    }
}

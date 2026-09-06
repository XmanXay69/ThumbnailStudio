import Foundation

/// Turns raw per-frame subject positions (faces from Vision, motion
/// centroids as fallback — sampled by the session) into a pan track that
/// watches like a camera operator: smoothed, deadbanded so it holds still
/// through jitter, and thinned to the keyframes that matter.
enum ReframeService {
    struct Options: Equatable {
        /// Exponential smoothing factor per sample — lower is steadier.
        var smoothing: Double = 0.30
        /// Movement under this fraction of the frame doesn't move the
        /// camera at all; real reframes do.
        var deadband: Double = 0.05
        /// Collinear keys within this tolerance are dropped.
        var thinning: Double = 0.01

        init() {}
    }

    /// One observed subject position, in effective clip time.
    struct Sample: Equatable {
        var t: Double
        var x: Double
        var y: Double
    }

    /// The full pass: raw samples in, pan keys out. Deterministic.
    static func panKeys(from samples: [Sample],
                        options: Options = Options()) -> [PanKey] {
        guard samples.count >= 2 else { return [] }
        let ordered = samples.sorted { $0.t < $1.t }

        // Exponential smoothing with a deadband: the camera stays parked
        // until the subject genuinely moves, then eases after it.
        var smoothed: [Sample] = []
        var current = ordered[0]
        smoothed.append(current)
        for sample in ordered.dropFirst() {
            let dx = sample.x - current.x
            let dy = sample.y - current.y
            if abs(dx) > options.deadband || abs(dy) > options.deadband {
                current.x += dx * options.smoothing
                current.y += dy * options.smoothing
            }
            current.t = sample.t
            smoothed.append(current)
        }

        // Thin: keep the first and last, drop any key that linear
        // interpolation between its neighbours already reproduces.
        var keys: [PanKey] = [PanKey(t: smoothed[0].t,
                                     x: clamp(smoothed[0].x), y: clamp(smoothed[0].y))]
        for index in 1..<(smoothed.count - 1) {
            let a = smoothed[index - 1]
            let b = smoothed[index]
            let c = smoothed[index + 1]
            let span = c.t - a.t
            guard span > 0.0001 else { continue }
            let f = (b.t - a.t) / span
            let predictedX = a.x + (c.x - a.x) * f
            let predictedY = a.y + (c.y - a.y) * f
            if abs(predictedX - b.x) > options.thinning
                || abs(predictedY - b.y) > options.thinning {
                keys.append(PanKey(t: b.t, x: clamp(b.x), y: clamp(b.y)))
            }
        }
        let last = smoothed[smoothed.count - 1]
        keys.append(PanKey(t: last.t, x: clamp(last.x), y: clamp(last.y)))

        // A track that never actually moves is no track at all.
        let xs = keys.map(\.x)
        let ys = keys.map(\.y)
        if (xs.max()! - xs.min()!) < options.deadband,
           (ys.max()! - ys.min()!) < options.deadband {
            return []
        }
        return keys
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}

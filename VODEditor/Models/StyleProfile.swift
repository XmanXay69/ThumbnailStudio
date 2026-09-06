import Foundation

/// Measurable editing style extracted from a reference video.
///
/// Deliberately limited to things that can actually be measured from pixels and
/// audio. Caption styling, zooms, punch-ins and meme overlays are *not* here —
/// see `StyleAnalyzer.limitations`.
struct StyleProfile: Codable, Equatable {
    var sourceName: String
    var analyzedAt: Date

    var duration: Double
    var width: Int
    var height: Int

    /// Cut rhythm.
    var cutCount: Int
    var medianShotSeconds: Double
    var shortShotSeconds: Double   // 25th percentile
    var longShotSeconds: Double    // 75th percentile

    /// Fraction of runtime that is below the speech floor — how much air the
    /// editor left in.
    var silenceRatio: Double
    var longestSilence: Double

    /// Continuous audio under the speech gaps, and roughly how far under.
    ///
    /// This detects *a bed*, not *music*: a music track and continuous room or
    /// game ambience look identical in an envelope. Gameplay footage reads as
    /// having a bed because the engine noise never stops.
    var hasMusicBed: Bool
    var musicLevelDB: Double?

    var aspect: Double { height > 0 ? Double(width) / Double(height) : 16.0 / 9.0 }
    var isVertical: Bool { aspect < 1 }
    var cutsPerMinute: Double { duration > 0 ? Double(cutCount) / (duration / 60) : 0 }

    /// A reference under three minutes reads as a short; over ten, as a
    /// long-form edit. In between, both sets of settings get nudged.
    var looksLikeShort: Bool { duration <= 180 }
    var looksLikeLongForm: Bool { duration >= 600 }

    var pacingLabel: String {
        switch medianShotSeconds {
        case ..<2: return "very fast"
        case ..<5: return "fast"
        case ..<12: return "moderate"
        default: return "slow"
        }
    }
}

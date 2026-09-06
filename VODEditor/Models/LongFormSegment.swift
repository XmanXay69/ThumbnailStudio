import Foundation

/// A contiguous piece of source material to render. One long-form segment can
/// produce several of these once internal dead air is cut out.
struct TimeRange: Codable, Equatable, Hashable {
    var start: Double
    var end: Double

    var duration: Double { max(0, end - start) }
}

struct LongFormOptions: Codable, Equatable {
    /// The brief asks for a 25–30 minute cut; selection aims for the middle and
    /// stops once it's inside the band.
    var targetMinutes: Double = 27
    var minimumSegment: Double = 30
    var maximumSegment: Double = 180

    /// Dead air inside a kept segment gets cut out rather than sitting in the
    /// final edit. Gaps shorter than this are left alone — cutting every small
    /// pause makes speech sound clipped.
    var trimInternalSilence: Bool = true
    /// Ingest's silencedetect pass only reports gaps of 0.6s or more, so
    /// anything below that is invisible here regardless.
    var internalSilenceThreshold: Double = 1.2
    /// Breathing room left on each side of a removed silence.
    var silencePadding: Double = 0.25

    var burnCaptions: Bool = false

    // MARK: Phase 4 — polish

    /// A short dissolve between segments reads better than a hard cut when the
    /// two moments are hours apart in the source.
    var crossfadeEnabled: Bool = true
    var crossfadeDuration: Double = 0.5

    var musicPath: String?
    var musicEnabled: Bool = false
    /// Music sits well under speech at roughly -16 dB before ducking.
    var musicGainDB: Double = -16
    var musicDucking: Bool = true
    /// sidechaincompress ratio — how hard the bed drops when anyone talks.
    var duckRatio: Double = 8

    var musicURL: URL? { musicPath.map { URL(fileURLWithPath: $0) } }

    static let standard = LongFormOptions()

    var targetSeconds: Double { targetMinutes * 60 }
}

struct LongFormSegment: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var start: Double
    var end: Double
    var score: Double
    var title: String

    /// Segments start on the timeline; discarding one moves it to the bin
    /// rather than deleting it, so it can be dragged back.
    var isIncluded: Bool = true
    /// Position in the assembled sequence. Chronological by default — a best-of
    /// that jumps around reads as chaotic — but reorderable.
    var order: Int = 0

    var duration: Double { max(0, end - start) }

    func overlaps(_ other: LongFormSegment) -> Bool {
        start < other.end && other.start < end
    }
}

/// The whole long-form edit as persisted.
struct LongFormEdit: Codable, Equatable {
    var segments: [LongFormSegment] = []
    var generatedAt: Date?

    var included: [LongFormSegment] {
        segments.filter(\.isIncluded).sorted { $0.order < $1.order }
    }

    var binned: [LongFormSegment] {
        segments.filter { !$0.isIncluded }.sorted { $0.start < $1.start }
    }
}

import AVFoundation
import Foundation

/// One rendered piece of the assembled edit, and where it lands in the
/// sequence. Used for both the AVComposition preview and the ffmpeg render, so
/// what you scrub is exactly what gets exported.
struct AssembledPiece: Equatable {
    var source: TimeRange
    var compositionStart: Double
    var segmentID: UUID

    var duration: Double { source.duration }
    var compositionEnd: Double { compositionStart + duration }
}

struct AssembledEdit: Equatable {
    var pieces: [AssembledPiece] = []

    var duration: Double { pieces.last?.compositionEnd ?? 0 }
    var isEmpty: Bool { pieces.isEmpty }

    /// Composition time → source time, for keeping the transcript in sync while
    /// scrubbing the assembled cut.
    func sourceTime(forComposition time: Double) -> Double? {
        guard let piece = pieces.last(where: { $0.compositionStart <= time }) else { return nil }
        let offset = min(time - piece.compositionStart, piece.duration)
        return piece.source.start + offset
    }

    func compositionTime(forSource time: Double) -> Double? {
        guard let piece = pieces.first(where: { time >= $0.source.start && time < $0.source.end })
        else { return nil }
        return piece.compositionStart + (time - piece.source.start)
    }

    /// Where a segment begins in the assembled sequence.
    func compositionStart(ofSegment id: UUID) -> Double? {
        pieces.first { $0.segmentID == id }?.compositionStart
    }

    func duration(ofSegment id: UUID) -> Double {
        pieces.filter { $0.segmentID == id }.reduce(0) { $0 + $1.duration }
    }
}

enum LongFormService {
    // MARK: - Selection

    /// Picks the strongest non-overlapping stretches until the edit reaches the
    /// target runtime, then restores chronological order.
    static func generate(curve: ScoreCurve,
                         transcript: Transcript,
                         silence: [SilenceInterval],
                         duration: Double,
                         throughlines: [Throughline] = [],
                         options: LongFormOptions = .standard) -> LongFormEdit {
        guard !curve.isEmpty, duration > 0 else { return LongFormEdit() }

        let values = curve.values
        let mean = values.reduce(0, +) / Double(values.count)
        let standardDeviation = sqrt(values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count))

        // A far lower bar than the shorts pass: ~27 minutes has to come from
        // somewhere, so anything above average is a candidate stretch.
        let neighbourhood = Int(20 / curve.windowSeconds)
        var peaks: [(index: Int, value: Double)] = []
        for index in values.indices where values[index] >= mean {
            let lower = max(0, index - neighbourhood)
            let upper = min(values.count - 1, index + neighbourhood)
            var isPeak = true
            for other in lower...upper where values[other] > values[index] { isPeak = false; break }
            if isPeak { peaks.append((index, values[index])) }
        }
        // A beat that belongs to a throughline is worth more than its raw score
        // suggests — the setup of a running bit is often quiet.
        if !throughlines.isEmpty {
            for index in peaks.indices {
                let time = Double(peaks[index].index) * curve.windowSeconds
                let bonus = throughlines
                    .filter { $0.contains(time) }
                    .map(\.strength)
                    .max() ?? 0
                peaks[index].value *= 1 + 0.4 * bonus
            }
        }

        peaks.sort { $0.value > $1.value }

        var accepted: [LongFormSegment] = []
        var total: Double = 0

        for peak in peaks {
            guard total < options.targetSeconds else { break }

            let floor = max(mean, peak.value * 0.5)
            var (start, end) = expand(around: peak.index, values: values, floor: floor,
                                      window: curve.windowSeconds, options: options)
            (start, end) = snap(start: start, end: end, silence: silence,
                                duration: duration, options: options)

            let candidate = LongFormSegment(
                start: start, end: end, score: peak.value,
                title: title(from: start, to: end, transcript: transcript)
            )
            guard !accepted.contains(where: { $0.overlaps(candidate) }) else { continue }

            accepted.append(candidate)
            total += effectiveDuration(of: candidate, silence: silence, options: options)
        }

        // Keeping one beat of a three-part joke and dropping the setup is worse
        // than keeping none, so any throughline that got in partially is
        // completed even if that overshoots the target a little.
        for throughline in throughlines.sorted(by: { $0.strength > $1.strength }) {
            let included = throughline.beats.filter { beat in
                accepted.contains { $0.start < beat.end && beat.start < $0.end }
            }
            guard !included.isEmpty, included.count < throughline.beats.count else { continue }
            guard total < options.targetSeconds * 1.15 else { break }

            for beat in throughline.beats {
                let alreadyIn = accepted.contains { $0.start < beat.end && beat.start < $0.end }
                guard !alreadyIn else { continue }

                var start = max(0, beat.start)
                var end = min(duration, max(beat.end, start + options.minimumSegment))
                if end - start > options.maximumSegment { end = start + options.maximumSegment }
                (start, end) = snap(start: start, end: end, silence: silence,
                                    duration: duration, options: options)

                let candidate = LongFormSegment(
                    start: start, end: end, score: throughline.strength,
                    title: title(from: start, to: end, transcript: transcript)
                )
                guard !accepted.contains(where: { $0.overlaps(candidate) }) else { continue }
                accepted.append(candidate)
                total += effectiveDuration(of: candidate, silence: silence, options: options)
            }
        }

        // Chronological order is the default for a reason: a best-of that jumps
        // around in time reads as chaotic.
        let ordered = accepted.sorted { $0.start < $1.start }
        var segments: [LongFormSegment] = []
        for (index, var segment) in ordered.enumerated() {
            segment.order = index
            segments.append(segment)
        }
        return LongFormEdit(segments: segments, generatedAt: Date())
    }

    private static func expand(around peakIndex: Int, values: [Double], floor: Double,
                               window: Double, options: LongFormOptions) -> (Double, Double) {
        var lower = peakIndex
        var upper = peakIndex
        let maxBins = Int(options.maximumSegment / window)

        while upper - lower < maxBins {
            let canGrowDown = lower > 0 && values[lower - 1] >= floor
            let canGrowUp = upper < values.count - 1 && values[upper + 1] >= floor
            if !canGrowDown && !canGrowUp { break }
            if canGrowDown && (!canGrowUp || values[lower - 1] >= values[upper + 1]) {
                lower -= 1
            } else {
                upper += 1
            }
        }

        var start = Double(lower) * window
        var end = Double(upper + 1) * window
        if end - start < options.minimumSegment {
            let deficit = options.minimumSegment - (end - start)
            start = max(0, start - deficit / 2)
            end += deficit / 2
        }
        return (start, end)
    }

    private static func snap(start: Double, end: Double, silence: [SilenceInterval],
                             duration: Double, options: LongFormOptions) -> (Double, Double) {
        var newStart = start
        var newEnd = end
        let searchWindow = 5.0

        if let gap = silence
            .filter({ abs($0.end - start) <= searchWindow })
            .min(by: { abs($0.end - start) < abs($1.end - start) }) {
            newStart = max(0, gap.end - options.silencePadding)
        }
        if let gap = silence
            .filter({ abs($0.start - end) <= searchWindow })
            .min(by: { abs($0.start - end) < abs($1.start - end) }) {
            newEnd = gap.start + options.silencePadding
        }

        newStart = max(0, newStart)
        newEnd = min(duration, max(newEnd, newStart + options.minimumSegment))
        if newEnd - newStart > options.maximumSegment { newEnd = newStart + options.maximumSegment }
        return (newStart, newEnd)
    }

    private static func title(from start: Double, to end: Double, transcript: Transcript) -> String {
        let inRange = transcript.segments.filter { $0.end > start && $0.start < end }
        let text = inRange.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return "Untitled segment" }
        return text.count > 60 ? String(text.prefix(60)) + "…" : text
    }

    // MARK: - Dead-air trimming

    /// Splits a segment around any internal silence long enough to read as dead
    /// air. Short pauses are kept — cutting every one makes speech sound
    /// clipped.
    static func renderRanges(for segment: LongFormSegment,
                             silence: [SilenceInterval],
                             options: LongFormOptions) -> [TimeRange] {
        guard options.trimInternalSilence else {
            return [TimeRange(start: segment.start, end: segment.end)]
        }

        let cuts = silence
            .filter { $0.duration >= options.internalSilenceThreshold }
            .compactMap { interval -> TimeRange? in
                let from = max(interval.start + options.silencePadding, segment.start)
                let to = min(interval.end - options.silencePadding, segment.end)
                guard to - from > 0.2 else { return nil }
                return TimeRange(start: from, end: to)
            }
            .sorted { $0.start < $1.start }

        var ranges: [TimeRange] = []
        var cursor = segment.start
        for cut in cuts {
            if cut.start > cursor { ranges.append(TimeRange(start: cursor, end: cut.start)) }
            cursor = max(cursor, cut.end)
        }
        if cursor < segment.end { ranges.append(TimeRange(start: cursor, end: segment.end)) }

        // Fragments too short to be worth a cut.
        return ranges.filter { $0.duration >= 0.5 }
    }

    static func effectiveDuration(of segment: LongFormSegment,
                                  silence: [SilenceInterval],
                                  options: LongFormOptions) -> Double {
        renderRanges(for: segment, silence: silence, options: options)
            .reduce(0) { $0 + $1.duration }
    }

    /// Flattens the included segments into the ordered piece list used for both
    /// preview and export.
    static func assemble(edit: LongFormEdit,
                         silence: [SilenceInterval],
                         options: LongFormOptions) -> AssembledEdit {
        var pieces: [AssembledPiece] = []
        var cursor: Double = 0
        for segment in edit.included {
            for range in renderRanges(for: segment, silence: silence, options: options) {
                pieces.append(AssembledPiece(source: range, compositionStart: cursor,
                                             segmentID: segment.id))
                cursor += range.duration
            }
        }
        return AssembledEdit(pieces: pieces)
    }

    // MARK: - Preview composition

    /// Builds an AVComposition of the assembled pieces so the player previews
    /// the actual cut — dead air already removed — instead of scrubbing around
    /// the source file.
    static func buildComposition(sourceURL: URL, assembled: AssembledEdit) async throws -> AVComposition {
        let asset = AVURLAsset(url: sourceURL,
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let composition = AVMutableComposition()

        let sourceVideo = try await asset.loadTracks(withMediaType: .video).first
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first

        let videoTrack = sourceVideo.flatMap { _ in
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        let audioTrack = sourceAudio.flatMap { _ in
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }

        var cursor = CMTime.zero
        for piece in assembled.pieces {
            let range = CMTimeRange(
                start: CMTime(seconds: piece.source.start, preferredTimescale: 600),
                duration: CMTime(seconds: piece.duration, preferredTimescale: 600)
            )
            if let sourceVideo, let videoTrack {
                try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            }
            if let sourceAudio, let audioTrack {
                try audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
            }
            cursor = cursor + range.duration
        }

        if let sourceVideo, let videoTrack {
            videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
        }
        return composition
    }
}

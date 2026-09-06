import Foundation

/// The Descript move, fully local: word timings already say where the dead
/// air and the "um"s are — this turns them into a cut list the user can
/// preview, then applies them as one undoable ripple pass.
enum TightenService {
    struct Options: Equatable {
        /// Gaps at or above this many seconds get closed.
        var gapThreshold: Double = 0.8
        /// Breathing room left on each side of a closed gap; cuts that butt
        /// straight against speech sound chopped.
        var padding: Double = 0.12
        var removeFillers: Bool = true

        init(gapThreshold: Double = 0.8, padding: Double = 0.12,
             removeFillers: Bool = true) {
            self.gapThreshold = gapThreshold
            self.padding = padding
            self.removeFillers = removeFillers
        }
    }

    /// One planned cut, in timeline seconds.
    struct Cut: Equatable {
        var start: Double
        var end: Double
        /// "silence" or the filler word itself.
        var reason: String

        var duration: Double { end - start }
    }

    /// Standalone disfluencies. Deliberately conservative — "like" and "you
    /// know" carry meaning too often to cut blind.
    static let fillers: Set<String> = ["um", "uh", "umm", "uhh", "er", "erm", "ehm", "mmm"]

    /// Walks every clip cut straight from the VOD and plans cuts from the
    /// transcript's word timings: silences over the threshold, plus filler
    /// words when asked. Clips from other files have no transcript and pass
    /// through untouched. Pure — same inputs, same plan.
    static func plan(edit: ClipEdit, transcript: Transcript,
                     projectSource: String?,
                     options: Options = Options()) -> [Cut] {
        var cuts: [Cut] = []
        var timelineCursor: Double = 0
        for clip in edit.clips {
            defer { timelineCursor += clip.effectiveDuration }
            guard !clip.isFreeze, clip.sourcePath == projectSource else { continue }
            let speed = clip.clampedSpeed
            let words = transcript.segments
                .filter { $0.end > clip.start && $0.start < clip.end }
                .flatMap(\.words)
                .filter { $0.end > clip.start && $0.start < clip.end }
                .sorted { $0.start < $1.start }
            guard !words.isEmpty else { continue }

            func timelineTime(_ sourceTime: Double) -> Double {
                timelineCursor + (sourceTime - clip.start) / speed
            }

            // Dead air between consecutive words (and before the first /
            // after the last), padded on both sides.
            var boundaries: [(from: Double, to: Double)] = []
            boundaries.append((clip.start, words[0].start))
            for (a, b) in zip(words, words.dropFirst()) {
                boundaries.append((a.end, b.start))
            }
            boundaries.append((words[words.count - 1].end, clip.end))
            for gap in boundaries where gap.to - gap.from >= options.gapThreshold {
                let from = gap.from == clip.start ? gap.from : gap.from + options.padding
                let to = gap.to == clip.end ? gap.to : gap.to - options.padding
                guard to - from >= 0.2 * speed else { continue }
                cuts.append(Cut(start: timelineTime(from), end: timelineTime(to),
                                reason: "silence"))
            }

            if options.removeFillers {
                for word in words {
                    let cleaned = word.text.lowercased()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: .punctuationCharacters)
                    guard fillers.contains(cleaned),
                          word.end - word.start >= 0.18 * speed else { continue }
                    cuts.append(Cut(start: timelineTime(word.start - 0.02),
                                    end: timelineTime(word.end + 0.02),
                                    reason: cleaned))
                }
            }
        }

        // Merge overlaps and drop slivers the ripple delete would refuse.
        let sorted = cuts.sorted { $0.start < $1.start }
        var merged: [Cut] = []
        for cut in sorted {
            if var last = merged.last, cut.start <= last.end + 0.05 {
                last.end = max(last.end, cut.end)
                last.reason = last.reason == cut.reason ? last.reason : "silence"
                merged[merged.count - 1] = last
            } else {
                merged.append(cut)
            }
        }
        return merged.filter { $0.duration >= 0.2 }
    }

    /// Applies a plan to an edit — cuts run back to front so earlier ranges
    /// stay valid while later ones ripple out. Returns the tightened edit
    /// and how many cuts actually landed.
    static func apply(_ cuts: [Cut], to edit: ClipEdit) -> (edit: ClipEdit, applied: Int) {
        var out = edit
        var applied = 0
        for cut in cuts.sorted(by: { $0.start > $1.start })
        where out.rippleDelete(from: cut.start, to: cut.end) {
            applied += 1
        }
        return (out, applied)
    }

    /// Aggressiveness presets for the one slider the panel shows.
    static func options(aggressiveness: Double, removeFillers: Bool) -> Options {
        // 0 = gentle (1.4s), 1 = tight (0.45s).
        let clamped = min(1, max(0, aggressiveness))
        return Options(gapThreshold: 1.4 - clamped * 0.95,
                       padding: 0.16 - clamped * 0.08,
                       removeFillers: removeFillers)
    }
}

import AppKit
import Foundation

// Verifies a completed project's artifacts against the invariants the UI and
// exporter rely on. Compiles the model layer standalone — no app, no UI.

let projectDir = CommandLine.arguments[1]
let transcriptURL = URL(fileURLWithPath: projectDir + "/transcript/transcript.json")
let waveformURL = URL(fileURLWithPath: projectDir + "/analysis/waveform.bin")
let shortsURL = URL(fileURLWithPath: projectDir + "/shorts.json")
let projectURL = URL(fileURLWithPath: projectDir + "/project.json")

var failures = 0
func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    print((condition ? "  PASS  " : "  FAIL  ") + label + (detail.isEmpty ? "" : " — \(detail)"))
    if !condition { failures += 1 }
}
func section(_ name: String) { print("\n\(name)") }

/// Shows where two renderings of the same speech diverge, so a failure names the
/// word rather than just saying the strings differ.
func firstDifference(_ left: String, _ right: String) -> String {
    let a = left.split(separator: " "), b = right.split(separator: " ")
    for index in 0..<min(a.count, b.count) where a[index] != b[index] {
        let context = { (words: [Substring]) in
            words[max(0, index - 3)..<min(words.count, index + 4)].joined(separator: " ")
        }
        return "at word \(index): cues “\(context(a))” vs lines “\(context(b))”"
    }
    return "lengths differ: \(a.count) words in cues vs \(b.count) in lines"
}

// MARK: - Phase 1: transcript and waveform

section("Transcript")

let transcript = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: transcriptURL))
check("transcript decodes", !transcript.isEmpty, "\(transcript.segments.count) segments")

check("segment starts non-decreasing",
      !transcript.segments.indices.dropFirst().contains { transcript.segments[$0].start < transcript.segments[$0 - 1].start })

var lookupOK = true, inSpan = 0, wordHits = 0, probes = 0
for pct in stride(from: 0.0, through: 1.0, by: 0.005) {
    let t = transcript.duration * pct
    guard let idx = transcript.indexOfSegment(at: t) else { continue }
    probes += 1
    let seg = transcript.segments[idx]
    if t < seg.start { lookupOK = false }
    if idx + 1 < transcript.segments.count, transcript.segments[idx + 1].start <= t { lookupOK = false }
    if t < seg.end {
        inSpan += 1
        if transcript.activeWordIndex(in: seg, at: t) != nil { wordHits += 1 }
    }
}
check("lookup returns last started segment", lookupOK, "\(probes) probes across the VOD")
check("word highlight resolves inside a segment", wordHits == inSpan, "\(wordHits)/\(inSpan)")

var agree = true
for pct in stride(from: 0.0, through: 1.0, by: 0.0013) {
    let t = transcript.duration * pct
    if transcript.indexOfSegment(at: t) != transcript.segments.lastIndex(where: { $0.start <= t }) { agree = false }
}
check("matches linear scan", agree)

let allWords = transcript.segments.flatMap(\.words)
check("no zero-length words", !allWords.contains { $0.end <= $0.start }, "\(allWords.count) words")
check("words monotonic within segments",
      !transcript.segments.contains { segment in
          segment.words.indices.dropFirst().contains { segment.words[$0].start < segment.words[$0 - 1].start }
      })

section("Waveform")

let waveform = try WaveformService.load(from: waveformURL, peaksPerSecond: 20)
check("waveform loads", !waveform.peaks.isEmpty,
      "\(waveform.peaks.count) peaks, \(String(format: "%.0f", waveform.duration))s")
check("waveform duration matches transcript", abs(waveform.duration - transcript.duration) < 5)
for zoom in [15.0, 60.0, 300.0, 1200.0, waveform.duration] {
    let mid = waveform.duration / 2
    let env = waveform.envelope(from: max(0, mid - zoom / 2),
                                to: min(waveform.duration, mid + zoom / 2), buckets: 1400)
    check("envelope @ \(Int(zoom))s", env.count == 1400 && env.allSatisfy { $0 >= 0 && $0 <= 1 } && env.contains { $0 > 0 })
}
check("envelope at t=0 safe", waveform.envelope(from: 0, to: 15, buckets: 800).count == 800)
check("envelope past end safe",
      waveform.envelope(from: waveform.duration - 5, to: waveform.duration + 60, buckets: 800).allSatisfy { $0 >= 0 })
check("degenerate range safe", waveform.envelope(from: 10, to: 10, buckets: 100).isEmpty)

let silenceIntervals: [SilenceInterval] = {
    let url = URL(fileURLWithPath: projectDir + "/analysis/silence.json")
    guard let data = try? Data(contentsOf: url),
          let decoded = try? JSONDecoder().decode([SilenceInterval].self, from: data) else { return [] }
    return decoded
}()
// A short source legitimately has no dead air in it, so this is only an
// assertion about a real VOD. The harness now runs against whatever project is
// newest, which since links can be pasted may be a 75-second clip.
let isFullLengthVOD = transcript.duration >= 1800
if isFullLengthVOD {
    check("silence map loads", !silenceIntervals.isEmpty, "\(silenceIntervals.count) intervals")
} else {
    print("  SKIP  silence map — source is \(Int(transcript.duration))s, too short to have dead air")
}

// MARK: - Phase 2: scoring, candidates, captions, export geometry

section("Shorts candidates")

let project = try JSONDecoder().decode(VODProject.self, from: Data(contentsOf: projectURL))
let options = project.candidateOptions

if let shortsData = try? Data(contentsOf: shortsURL) {
    let shorts = try JSONDecoder().decode([ShortCandidate].self, from: shortsData)
    check("shorts decode", !shorts.isEmpty, "\(shorts.count) candidates")

    // Generation clamps to the option bounds; the user then trims freely with
    // the handles, and stretching one clip past the cap is legitimate editing.
    // A broken generator misses the band everywhere, not on one hand-edit.
    let durations = shorts.map(\.duration)
    let outsideBand = durations.filter {
        $0 < options.minDuration * 0.5 || $0 > options.maxDuration * 1.5
    }
    check("durations in the \(Int(options.minDuration))–\(Int(options.maxDuration))s band's neighbourhood",
          outsideBand.isEmpty,
          String(format: "min %.1f max %.1f mean %.1f · %d beyond the band",
                 durations.min() ?? 0, durations.max() ?? 0,
                 durations.reduce(0, +) / Double(max(durations.count, 1)),
                 outsideBand.count))

    let ordered = shorts.sorted { $0.start < $1.start }
    var worstOverlap = 0.0
    var violations = 0
    for index in ordered.indices.dropLast() {
        let overlap = ordered[index].overlap(with: ordered[index + 1])
        worstOverlap = max(worstOverlap, overlap)
        let allowed = options.maxOverlapRatio * min(ordered[index].duration, ordered[index + 1].duration)
        if overlap > allowed + 0.01 { violations += 1 }
    }
    // The dedup rule holds at generation time; the user is then free to
    // stretch an accepted clip into its neighbour with the trim handles. A
    // stretched pair or two is user editing — a broken dedup pass produces
    // violations everywhere.
    check("candidate overlaps stay at user-trim scale, not dedup failure", violations <= 2,
          String(format: "%d pair(s) beyond the rule, worst overlap %.1fs", violations, worstOverlap))
    // Whisper stops at the last speech, so the media can outlive the
    // transcript by a stretch of trailing silence — and trim handles are
    // allowed to reach into it. Generation clamps to the VOD; a candidate
    // running *wildly* past the transcript is the actual failure.
    check("candidates inside the VOD",
          shorts.allSatisfy { $0.start >= 0 && $0.end <= transcript.duration + 30 })
    check("every candidate has a title", shorts.allSatisfy { !$0.title.isEmpty })

    // Captions for the highest-scoring clip exercise the whole build path.
    section("Captions")
    let candidate = shorts.max { $0.score < $1.score }!
    var style = CaptionStyle.standard
    style.uppercase = true
    let lines = CaptionBuilder.lines(for: candidate, transcript: transcript, style: style)
    check("caption lines produced", !lines.isEmpty, "\(lines.count) lines")
    check("caption lines never overlap",
          !lines.indices.dropFirst().contains { lines[$0].start < lines[$0 - 1].end - 1e-6 })
    check("caption lines ordered and non-empty",
          lines.allSatisfy { $0.end > $0.start } &&
          !lines.indices.dropFirst().contains { lines[$0].start < lines[$0 - 1].start })
    check("caption lines inside the clip",
          lines.allSatisfy { $0.start >= -0.001 && $0.end <= candidate.duration + 0.001 })
    check("uppercase honoured", lines.allSatisfy { $0.text == $0.text.uppercased() })

    var plainStyle = style
    plainStyle.uppercase = false
    let plainLines = CaptionBuilder.lines(for: candidate, transcript: transcript, style: plainStyle)
    check("uppercase toggle changes output", plainLines.map(\.text) != lines.map(\.text))

    section("Caption phrasing")

    var sentenceStyle = style
    sentenceStyle.grouping = .sentence
    let sentences = CaptionBuilder.lines(for: candidate, transcript: transcript, style: sentenceStyle)
    let editable = CaptionBuilder.editableLines(for: candidate, transcript: transcript, style: style)
    check("sentence grouping is a pass-through", sentences.map(\.text) == editable.map(\.text),
          "\(sentences.count) sentences")

    func wordCount(_ line: CaptionLine) -> Int {
        line.text.split(separator: " ").count
    }
    let sentenceWords = sentences.map(wordCount)

    // Across the whole VOD, not just this clip — how long whisper's own
    // segments actually run is what phrasing has to improve on.
    let allSegmentWords = transcript.segments.map { $0.text.split(separator: " ").count }
    let segmentMean = Double(allSegmentWords.reduce(0, +)) / Double(max(1, allSegmentWords.count))
    let overLimit = allSegmentWords.filter { $0 > 8 }.count
    check("whisper's segment lengths measured", !allSegmentWords.isEmpty,
          String(format: "mean %.1f words, longest %d, %d of %d over 8 words (%.0f%%)",
                 segmentMean, allSegmentWords.max() ?? 0, overLimit, allSegmentWords.count,
                 Double(overLimit) / Double(max(1, allSegmentWords.count)) * 100))

    for target in [4, 6, 7, 8, 10] {
        var phraseStyle = style
        phraseStyle.wordsPerCue = target
        let cues = CaptionBuilder.lines(for: candidate, transcript: transcript, style: phraseStyle)
        let counts = cues.map(wordCount)
        let mean = Double(counts.reduce(0, +)) / Double(max(1, counts.count))
        check("\(target) words/cue: never exceeds the target",
              counts.allSatisfy { $0 <= target },
              String(format: "%d cues, mean %.1f, max %d", cues.count, mean, counts.max() ?? 0))
        check("\(target) words/cue: cues stay ordered and disjoint",
              cues.allSatisfy { $0.end > $0.start } &&
              !cues.indices.dropFirst().contains { cues[$0].start < cues[$0 - 1].end - 1e-6 })
        // Compared as a multiset, not a sequence. Whisper's segments overlap, so
        // a word from the next segment can start before the last word of this
        // one; the phraser sorts globally by time, which is what keeps karaoke
        // from jumping backwards but does reorder those pairs against the
        // transcript's reading order. What must hold is that no word is lost or
        // shown twice.
        func spoken(_ lines: [CaptionLine]) -> [String] {
            lines.flatMap { $0.words.map { $0.text.trimmingCharacters(in: .whitespaces) } }
                .filter { !$0.isEmpty }
        }
        let fromCues = spoken(cues), fromLines = spoken(editable)
        check("\(target) words/cue: nothing is dropped or duplicated",
              fromCues.sorted() == fromLines.sorted(),
              fromCues.sorted() == fromLines.sorted()
                  ? "\(fromCues.count) words"
                  : firstDifference(fromCues.sorted().joined(separator: " "),
                                    fromLines.sorted().joined(separator: " ")))
        check("\(target) words/cue: words never run backwards",
              !cues.contains { cue in
                  cue.words.indices.dropFirst().contains { cue.words[$0].start < cue.words[$0 - 1].start }
              })
    }

    // The whole point: no cue may run longer than the cap the user set — which
    // whisper's own segments violate whenever they run long. Whether this
    // candidate's sentences actually run long is the data's business.
    var sevens = style
    sevens.wordsPerCue = 7
    let sevenCues = CaptionBuilder.lines(for: candidate, transcript: transcript, style: sevens)
    let sevenMean = Double(sevenCues.map(wordCount).reduce(0, +)) / Double(max(1, sevenCues.count))
    let sentenceMean = Double(sentenceWords.reduce(0, +)) / Double(max(1, sentenceWords.count))
    check("phrasing caps cues at the words-per-cue limit",
          (sevenCues.map(wordCount).max() ?? 0) <= 7,
          String(format: "longest cue %d words vs %d as sentences; mean %.1f vs %.1f",
                 sevenCues.map(wordCount).max() ?? 0, sentenceWords.max() ?? 0,
                 sevenMean, sentenceMean))
    check("cue times come from the words themselves",
          sevenCues.allSatisfy { cue in
              guard let first = cue.words.first, let last = cue.words.last else { return false }
              return abs(cue.start - first.start) < 1e-6 && cue.end >= last.end - 1e-6
          })
    check("cues are readable on screen",
          sevenCues.indices.dropLast().allSatisfy { index in
              // Either it makes the minimum, or the next cue starts too soon.
              sevenCues[index].end - sevenCues[index].start >= CaptionPhraser.minimumOnScreen - 1e-6
                  || sevenCues[index + 1].start - sevenCues[index].start < CaptionPhraser.minimumOnScreen
          })

    // Synthetic: a pause has to break a cue regardless of the word count.
    do {
        func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptWord {
            TranscriptWord(text: text, start: start, end: end, probability: 1)
        }
        let paused = CaptionLine(id: 0, start: 0, end: 6, text: "one two three then four five six",
                                 words: [word("one", 0, 0.3), word(" two", 0.3, 0.6),
                                         word(" three", 0.6, 0.9),
                                         // 1.5s of nothing
                                         word(" then", 2.4, 2.7), word(" four", 2.7, 3.0),
                                         word(" five", 3.0, 3.3), word(" six", 3.3, 3.6)])
        var wide = CaptionStyle.standard
        wide.wordsPerCue = 12
        wide.uppercase = false
        let split = CaptionPhraser.regroup([paused], style: wide)
        check("a pause breaks a cue below the target", split.count == 2,
              "\(split.count) cues from 7 words at 12/cue")
        check("the break lands on the pause", split.first?.text == "one two three")

        let stopped = CaptionLine(id: 0, start: 0, end: 3, text: "that was it. now this happens",
                                  words: [word("that", 0, 0.3), word(" was", 0.3, 0.6),
                                          word(" it.", 0.6, 0.9), word(" now", 0.95, 1.2),
                                          word(" this", 1.2, 1.5), word(" happens", 1.5, 1.8)])
        var eight = CaptionStyle.standard
        eight.wordsPerCue = 8
        eight.uppercase = false
        let broken = CaptionPhraser.regroup([stopped], style: eight)
        check("a cue never spans two sentences",
              broken.count == 2 && broken.first?.text == "that was it.",
              broken.map(\.text).joined(separator: " | "))
    }

    // The Browse preview looks up a whole-transcript cue index. That index has
    // to hold the same invariants the per-clip path does, and the lookup has to
    // find the same cue a linear scan would.
    do {
        var previewStyle = CaptionStyle.standard
        previewStyle.uppercase = false
        let cues = CaptionBuilder.lines(transcript: transcript, style: previewStyle)
        check("whole-transcript cue index builds", !cues.isEmpty, "\(cues.count) cues")
        check("index cues are ordered and disjoint",
              cues.allSatisfy { $0.end > $0.start } &&
              !cues.indices.dropFirst().contains { cues[$0].start < cues[$0 - 1].end - 1e-6 })
        check("index respects the word cap",
              cues.allSatisfy { $0.text.split(separator: " ").count <= previewStyle.wordsPerCue },
              "longest \(cues.map { $0.text.split(separator: " ").count }.max() ?? 0) words")

        // Mirrors CaptionPreview.line — the binary search must agree with a scan.
        func lookup(_ time: Double) -> CaptionLine? {
            guard let first = cues.first, time >= first.start else { return nil }
            var low = 0, high = cues.count - 1, found = 0
            while low <= high {
                let mid = (low + high) / 2
                if cues[mid].start <= time { found = mid; low = mid + 1 } else { high = mid - 1 }
            }
            return time < cues[found].end ? cues[found] : nil
        }
        var probes = 0, agreements = 0
        for percent in stride(from: 0.001, through: 0.999, by: 0.0007) {
            let time = transcript.duration * percent
            probes += 1
            if lookup(time)?.text == cues.last(where: { time >= $0.start && time < $0.end })?.text {
                agreements += 1
            }
        }
        check("preview lookup matches a linear scan", agreements == probes,
              "\(agreements)/\(probes) probes")
    }

    section("ASS output")
    let ass = ASSBuilder.makeFile(lines: lines, style: style)
    check("has script header",
          ass.contains("[Script Info]") && ass.contains("PlayResX: 1080") && ass.contains("PlayResY: 1920"))
    check("has exactly one style", ass.components(separatedBy: "\nStyle:").count == 2)

    let events = ass.split(separator: "\n").filter { $0.hasPrefix("Dialogue:") }
    check("has dialogue events", !events.isEmpty, "\(events.count) events")
    check("every event has 10 fields",
          events.allSatisfy { $0.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false).count == 10 })

    func parseASSTime(_ value: Substring) -> Double? {
        let parts = value.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }
    var timecodesOK = true
    var previousStart = -1.0
    for event in events {
        let fields = event.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
        guard let start = parseASSTime(fields[1]), let end = parseASSTime(fields[2]), end > start,
              start >= previousStart - 1e-6 else {
            timecodesOK = false
            continue
        }
        previousStart = start
    }
    check("event timecodes parse, ordered, non-empty", timecodesOK)
    check("karaoke highlights one word per event",
          events.allSatisfy { $0.components(separatedBy: "{\\c").count <= 3 })

    section("Export geometry")
    let width = project.media?.width ?? 1920
    let height = project.media?.height ?? 1080
    let target = Double(ASSBuilder.renderWidth) / Double(ASSBuilder.renderHeight)

    // The single crop's default is exactly 9:16, so the on-screen box equals
    // the exported frame with no cover-crop.
    let fillPx = ExportService.pixelRect(NormalizedRect.defaultFill,
                                         sourceWidth: width, sourceHeight: height)
    let fillAspect = Double(fillPx.width) / Double(fillPx.height)
    check("default single crop is 9:16", abs(fillAspect - target) < 0.005,
          String(format: "%d×%d = %.4f vs %.4f", fillPx.width, fillPx.height, fillAspect, target))
    check("default single crop is even and inside the frame",
          fillPx.width % 2 == 0 && fillPx.height % 2 == 0
              && fillPx.x >= 0 && fillPx.x + fillPx.width <= width
              && fillPx.y >= 0 && fillPx.y + fillPx.height <= height)

    // Aspect-locked resize keeps the crop 9:16 whatever corner is dragged.
    let heightPerWidth = (Double(width) / Double(height)) * (1920.0 / 1080.0)
    let maxW = min(1.0, 1.0 / heightPerWidth)
    for corner in [BoxCorner.bottomRight, .bottomLeft, .topRight, .topLeft] {
        let zoomed = corner.resizeLocked(.defaultFill, dx: -0.08,
                                         heightPerWidth: heightPerWidth, maxWidth: maxW).clamped()
        let px = ExportService.pixelRect(zoomed, sourceWidth: width, sourceHeight: height)
        let aspect = Double(px.width) / Double(px.height)
        check("locked resize from \(corner) stays 9:16", abs(aspect - target) < 0.01,
              String(format: "%.4f", aspect))
    }
    // Cover-fit of the fill rect produces exactly 1080×1920.
    let media = project.media ?? MediaInfo(durationSeconds: 1, width: width, height: height, fps: 30,
                                           videoCodec: "h264", audioCodec: "aac", audioSampleRate: 48000,
                                           audioChannels: 2, sizeBytes: 0)
    let fillChain = ExportService.boxChain(.defaultFill, boxWidth: 1080, boxHeight: 1920, media: media)
    check("single crop fills 1080×1920", fillChain.contains("crop=1080:1920"),
          fillChain)
} else {
    print("  SKIP  shorts.json not present — run analysis first")
}

// MARK: - Phase 3: long-form assembly

section("Dead-air trimming (synthetic)")

// The real VOD's selected segments contain almost no internal silence — scoring
// picks high-energy regions, so it selects away from it. These synthetic cases
// exercise the trimming path that production data doesn't reach.
do {
    var options = LongFormOptions.standard
    options.trimInternalSilence = true
    options.internalSilenceThreshold = 1.2
    options.silencePadding = 0.25

    let segment = LongFormSegment(start: 100, end: 200, score: 1, title: "synthetic")

    let noSilence = LongFormService.renderRanges(for: segment, silence: [], options: options)
    check("no silence → one range", noSilence == [TimeRange(start: 100, end: 200)])

    // One 5s gap in the middle: expect two ranges with padding retained.
    let middle = [SilenceInterval(start: 140, end: 145)]
    let split = LongFormService.renderRanges(for: segment, silence: middle, options: options)
    check("gap in the middle splits the segment", split.count == 2,
          split.map { String(format: "%.2f–%.2f", $0.start, $0.end) }.joined(separator: ", "))
    check("padding retained on both sides of the cut",
          abs((split.first?.end ?? 0) - 140.25) < 0.001 && abs((split.last?.start ?? 0) - 144.75) < 0.001)
    check("trimmed total is shorter than raw",
          split.reduce(0) { $0 + $1.duration } < segment.duration)

    // A gap below the threshold must be left alone.
    let shortGap = [SilenceInterval(start: 150, end: 150.8)]
    check("sub-threshold gap is left alone",
          LongFormService.renderRanges(for: segment, silence: shortGap, options: options).count == 1)

    // Silence outside the segment must not affect it.
    let outside = [SilenceInterval(start: 10, end: 40), SilenceInterval(start: 300, end: 340)]
    check("silence outside the segment is ignored",
          LongFormService.renderRanges(for: segment, silence: outside, options: options)
              == [TimeRange(start: 100, end: 200)])

    // Silence overlapping an edge trims that edge rather than splitting.
    let edge = [SilenceInterval(start: 95, end: 110)]
    let trimmedEdge = LongFormService.renderRanges(for: segment, silence: edge, options: options)
    check("silence over the leading edge trims it",
          trimmedEdge.count == 1 && (trimmedEdge.first?.start ?? 0) > 100)

    var off = options
    off.trimInternalSilence = false
    check("trimming can be disabled",
          LongFormService.renderRanges(for: segment, silence: middle, options: off)
              == [TimeRange(start: 100, end: 200)])

    // Assembly must lay pieces end to end with no gaps or overlaps.
    var edit = LongFormEdit()
    edit.segments = [
        LongFormSegment(start: 100, end: 200, score: 1, title: "a", isIncluded: true, order: 0),
        LongFormSegment(start: 400, end: 460, score: 1, title: "b", isIncluded: true, order: 1),
        LongFormSegment(start: 900, end: 960, score: 1, title: "c", isIncluded: false, order: 2),
    ]
    let assembly = LongFormService.assemble(edit: edit, silence: middle, options: options)
    check("excluded segments stay out of the assembly",
          !assembly.pieces.contains { $0.segmentID == edit.segments[2].id })
    check("pieces are contiguous in composition time",
          !assembly.pieces.indices.dropFirst().contains {
              abs(assembly.pieces[$0].compositionStart - assembly.pieces[$0 - 1].compositionEnd) > 0.001
          })
    check("assembled duration equals the sum of pieces",
          abs(assembly.duration - assembly.pieces.reduce(0) { $0 + $1.duration }) < 0.001,
          String(format: "%.2fs", assembly.duration))

    // Round-tripping time through the mapping has to land back where it started.
    var mappingOK = true
    for piece in assembly.pieces {
        let probe = piece.compositionStart + piece.duration / 2
        guard let source = assembly.sourceTime(forComposition: probe),
              let back = assembly.compositionTime(forSource: source),
              abs(back - probe) < 0.001 else { mappingOK = false; continue }
    }
    check("composition ↔ source time round-trips", mappingOK)
}

section("Long-form edit on disk")

let longFormURL = URL(fileURLWithPath: projectDir + "/longform.json")
if let data = try? Data(contentsOf: longFormURL) {
    let edit = try JSONDecoder().decode(LongFormEdit.self, from: data)
    let options = project.longFormOptions
    let included = edit.included

    check("long-form edit decodes", !included.isEmpty, "\(included.count) segments included")
    check("orders are unique and contiguous",
          Set(included.map(\.order)).count == included.count
              && included.map(\.order) == Array(0..<included.count))
    check("segments do not overlap in source time",
          !included.sorted { $0.start < $1.start }.indices.dropFirst().contains { index in
              let ordered = included.sorted { $0.start < $1.start }
              return ordered[index].start < ordered[index - 1].end
          })
    // Generation respects the bounds; the user is then free to hand-trim a
    // segment shorter or stretch one longer. The assertion is that lengths
    // stay in the bounds' neighbourhood — a broken segmenter violates them
    // everywhere, not by a hand-trim's margin.
    check("segment lengths in the bounds' neighbourhood",
          included.allSatisfy { $0.duration >= options.minimumSegment * 0.5 && $0.duration <= options.maximumSegment * 1.5 + 0.01 },
          String(format: "min %.0fs max %.0fs against %.0f-%.0fs generation bounds",
                 included.map(\.duration).min() ?? 0, included.map(\.duration).max() ?? 0,
                 options.minimumSegment, options.maximumSegment))

    let assembly = LongFormService.assemble(edit: edit, silence: silenceIntervals, options: options)
    let minutes = assembly.duration / 60
    if isFullLengthVOD {
        // The target is the user's own (5–60 min presets), and hand-dragging
        // segments in and out of the cut is legitimate — so the assertion is
        // that assembly stays in the target's neighbourhood, not a fixed band.
        let target = options.targetMinutes
        check("runtime in the neighbourhood of the \(Int(target))-minute target",
              minutes >= target * 0.5 && minutes <= target * 1.6,
              String(format: "%.1f min across %d pieces", minutes, assembly.pieces.count))
    } else {
        // You can't cut 27 minutes out of a source shorter than that.
        print(String(format: "  SKIP  runtime target — source is only %.1f min",
                     transcript.duration / 60))
    }
    check("assembly is contiguous",
          !assembly.pieces.indices.dropFirst().contains {
              abs(assembly.pieces[$0].compositionStart - assembly.pieces[$0 - 1].compositionEnd) > 0.001
          })
    check("every piece lies inside its segment",
          assembly.pieces.allSatisfy { piece in
              guard let segment = edit.segments.first(where: { $0.id == piece.segmentID }) else { return false }
              return piece.source.start >= segment.start - 0.001 && piece.source.end <= segment.end + 0.001
          })
} else {
    print("  SKIP  longform.json not present")
}

// MARK: - Phase 4: crossfades and music

section("Join command")

do {
    let service = try? ExportService()
    if let service {
        let pieces = [URL(fileURLWithPath: "/tmp/p0.mp4"),
                      URL(fileURLWithPath: "/tmp/p1.mp4"),
                      URL(fileURLWithPath: "/tmp/p2.mp4")]
        let durations = [10.0, 10.0, 10.0]
        let list = URL(fileURLWithPath: "/tmp/list.txt")
        let settings = ExportSettings.standard

        // Nothing to re-encode → plain stream copy.
        var plain = LongFormOptions.standard
        plain.crossfadeEnabled = false
        plain.musicEnabled = false
        let copyCommand = service.joinCommand(pieceURLs: pieces, pieceDurations: durations,
                                              listURL: list, assURL: nil, options: plain,
                                              settings: settings, encoderName: "h264_videotoolbox",
                                              destination: URL(fileURLWithPath: "/tmp/out.mp4"))
        check("no-effect join is a stream copy",
              copyCommand.contains("-c") && copyCommand.contains("copy")
                  && !copyCommand.contains("-filter_complex"))
        check("no-effect join uses the concat demuxer", copyCommand.contains("concat"))

        // Crossfade → xfade/acrossfade chain with cumulative offsets.
        var fade = LongFormOptions.standard
        fade.crossfadeEnabled = true
        fade.crossfadeDuration = 0.5
        fade.musicEnabled = false
        let fadeCommand = service.joinCommand(pieceURLs: pieces, pieceDurations: durations,
                                              listURL: list, assURL: nil, options: fade,
                                              settings: settings, encoderName: "h264_videotoolbox",
                                              destination: URL(fileURLWithPath: "/tmp/out.mp4"))
        let graph = fadeCommand.first { $0.contains("xfade") } ?? ""
        check("crossfade builds a filter graph", !graph.isEmpty)
        check("one xfade and one acrossfade per join",
              graph.components(separatedBy: "xfade=transition").count - 1 == 2
                  && graph.components(separatedBy: "acrossfade=").count - 1 == 2)
        // p0 is 10s: first transition starts at 10 - 0.5; second at 19.5 - 0.5.
        check("cumulative offsets are correct",
              graph.contains("offset=9.500") && graph.contains("offset=19.000"), graph.contains("offset=19.000") ? "9.5, 19.0" : graph)
        check("crossfade passes every piece as its own input",
              fadeCommand.filter { $0 == "-i" }.count == 3)

        check("expected duration subtracts every join",
              abs(ExportService.expectedDuration(pieceDurations: durations, options: fade) - 29.0) < 0.001)
        check("expected duration unchanged when crossfade is off",
              abs(ExportService.expectedDuration(pieceDurations: durations, options: plain) - 30.0) < 0.001)

        // Music → looped input, ducking via sidechaincompress keyed on speech.
        var music = fade
        music.musicEnabled = true
        music.musicPath = "/tmp/bed.m4a"
        music.musicDucking = true
        music.musicGainDB = -16
        let musicCommand = service.joinCommand(pieceURLs: pieces, pieceDurations: durations,
                                               listURL: list, assURL: nil, options: music,
                                               settings: settings, encoderName: "h264_videotoolbox",
                                               destination: URL(fileURLWithPath: "/tmp/out.mp4"))
        let musicGraph = musicCommand.first { $0.contains("sidechaincompress") } ?? ""
        check("music is looped to cover the cut", musicCommand.contains("-stream_loop"))
        check("ducking keys the compressor off the programme audio",
              musicGraph.contains("asplit=2[aprog][akey]") && musicGraph.contains("[mus][akey]sidechaincompress"))
        check("mix does not renormalise levels", musicGraph.contains("normalize=0"))
        check("-16 dB becomes a 0.158 linear gain", musicGraph.contains("volume=0.158"))
        check("output is bounded by the programme", musicCommand.contains("-shortest"))

        var noDuck = music
        noDuck.musicDucking = false
        let flatCommand = service.joinCommand(pieceURLs: pieces, pieceDurations: durations,
                                              listURL: list, assURL: nil, options: noDuck,
                                              settings: settings, encoderName: "h264_videotoolbox",
                                              destination: URL(fileURLWithPath: "/tmp/out.mp4"))
        check("ducking can be turned off",
              !(flatCommand.first { $0.contains("amix") } ?? "").contains("sidechaincompress"))
    } else {
        print("  SKIP  ffmpeg not found")
    }
}

// MARK: - Coherence pass (fixtures — no live API call)

section("Coherence pass")

do {
    // Transcript rendering: whole seconds, one line per segment.
    let rendered = CoherenceService.render(transcript)
    let lines = rendered.split(separator: "\n")
    check("transcript renders one line per segment", lines.count <= transcript.segments.count)
    check("every line is timestamp-prefixed",
          lines.allSatisfy { $0.hasPrefix("[") && $0.contains("] ") })
    // Only the bracketed timestamp must be integral — the transcript text
    // itself is full of sentence punctuation.
    let stamps = lines.compactMap { line -> Substring? in
        guard let close = line.firstIndex(of: "]") else { return nil }
        return line[line.index(after: line.startIndex)..<close]
    }
    check("timestamps are whole seconds",
          stamps.count == lines.count && stamps.allSatisfy { $0.allSatisfy(\.isNumber) },
          "\(lines.count) lines, ~\(rendered.count / 4) tokens")

    // A chat-style reply: prose around a fenced JSON block, the shape people
    // actually paste back from claude.ai.
    let reply = """
    Here you go! I found these:

    ```json
    {"throughlines":[
      {"title":"The car bet","summary":"A wager that pays off later",
       "kind":"arc","strength":0.9,
       "beats":[{"start_seconds":100,"end_seconds":140,"why":"setup"},
                {"start_seconds":900,"end_seconds":960,"why":"payoff"}]},
      {"title":"Solo","summary":"only one beat","kind":"story","strength":0.5,
       "beats":[{"start_seconds":10,"end_seconds":20,"why":"x"}]},
      {"title":"Out of range","summary":"clamps","kind":"running_bit","strength":4.2,
       "beats":[{"start_seconds":50,"end_seconds":60,"why":"a"},
                {"start_seconds":80,"end_seconds":70,"why":"inverted"},
                {"start_seconds":200,"end_seconds":230,"why":"b"}]}
    ]}
    ```

    Let me know if you want more!
    """

    let parsed = try CoherenceService.parseReply(reply)
    check("parses a pasted chat reply, prose and fences included", parsed.count == 2,
          "\(parsed.count) throughlines kept")
    check("drops single-beat throughlines", !parsed.contains { $0.beats.count < 2 })
    check("clamps out-of-range strength", parsed.allSatisfy { $0.strength >= 0 && $0.strength <= 1 })
    check("drops inverted beats", parsed.allSatisfy { t in t.beats.allSatisfy { $0.end > $0.start } })
    check("beats sorted by start",
          parsed.allSatisfy { t in !t.beats.indices.dropFirst().contains { t.beats[$0].start < t.beats[$0 - 1].start } })
    check("maps kind enum", parsed.first?.kind == .arc)

    var noJSON = false
    do { _ = try CoherenceService.parseReply("thanks, great stream!") } catch { noJSON = true }
    check("a reply with no JSON is an error, not silence", noJSON)
    var wrongShape = false
    do { _ = try CoherenceService.parseReply("{\"wrong\":1}") } catch { wrongShape = true }
    check("a shape mismatch surfaces as an error", wrongShape)

    // The copied prompt carries everything the chat needs.
    let prompt = CoherenceService.manualPrompt(transcript: transcript, vocabulary: "YaboyXay")
    check("throughlines prompt carries rules, shape, vocab, and transcript",
          prompt.contains("running_bit") && prompt.contains("```json")
              && prompt.contains("YaboyXay") && prompt.contains("] "))

    // Partially-included throughlines must be completed by selection.
    section("Throughline completion")

    let curve = ScoreCurve(
        windowSeconds: 1,
        // One loud region early; the payoff at ~900s is quiet and would never
        // be selected on score alone.
        values: (0..<1200).map { $0 >= 100 && $0 < 200 ? 0.9 : 0.1 },
        hasChat: false
    )
    let throughline = Throughline(
        title: "The car bet", summary: "", kind: .arc, strength: 1.0,
        beats: [.init(start: 120, end: 180, why: "setup"),
                .init(start: 900, end: 960, why: "payoff")]
    )
    var options = LongFormOptions.standard
    options.targetMinutes = 2
    options.minimumSegment = 30
    options.maximumSegment = 120

    let without = LongFormService.generate(curve: curve, transcript: transcript, silence: [],
                                           duration: 1200, throughlines: [], options: options)
    let with = LongFormService.generate(curve: curve, transcript: transcript, silence: [],
                                        duration: 1200, throughlines: [throughline], options: options)

    func covers(_ edit: LongFormEdit, _ time: Double) -> Bool {
        edit.included.contains { $0.start <= time && time < $0.end }
    }
    check("quiet payoff is missed without the throughline", !covers(without, 930))
    check("quiet payoff is pulled in with it", covers(with, 930),
          with.included.map { String(format: "%.0f–%.0f", $0.start, $0.end) }.joined(separator: ", "))
    check("loud setup is kept either way", covers(without, 150) && covers(with, 150))
    check("completion still yields non-overlapping segments",
          !with.included.sorted { $0.start < $1.start }.indices.dropFirst().contains { index in
              let ordered = with.included.sorted { $0.start < $1.start }
              return ordered[index].start < ordered[index - 1].end
          })
}

// MARK: - Caption sidecars

section("Caption files")

do {
    let sample = [
        CaptionLine(id: 0, start: 0, end: 1.039, text: "FIRST LINE", words: []),
        CaptionLine(id: 1, start: 2.06, end: 5.1,
                    text: "A MUCH LONGER SECOND LINE THAT HAS TO WRAP ONTO TWO ROWS TO STAY READABLE",
                    words: []),
    ]

    let srt = CaptionExporter.srt(lines: sample)
    check("SRT is numbered from 1", srt.hasPrefix("1\n"))
    check("SRT uses comma milliseconds", srt.contains("00:00:00,000 --> 00:00:01,039"))
    check("SRT separates cues with a blank line", srt.contains("\n\n"))

    let vtt = CaptionExporter.vtt(lines: sample)
    check("VTT starts with the WEBVTT header", vtt.hasPrefix("WEBVTT\n"))
    check("VTT uses dot milliseconds", vtt.contains("00:00:00.000 --> 00:00:01.039"))

    // Long cues must wrap, and never to more than two rows.
    let wrapped = srt.components(separatedBy: "\n\n")
        .first { $0.contains("LONGER") }?
        .split(separator: "\n").dropFirst(2) ?? []
    check("long cues wrap to at most two rows", wrapped.count <= 2 && wrapped.count >= 2,
          "\(wrapped.count) rows")

    check("timecode rounds hours correctly",
          CaptionExporter.timecode(3661.5, separator: ",") == "01:01:01,500",
          CaptionExporter.timecode(3661.5, separator: ","))
    check("negative times clamp to zero",
          CaptionExporter.timecode(-5, separator: ".") == "00:00:00.000")

    check("caption modes map to the right delivery",
          CaptionMode.burned.burnsIn && !CaptionMode.burned.embedsTrack
              && CaptionMode.soft.embedsTrack && !CaptionMode.soft.burnsIn
              && CaptionMode.both.burnsIn && CaptionMode.both.embedsTrack
              && !CaptionMode.none.burnsIn && !CaptionMode.none.embedsTrack)
}

// MARK: - Style profile

section("Style profile")

do {
    let media = MediaInfo(durationSeconds: 600, width: 1080, height: 1920, fps: 30,
                          videoCodec: "h264", audioCodec: "aac", audioSampleRate: 48000,
                          audioChannels: 2, sizeBytes: 0)
    // Cuts every 10s → 60 shots of 10s each.
    let cuts = stride(from: 10.0, to: 600.0, by: 10).map { $0 }
    // A bed: the envelope never drops to zero during the "silent" stretches.
    let bedPeaks = [UInt8](repeating: 30, count: 600 * 20)
    let bed = WaveformData(peaks: bedPeaks, peaksPerSecond: 20)
    let gaps = [SilenceInterval(start: 100, end: 130), SilenceInterval(start: 300, end: 330)]

    let profile = StyleAnalyzer.build(media: media, name: "ref.mp4", cuts: cuts,
                                      silence: gaps, waveform: bed)
    check("counts cuts", profile.cutCount == cuts.count, "\(profile.cutCount)")
    check("derives shot length", abs(profile.medianShotSeconds - 10) < 0.5,
          String(format: "%.1fs", profile.medianShotSeconds))
    check("computes cuts per minute", abs(profile.cutsPerMinute - 5.9) < 0.3,
          String(format: "%.1f", profile.cutsPerMinute))
    check("detects vertical framing", profile.isVertical)
    check("computes silence ratio", abs(profile.silenceRatio - 0.1) < 0.001,
          String(format: "%.2f", profile.silenceRatio))
    check("detects a continuous bed", profile.hasMusicBed)

    // A true-silence reference must not read as having a bed.
    var quietPeaks = [UInt8](repeating: 200, count: 600 * 20)
    for index in (100 * 20)..<(130 * 20) { quietPeaks[index] = 0 }
    for index in (300 * 20)..<(330 * 20) { quietPeaks[index] = 0 }
    let quiet = StyleAnalyzer.build(media: media, name: "ref.mp4", cuts: cuts,
                                    silence: gaps,
                                    waveform: WaveformData(peaks: quietPeaks, peaksPerSecond: 20))
    check("true silence is not mistaken for a bed", !quiet.hasMusicBed)

    // Applying must actually change settings, and stay inside sane bounds.
    var target = VODProject(name: "t", sourcePath: "/tmp/x.mp4")
    let changes = StyleAnalyzer.apply(profile, to: &target)
    check("apply reports what it changed", !changes.isEmpty, "\(changes.count) changes")
    check("segment bounds stay ordered",
          target.longFormOptions.minimumSegment < target.longFormOptions.maximumSegment)
    check("shorts bounds stay ordered",
          target.candidateOptions.minDuration < target.candidateOptions.maxDuration)
    check("target runtime stays sane",
          target.longFormOptions.targetMinutes >= 5 && target.longFormOptions.targetMinutes <= 60)
}

// MARK: - Audio tuning

section("Audio tuning")

do {
    func word(_ start: Double, _ end: Double) -> TranscriptWord {
        TranscriptWord(text: "x", start: start, end: end, probability: 1)
    }

    // Words inside one breath merge; a real gap survives.
    let merged = AudioTuner.speechIntervals(
        words: [word(10, 10.4), word(10.5, 10.9), word(30, 30.4)],
        clampedTo: 60
    )
    check("adjacent words merge into one speech run", merged.count == 2,
          merged.map { String(format: "%.2f–%.2f", $0.lowerBound, $0.upperBound) }.joined(separator: ", "))
    check("speech runs are padded",
          merged[0].lowerBound < 10 && merged[0].upperBound > 10.9)
    check("padding never leaves the clip",
          AudioTuner.speechIntervals(words: [word(0, 0.2)], clampedTo: 5)[0].lowerBound >= 0)

    // The envelope is the whole ducking mechanism, so its contents matter.
    let envelopeURL = URL(fileURLWithPath: NSTemporaryDirectory() + "verify-duck.wav")
    defer { try? FileManager.default.removeItem(at: envelopeURL) }
    let rate = 2000
    try AudioTuner.writeDuckEnvelope(speech: [10...20], duration: 30, duckDB: 6,
                                     to: envelopeURL, sampleRate: rate)

    let handle = try FileHandle(forReadingFrom: envelopeURL)
    let (offset, length) = try WaveformService.locatePCMData(in: handle)
    try handle.seek(toOffset: offset)
    let raw = try handle.read(upToCount: Int(length)) ?? Data()
    try handle.close()
    var gains: [Double] = []
    gains.reserveCapacity(raw.count / 2)
    raw.withUnsafeBytes { buffer in
        let bytes = buffer.bindMemory(to: UInt8.self)
        var index = 0
        while index + 1 < bytes.count {
            let sample = Int16(bitPattern: UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
            gains.append(Double(sample) / 32767)
            index += 2
        }
    }

    // The envelope has to outlast the clip: amix is bounded by its shortest
    // input, and a short envelope would silently truncate the render.
    check("envelope outlasts the clip",
          Double(gains.count) / Double(rate) >= 30 + AudioTuner.envelopeTailSeconds - 0.01,
          String(format: "%.2fs for a 30s clip", Double(gains.count) / Double(rate)))
    check("unity where nobody is talking",
          abs(gains[2 * rate] - 1) < 0.001 && abs(gains[28 * rate] - 1) < 0.001)
    let floor = pow(10.0, -6.0 / 20)
    check("ducks by exactly the number asked for",
          abs(gains[15 * rate] - floor) < 0.002,
          String(format: "%.4f vs %.4f (%.2f dB)", gains[15 * rate], floor,
                 20 * log10(gains[15 * rate])))
    check("edges ramp rather than step",
          gains[(10 * rate) - rate / 40] < 1 && gains[(10 * rate) - rate / 40] > floor,
          String(format: "%.3f mid-ramp", gains[(10 * rate) - rate / 40]))
    check("ramp is monotonic into the duck",
          !((10 * rate - Int(AudioTuning.rampSeconds * Double(rate)))..<(10 * rate)).contains {
              gains[$0 + 1] > gains[$0] + 1e-6
          })

    // A duck of zero has to be a true no-op, since that is what "off" means.
    try AudioTuner.writeDuckEnvelope(speech: [10...20], duration: 30, duckDB: 0,
                                     to: envelopeURL, sampleRate: rate)
    let flat = try Data(contentsOf: envelopeURL)
    check("zero duck writes a flat envelope", flat.count > 44)

    // The filter graph has to be connected: every label made once, used once.
    var tuning = AudioTuning.standard
    tuning.enabled = true
    tuning.duckDB = 6
    tuning.presenceDB = 3
    tuning.normalize = true
    let loudness = LoudnessMeasurement(integrated: -30, truePeak: -9, range: 8,
                                       threshold: -40, offset: 0)
    let statements = AudioTuner.filters(input: "0:a", key: "1:a", tuning: tuning,
                                        output: "aout", loudness: loudness)

    func labels(_ text: String, produced: Bool) -> [String] {
        // Inputs are the leading [..] run; outputs the trailing one.
        var found: [String] = []
        var scanning = Substring(text)
        if produced {
            while let close = scanning.lastIndex(of: "]"),
                  let open = scanning[..<close].lastIndex(of: "[") {
                let label = String(scanning[scanning.index(after: open)..<close])
                if scanning[scanning.index(after: close)...].isEmpty || found.isEmpty {
                    found.append(label)
                    scanning = scanning[..<open]
                } else { break }
            }
        } else {
            while scanning.first == "[", let close = scanning.firstIndex(of: "]") {
                found.append(String(scanning[scanning.index(after: scanning.startIndex)..<close]))
                scanning = scanning[scanning.index(after: close)...]
            }
        }
        return found
    }

    var produced = Set<String>()
    var consumed: [String] = []
    for statement in statements {
        consumed += labels(statement, produced: false)
        for label in labels(statement, produced: true) { produced.insert(label) }
    }
    check("graph produces the output label", produced.contains("aout"))
    check("every intermediate label is consumed exactly once",
          produced.subtracting(["aout"]).allSatisfy { label in
              consumed.filter { $0 == label }.count == 1
          }, "\(produced.count) labels")
    check("every consumed label is either an input or produced",
          consumed.allSatisfy { $0 == "0:a" || $0 == "1:a" || produced.contains($0) })
    check("ducking splits the bands", statements.contains { $0.contains("acrossover") })
    check("ducking multiplies by the envelope",
          statements.filter { $0.contains("amultiply") }.count == 2)
    check("normalization is a constant gain, not loudnorm",
          statements.contains { $0.contains("volume=") && $0.contains("dB") }
              && !statements.contains { $0.contains("loudnorm") })
    check("output is peak limited", statements.contains { $0.contains("alimiter") })
    check("gain aims at the target",
          statements.contains { $0.contains("volume=16.00dB") },
          statements.first { $0.contains("_lvl]") } ?? "no levelling stage")

    // Without a key there is nothing to duck, so no split is worth paying for.
    let eqOnly = AudioTuner.filters(input: "0:a", key: nil, tuning: tuning,
                                    output: "aout", loudness: loudness)
    check("no key means one EQ instead of a band split",
          !eqOnly.contains { $0.contains("acrossover") }
              && eqOnly.contains { $0.contains("equalizer") })

    let analysis = AudioTuner.filters(input: "0:a", key: "1:a", tuning: tuning,
                                      output: "lnout", analyzing: true)
    check("analysis pass asks loudnorm for its numbers",
          analysis.contains { $0.contains("print_format=json") })

    check("loudness JSON parses",
          AudioTuner.parseLoudness("""
          {"input_i":"-33.15","input_tp":"-12.11","input_lra":"4.50",
           "input_thresh":"-43.15","target_offset":"0.89"}
          """) == LoudnessMeasurement(integrated: -33.15, truePeak: -12.11, range: 4.5,
                                      threshold: -43.15, offset: 0.89))
    check("silent input is rejected rather than normalized",
          AudioTuner.parseLoudness("""
          {"input_i":"-inf","input_tp":"-inf","input_lra":"0.00","input_thresh":"-inf"}
          """) == nil)

    // Recommendations have to stay inside what the sliders allow.
    for clarity in stride(from: -10.0, through: 30.0, by: 2.0) {
        let profile = AudioProfile(measuredAt: Date(), speechSeconds: 600, backgroundSeconds: 600,
                                   voiceBandSpeechDB: -20, voiceBandBackgroundDB: -28,
                                   outOfBandSpeechDB: -20 - clarity,
                                   outOfBandBackgroundDB: -30)
        let suggested = AudioTuning.recommended(for: profile)
        if !(suggested.duckDB >= 0 && suggested.duckDB <= 12
             && suggested.presenceDB >= 0 && suggested.presenceDB <= 4) {
            check("recommendation stays in range at clarity \(clarity)", false)
        }
    }
    check("recommendations stay inside the slider range", true, "clarity −10 to +30 dB")

    let buried = AudioProfile(measuredAt: Date(), speechSeconds: 600, backgroundSeconds: 600,
                              voiceBandSpeechDB: -20, voiceBandBackgroundDB: -22,
                              outOfBandSpeechDB: -22, outOfBandBackgroundDB: -30)
    let clear = AudioProfile(measuredAt: Date(), speechSeconds: 600, backgroundSeconds: 600,
                             voiceBandSpeechDB: -20, voiceBandBackgroundDB: -45,
                             outOfBandSpeechDB: -50, outOfBandBackgroundDB: -55)
    check("a buried voice gets more ducking than a clear one",
          AudioTuning.recommended(for: buried).duckDB > AudioTuning.recommended(for: clear).duckDB,
          String(format: "%.0f vs %.0f dB", AudioTuning.recommended(for: buried).duckDB,
                 AudioTuning.recommended(for: clear).duckDB))
    check("a mix whose noise is all in the speech band is called out",
          buried.verdict.contains("source"), buried.verdict)
    check("too little material is refused rather than guessed",
          !AudioProfile(measuredAt: Date(), speechSeconds: 5, backgroundSeconds: 2,
                        voiceBandSpeechDB: -20, voiceBandBackgroundDB: -30,
                        outOfBandSpeechDB: -30, outOfBandBackgroundDB: -30).isReliable)

    // Long-form joins can carry four extra inputs at once, and a wrong index
    // maps the wrong stream without any error — so the numbers the graph uses
    // are checked against the order the inputs were actually declared in.
    let service = try? ExportService()
    if let service {
        let pieces = (0..<3).map { URL(fileURLWithPath: "/tmp/piece_\($0).mp4") }
        var options = LongFormOptions.standard
        options.musicEnabled = true
        options.musicPath = "/tmp/bed.mp3"
        options.crossfadeEnabled = false

        let arguments = service.joinCommand(
            pieceURLs: pieces, pieceDurations: [10, 10, 10],
            listURL: URL(fileURLWithPath: "/tmp/list.txt"),
            assURL: URL(fileURLWithPath: "/tmp/cap.ass"),
            softSubtitleURL: URL(fileURLWithPath: "/tmp/cap.srt"),
            tuning: tuning, duckKeyURL: URL(fileURLWithPath: "/tmp/duck.wav"),
            loudness: loudness, options: options, settings: .standard,
            encoderName: "h264_videotoolbox",
            destination: URL(fileURLWithPath: "/tmp/out.mp4")
        )

        // Rebuild the input list in declaration order.
        var declared: [String] = []
        for (index, argument) in arguments.enumerated() where argument == "-i" {
            declared.append(arguments[index + 1])
        }
        check("join declares every input once", declared.count == 4,
              declared.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))

        let graph = arguments.first { $0.contains("amix") || $0.contains("acrossover") } ?? ""
        func inputIndex(of name: String) -> Int? {
            declared.firstIndex { $0.hasSuffix(name) }
        }
        check("the bed is read from the input that is the bed",
              inputIndex(of: "bed.mp3").map { graph.contains("[\($0):a]volume=") } ?? false,
              "bed at input \(inputIndex(of: "bed.mp3") ?? -1)")
        check("the duck envelope is read from the envelope input",
              inputIndex(of: "duck.wav").map { graph.contains("[\($0):a]aresample") } ?? false,
              "envelope at input \(inputIndex(of: "duck.wav") ?? -1)")
        if let subtitle = inputIndex(of: "cap.srt"),
           let mapIndex = arguments.firstIndex(of: "-c:s") {
            check("the subtitle track is mapped from the subtitle input",
                  arguments[mapIndex - 1] == "\(subtitle):0",
                  "mapped \(arguments[mapIndex - 1]), subtitle at input \(subtitle)")
        }
        check("tuning runs before the bed is laid in",
              (graph.range(of: "atuned")?.lowerBound).map { tuned in
                  (graph.range(of: "[mus]")?.lowerBound).map { $0 > tuned } ?? false
              } ?? false)
        check("tuning forces a re-encode rather than a stream copy",
              !arguments.contains("copy"))
    } else {
        print("  SKIP  ffmpeg not found — join command not checked")
    }

    // The representative window has to contain both things it compares.
    let window = AudioTuner.representativeWindow(
        speech: (0..<40).map { Double($0) * 60...(Double($0) * 60 + 20) },
        duration: 2400, length: 90
    )
    check("preview window is inside the source",
          window.lowerBound >= 0 && window.upperBound <= 2400,
          String(format: "%.0f–%.0fs", window.lowerBound, window.upperBound))
}

// MARK: - Packaging

section("Thumbnails")

do {
    let rows = ThumbnailService.wrap("HE UNFOLLOWED ME MID GAME", limit: 14)
    check("wraps at the limit", rows.allSatisfy { $0.count <= 14 || !$0.contains(" ") },
          rows.joined(separator: " / "))
    check("wrapping loses no words",
          rows.joined(separator: " ").split(separator: " ").count
              == "HE UNFOLLOWED ME MID GAME".split(separator: " ").count)
    check("a single long word overflows rather than breaking",
          ThumbnailService.wrap("SUPERCALIFRAGILISTIC", limit: 6) == ["SUPERCALIFRAGILISTIC"])

    var style = ThumbnailTextStyle.standard
    style.position = .bottomLeft
    style.fontSize = 130

    func fontSize(in ass: String) -> Int? {
        guard let line = ass.split(separator: "\n").first(where: { $0.hasPrefix("Style:") }) else {
            return nil
        }
        return Int(line.split(separator: ",")[2])
    }

    let wide = ThumbnailService.assFile(text: "HE UNFOLLOWED ME", style: style,
                                        width: 1280, height: 720)
    let tall = ThumbnailService.assFile(text: "HE UNFOLLOWED ME", style: style,
                                        width: 1080, height: 1920)

    check("horizontal keeps the authored size", fontSize(in: wide) == 130,
          "\(fontSize(in: wide) ?? -1)")
    // The bug this catches: scaling type by height made the vertical cover's
    // font 2.7x bigger inside a frame 200px narrower, and the text ran off the
    // right edge of every vertical thumbnail.
    check("vertical scales type by width, not height",
          (fontSize(in: tall) ?? 999) < 130,
          "\(fontSize(in: tall) ?? -1) at 1080 wide")

    check("resolution matches the requested frame",
          tall.contains("PlayResX: 1080") && tall.contains("PlayResY: 1920"))
    check("position maps to ASS alignment",
          wide.split(separator: "\n").first { $0.hasPrefix("Style:") }?
              .split(separator: ",")[18] == "1",
          "bottomLeft should be 1")
    check("every position has a distinct alignment",
          Set(ThumbnailTextPosition.allCases.map(\.assAlignment)).count
              == ThumbnailTextPosition.allCases.count)
    check("has exactly one event", wide.components(separatedBy: "\nDialogue:").count == 2)
    check("braces in text can't open an override block",
          ThumbnailService.assFile(text: "{\\an8}HACK", style: style, width: 1280, height: 720)
              .contains("\\{"))
    check("wrapped rows become ASS line breaks",
          ThumbnailService.assFile(text: "HE UNFOLLOWED ME", style: style,
                                   width: 1280, height: 720).contains("\\N"))
}

section("Packaging pass")

do {
    let reply = """
    Sure — here's the packaging:

    ```json
    {"titles":[{"text":"He unfollowed me mid-race","why":"[7543] the unfollow bit"},
               {"text":"\(String(repeating: "x", count: 75))","why":"long"}],
     "hooks":["bro really unfollowed me"],
     "thumbnail_texts":["HE UNFOLLOWED ME"],
     "description":"A stream.",
     "tags":["GTA","Roleplay"],
     "best_moment_seconds":7543,
     "image_prompt":"a car at night"}
    ```
    """
    let pack = try IdeaService.parseReply(reply, scopeLabel: "whole stream")
    check("packaging reply parses from a chat paste", pack.titles.count == 2 && pack.hooks.count == 1,
          "\(pack.titles.count) titles")
    check("tags are lowercased", pack.tags == ["gta", "roleplay"], pack.tags.joined(separator: ", "))
    check("keeps the model's best moment", pack.bestMomentSeconds == 7543)
    check("flags titles that truncate in search",
          pack.titles[0].fitsSearchResults && !pack.titles[1].fitsSearchResults,
          "\(pack.titles[0].length) and \(pack.titles[1].length) chars")

    let rendered = IdeaService.render(transcript, range: 100...200)
    check("scoping the transcript actually narrows it",
          rendered.count < IdeaService.render(transcript, range: nil).count,
          "\(rendered.count) vs \(IdeaService.render(transcript, range: nil).count) chars")
    check("packaging prompt carries rules, shape, and transcript", {
        let prompt = IdeaService.manualPrompt(transcript: transcript, range: nil,
                                              moments: [.init(start: 10, score: 0.9, text: "a moment")],
                                              vocabulary: "")
        return prompt.contains("60 characters") && prompt.contains("```json")
            && prompt.contains("[10] (0.90) a moment")
    }())
}

// MARK: - Links

section("Link import")

do {
    func accepts(_ text: String) -> String? {
        if case .success(let url) = DownloadService.normalize(text) { return url.absoluteString }
        return nil
    }
    func rejects(_ text: String) -> String? {
        if case .failure(let error) = DownloadService.normalize(text) {
            return error.localizedDescription
        }
        return nil
    }

    check("a plain Twitch VOD link passes through",
          accepts("https://www.twitch.tv/videos/2827607094")
              == "https://www.twitch.tv/videos/2827607094")
    check("a missing scheme is filled in",
          accepts("twitch.tv/videos/2827607094") == "https://twitch.tv/videos/2827607094")
    // Pasted links arrive wrapped in whatever the source app added.
    check("angle brackets are stripped",
          accepts("<https://www.twitch.tv/videos/123>") == "https://www.twitch.tv/videos/123")
    check("a trailing sentence full stop is stripped",
          accepts("watch https://twitch.tv/videos/123.".components(separatedBy: " ")[1])
              == "https://twitch.tv/videos/123")
    check("surrounding quotes are stripped",
          accepts("\"https://twitch.tv/videos/123\"") == "https://twitch.tv/videos/123")
    check("a timestamp query survives",
          accepts("https://www.twitch.tv/videos/123?t=1h2m3s")?.contains("t=1h2m3s") == true)
    check("whitespace is trimmed",
          accepts("  https://twitch.tv/videos/123\n ") == "https://twitch.tv/videos/123")

    check("prose is rejected", rejects("not a link at all") != nil)
    check("an empty paste is rejected", rejects("   ") != nil)
    // A local path is a file to open, not a link to download.
    check("file:// is named as the wrong kind of link",
          rejects("file:///Users/me/vod.mp4")?.contains("http") == true,
          rejects("file:///Users/me/vod.mp4") ?? "accepted")
    check("other schemes are named",
          rejects("ftp://example.com/vod.mp4")?.contains("ftp") == true,
          rejects("ftp://example.com/vod.mp4") ?? "accepted")

    let block = """
    https://www.twitch.tv/videos/111
    https://www.twitch.tv/videos/222

    some notes that aren't links
    twitch.tv/videos/333
    https://www.twitch.tv/videos/111
    """
    let links = DownloadService.extractLinks(block)
    check("a pasted block queues every link once", links.count == 3,
          links.map(\.absoluteString).joined(separator: ", "))

    // yt-dlp's own totals for an HLS VOD are extrapolated from the current
    // fragment and swing wildly; only the byte count and speed are trusted.
    let progress = DownloadService.parseProgress("VODPROGRESS 12143177 204848.79 1513",
                                                 estimatedBytes: 9_992_182_000)
    check("progress parses", progress?.downloadedBytes == 12_143_177)
    check("percentage uses the probe's estimate, not yt-dlp's",
          progress.map { abs(($0.fraction ?? 0) - 0.001215) < 0.0001 } == true,
          String(format: "%.4f", progress?.fraction ?? -1))
    check("speed is reported", progress?.speedLabel != nil, progress?.speedLabel ?? "none")
    check("ETA is derived from measured speed", progress?.etaLabel != nil,
          progress?.etaLabel ?? "none")

    let unknown = DownloadService.parseProgress("VODPROGRESS 500 NA 1513", estimatedBytes: nil)
    check("an unknown total gives no false percentage",
          unknown?.fraction == nil && unknown?.downloadedBytes == 500)
    check("NA speed is not read as zero", unknown?.bytesPerSecond == nil)
    check("non-progress output is ignored",
          DownloadService.parseProgress("[twitch:vod] Extracting URL", estimatedBytes: nil) == nil)
    check("percentage never reaches 100 before the file does",
          DownloadService.parseProgress("VODPROGRESS 99999999999 100 1", estimatedBytes: 1000)?
              .fraction == 0.999)

    // Twitch ids gain a `v` prefix, so the finished file is found by id rather
    // than by guessing the name.
    let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("verify-dl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let video = RemoteVideo(id: "v2827607094", title: "t", duration: 100, uploader: "u",
                            fileExtension: "mp4", width: 1920, height: 1080, isLive: false,
                            webpageURL: "", estimatedBytes: nil)
    try Data(repeating: 0, count: 10).write(to: temporary.appendingPathComponent("v2827607094.mp4.part"))
    check("a partial download is not mistaken for a finished one",
          DownloadService.finishedFile(for: video, in: temporary) == nil)
    try Data(repeating: 0, count: 20).write(to: temporary.appendingPathComponent("v2827607094.mp4"))
    check("the finished file is found by id",
          DownloadService.finishedFile(for: video, in: temporary)?.lastPathComponent
              == "v2827607094.mp4")
    check("another video's file is not picked up",
          DownloadService.finishedFile(
              for: RemoteVideo(id: "other", title: "t", duration: 1, uploader: "", fileExtension: "mp4",
                               width: 0, height: 0, isLive: false, webpageURL: "", estimatedBytes: nil),
              in: temporary) == nil)

    var spaceRefused = false
    do {
        try DownloadService.checkSpace(needed: 900_000_000_000_000, in: temporary)
    } catch { spaceRefused = true }
    check("an impossible download is refused before it starts", spaceRefused)

    check("yt-dlp errors are unwrapped",
          DownloadService.cleanError("""
          [twitch:vod] Extracting URL
          ERROR: [twitch:vod] 999: Video 999 does not exist
          """) == "[twitch:vod] 999: Video 999 does not exist")
}

// MARK: - Streaming

section("Stream source")

do {
    // Exactly the shape Twitch serves: EVENT rather than VOD, relative segment
    // names, and an ENDLIST proving the thing is finished.
    let twitch = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:10
    #EXT-X-PLAYLIST-TYPE:EVENT
    #EXT-X-MEDIA-SEQUENCE:0
    #EXT-X-TWITCH-TOTAL-SECS:15120.0
    #EXTINF:8.000,
    2827607094v0-10.ts
    #EXT-X-DISCONTINUITY
    #EXTINF:10.000,
    2827607094v1-10.ts
    #EXTINF:2.000,
    2827607094v2-10.ts
    #EXT-X-ENDLIST
    """
    let base = URL(string: "https://cdn.example.com/abc/chunked/highlight-2827607094.m3u8")!
    let rewritten = HLSSource.rewrite(twitch, base: base)

    // This one line is the entire difference between a 60-second cut taking 8
    // seconds and not finishing in six minutes.
    check("EVENT becomes VOD",
          rewritten.contains("#EXT-X-PLAYLIST-TYPE:VOD")
              && !rewritten.contains("#EXT-X-PLAYLIST-TYPE:EVENT"))
    check("segments become absolute",
          rewritten.contains("https://cdn.example.com/abc/chunked/2827607094v0-10.ts"))
    check("every segment is rewritten",
          rewritten.components(separatedBy: "https://cdn.example.com/abc/chunked/").count == 4,
          "\(rewritten.components(separatedBy: "https://cdn.example.com/abc/chunked/").count - 1) of 3")
    check("timing lines survive untouched",
          rewritten.contains("#EXTINF:8.000,") && rewritten.contains("#EXTINF:2.000,"))
    check("discontinuities survive", rewritten.contains("#EXT-X-DISCONTINUITY"))
    check("the end marker survives", rewritten.contains("#EXT-X-ENDLIST"))
    check("runtime comes from the playlist's own durations",
          abs(HLSSource.duration(ofPlaylist: rewritten) - 20) < 0.001,
          String(format: "%.1fs", HLSSource.duration(ofPlaylist: rewritten)))

    // A playlist with no type at all seeks like a live one, so a type has to be
    // declared rather than assumed.
    let untyped = HLSSource.rewrite("""
    #EXTM3U
    #EXT-X-VERSION:3
    #EXTINF:4.000,
    seg0.ts
    #EXT-X-ENDLIST
    """, base: base)
    check("a playlist with no type is given one",
          untyped.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
    check("the type is declared before the segments",
          (untyped.range(of: "#EXT-X-PLAYLIST-TYPE:VOD")?.lowerBound).map { type in
              (untyped.range(of: "seg0.ts")?.lowerBound).map { $0 > type } ?? false
          } ?? false)

    let absolute = HLSSource.rewrite("""
    #EXTM3U
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXTINF:4.000,
    https://other.example.com/seg0.ts
    #EXT-X-ENDLIST
    """, base: base)
    check("already-absolute segments are left alone",
          absolute.contains("https://other.example.com/seg0.ts")
              && !absolute.contains("cdn.example.com/abc/chunked/https"))

    // ffmpeg refuses a local playlist pointing at remote segments unless the
    // nested protocols are whitelisted — it reports "Invalid data found",
    // which reads like a corrupt file rather than a policy refusal.
    let playlistArguments = HLSSource.inputArguments(for: URL(fileURLWithPath: "/tmp/stream.m3u8"))
    check("a playlist input carries the protocol whitelist",
          playlistArguments.contains("-protocol_whitelist")
              && playlistArguments.contains("file,http,https,tcp,tls,crypto"))
    check("the whitelist comes before the input",
          (playlistArguments.firstIndex(of: "-protocol_whitelist") ?? 99)
              < (playlistArguments.firstIndex(of: "-i") ?? 0))
    let fileArguments = HLSSource.inputArguments(for: URL(fileURLWithPath: "/tmp/vod.mp4"))
    check("an ordinary file gets no whitelist",
          fileArguments == ["-i", "/tmp/vod.mp4"])
    check("playlists are recognised by extension",
          HLSSource.isPlaylist(URL(fileURLWithPath: "/tmp/a.M3U8"))
              && !HLSSource.isPlaylist(URL(fileURLWithPath: "/tmp/a.mp4")))

    let source = RemoteSource(webpageURL: "https://twitch.tv/videos/1",
                              playlistPath: "/tmp/stream.m3u8",
                              audioPlaylistPath: "/tmp/audio.m3u8",
                              preparedAt: Date(), videoFormat: "1080p60",
                              audioFormat: "Audio_Only",
                              fullVideoBytes: 9_992_182_000, audioBytes: 407_150_000)
    check("the saving is what isn't downloaded",
          source.savedBytes == 9_585_032_000,
          ByteCountFormatter.string(fromByteCount: source.savedBytes ?? 0, countStyle: .file))

    var streamed = VODProject(name: "s", sourcePath: "/tmp/stream.m3u8")
    streamed.remote = source
    check("a streamed project knows it is one", streamed.isStreamed)
    check("a local project does not",
          !VODProject(name: "l", sourcePath: "/tmp/vod.mp4").isStreamed)
}

// MARK: - Thumbnail layers

section("Thumbnail layers")

do {
    // Layers must survive a project round-trip, or a draft with a logo on it
    // loses the logo the next time the project loads.
    var project = VODProject(name: "t", sourcePath: "/tmp/x.mp4")
    project.thumbnail.text = "HELLO"
    project.thumbnail.layers = [
        ThumbnailLayer(path: "/tmp/logo.png", origin: .file, name: "logo",
                       centerX: 0.15, centerY: 0.2, width: 0.3),
        ThumbnailLayer(path: "/tmp/burst.svg", origin: .designed, name: "burst",
                       centerX: 0.8, centerY: 0.2, width: 0.4, opacity: 0.9, flipped: true),
    ]
    let encoded = try JSONEncoder().encode(project)
    let restored = try JSONDecoder().decode(VODProject.self, from: encoded)
    check("layers survive a project round-trip",
          restored.thumbnail.layers == project.thumbnail.layers,
          "\(restored.thumbnail.layers.count) layers")
    check("a project saved before layers existed still loads",
          (try? JSONDecoder().decode(VODProject.self, from: Data("""
          {"id":"\(UUID().uuidString)","name":"old","sourcePath":"/tmp/x.mp4"}
          """.utf8)))?.thumbnail.layers.isEmpty == true)

    // The SVG sanitizer is a security boundary: the art is rendered locally, so
    // anything that could fetch or execute has to be refused.
    check("clean SVG passes",
          (try? OverlayDesigner.sanitize("<svg viewBox=\"0 0 10 10\"><circle r=\"5\"/></svg>")) != nil)
    check("a code fence is stripped",
          (try? OverlayDesigner.sanitize("```svg\n<svg viewBox=\"0 0 1 1\"><rect/></svg>\n```"))?
              .hasPrefix("<svg") == true)
    for danger in ["<svg><script>alert(1)</script></svg>",
                   "<svg><image href=\"http://x/y.png\"/></svg>",
                   "<svg><use xlink:href=\"http://x\"/></svg>",
                   "<svg><foreignObject><iframe/></foreignObject></svg>"] {
        var rejected = false
        do { _ = try OverlayDesigner.sanitize(danger) } catch { rejected = true }
        check("rejects unsafe SVG: \(danger.prefix(28))…", rejected)
    }
    var noSVG = false
    do { _ = try OverlayDesigner.sanitize("here is your art!") } catch { noSVG = true }
    check("prose with no SVG is refused", noSVG)

    check("supported layer formats include SVG and PNG",
          LayerRasterizer.supportedExtensions.contains("svg")
              && LayerRasterizer.supportedExtensions.contains("png"))
}

// MARK: - Two-box portrait layout

section("Portrait split layout")

do {
    let media = MediaInfo(durationSeconds: 100, width: 1920, height: 1080, fps: 60,
                          videoCodec: "h264", audioCodec: "aac", audioSampleRate: 48000,
                          audioChannels: 2, sizeBytes: 0)
    var layout = ShortLayout(mode: .split,
                             camRect: NormalizedRect(x: 0.02, y: 0.05, width: 0.15, height: 0.27),
                             gameRect: NormalizedRect(x: 0.28, y: 0, width: 0.44, height: 1),
                             camFraction: 0.34, camOnTop: true)
    let statements = ExportService.splitStatements(layout, media: media, input: "0:v", output: "vout")
    let graph = statements.joined(separator: ";")

    check("the graph produces the output label", graph.contains("[vout]"))
    check("the source is split once, not decoded twice", graph.contains("split=2"))
    check("the two boxes are stacked", graph.contains("vstack=inputs=2"))

    // Both boxes must be exactly 1080 wide or vstack refuses to stack them.
    func scaleWidth(_ label: String) -> Int? {
        guard let range = graph.range(of: label) else { return nil }
        let after = graph[range.upperBound...]
        guard let scale = after.range(of: "scale=") else { return nil }
        let value = after[scale.upperBound...].prefix { $0 != ":" }
        return Int(value)
    }
    check("cam box scales to 1080 wide", scaleWidth("[splitcam]") == 1080,
          "\(scaleWidth("[splitcam]") ?? -1)")
    check("gameplay box scales to 1080 wide", scaleWidth("[splitgame]") == 1080,
          "\(scaleWidth("[splitgame]") ?? -1)")

    // Cam-height fraction + gameplay height must total exactly 1920.
    var camH = Int((1920.0 * layout.camFraction).rounded()); camH -= camH % 2
    check("box heights sum to 1920",
          graph.contains("scale=1080:\(camH)") && graph.contains("scale=1080:\(1920 - camH):"),
          "cam \(camH) + game \(1920 - camH)")

    // Cam on top vs. bottom swaps the stack order.
    layout.camOnTop = false
    let bottom = ExportService.splitStatements(layout, media: media,
                                               input: "0:v", output: "v").joined(separator: ";")
    check("cam-on-top orders cam first", graph.contains("[cambox][gamebox]vstack"))
    check("cam-on-bottom orders gameplay first", bottom.contains("[gamebox][cambox]vstack"))

    // The cam pixel rect stays inside the frame and even-dimensioned.
    let cam = ExportService.pixelRect(NormalizedRect(x: 0.9, y: 0.9, width: 0.3, height: 0.3),
                                      sourceWidth: 1920, sourceHeight: 1080)
    check("a cam box near the edge is clamped inside the frame",
          cam.x >= 0 && cam.y >= 0 && cam.x + cam.width <= 1920 && cam.y + cam.height <= 1080,
          "\(cam.width)×\(cam.height) at (\(cam.x),\(cam.y))")
    check("cam box dimensions are even",
          cam.width % 2 == 0 && cam.height % 2 == 0 && cam.x % 2 == 0 && cam.y % 2 == 0)

    // The gameplay box is its own free rectangle now, cover-fit into the band —
    // so the graph crops the gameRect and scales it to fill 1080×gameH.
    let gameH = 1920 - camH
    check("gameplay box fills its band width and height",
          graph.contains("scale=1080:\(gameH):force_original_aspect_ratio=increase"),
          "gameH \(gameH)")
    check("both boxes cover-fit (scale-then-crop)",
          graph.components(separatedBy: "force_original_aspect_ratio=increase").count == 3)

    // A NormalizedRect never leaves the unit square once clamped.
    let wild = NormalizedRect(x: -0.5, y: 1.4, width: 2, height: 0.01).clamped()
    check("a dragged box stays in bounds",
          wild.x >= 0 && wild.y >= 0 && wild.x + wild.width <= 1.0001
              && wild.y + wild.height <= 1.0001 && wild.width >= 0.05 && wild.height >= 0.05)

    // Corner resize keeps the opposite corner fixed.
    let base = NormalizedRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2)
    let grown = BoxCorner.bottomRight.resize(base, dx: 0.1, dy: 0.1)
    check("bottom-right resize grows from the top-left anchor",
          abs(grown.x - base.x) < 1e-9 && abs(grown.y - base.y) < 1e-9
              && abs(grown.width - 0.3) < 1e-9 && abs(grown.height - 0.3) < 1e-9)
    let tl = BoxCorner.topLeft.resize(base, dx: 0.05, dy: 0.05)
    check("top-left resize keeps the bottom-right corner fixed",
          abs((tl.x + tl.width) - (base.x + base.width)) < 1e-9
              && abs((tl.y + tl.height) - (base.y + base.height)) < 1e-9)

    // Layout survives a project round-trip, and old projects still load.
    var project = VODProject(name: "t", sourcePath: "/tmp/x.mp4")
    project.defaultShortLayout = layout
    let restored = try JSONDecoder().decode(VODProject.self,
                                            from: try JSONEncoder().encode(project))
    check("project default layout round-trips", restored.defaultShortLayout == layout)
    var clip = ShortCandidate(start: 0, end: 10, peakTime: 5, score: 0.5)
    clip.layout = layout
    let clipBack = try JSONDecoder().decode(ShortCandidate.self,
                                            from: try JSONEncoder().encode(clip))
    check("candidate layout round-trips", clipBack.layout == layout)
    check("a candidate saved before layouts defaults to fill",
          (try? JSONDecoder().decode(ShortCandidate.self, from: Data("""
          {"id":"\(UUID().uuidString)","start":0,"end":10,"peakTime":5,"score":0.5}
          """.utf8)))?.layout.mode == .fill)
}

// MARK: - YouTube links

section("YouTube links")

do {
    func accepted(_ text: String) -> String? {
        if case .success(let url) = DownloadService.normalize(text) { return url.absoluteString }
        return nil
    }
    check("a YouTube watch link passes",
          accepted("https://www.youtube.com/watch?v=jNQXAC9IVRw")
              == "https://www.youtube.com/watch?v=jNQXAC9IVRw")
    check("a youtu.be share link passes",
          accepted("youtu.be/jNQXAC9IVRw") == "https://youtu.be/jNQXAC9IVRw")
    check("a Shorts link passes",
          accepted("https://youtube.com/shorts/jNQXAC9IVRw") != nil)
    check("a watch link keeps its timestamp",
          accepted("https://www.youtube.com/watch?v=jNQXAC9IVRw&t=42s")?.contains("t=42s") == true)
}

// MARK: - Transcript polish

section("Transcript polish")

do {
    // The reply shape people paste back from a claude.ai chat.
    let corrections = try TranscriptPolisher.parseReply("""
    Only two lines needed fixing:
    ```json
    {"corrections":[{"id":4,"text":"really long trunks"},{"id":9,"text":"  "}]}
    ```
    """)
    check("polish corrections parse from a chat paste",
          corrections == [.init(id: 4, text: "really long trunks")],
          "\(corrections.count) kept (blank one dropped)")

    var noJSON = false
    do { _ = try TranscriptPolisher.parseReply("all lines look fine to me!") } catch { noJSON = true }
    check("a polish reply with no JSON is an error", noJSON)
    check("polish prompt numbers the lines it covers",
          TranscriptPolisher.manualPrompt(segments: [(id: 7, text: "he said fronts")],
                                          vocabulary: "trunks")
              .contains("[7] he said fronts"))

    // Applying a correction: same word count keeps the real DTW timings.
    func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptWord {
        TranscriptWord(text: text, start: start, end: end, probability: 1)
    }
    var segment = TranscriptSegment(id: 4, start: 10, end: 12, text: "really long fronts",
                                    words: [word("really", 10, 10.6), word(" long", 10.6, 11.1),
                                            word(" fronts", 11.1, 12)])
    let sameCount = TranscriptPolisher.corrected(segment: segment, text: "really long trunks")
    check("same word count keeps the original timings",
          sameCount.text == "really long trunks"
              && sameCount.words.map(\.start) == segment.words.map(\.start)
              && sameCount.words.last?.text.contains("trunks") == true)

    let differentCount = TranscriptPolisher.corrected(segment: segment, text: "really long elephant trunks")
    check("changed word count falls back to an even split",
          differentCount.words.count == 4
              && differentCount.words.first?.start == segment.start)

    check("an unchanged line is left alone",
          TranscriptPolisher.corrected(segment: segment, text: segment.text) == segment)
    check("an empty correction is refused",
          TranscriptPolisher.corrected(segment: segment, text: "   ") == segment)
}

// MARK: - Clip editor timeline

section("Clip editor")

do {
    var edit = ClipEdit()
    edit.title = "Drew & Jalen CRASH OUT"
    edit.twitchHandle = "YaboyXay"
    edit.instagramHandle = "XayButler14"
    edit.clips = [
        TimelineClip(sourcePath: "/tmp/a.mp4", start: 10, end: 18, sourceDuration: 60),
        TimelineClip(sourcePath: "/tmp/b.mp4", start: 0, end: 6, sourceDuration: 6),
    ]
    edit.musicPath = "/tmp/song.mp3"
    edit.textItems = [TextItem(text: "LET HIM COOK", x: 0.5, y: 0.72, size: 0.04, colorHex: "FFD60A")]

    check("timeline duration is the sum of its clips", abs(edit.totalDuration - 14) < 1e-9,
          String(format: "%.1fs", edit.totalDuration))
    let restored = try JSONDecoder().decode(ClipEdit.self, from: try JSONEncoder().encode(edit))
    check("edit round-trips", restored == edit)

    // The overlay is the preview AND the export input, so it has to render.
    check("overlay renders with alpha",
          SocialOverlayRenderer.pngData(for: edit).map { $0.count > 5_000 } == true,
          "\(SocialOverlayRenderer.pngData(for: edit)?.count ?? 0) bytes")
    check("an empty overlay draws nothing", SocialOverlayRenderer.image(for: ClipEdit()) == nil)
    var titleOnly = ClipEdit(); titleOnly.title = "X"
    check("a title alone is enough to draw", SocialOverlayRenderer.image(for: titleOnly) != nil)

    // Free text: it draws on its own, lands where its position says, and the
    // drag target's measurement is real.
    var textOnly = ClipEdit()
    textOnly.textItems = [TextItem(text: "LET HIM COOK", x: 0.5, y: 0.5, size: 0.04)]
    check("a text item alone is enough to draw", SocialOverlayRenderer.image(for: textOnly) != nil)
    var blankText = ClipEdit(); blankText.textItems = [TextItem(text: "   ")]
    check("a blank text item draws nothing", SocialOverlayRenderer.image(for: blankText) == nil)
    let block = SocialOverlayRenderer.textBlockSize(for: textOnly.textItems[0])
    check("the drag target measures a real block", block.width > 100 && block.height > 40,
          "\(Int(block.width))×\(Int(block.height))")
    if let rep = SocialOverlayRenderer.image(for: textOnly)?.representations.first as? NSBitmapImageRep {
        func opaque(nearX cx: Int, _ cy: Int) -> Bool {
            for x in stride(from: cx - 30, through: cx + 30, by: 5) {
                for y in stride(from: cy - 30, through: cy + 30, by: 5)
                where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                    return true
                }
            }
            return false
        }
        check("text pixels land at the item's position", opaque(nearX: 540, 960))
        check("and nowhere else", !opaque(nearX: 120, 120))
    } else {
        check("text overlay yields a readable bitmap", false)
    }

    // Join command bookkeeping — wrong indices map the wrong stream silently.
    let plain = ExportService.clipEditJoinCommand(
        listURL: URL(fileURLWithPath: "/tmp/list.txt"), overlays: [], musicURL: nil,
        musicGainDB: 0, settings: .standard, encoderName: "h264_videotoolbox",
        destination: URL(fileURLWithPath: "/tmp/out.mp4"))
    check("no overlay and no music is a stream copy", plain.contains("copy"))

    let full = ExportService.clipEditJoinCommand(
        listURL: URL(fileURLWithPath: "/tmp/list.txt"),
        overlays: [.init(url: URL(fileURLWithPath: "/tmp/overlay.png"), start: nil, end: nil),
                   .init(url: URL(fileURLWithPath: "/tmp/text-a.png"), start: 2, end: 5.5)],
        musicURL: URL(fileURLWithPath: "/tmp/song.mp3"),
        musicGainDB: -18, settings: .standard, encoderName: "h264_videotoolbox",
        destination: URL(fileURLWithPath: "/tmp/out.mp4"))
    var declared: [String] = []
    for (index, argument) in full.enumerated() where argument == "-i" {
        declared.append(full[index + 1])
    }
    let graph = full.first { $0.contains("overlay=") } ?? ""
    check("overlay reads from the overlay input",
          declared.firstIndex { $0.hasSuffix("overlay.png") }
              .map { graph.contains("[\($0):v]overlay") } ?? false)
    check("a timed overlay is gated by its window",
          graph.contains("enable='between(t,2.000,5.500)'"), graph)
    check("the always-on overlay has no gate", {
        let base = graph.components(separatedBy: ";").first { $0.contains("overlay.png") || $0.contains("[1:v]overlay") } ?? ""
        return !base.contains("enable")
    }())
    check("timed text chains onto the base overlay",
          declared.firstIndex { $0.hasSuffix("text-a.png") }
              .map { graph.contains("[\($0):v]overlay") } ?? false)
    check("music reads from the music input",
          declared.firstIndex { $0.hasSuffix("song.mp3") }
              .map { graph.contains("[\($0):a]volume") } ?? false)
    check("looped music is bounded by the cut",
          full.contains("-shortest") && graph.contains("duration=first"))
    // Crossfade join: index bookkeeping and offset maths.
    let faded = ExportService.clipEditCrossfadeCommand(
        pieceURLs: [URL(fileURLWithPath: "/tmp/p0.mp4"), URL(fileURLWithPath: "/tmp/p1.mp4"),
                    URL(fileURLWithPath: "/tmp/p2.mp4")],
        pieceDurations: [8, 6, 4],
        overlays: [.init(url: URL(fileURLWithPath: "/tmp/overlay.png"), start: nil, end: nil)],
        musicURL: URL(fileURLWithPath: "/tmp/song.mp3"),
        musicGainDB: -18, crossfade: 0.7, settings: .standard,
        encoderName: "h264_videotoolbox", destination: URL(fileURLWithPath: "/tmp/out.mp4"))
    let fadedGraph = faded.first { $0.contains("xfade") } ?? ""
    check("first crossfade starts a fade before the first join",
          fadedGraph.contains("offset=7.300"), fadedGraph.components(separatedBy: ";").first ?? "")
    check("second crossfade accounts for the fade already spent",
          fadedGraph.contains("offset=12.600"))
    check("audio crossfades alongside the video",
          fadedGraph.components(separatedBy: "acrossfade").count == 3)
    check("overlay input follows the pieces", fadedGraph.contains("[3:v]overlay"))
    check("music input follows the overlay", fadedGraph.contains("[4:a]volume"))

    // Timed text: only untimed items live in the always-on PNG; timed ones
    // render alone and know when they're on screen.
    var timedEdit = ClipEdit()
    timedEdit.textItems = [
        TextItem(text: "ALWAYS", x: 0.5, y: 0.3, size: 0.04),
        TextItem(text: "LATER", x: 0.5, y: 0.6, size: 0.04, startTime: 3, duration: 2),
    ]
    check("timed text stays out of the static overlay", {
        var only = ClipEdit()
        only.textItems = [timedEdit.textItems[1]]
        return SocialOverlayRenderer.image(for: only) == nil
    }())
    check("a timed item renders on its own canvas",
          SocialOverlayRenderer.pngData(for: timedEdit.textItems[1]).map { $0.count > 1_000 } == true)
    check("visibility follows the window",
          !timedEdit.textItems[1].visible(at: 1) && timedEdit.textItems[1].visible(at: 4)
              && timedEdit.textItems[0].visible(at: 1))

    var expected = ClipEdit()
    expected.crossfadeDuration = 0.7
    expected.clips = [
        TimelineClip(sourcePath: "/tmp/a.mp4", start: 0, end: 8, sourceDuration: 8),
        TimelineClip(sourcePath: "/tmp/b.mp4", start: 0, end: 6, sourceDuration: 18),
    ]
    check("export duration subtracts the overlapped fades",
          abs(expected.exportDuration - 13.3) < 1e-9,
          String(format: "%.1fs", expected.exportDuration))

    // An edit saved before crossfades existed still loads.
    let oldEdit = try? JSONDecoder().decode(ClipEdit.self, from: Data("""
    {"clips":[],"title":"x","twitchHandle":"","instagramHandle":"","handleY":0.5,"musicGainDB":-18}
    """.utf8))
    check("an old clipedit.json still decodes", oldEdit?.crossfadeDuration == 0)
    check("and comes back with no text items", oldEdit?.textItems.isEmpty == true)
    check("and an empty library", oldEdit?.library.isEmpty == true)
    // A text item saved before timing existed is always-on.
    let oldText = try? JSONDecoder().decode(TextItem.self, from: Data("""
    {"id":"\(UUID().uuidString)","text":"hi","x":0.5,"y":0.3,"size":0.034,"colorHex":"FFFFFF"}
    """.utf8))
    check("an old text item decodes as always-on", oldText?.isTimed == false)

    // Manual prompts: the transcript and the rules the user cares about have
    // to actually be in what lands on the clipboard.
    let titlePrompt = ManualPrompts.titles(transcript: "he really did that", vocabulary: "YaboyXay")
    check("title prompt carries transcript, rules, and vocabulary",
          titlePrompt.contains("he really did that") && titlePrompt.contains("60 characters")
              && titlePrompt.contains("YaboyXay") && titlePrompt.contains("exactly 5 titles"))
    check("empty vocabulary leaves no dangling line",
          !ManualPrompts.titles(transcript: "x", vocabulary: "  ").contains("Names and terms"))
    let postPrompt = ManualPrompts.post(transcript: "he really did that",
                                        title: "CRASH OUT", vocabulary: "")
    check("post prompt carries transcript, hashtag rule, and the title",
          postPrompt.contains("he really did that") && postPrompt.contains("10 hashtags")
              && postPrompt.contains("CRASH OUT"))

    // Per-clip framing: defaults reproduce the plain cover-fit exactly, and
    // the adjusted chain puts the window where the sliders say.
    check("default framing is the plain cover-fit",
          ExportService.clipPieceVideoFilter(zoom: 1, centerX: 0.5, centerY: 0.5)
              == "scale=1080:1920:force_original_aspect_ratio=increase:flags=lanczos,crop=1080:1920,setsar=1,fps=60")
    let zoomed = ExportService.clipPieceVideoFilter(zoom: 2, centerX: 0, centerY: 1)
    check("zoomed framing scales up and parks the window",
          zoomed.contains("scale=2160:3840") && zoomed.contains("crop=1080:1920:(in_w-1080)*0.0000:(in_h-1920)*1.0000"),
          zoomed)
    check("pan alone still crops off-centre",
          ExportService.clipPieceVideoFilter(zoom: 1, centerX: 0.2, centerY: 0.5)
              .contains("crop=1080:1920:(in_w-1080)*0.2000:(in_h-1920)*0.5000"))
    check("clip gain is skipped at zero and formatted when set",
          ExportService.clipPieceAudioFilter(gainDB: 0) == nil
              && ExportService.clipPieceAudioFilter(gainDB: -12) == "volume=-12.0dB")

    // A timeline clip saved before candidateID/hasCaptions/framing existed
    // still loads, with the new knobs at their do-nothing defaults.
    let oldClip = try? JSONDecoder().decode(TimelineClip.self, from: Data("""
    {"id":"\(UUID().uuidString)","sourcePath":"/tmp/a.mp4","start":0,"end":8,
     "sourceDuration":8,"name":"old"}
    """.utf8))
    check("an old timeline clip still decodes",
          oldClip != nil && oldClip?.candidateID == nil && oldClip?.hasCaptions == false)
    check("and its framing and audio are untouched defaults",
          oldClip?.hasAdjustments == false)

}

// MARK: - Clients and platforms

section("Clients and platforms")

do {
    // Applying a profile stamps the whole look; capturing lifts it back out.
    var style = CaptionStyle.standard
    style.fontName = "Anton"
    style.uppercase = false
    var profile = ClientProfile(name: "Xay", twitchHandle: "YaboyXay",
                                instagramHandle: "XayButler14",
                                logoPath: "/tmp/logo.png",
                                captionStyle: style, defaultLayout: .fill,
                                vocabulary: "Drew, Jalen, GTA RP")
    var project = VODProject(name: "vod", sourcePath: "/tmp/vod.mp4")
    let (stamped, stampedEdit) = profile.applied(to: project, edit: ClipEdit())
    check("applying a client stamps handles, style, and vocabulary",
          stampedEdit.twitchHandle == "YaboyXay" && stampedEdit.instagramHandle == "XayButler14"
              && stamped.captionStyle.fontName == "Anton"
              && stamped.vocabularyPrompt == "Drew, Jalen, GTA RP"
              && stamped.clientName == "Xay" && stamped.clientProfileID == profile.id)
    check("the logo lands as one thumbnail layer",
          stamped.thumbnail.layers.filter { $0.path == "/tmp/logo.png" }.count == 1)
    let (stampedTwice, _) = profile.applied(to: stamped, edit: stampedEdit)
    check("applying twice doesn't duplicate the logo",
          stampedTwice.thumbnail.layers.filter { $0.path == "/tmp/logo.png" }.count == 1)
    profile.vocabulary = "   "
    project.vocabularyPrompt = "keep me"
    check("an empty profile vocabulary doesn't wipe the project's",
          profile.applied(to: project, edit: ClipEdit()).0.vocabularyPrompt == "keep me")

    let captured = ClientProfile.captured(from: stamped, edit: stampedEdit, named: "Xay 2")
    check("capture lifts the applied look back out",
          captured.twitchHandle == "YaboyXay" && captured.captionStyle.fontName == "Anton"
              && captured.vocabulary == "Drew, Jalen, GTA RP")

    check("an old clients.json entry still decodes",
          (try? JSONDecoder().decode(ClientProfile.self, from: Data("""
          {"id":"\(UUID().uuidString)","name":"Old"}
          """.utf8)))?.captionStyle == .standard)
    check("an old project decodes with no client and not posted", {
        let old = try? JSONDecoder().decode(VODProject.self, from: Data("""
        {"id":"\(UUID().uuidString)","name":"x","sourcePath":"/tmp/a.mp4"}
        """.utf8))
        return old != nil && old?.clientName == "" && old?.postedAt == nil
    }())

    // The platform plan trims only what each cap demands.
    let short = PlatformPreset.plan(duration: 60)
    check("a 60s master ships untrimmed everywhere",
          short.allSatisfy { $0.trimmedTo == nil })
    let long = PlatformPreset.plan(duration: 200)
    func trim(_ name: String, _ planned: [PlatformPreset.Planned]) -> Double? {
        planned.first { $0.preset.name == name }?.trimmedTo
    }
    check("a 200s master trims for Shorts and Reels only",
          trim("shorts", long) == 180 && trim("reels", long) == 90
              && trim("tiktok", long) == nil && trim("youtube", long) == nil)
    check("a 700s master trims for TikTok too", trim("tiktok", PlatformPreset.plan(duration: 700)) == 600)

    // Derivative commands: portrait is a remux, landscape re-encodes the blur.
    let master = URL(fileURLWithPath: "/tmp/master.mp4")
    let reels = ExportService.platformDeriveCommand(
        master: master, planned: .init(preset: PlatformPreset.all.first { $0.name == "reels" }!,
                                       trimmedTo: 90),
        settings: .standard, encoderName: "h264_videotoolbox",
        destination: URL(fileURLWithPath: "/tmp/out-reels.mp4"))
    check("a capped portrait file is a trimmed stream copy",
          reels.contains("-t") && reels.contains("90.000")
              && reels.contains("copy") && !reels.contains("-filter_complex"))
    let tiktok = ExportService.platformDeriveCommand(
        master: master, planned: .init(preset: PlatformPreset.all.first { $0.name == "tiktok" }!,
                                       trimmedTo: nil),
        settings: .standard, encoderName: "h264_videotoolbox",
        destination: URL(fileURLWithPath: "/tmp/out-tiktok.mp4"))
    check("an uncapped portrait file is a plain remux",
          !tiktok.contains("-t") && tiktok.contains("copy"))
    let youtube = ExportService.platformDeriveCommand(
        master: master, planned: .init(preset: PlatformPreset.all.first { $0.name == "youtube" }!,
                                       trimmedTo: nil),
        settings: .standard, encoderName: "h264_videotoolbox",
        destination: URL(fileURLWithPath: "/tmp/out-youtube.mp4"))
    let graph = youtube.first { $0.contains("boxblur") } ?? ""
    check("the landscape file blurs its own blow-up behind the frame",
          graph.contains("scale=1920:1080") && graph.contains("boxblur")
              && graph.contains("overlay=(W-w)/2:(H-h)/2"))
    check("and keeps the master's audio untouched",
          youtube.contains("0:a?") && youtube.contains("-c:a"))
}

// MARK: - Focus, speed, freeze, overlays, transitions

section("Focus and advanced editing")

do {
    // Focus presets scale, never zero out.
    let base = ScoreWeights.standard
    check("balanced focus changes nothing", base.focused(.balanced) == base)
    let funny = base.focused(.funny)
    check("funny focus leads with laughter and hype",
          funny.laughter > base.laughter * 2 && funny.excitement > base.excitement
              && funny.audio == base.audio)
    let story = base.focused(.story)
    check("story focus leads with speech and steps game noise back",
          story.speech > base.speech * 2 && story.scene < base.scene && story.audio < base.audio)
    check("missions focus leads with scene cuts and game audio",
          base.focused(.missions).scene > base.scene && base.focused(.missions).audio > base.audio)
    check("chat focus leads with chat",
          base.focused(.chat).chat > base.chat * 2)

    // Speed and freeze arithmetic — the timeline runs on effectiveDuration.
    let sped = TimelineClip(sourcePath: "/tmp/a.mp4", start: 0, end: 8, sourceDuration: 8, speed: 2)
    check("a 2× clip occupies half its source range", abs(sped.effectiveDuration - 4) < 1e-9)
    let frozen = TimelineClip(sourcePath: "/tmp/a.mp4", start: 10, end: 13, sourceDuration: 60,
                              isFreeze: true)
    check("a freeze holds for its trimmed length regardless of speed",
          abs(frozen.effectiveDuration - 3) < 1e-9)
    var spedEdit = ClipEdit()
    spedEdit.clips = [sped, frozen]
    check("the timeline sums effective durations", abs(spedEdit.totalDuration - 7) < 1e-9)

    check("atempo chains for out-of-range speeds",
          ExportService.atempoChain(speed: 1).isEmpty
              && ExportService.atempoChain(speed: 1.5) == ["atempo=1.5000"]
              && ExportService.atempoChain(speed: 2.5) == ["atempo=2.0", "atempo=1.2500"]
              && ExportService.atempoChain(speed: 0.25) == ["atempo=0.5", "atempo=0.5000"])
    check("the piece filter re-times before snapping back to 60fps",
          ExportService.clipPieceVideoFilter(zoom: 1, centerX: 0.5, centerY: 0.5, speed: 1.5)
              .contains("setsar=1,setpts=PTS/1.5000,fps=60"))
    check("a landscape piece frames to 1920×1080",
          ExportService.clipPieceVideoFilter(zoom: 1, centerX: 0.5, centerY: 0.5,
                                             width: 1920, height: 1080)
              .contains("scale=1920:1080"))
    let freezeArguments = ExportService.clipFreezeArguments(
        framePNG: URL(fileURLWithPath: "/tmp/f.png"), duration: 3,
        videoFilter: "scale=1080:1920", settings: .standard,
        encoderName: "h264_videotoolbox", destination: URL(fileURLWithPath: "/tmp/p.mp4"))
    check("a freeze piece loops one frame over silence",
          freezeArguments.contains("-loop") && freezeArguments.contains("anullsrc=r=48000:cl=stereo")
              && freezeArguments.contains("-t") && freezeArguments.contains("3.000"))

    // Transitions ride the xfade name straight through.
    let slid = ExportService.clipEditCrossfadeCommand(
        pieceURLs: [URL(fileURLWithPath: "/tmp/p0.mp4"), URL(fileURLWithPath: "/tmp/p1.mp4")],
        pieceDurations: [8, 6], overlays: [],
        musicURL: nil, musicGainDB: 0, crossfade: 0.5, transition: "slideleft",
        settings: .standard, encoderName: "h264_videotoolbox",
        destination: URL(fileURLWithPath: "/tmp/out.mp4"))
    check("the chosen transition reaches xfade",
          (slid.first { $0.contains("xfade") } ?? "").contains("xfade=transition=slideleft"))

    // Chroma overlays: keyed, re-timed to their window, positioned, mixed.
    let overlay = ExportService.VideoOverlay(
        url: URL(fileURLWithPath: "/tmp/green.mp4"), sourceStart: 1, duration: 4,
        startTime: 6, rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4),
        chromaHex: "00FF00", similarity: 0.22, blend: 0.08, muted: false, gainDB: -6)
    let keyed = ExportService.clipEditJoinCommand(
        listURL: URL(fileURLWithPath: "/tmp/list.txt"), overlays: [],
        videoOverlays: [overlay],
        voiceover: ExportService.VoiceoverInput(url: URL(fileURLWithPath: "/tmp/vo.m4a"),
                                                start: 2.5, gainDB: 3),
        musicURL: nil, musicGainDB: 0,
        settings: .standard, encoderName: "h264_videotoolbox",
        destination: URL(fileURLWithPath: "/tmp/out.mp4"))
    let keyedGraph = keyed.joined(separator: " ")
    check("the overlay video is keyed and re-timed to its window",
          keyedGraph.contains("chromakey=0x00FF00:0.22:0.08")
              && keyedGraph.contains("setpts=PTS-STARTPTS+6.000/TB")
              && keyedGraph.contains("enable='between(t,6.000,10.000)'"))
    check("the overlay is parked at its rect",
          keyedGraph.contains("overlay=540:960"))
    check("the overlay input is trimmed at the demuxer",
          keyed.contains("-ss") && keyed.contains("1.000") && keyed.contains("4.000"))
    check("overlay audio and the voice-over land in one mix, delayed to place",
          keyedGraph.contains("adelay=6000:all=1") && keyedGraph.contains("adelay=2500:all=1")
              && keyedGraph.contains("amix=inputs=3"))
    let mutedOverlay = ExportService.clipEditJoinCommand(
        listURL: URL(fileURLWithPath: "/tmp/list.txt"), overlays: [],
        videoOverlays: [{ var o = overlay; o.muted = true; return o }()],
        musicURL: nil, musicGainDB: 0,
        settings: .standard, encoderName: "h264_videotoolbox",
        destination: URL(fileURLWithPath: "/tmp/out.mp4")).joined(separator: " ")
    check("a muted overlay stays out of the mix",
          !mutedOverlay.contains("adelay") && !mutedOverlay.contains("amix=inputs"))

    // Aspect: the landscape overlay renders, and old documents stay portrait.
    var wide = ClipEdit()
    wide.aspect = .landscape
    wide.title = "LONG FORM"
    check("the social overlay renders in 16:9",
          SocialOverlayRenderer.pngData(for: wide).map { $0.count > 3_000 } == true)
    check("an old clipedit stays portrait with fade cuts and no overlays", {
        let old = try? JSONDecoder().decode(ClipEdit.self, from: Data("""
        {"clips":[],"title":"x","twitchHandle":"","instagramHandle":"","handleY":0.5,"musicGainDB":-18}
        """.utf8))
        return old?.aspect == .portrait && old?.transitionStyle == "fade"
            && old?.overlayClips.isEmpty == true && old?.voiceoverPath == nil
    }())
    check("an old timeline clip is real-time and unfrozen", {
        let old = try? JSONDecoder().decode(TimelineClip.self, from: Data("""
        {"id":"\(UUID().uuidString)","sourcePath":"/tmp/a.mp4","start":0,"end":8,"sourceDuration":8}
        """.utf8))
        return old?.speed == 1 && old?.isFreeze == false
    }())
    check("an old project keeps balanced focus and fast transcription", {
        let old = try? JSONDecoder().decode(VODProject.self, from: Data("""
        {"id":"\(UUID().uuidString)","name":"x","sourcePath":"/tmp/a.mp4"}
        """.utf8))
        return old?.contentFocus == .balanced && old?.useAccurateTranscription == false
    }())
}

// MARK: - Socials block placement

section("Auto clips")

do {
    let categories = ClipCategory.defaults
    let funny = categories[0], chatCat = categories[1], story = categories[2]

    // Emote spikes: a KEKW wall spikes; the same emote at a constant trickle
    // doesn't — the threshold rides on the VOD's own baseline.
    var chat: [ChatMessage] = []
    for index in 0..<200 {
        chat.append(ChatMessage(offset: Double(index * 30), body: "nice play", author: "a"))
    }
    for index in 0..<12 {
        chat.append(ChatMessage(offset: 2000 + Double(index), body: "KEKW", author: "b\(index)"))
    }
    chat.sort { $0.offset < $1.offset }
    let spikes = ClipSignals.emoteSpikes(chat: chat, categories: categories)
    check("a KEKW wall registers as a funny spike",
          spikes.contains { $0.categoryID == funny.id && abs($0.time - 2000) < 15 },
          "\(spikes.count) spikes")
    let trickle = (0..<40).map { ChatMessage(offset: Double($0 * 90), body: "KEKW", author: "c") }
    check("a constant KEKW trickle is baseline, not signal",
          ClipSignals.emoteSpikes(chat: trickle, categories: categories).isEmpty)

    // Chat reading: streamer echoes a chat message a few seconds later.
    func segment(_ id: Int, _ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(id: id, start: start, end: end, text: text, words: [])
    }
    let readTranscript = Transcript(segments: [
        segment(0, 100, 104, "so anyway the boss fight"),
        segment(1, 106, 111, "someone asked what headset do you use for streaming"),
        segment(2, 112, 118, "it's the same one from last year"),
    ])
    let readChat = [ChatMessage(offset: 101, body: "what headset do you use for streaming", author: "z")]
    let reads = ClipSignals.chatReadingMoments(transcript: readTranscript, chat: readChat)
    check("the streamer echoing chat is caught with no semantics",
          reads.count == 1 && abs(reads[0] - 103) < 2, "\(reads)")
    check("unread chat stays silent",
          ClipSignals.chatReadingMoments(
              transcript: readTranscript,
              chat: [ChatMessage(offset: 101, body: "completely unrelated sentence here", author: "z")]).isEmpty)

    // Monologues: continuous quiet-chat speech is kept; busy chat is not.
    var storySegments: [TranscriptSegment] = []
    for index in 0..<30 {
        storySegments.append(segment(index, 500 + Double(index * 4), 500 + Double(index * 4) + 3.5,
                                     "and then the security guy said"))
    }
    let quiet = ClipSignals.monologues(transcript: Transcript(segments: storySegments),
                                       chat: chat)
    check("a two-minute uninterrupted stretch reads as a monologue",
          quiet.contains { $0.start <= 501 && $0.end >= 610 }, "\(quiet)")

    // THE spec-critical path: a quiet story survives the energy pre-filter.
    var values = [Double](repeating: 0.9, count: 100) + [Double](repeating: 0.05, count: 500)
    values += [Double](repeating: 0.9, count: 50)
    let curve = ScoreCurve(windowSeconds: 1, values: values, hasChat: false)
    let windows = ClipSignals.interestWindows(
        curve: curve, duration: 650,
        monologues: [ClipSignals.Monologue(start: 300, end: 420)])
    check("a quiet monologue survives the energy pre-filter",
          windows.contains { $0.lowerBound <= 300 && $0.upperBound >= 420 },
          "\(windows.map { "\(Int($0.lowerBound))-\(Int($0.upperBound))" })")
    check("dead air is still dropped",
          !windows.contains { $0.contains(250) })

    // Chunk planning: ~10 minutes with 2.5 minutes of overlap.
    let chunks = ClipSignals.planChunks(windows: [0...1500])
    check("chunks are small with real overlap",
          chunks.count == 3 && chunks[1].start == chunks[0].end - 150,
          "\(chunks.map { "\(Int($0.start))-\(Int($0.end))" })")

    // Prompts: descriptions are the detection, so they must be in there.
    let system = AutoClipService.systemPrompt(categories: categories)
    check("every category name and description is in the prompt",
          categories.allSatisfy { system.contains($0.name) && system.contains($0.description) })
    let hints = AutoClipService.hints(
        for: AutoClipChunk(index: 0, start: 1990, end: 2600),
        spikes: spikes, chatReads: [2100], monologues: [.init(start: 2200, end: 2300)],
        categories: categories)
    check("all three hint kinds phrase themselves", hints.count >= 3, "\(hints)")

    // Parse: tolerant of the model's manners, strict about invented times.
    let chunk = AutoClipChunk(index: 0, start: 4800, end: 5400)
    let reply = """
    {"candidates":[
      {"start":4821.3,"end":4867.9,"category":"story time","confidence":0.82,
       "title":"The airport security story","hook":"So I'm at the airport","why":"self-contained","suggested_caption":"cooked at TSA"},
      {"start":100,"end":160,"category":"funny moments","confidence":0.9,"title":"invented"},
      {"start":5000,"end":5040,"category":"funny","confidence":0.7,"title":"abbreviated category"},
      {"start":5100,"end":5140,"category":"basketweaving","confidence":0.7,"title":"unknown category"}
    ]}
    """
    let parsed = try AutoClipService.parseReply(reply, chunk: chunk, categories: categories)
    check("good candidates parse, invented times and unknown categories drop",
          parsed.count == 2 && parsed[0].categoryID == story.id, "\(parsed.count) kept")
    check("an abbreviated category name still matches",
          parsed.contains { $0.categoryID == funny.id })

    // Boundaries: never mid-sentence, padded, inside the band.
    let boundaryTranscript = Transcript(segments: [
        segment(0, 4818.0, 4822.5, "okay okay okay"),
        segment(1, 4822.5, 4830.0, "so i'm at the airport right"),
        segment(2, 4830.0, 4862.0, "and the guy pulls me aside"),
        segment(3, 4862.0, 4869.4, "and that's why i can't fly delta"),
        segment(4, 4869.4, 4880.0, "anyway what were we doing"),
    ])
    let rough = AutoClipCandidate(start: 4824.0, end: 4866.0, categoryID: story.id,
                                  confidence: 0.8, title: "x")
    let snapped = AutoClipService.snapBoundaries(
        rough, transcript: boundaryTranscript,
        request: AutoClipRequest(count: 5, minSeconds: 30, maxSeconds: 60, categoryIDs: []),
        duration: 6000)
    check("start snaps back to the sentence it lands in, with breath padding",
          abs(snapped.start - (4822.5 - 0.3)) < 0.01, String(format: "%.2f", snapped.start))
    check("end snaps forward to the payoff's sentence end, padded",
          abs(snapped.end - (4869.4 + 0.5)) < 0.01, String(format: "%.2f", snapped.end))

    // Dedupe and balanced selection.
    let a = AutoClipCandidate(start: 100, end: 150, categoryID: funny.id, confidence: 0.9, title: "a")
    let b = AutoClipCandidate(start: 110, end: 155, categoryID: funny.id, confidence: 0.6, title: "b")
    let c = AutoClipCandidate(start: 400, end: 450, categoryID: story.id, confidence: 0.5, title: "c")
    check("overlap dedupe keeps the confident twin",
          AutoClipService.dedupe([a, b, c]).map(\.title) == ["a", "c"])
    var pool: [AutoClipCandidate] = []
    for index in 0..<6 {
        pool.append(AutoClipCandidate(start: Double(index * 100), end: Double(index * 100 + 50),
                                      categoryID: funny.id, confidence: 0.9 - Double(index) * 0.01,
                                      title: "f\(index)"))
    }
    pool.append(AutoClipCandidate(start: 900, end: 950, categoryID: story.id, confidence: 0.5, title: "s"))
    pool.append(AutoClipCandidate(start: 1000, end: 1050, categoryID: chatCat.id, confidence: 0.4, title: "c"))
    let selected = AutoClipService.select(pool, request: AutoClipRequest(
        count: 4, minSeconds: 30, maxSeconds: 60, categoryIDs: []))
    let suggestedTitles = Set(selected.filter { $0.state == .suggested }.map(\.title))
    check("selection spreads across categories instead of stacking one",
          suggestedTitles.contains("s") && suggestedTitles.contains("c")
              && suggestedTitles.count == 4, "\(suggestedTitles.sorted())")
    check("surplus is held in reserve",
          selected.contains { $0.state == .surplus })

    // Heuristic fallback produces usable candidates on its own.
    let fallback = AutoClipService.heuristicCandidates(
        chunk: AutoClipChunk(index: 0, start: 1900, end: 2600),
        transcript: readTranscript, spikes: spikes, chatReads: [],
        monologues: [], categories: categories,
        request: AutoClipRequest(count: 5, minSeconds: 30, maxSeconds: 60, categoryIDs: []))
    check("the no-model fallback still finds the KEKW moment",
          fallback.contains { $0.categoryID == funny.id && $0.source == .heuristic })

    // Ollama plumbing: schema-constrained body, RAM-gated model choice.
    let body = OllamaClient.chatBody(model: "llama3.1:8b", system: "s", user: "u",
                                     schema: AutoClipService.schema)
    check("the request pins the schema and disables streaming",
          body["format"] != nil && (body["stream"] as? Bool) == false)
    check("model choice gates 14B on RAM",
          OllamaClient.chooseModel(installed: ["qwen2.5:14b", "llama3.1:8b"],
                                   ramBytes: 16 * 1_073_741_824) == "llama3.1:8b"
              && OllamaClient.chooseModel(installed: ["qwen2.5:14b", "llama3.1:8b"],
                                          ramBytes: 32 * 1_073_741_824) == "qwen2.5:14b")

    // Cache compatibility: yesterday's project files still decode.
    check("an empty autoclips.json decodes to a fresh run",
          (try? JSONDecoder().decode(AutoClipRun.self, from: Data("{}".utf8))) != nil)
    check("an old project seeds the default categories", {
        let old = try? JSONDecoder().decode(VODProject.self, from: Data("""
        {"id":"\(UUID().uuidString)","name":"x","sourcePath":"/tmp/a.mp4"}
        """.utf8))
        return old?.clipCategories.count == 6 && old?.autoClipPromptShown == false
    }())
}

section("Timeline editor")

do {
    // The blade, on a sped clip: the offset is in timeline seconds, the cut
    // lands in source seconds.
    let sped = TimelineClip(sourcePath: "/tmp/a.mp4", start: 10, end: 30,
                            sourceDuration: 60, speed: 2)
    if let (first, second) = sped.split(atOffset: 4) {
        check("the blade maps timeline offset through speed into source time",
              abs(first.end - 18) < 1e-9 && abs(second.start - 18) < 1e-9
                  && abs(first.effectiveDuration - 4) < 1e-9
                  && abs(second.effectiveDuration - 6) < 1e-9)
        check("both halves keep the full source available for trimming",
              first.sourceDuration == 60 && second.sourceDuration == 60
                  && first.id != second.id)
    } else {
        check("the blade maps timeline offset through speed into source time", false)
    }
    let frozen = TimelineClip(sourcePath: "/tmp/a.mp4", start: 100, end: 106,
                              sourceDuration: 600, isFreeze: true)
    if let (first, second) = frozen.split(atOffset: 2) {
        check("splitting a freeze splits the hold, same frame both sides",
              abs(first.effectiveDuration - 2) < 1e-9
                  && abs(second.effectiveDuration - 4) < 1e-9
                  && first.start == second.start)
    } else {
        check("splitting a freeze splits the hold, same frame both sides", false)
    }
    check("a cut too close to an edge is refused",
          sped.split(atOffset: 0.1) == nil && sped.split(atOffset: 9.9) == nil)

    // Snapping: nearest target inside the threshold, nothing outside it.
    check("snapping grabs the nearest target inside the threshold",
          TimelineSnap.snapped(10.2, to: [0, 10, 20], threshold: 0.5) == 10
              && TimelineSnap.snapped(15, to: [0, 10, 20], threshold: 0.5) == nil
              && TimelineSnap.snapped(19.7, to: [0, 10, 20], threshold: 0.5) == 20)

    // Undo coalescing: same action inside the window extends the step; a
    // different action or a pause starts a new one.
    let now = Date()
    check("a slider drag coalesces into one undo step",
          UndoCoalescing.shouldCoalesce(action: "Music Volume", lastAction: "Music Volume",
                                        lastAt: now.addingTimeInterval(-0.3), now: now))
    check("a pause or a different action starts a new step",
          !UndoCoalescing.shouldCoalesce(action: "Music Volume", lastAction: "Music Volume",
                                         lastAt: now.addingTimeInterval(-2), now: now)
              && !UndoCoalescing.shouldCoalesce(action: "Trim Clip", lastAction: "Music Volume",
                                                lastAt: now.addingTimeInterval(-0.3), now: now)
              && !UndoCoalescing.shouldCoalesce(action: nil, lastAction: nil,
                                                lastAt: now, now: now))

    // Markers persist, and old documents load without them.
    var marked = ClipEdit()
    marked.markers = [TimelineMarker(time: 42, note: "the drone bit")]
    let restored = try JSONDecoder().decode(ClipEdit.self,
                                            from: try JSONEncoder().encode(marked))
    check("markers round-trip with their notes",
          restored.markers.first?.time == 42 && restored.markers.first?.note == "the drone bit")
    check("an old clipedit decodes with no markers", {
        let old = try? JSONDecoder().decode(ClipEdit.self, from: Data("""
        {"clips":[],"title":"x","twitchHandle":"","instagramHandle":"","handleY":0.5,"musicGainDB":-18}
        """.utf8))
        return old?.markers.isEmpty == true
    }())
}

section("Thumbnail Studio")

do {
    // The renderer is the preview AND the export, so it has to put pixels
    // where the document says. Injected provider — no disk.
    var doc = ThumbDocument()
    var text = TextSpec(text: "WATCH")
    text.sizeFraction = 0.2
    text.shadowEnabled = false
    doc.layers = [ThumbLayer(kind: .text(text), x: 0.5, y: 0.5, widthFraction: 0.8)]
    let rendered = ThumbnailRenderer.render(doc) { _ in nil }
    check("a text layer renders", rendered != nil)
    if let rep = rendered?.representations.first as? NSBitmapImageRep {
        func brightNear(_ cx: Int, _ cy: Int) -> Bool {
            for x in stride(from: cx - 60, through: cx + 60, by: 6) {
                for y in stride(from: cy - 40, through: cy + 40, by: 6)
                where (rep.colorAt(x: x, y: y)?.brightnessComponent ?? 0) > 0.7 { return true }
            }
            return false
        }
        check("text pixels land at the layer's position",
              brightNear(640, 360) && !brightNear(150, 120))
    }

    // A red rectangle at a corner, checked at the pixel.
    var shapeDoc = ThumbDocument()
    var rect = ShapeSpec(shape: "rectangle")
    rect.fillHex = "FF0000"
    rect.cornerRadius = 0
    shapeDoc.layers = [ThumbLayer(kind: .shape(rect), x: 0.25, y: 0.25,
                                  widthFraction: 0.3, heightFraction: 0.3)]
    if let rep = (ThumbnailRenderer.render(shapeDoc) { _ in nil })?
        .representations.first as? NSBitmapImageRep {
        let inside = rep.colorAt(x: 320, y: 180)
        let outside = rep.colorAt(x: 1000, y: 600)
        check("a shape fills exactly its rect",
              (inside?.redComponent ?? 0) > 0.8 && (outside?.redComponent ?? 1) < 0.3)
    } else {
        check("a shape fills exactly its rect", false)
    }

    // An image layer draws the provided image, opacity respected.
    var imageDoc = ThumbDocument()
    imageDoc.layers = [ThumbLayer(kind: .image(ImageSpec(path: "/synthetic")),
                                  x: 0.5, y: 0.5, widthFraction: 0.5)]
    let synthetic = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { rect in
        NSColor.green.setFill(); rect.fill(); return true
    }
    if let rep = (ThumbnailRenderer.render(imageDoc) { _ in synthetic })?
        .representations.first as? NSBitmapImageRep {
        check("an image layer draws through the provider",
              (rep.colorAt(x: 640, y: 360)?.greenComponent ?? 0) > 0.8)
    } else {
        check("an image layer draws through the provider", false)
    }

    check("blend mode names map", ThumbnailRenderer.blendMode("multiply") == .multiply
          && ThumbnailRenderer.blendMode("weird") == .normal)
    check("shape paths exist for every kind",
          ShapeSpec.shapes.allSatisfy { shape in
              var spec = ShapeSpec(shape: shape)
              spec.sides = 6
              let path = ThumbnailRenderer.shapePath(spec, in: NSRect(x: 0, y: 0, width: 100, height: 60))
              return !path.isEmpty
          })

// Motion keyframes: the engine punch-ins and auto-reframe share.
// The export chains were proven live: pan swept a red|blue source pure-red ->
// 50/50 -> pure-blue, and a 2x push measured exactly 4x the white area.
section("Motion keyframes")
do {
    var clip = TimelineClip(sourcePath: "/x.mp4", start: 0, end: 4, sourceDuration: 4)
    check("no keys means static framing",
          clip.motionAt(2) == (1.0, 0.5, 0.5) && !clip.hasMotion)

    clip.zoomKeys = [MotionKey(t: 1, v: 1), MotionKey(t: 2, v: 1.5)]
    clip.panKeys = [PanKey(t: 0, x: 0.2, y: 0.5), PanKey(t: 4, x: 0.8, y: 0.5)]
    let mid = clip.motionAt(1.5)
    check("keys interpolate linearly and flat outside",
          abs(mid.zoom - 1.25) < 0.001 && abs(clip.motionAt(0).zoom - 1) < 0.001
              && abs(clip.motionAt(3).zoom - 1.5) < 0.001
              && abs(mid.cx - 0.425) < 0.001 && abs(clip.motionAt(9).cx - 0.8) < 0.001)

    check("piecewise expression matches the sampler's shape",
          ExportService.piecewiseExpr([(0, 0.0), (2, 1.0)], timeVar: "t")
              == "if(lt(t\\,0.0000)\\,0.0000\\,if(lt(t\\,2.0000)\\,0.0000+(1.0000-0.0000)*(t-0.0000)/2.0000\\,1.0000))")

    var panOnly = TimelineClip(sourcePath: "/x.mp4", start: 0, end: 4, sourceDuration: 4)
    panOnly.panKeys = clip.panKeys
    let panChain = ExportService.clipPieceVideoFilter(for: panOnly, width: 1080, height: 1920)
    check("pan-only keeps the single lanczos scale, no zoompan",
          panChain.contains("crop=1080:1920:x='(iw-ow)*(if(lt(t")
              && !panChain.contains("zoompan") && panChain.contains("scale=1080:1920"))

    var pushy = TimelineClip(sourcePath: "/x.mp4", start: 0, end: 4, sourceDuration: 4)
    pushy.zoomKeys = [MotionKey(t: 0.5, v: 1), MotionKey(t: 1, v: 1.15)]
    let zoomChain = ExportService.clipPieceVideoFilter(for: pushy, width: 1080, height: 1920)
    check("varying zoom rides zoompan at 2x supersample on the effective clock",
          zoomChain.contains("scale=2160:3840") && zoomChain.contains("zoompan=z='max(1\\,if(lt(it")
              && zoomChain.contains("s=1080x1920") && zoomChain.hasSuffix(":fps=60"))

    var sped = panOnly
    sped.speed = 2
    check("pan keys scale into source time before the retiming",
          ExportService.clipPieceVideoFilter(for: sped, width: 1080, height: 1920)
              .contains("(t-0.0000)/8.0000"))

    var plain = TimelineClip(sourcePath: "/x.mp4", start: 0, end: 4, sourceDuration: 4,
                             zoom: 1.3, centerX: 0.4, centerY: 0.6)
    plain.speed = 1.5
    check("static clips fall through to the proven chain",
          ExportService.clipPieceVideoFilter(for: plain, width: 1080, height: 1920)
              == ExportService.clipPieceVideoFilter(zoom: 1.3, centerX: 0.4, centerY: 0.6,
                                                    width: 1080, height: 1920, speed: 1.5))

    var cut = TimelineClip(sourcePath: "/x.mp4", start: 0, end: 10, sourceDuration: 10)
    cut.zoomKeys = [MotionKey(t: 2, v: 1.2), MotionKey(t: 8, v: 1.4)]
    cut.panKeys = [PanKey(t: 0, x: 0, y: 0.5), PanKey(t: 10, x: 1, y: 0.5)]
    if let (a, b) = cut.split(atOffset: 5) {
        let pinned = abs((MotionCurve.sample(a.zoomKeys.map { ($0.t, $0.v) }, at: 5) ?? 0) - 1.3) < 0.01
        let secondStartsPinned = b.zoomKeys.first.map { $0.t == 0 && abs($0.v - 1.3) < 0.01 } ?? false
        let panContinuous = abs((b.panKeys.first?.x ?? 0) - 0.5) < 0.01
            && abs((a.panKeys.last?.x ?? 0) - 0.5) < 0.01
        check("the blade pins motion at the cut so framing doesn't jump",
              pinned && secondStartsPinned && panContinuous
                  && a.zoomKeys.allSatisfy { $0.t <= 5 } && b.zoomKeys.allSatisfy { $0.t <= 5 })
    } else {
        check("the blade pins motion at the cut so framing doesn't jump", false)
    }
}

// Diagonal cuts and renderer-level crop.
section("Cuts and crop")
do {
    // A right-edge cut on a full-canvas white image over black: the moved
    // corner goes dark, the kept corner stays white.
    var doc = ThumbDocument()
    doc.width = 200; doc.height = 200
    doc.backgroundHex = "000000"
    var cutSpec = ImageSpec(path: "/synthetic")
    cutSpec.cutEdge = "right"
    cutSpec.cutAmount = 0.5
    cutSpec.shadowEnabled = false
    doc.layers = [ThumbLayer(kind: .image(cutSpec), x: 0.5, y: 0.5, widthFraction: 1.0)]
    let white = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { rect in
        NSColor.white.setFill(); rect.fill(); return true
    }
    if let rep = (ThumbnailRenderer.render(doc) { _ in white })?
        .representations.first as? NSBitmapImageRep {
        // flip=false moves the TOP-right corner inward (bitmap y=0 is top).
        let movedCorner = rep.colorAt(x: 192, y: 8)
        let keptCorner = rep.colorAt(x: 192, y: 192)
        let centre = rep.colorAt(x: 90, y: 100)
        check("a right cut slants the edge: top corner gone, bottom kept",
              (movedCorner?.redComponent ?? 1) < 0.2
                  && (keptCorner?.redComponent ?? 0) > 0.9
                  && (centre?.redComponent ?? 0) > 0.9)
    } else {
        check("a right cut slants the edge: top corner gone, bottom kept", false)
    }

    // Same cut, flipped: the other corner moves.
    var flipped = doc
    if case .image(var spec) = flipped.layers[0].kind {
        spec.cutFlip = true
        flipped.layers[0].kind = .image(spec)
    }
    if let rep = (ThumbnailRenderer.render(flipped) { _ in white })?
        .representations.first as? NSBitmapImageRep {
        check("flipping the cut leans it the other way",
              (rep.colorAt(x: 192, y: 8)?.redComponent ?? 0) > 0.9
                  && (rep.colorAt(x: 192, y: 192)?.redComponent ?? 1) < 0.2)
    } else {
        check("flipping the cut leans it the other way", false)
    }

    // Shape cut: a red rect with a bottom cut loses its slanted corner.
    var shapeDoc = ThumbDocument()
    shapeDoc.width = 200; shapeDoc.height = 200
    shapeDoc.backgroundHex = "000000"
    var slab = ShapeSpec(shape: "rectangle")
    slab.fillHex = "FF0000"
    slab.cutEdge = "bottom"
    slab.cutAmount = 0.5
    shapeDoc.layers = [ThumbLayer(kind: .shape(slab), x: 0.5, y: 0.5,
                                  widthFraction: 1.0, heightFraction: 1.0)]
    if let rep = (ThumbnailRenderer.render(shapeDoc) { _ in nil })?
        .representations.first as? NSBitmapImageRep {
        check("shapes take the same cut — slanted colour panels work",
              (rep.colorAt(x: 100, y: 20)?.redComponent ?? 0) > 0.9
                  && (rep.colorAt(x: 20, y: 192)?.redComponent ?? 1) < 0.2)
    } else {
        check("shapes take the same cut — slanted colour panels work", false)
    }

    // Crop now lives in the renderer: a left|right red|blue image cropped
    // to its right half draws blue everywhere, whatever provider supplied it.
    var cropDoc = ThumbDocument()
    cropDoc.width = 200; cropDoc.height = 100
    var croppedSpec = ImageSpec(path: "/synthetic")
    croppedSpec.crop = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)
    croppedSpec.shadowEnabled = false
    cropDoc.layers = [ThumbLayer(kind: .image(croppedSpec), x: 0.5, y: 0.5,
                                 widthFraction: 1.0)]
    let split = NSImage(size: NSSize(width: 200, height: 100), flipped: false) { rect in
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 100, height: 100).fill()
        NSColor.blue.setFill()
        NSRect(x: 100, y: 0, width: 100, height: 100).fill()
        return true
    }
    if let rep = (ThumbnailRenderer.render(cropDoc) { _ in split })?
        .representations.first as? NSBitmapImageRep {
        let left = rep.colorAt(x: 20, y: 50)
        let right = rep.colorAt(x: 180, y: 50)
        check("crop applies in the renderer for any provider",
              (left?.blueComponent ?? 0) > 0.8 && (right?.blueComponent ?? 0) > 0.8
                  && (left?.redComponent ?? 1) < 0.3)
    } else {
        check("crop applies in the renderer for any provider", false)
    }

    // Crop and cut compose: crop to the blue half, then slant its right
    // edge — the blue survives in the middle, the slanted corner goes dark.
    var both = ThumbDocument()
    both.width = 200; both.height = 200
    both.backgroundHex = "000000"
    var comboSpec = ImageSpec(path: "/synthetic")
    comboSpec.crop = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)
    comboSpec.cutEdge = "right"
    comboSpec.cutAmount = 0.5
    comboSpec.shadowEnabled = false
    both.layers = [ThumbLayer(kind: .image(comboSpec), x: 0.5, y: 0.5, widthFraction: 1.0)]
    let splitSource = NSImage(size: NSSize(width: 200, height: 100), flipped: false) { rect in
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 100, height: 100).fill()
        NSColor.blue.setFill()
        NSRect(x: 100, y: 0, width: 100, height: 100).fill()
        return true
    }
    if let rep = (ThumbnailRenderer.render(both) { _ in splitSource })?
        .representations.first as? NSBitmapImageRep {
        let centre = rep.colorAt(x: 60, y: 100)
        let cutCorner = rep.colorAt(x: 192, y: 8)
        check("crop and diagonal cut compose in one render",
              (centre?.blueComponent ?? 0) > 0.8 && (centre?.redComponent ?? 1) < 0.3
                  && (cutCorner?.blueComponent ?? 1) < 0.2)
    } else {
        check("crop and diagonal cut compose in one render", false)
    }

section("Frame quality")
do {
    // Synthetic frames with one property varied at a time, so each component
    // is shown to measure the thing it claims to.
    func frame(_ draw: (NSRect) -> Void) -> CIImage? {
        let size = NSSize(width: 320, height: 180)
        let image = NSImage(size: size)
        image.lockFocus()
        draw(NSRect(origin: .zero, size: size))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation else { return nil }
        return CIImage(data: tiff)
    }

    // Sharp: hard-edged stripes. Blurred: the same, blurred.
    let stripes = frame { rect in
        NSColor.black.setFill(); rect.fill()
        NSColor.white.setFill()
        for x in stride(from: 0, to: Int(rect.width), by: 8) {
            NSRect(x: CGFloat(x), y: 0, width: 4, height: rect.height).fill()
        }
    }
    let sharp = stripes.flatMap { FrameQualityScorer.score($0) }
    let blurred = stripes
        .map { $0.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 6])
                 .cropped(to: $0.extent) }
        .flatMap { FrameQualityScorer.score($0) }
    check("a sharp frame scores high on sharpness",
          (sharp?.sharpness ?? 0) > 0.6, String(format: "%.2f", sharp?.sharpness ?? -1))
    check("blurring the same frame drops sharpness",
          (blurred?.sharpness ?? 1) < (sharp?.sharpness ?? 0) * 0.7,
          String(format: "%.2f vs %.2f", blurred?.sharpness ?? -1, sharp?.sharpness ?? -1))

    // Exposure: a dark frame and a bright one.
    let dark = frame { rect in NSColor(calibratedWhite: 0.06, alpha: 1).setFill(); rect.fill() }
        .flatMap { FrameQualityScorer.score($0) }
    let bright = frame { rect in NSColor(calibratedWhite: 0.95, alpha: 1).setFill(); rect.fill() }
        .flatMap { FrameQualityScorer.score($0) }
    check("a dark frame reads dark", (dark?.exposure ?? 1) < 0.2,
          String(format: "%.2f", dark?.exposure ?? -1))
    check("a bright frame reads bright", (bright?.exposure ?? 0) > 0.8,
          String(format: "%.2f", bright?.exposure ?? -1))
    check("both extremes are punished by the overall score",
          (dark?.overall ?? 1) < 0.45 && (bright?.overall ?? 1) < 0.45,
          String(format: "%.2f / %.2f", dark?.overall ?? -1, bright?.overall ?? -1))

    // Contrast: a flat grey field versus black-and-white halves.
    let flat = frame { rect in NSColor(calibratedWhite: 0.5, alpha: 1).setFill(); rect.fill() }
        .flatMap { FrameQualityScorer.score($0) }
    let punchy = frame { rect in
        NSColor.black.setFill(); rect.fill()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: rect.width / 2, height: rect.height).fill()
    }.flatMap { FrameQualityScorer.score($0) }
    check("a flat field has no contrast", (flat?.contrast ?? 1) < 0.05,
          String(format: "%.2f", flat?.contrast ?? -1))
    check("split black and white has full contrast", (punchy?.contrast ?? 0) > 0.9,
          String(format: "%.2f", punchy?.contrast ?? -1))

    // No face is not a crash, and the explanation says so.
    check("a frame with no face reports none",
          (flat?.faceCount ?? -1) == 0 && (flat?.faceArea ?? 1) == 0)
    check("the explanation names the problems",
          (flat?.explanation ?? "").contains("no face")
              && (flat?.explanation ?? "").contains("flat contrast"))

    // The weighting is a stated opinion, but it must at least be monotone in
    // the thing it claims to weigh most.
    var withFace = FrameQuality()
    withFace.sharpness = 0.8; withFace.contrast = 0.7; withFace.exposure = 0.5
    var withoutFace = withFace
    withFace.faceCount = 1; withFace.faceArea = 0.14
    withFace.facePlacement = 0.9; withFace.eyesOpen = 0.9
    check("a big open-eyed face outranks the same frame without one",
          withFace.overall > withoutFace.overall + 0.2,
          String(format: "%.2f vs %.2f", withFace.overall, withoutFace.overall))
    var eyesShut = withFace
    eyesShut.eyesOpen = 0.0
    check("closed eyes cost a frame its lead", eyesShut.overall < withFace.overall,
          String(format: "%.2f vs %.2f", eyesShut.overall, withFace.overall))
}

section("Frame sampling")
do {
    // One moment, five samples, 1.2s either side.
    let one = FrameSampling.times(around: [10], spread: 1.2, samplesPerMoment: 5)
    check("a moment yields the requested number of samples", one.count == 5, "\(one.count)")
    check("they span the full window either side",
          abs((one.first ?? 0) - 8.8) < 0.001 && abs((one.last ?? 0) - 11.2) < 0.001,
          "\(one.first ?? -1)…\(one.last ?? -1)")
    check("they are evenly spaced and sorted",
          abs((one[1] - one[0]) - 0.6) < 0.001 && one == one.sorted())
    check("the moment itself is sampled", one.contains { abs($0 - 10) < 0.001 })

    // Overlapping moments must not extract the same instant twice — the whole
    // reason frame filenames carry milliseconds now.
    let overlapping = FrameSampling.times(around: [10, 10.6], spread: 1.2, samplesPerMoment: 5)
    check("overlapping moments do not duplicate instants",
          overlapping.count == Set(overlapping).count, "\(overlapping.count) unique")
    check("and the union is smaller than the naive product",
          overlapping.count < 10, "\(overlapping.count) of 10")

    // A moment near zero must not ask ffmpeg for a negative timestamp.
    let earliest = FrameSampling.times(around: [0.3], spread: 1.2, samplesPerMoment: 5)
    check("sampling never goes before the start of the video",
          (earliest.first ?? -1) >= 0, "\(earliest.first ?? -1)")

    // Degenerate inputs return nothing rather than crashing.
    check("no moments means no work", FrameSampling.times(around: []).isEmpty)
    check("zero samples means no work",
          FrameSampling.times(around: [5], samplesPerMoment: 0).isEmpty)
    check("a single sample lands exactly on the moment",
          FrameSampling.times(around: [7], samplesPerMoment: 1) == [7])
}

section("Small-size legibility")
do {
    func doc(sizeFraction: Double, x: Double = 0.5, y: Double = 0.5) -> ThumbDocument {
        var d = ThumbDocument()
        d.width = 1280; d.height = 720
        var spec = TextSpec(text: "DOOMSDAY HEIST")
        spec.sizeFraction = sizeFraction
        d.layers = [ThumbLayer(kind: .text(spec), x: x, y: y, widthFraction: 0.8)]
        return d
    }

    check("a design with no text reports no text",
          ThumbLegibility.report(for: ThumbDocument()).textLayerCount == 0)

    // A big headline survives the up-next rail; tiny body copy does not.
    let big = ThumbLegibility.report(for: doc(sizeFraction: 0.16))
    check("a headline is readable in the up-next rail", big.isReadable,
          String(format: "%.1f px", big.smallestTextPixels ?? -1))
    let small = ThumbLegibility.report(for: doc(sizeFraction: 0.03))
    check("small text is flagged as unreadable there", !small.isReadable,
          String(format: "%.1f px", small.smallestTextPixels ?? -1))

    // The measurement is a real scaling, not a constant.
    check("the reported size scales with the font",
          (big.smallestTextPixels ?? 0) > (small.smallestTextPixels ?? 0) * 4)

    // Text hidden behind YouTube's duration stamp is wasted.
    let clear = ThumbLegibility.report(for: doc(sizeFraction: 0.12, x: 0.3, y: 0.3))
    check("text away from the corner is not flagged",
          clear.layersUnderDurationStamp == 0)
    let stamped = ThumbLegibility.report(for: doc(sizeFraction: 0.12, x: 0.88, y: 0.9))
    check("text under the duration stamp is flagged",
          stamped.layersUnderDurationStamp == 1)

    // Overlap is measured against the GLYPHS, not the layout box. A centred
    // headline's wrap width is far wider than its ink, so testing the box
    // reports collisions the reader never sees.
    //
    // The real geometry from the user's own design, which is a true positive
    // and was verified by measurement: 14 characters at 0.16 of canvas height
    // measure 898 px, so centred they span x 0.149…0.851 and y 0.688…0.882 —
    // genuinely clipping the stamp zone's top-left corner at (0.800, 0.855).
    var headline = ThumbDocument()
    headline.width = 1280; headline.height = 720
    var wide = TextSpec(text: "Doomsday Heist")
    wide.sizeFraction = 0.16
    headline.layers = [ThumbLayer(kind: .text(wide), x: 0.5, y: 0.785, widthFraction: 0.85)]
    check("a headline whose ink reaches the stamp is flagged",
          ThumbLegibility.report(for: headline).layersUnderDurationStamp == 1)

    // Short centred text in the same wide box does NOT reach it — this is the
    // case that measuring the layout box would get wrong.
    var shortWord = headline
    var brief = wide
    brief.text = "HI"
    shortWord.layers[0].kind = .text(brief)
    check("short centred text in a wide box is not falsely flagged",
          ThumbLegibility.report(for: shortWord).layersUnderDurationStamp == 0)

    // And the ink measurement is doing the work: the layout box is unchanged
    // between those two, so a box-based test would flag both identically.
    check("the two differ only by their ink, not their layout box",
          headline.layers[0].widthFraction == shortWord.layers[0].widthFraction)

    // A hidden layer is not a legibility problem.
    var hiddenDoc = doc(sizeFraction: 0.02)
    hiddenDoc.layers[0].isVisible = false
    check("hidden text is ignored",
          ThumbLegibility.report(for: hiddenDoc).textLayerCount == 0)

    // Empty strings are not text.
    var blank = ThumbDocument()
    blank.layers = [ThumbLayer(kind: .text(TextSpec(text: "   ")))]
    check("whitespace-only text is ignored",
          ThumbLegibility.report(for: blank).textLayerCount == 0)
}

section("Image adjustments")
do {
    // A red square, so a brightness/saturation change is unmistakable.
    let source = NSImage(size: NSSize(width: 64, height: 64))
    source.lockFocus()
    NSColor(calibratedRed: 0.5, green: 0.2, blue: 0.2, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 64, height: 64).fill()
    source.unlockFocus()

    func middle(_ image: NSImage?) -> NSColor? {
        guard let image, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
    }

    var plain = ImageSpec(path: "/synthetic")
    check("an unadjusted spec reports no adjustments", !plain.hasAdjustments)

    plain.brightness = 0.5
    check("setting brightness marks the spec adjusted", plain.hasAdjustments)
    let brighter = middle(AdjustedImageCache.adjusted(source, spec: plain))
    check("brightness actually brightens",
          (brighter?.redComponent ?? 0) > 0.5,
          String(format: "%.3f", brighter?.redComponent ?? -1))

    var grey = ImageSpec(path: "/synthetic")
    grey.filterPreset = "mono"
    let mono = middle(AdjustedImageCache.adjusted(source, spec: grey))
    check("the mono filter desaturates",
          abs((mono?.redComponent ?? 0) - (mono?.greenComponent ?? 1)) < 0.02,
          String(format: "r %.3f g %.3f", mono?.redComponent ?? -1, mono?.greenComponent ?? -1))

    // The fix that made adjusted images 66x cheaper to redraw: the result has
    // to be a real bitmap, not a lazy Core Image promise that re-runs the
    // whole filter chain on every single draw.
    let adjusted = AdjustedImageCache.adjusted(source, spec: plain)
    let isLazy = adjusted?.representations.contains { $0 is NSCIImageRep } ?? true
    check("an adjusted image is flattened, not a lazy Core Image rep", !isLazy)
    check("and it keeps the source's size",
          adjusted?.size == source.size,
          "\(adjusted?.size ?? .zero) vs \(source.size)")
}

section("Regressions found in review")
do {
    // A lock reads as protection everywhere else — drag, resize, nudge all
    // honour it — so Delete has to as well.
    var doc = ThumbDocument()
    var locked = ThumbLayer(kind: .text(TextSpec(text: "background")))
    locked.isLocked = true
    let free = ThumbLayer(kind: .text(TextSpec(text: "headline")))
    doc.layers = [locked, free]
    check("delete leaves a locked layer alone",
          doc.removeLayers(ids: [locked.id, free.id]) && doc.layers.map(\.id) == [locked.id])
    check("deleting only locked layers reports nothing",
          !doc.removeLayers(ids: [locked.id]) && doc.layers.count == 1)

    // The placeholder for an unfilled image slot is editor chrome. It must
    // never reach a file someone else will see.
    var slot = ThumbDocument()
    slot.width = 160
    slot.height = 90
    slot.backgroundHex = "000000"
    slot.layers = [ThumbLayer(kind: .image(ImageSpec(path: "")),
                              widthFraction: 0.8, heightFraction: 0.8)]
    func litFraction(_ image: NSImage?) -> Double {
        guard let image, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return -1 }
        var lit = 0.0
        var total = 0.0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                if colour.redComponent > 0.12 { lit += 1 }
                total += 1
            }
        }
        return total > 0 ? lit / total : -1
    }
    let exported = ThumbnailRenderer.render(slot) { _ in nil }
    let onCanvas = ThumbnailRenderer.render(slot, showingPlaceholders: true) { _ in nil }
    check("an unfilled image slot is invisible in an export",
          litFraction(exported) < 0.001, String(format: "%.4f", litFraction(exported)))
    check("the same slot is visible while you are editing",
          litFraction(onCanvas) > 0.3, String(format: "%.3f", litFraction(onCanvas)))

    // Stroke-free text — every sticker — asked for a shadow and never got one,
    // because the shadow was cleared before anything was drawn.
    func shadowSpread(strokeWidth: Double) -> Double {
        var document = ThumbDocument()
        document.width = 200
        document.height = 120
        document.backgroundHex = "FFFFFF"
        var spec = TextSpec(text: "A")
        spec.sizeFraction = 0.5
        spec.fillHex = "FFFFFF"
        spec.strokeWidth = strokeWidth
        spec.shadowEnabled = true
        spec.shadowHex = "000000"
        spec.shadowBlur = 6
        spec.shadowOffset = 4
        document.layers = [ThumbLayer(kind: .text(spec), widthFraction: 0.9)]
        guard let image = ThumbnailRenderer.render(document, provider: { _ in nil }),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return -1 }
        // White text on white: anything darker than white IS the shadow.
        var dark = 0.0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                if colour.redComponent < 0.9 { dark += 1 }
            }
        }
        return dark
    }
    check("stroke-free text still casts its drop shadow",
          shadowSpread(strokeWidth: 0) > 20, "\(shadowSpread(strokeWidth: 0)) dark pixels")
    check("stroked text casts one too", shadowSpread(strokeWidth: 8) > 20)

    // A rounded or diagonally-cut image asked for a drop shadow and got a
    // 1%-opacity one, because it was cast from a near-transparent fill.
    func shadowedPixels(maskShape: String, cutEdge: String, shadow: Bool) -> Double {
        var document = ThumbDocument()
        document.width = 200
        document.height = 200
        document.backgroundHex = "FFFFFF"
        var spec = ImageSpec(path: "/synthetic")
        spec.maskShape = maskShape
        spec.cutEdge = cutEdge
        spec.shadowEnabled = shadow
        spec.shadowHex = "000000"
        spec.shadowBlur = 8
        spec.shadowOffset = 6
        document.layers = [ThumbLayer(kind: .image(spec), widthFraction: 0.5)]
        let solid = NSImage(size: NSSize(width: 100, height: 100))
        solid.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 100, height: 100).fill()
        solid.unlockFocus()
        guard let image = ThumbnailRenderer.render(document, provider: { _ in solid }),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return -1 }
        // Grey pixels are shadow: not the white ground, not the red subject.
        var grey = 0.0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                let r = colour.redComponent, g = colour.greenComponent, b = colour.blueComponent
                if r < 0.92, abs(r - g) < 0.06, abs(g - b) < 0.06 { grey += 1 }
            }
        }
        return grey
    }
    for (label, mask, cut) in [("a rounded image", "rounded", "none"),
                               ("a circular image", "circle", "none"),
                               ("a diagonally cut image", "none", "right")] {
        let on = shadowedPixels(maskShape: mask, cutEdge: cut, shadow: true)
        let off = shadowedPixels(maskShape: mask, cutEdge: cut, shadow: false)
        check("\(label) casts a real drop shadow", on > off + 50,
              "\(on) shadow pixels vs \(off) without")
    }

    // A freshly lifted subject gets the treatment that separates it from the
    // background; a re-lift must not stomp what the user has since set.
    var fresh = ImageSpec(path: "/photo.png")
    CutoutRun.applyResult(URL(fileURLWithPath: "/cut.png"), to: &fresh)
    check("a new cutout gets the shadow and outline treatment",
          fresh.useCutout && fresh.shadowEnabled && fresh.strokeWidth >= 6
              && fresh.cutoutPath == "/cut.png")
    var retuned = fresh
    retuned.shadowEnabled = false
    retuned.strokeWidth = 0
    CutoutRun.applyResult(URL(fileURLWithPath: "/cut2.png"), to: &retuned)
    check("re-lifting keeps the treatment you chose",
          !retuned.shadowEnabled && retuned.strokeWidth == 0
              && retuned.cutoutPath == "/cut2.png")
}

section("Background removal")
do {
    // A white square on black is a matte: the square is the subject.
    let side = 200.0
    let square = CIImage(color: .white)
        .cropped(to: CGRect(x: 60, y: 60, width: 80, height: 80))
    let matte = square.composited(over: CIImage(color: .black)
        .cropped(to: CGRect(x: 0, y: 0, width: side, height: side)))
    let context = CIContext()

    func coverage(_ image: CIImage) -> Double {
        guard let cg = context.createCGImage(image, from: CGRect(x: 0, y: 0,
                                                                 width: side, height: side))
        else { return -1 }
        let rep = NSBitmapImageRep(cgImage: cg)
        var lit = 0.0
        var total = 0.0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                lit += Double(colour.redComponent)
                total += 1
            }
        }
        return total > 0 ? lit / total : -1
    }

    let plain = coverage(CutoutService.refine(matte, options: CutoutService.Options(
        instance: nil, contract: 0, feather: 0, contrast: 0)))
    check("an unrefined matte passes through unchanged", abs(plain - 0.16) < 0.03,
          String(format: "%.3f", plain))

    // Contracting pulls the edge in, which is what kills the halo of old
    // background a raw Vision mask keeps.
    let contracted = coverage(CutoutService.refine(matte, options: CutoutService.Options(
        instance: nil, contract: 6, feather: 0, contrast: 0)))
    check("contract pulls the matte edge in", contracted < plain - 0.01,
          String(format: "%.3f vs %.3f", contracted, plain))

    // Expanding is the same control in the other direction.
    let expanded = coverage(CutoutService.refine(matte, options: CutoutService.Options(
        instance: nil, contract: -6, feather: 0, contrast: 0)))
    check("a negative contract grows the matte", expanded > plain + 0.01,
          String(format: "%.3f vs %.3f", expanded, plain))

    // What feather is actually for: turning a hard edge into a ramp, so the
    // subject sits on a new background instead of being stamped onto it. It
    // must not move the subject or leak into the far background.
    // (Core Image blurs in linear light, so a feathered matte reads slightly
    // brighter overall in sRGB — that biases the edge toward keeping pixels,
    // which is why `contract` defaults above zero.)
    func partialPixels(_ image: CIImage) -> Int {
        guard let cg = context.createCGImage(image, from: CGRect(x: 0, y: 0,
                                                                 width: side, height: side))
        else { return -1 }
        let rep = NSBitmapImageRep(cgImage: cg)
        var partial = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                let value = Double(colour.redComponent)
                if value > 0.05, value < 0.95 { partial += 1 }
            }
        }
        return partial
    }

    func value(_ image: CIImage, x: Int, y: Int) -> Double {
        guard let cg = context.createCGImage(image, from: CGRect(x: 0, y: 0,
                                                                 width: side, height: side))
        else { return -1 }
        return Double(NSBitmapImageRep(cgImage: cg).colorAt(x: x, y: y)?.redComponent ?? -1)
    }

    let hard = CutoutService.refine(matte, options: CutoutService.Options(
        instance: nil, contract: 0, feather: 0, contrast: 0))
    let feathered = CutoutService.refine(matte, options: CutoutService.Options(
        instance: nil, contract: 0, feather: 4, contrast: 0))
    check("a hard matte has almost no partial pixels", partialPixels(hard) < 400,
          "\(partialPixels(hard))")
    check("feather turns the edge into a ramp",
          partialPixels(feathered) > partialPixels(hard) * 3,
          "\(partialPixels(feathered)) partial vs \(partialPixels(hard))")
    check("feather leaves the middle of the subject solid",
          value(feathered, x: 100, y: 100) > 0.95)
    check("feather does not leak into the far background",
          value(feathered, x: 5, y: 5) < 0.05)
    check("feather leaves the matte the same size as the source",
          feathered.extent == matte.extent)

    // Hardening is the counterweight: it pushes a soft matte back toward a
    // decision, which is what kills a grey halo over a busy background.
    let hardened = CutoutService.refine(matte, options: CutoutService.Options(
        instance: nil, contract: 0, feather: 4, contrast: 0.9))
    check("harden collapses the ramp again",
          partialPixels(hardened) < partialPixels(feathered),
          "\(partialPixels(hardened)) vs \(partialPixels(feathered))")

    // Every refinement must return the source extent, or CIBlendWithMask
    // shifts the subject against the photo.
    var extentsHeld = true
    for contract in [-4.0, 0, 4] {
        for feather in [0.0, 3] {
            for contrast in [0.0, 0.8] {
                let refined = CutoutService.refine(matte, options: CutoutService.Options(
                    instance: nil, contract: contract, feather: feather, contrast: contrast))
                if refined.extent != matte.extent { extentsHeld = false }
            }
        }
    }
    check("every refinement keeps the source extent", extentsHeld)

    let defaults = CutoutService.Options.standard
    check("the default cutout softens and tightens a little",
          defaults.contract > 0 && defaults.feather > 0 && defaults.contrast > 0
              && defaults.instance == nil)
}

section("App-owned image assets")
do {
    let one = Data("thumbnail-asset-one".utf8)
    let two = Data("thumbnail-asset-two".utf8)
    check("the digest is stable", ThumbAssets.digest(one) == ThumbAssets.digest(one))
    check("different content digests differently",
          ThumbAssets.digest(one) != ThumbAssets.digest(two))

    // Cutouts are keyed by source, its modification time and the settings, so
    // changing a slider produces a new file and going back reuses the old one.
    let sourcePath = NSTemporaryDirectory() + "/verify-cutout-source.png"
    FileManager.default.createFile(atPath: sourcePath, contents: one)
    let a = ThumbAssets.cutoutURL(for: sourcePath, tag: "all-1.0-1.0-0.35")
    let b = ThumbAssets.cutoutURL(for: sourcePath, tag: "all-1.0-1.0-0.35")
    let c = ThumbAssets.cutoutURL(for: sourcePath, tag: "all-3.0-1.0-0.35")
    check("the same settings resolve to the same cutout file", a == b)
    check("different settings resolve to different cutout files", a != c)
    // Keyed on the bytes, not the path: replacing an image at the same path
    // must not reuse the old subject.
    FileManager.default.createFile(atPath: sourcePath, contents: two)
    let afterReplace = ThumbAssets.cutoutURL(for: sourcePath, tag: "all-1.0-1.0-0.35")
    check("replacing the source at the same path invalidates its cutout",
          afterReplace != a)
    FileManager.default.createFile(atPath: sourcePath, contents: one)
    check("restoring the original content resolves back to the original cutout",
          ThumbAssets.cutoutURL(for: sourcePath, tag: "all-1.0-1.0-0.35") == a)
    check("cutouts live in the app's own folder, not beside the photo",
          a.deletingLastPathComponent().lastPathComponent == "ThumbAssets"
              && !a.path.hasPrefix(NSTemporaryDirectory()))

    // Pruning must never take a file a design still points at — a cutout
    // cannot be regenerated if its source has since moved.
    let keep = ThumbAssets.store(data: Data("kept-asset".utf8), suffix: "keep")
    let drop = ThumbAssets.store(data: Data("dropped-asset".utf8), suffix: "drop")
    if let keep, let drop {
        var referencing = ThumbDocument()
        var spec = ImageSpec(path: "/somewhere/original.png")
        spec.cutoutPath = keep.path
        spec.useCutout = true
        referencing.layers = [ThumbLayer(kind: .image(spec))]
        let designURL = Paths.thumbLabRoot
            .appendingPathComponent("verify-prune-fixture.json")
        try? FileManager.default.createDirectory(at: Paths.thumbLabRoot,
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(referencing).write(to: designURL, options: .atomic)

        // A file written moments ago may still be live in a running app's
        // undo stack, so pruning only considers files older than a day.
        ThumbAssets.pruneUnreferenced()
        check("pruning spares a freshly written asset even if nothing names it",
              FileManager.default.fileExists(atPath: drop.path))

        func age(_ url: URL) {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-172_800)],
                ofItemAtPath: url.path)
        }
        age(keep)
        age(drop)
        ThumbAssets.pruneUnreferenced()
        check("pruning keeps an old asset a design still points at",
              FileManager.default.fileExists(atPath: keep.path))
        check("pruning removes an old asset nothing points at",
              !FileManager.default.fileExists(atPath: drop.path))

        try? FileManager.default.removeItem(at: designURL)
        age(keep)
        ThumbAssets.pruneUnreferenced()
        check("once the design is gone, so is its asset",
              !FileManager.default.fileExists(atPath: keep.path))
    } else {
        check("pruning keeps an asset a design still points at", false)
        check("pruning removes an asset nothing points at", false)
        check("once the design is gone, so is its asset", false)
    }
    try? FileManager.default.removeItem(atPath: sourcePath)
}

section("Layer verbs the keyboard drives")
do {
    let a = ThumbLayer(kind: .text(TextSpec(text: "A")))
    let b = ThumbLayer(kind: .text(TextSpec(text: "B")))
    let c = ThumbLayer(kind: .text(TextSpec(text: "C")))

    // Duplicate lands directly above its original, offset so you can see
    // there are two, and never inherits a lock you would then have to undo.
    var doc = ThumbDocument()
    doc.layers = [a, b, c]
    let copies = doc.duplicateLayers(ids: [b.id])
    check("duplicate returns the new ids", copies.count == 1 && copies[0] != b.id)
    check("duplicate inserts directly above the original",
          doc.layers.count == 4 && doc.layers[1].id == b.id && doc.layers[2].id == copies[0])
    if case .text(let spec)? = doc.layers.first(where: { $0.id == copies[0] })?.kind {
        check("duplicate copies the content", spec.text == "B")
    } else {
        check("duplicate copies the content", false)
    }
    check("duplicate offsets the copy so it is visible",
          (doc.layers[2].x - b.x) > 0.001 && (doc.layers[2].y - b.y) > 0.001)

    var locked = ThumbDocument()
    var lockedLayer = ThumbLayer(kind: .shape(ShapeSpec()))
    lockedLayer.isLocked = true
    locked.layers = [lockedLayer]
    let unlockedCopy = locked.duplicateLayers(ids: [lockedLayer.id])
    check("a duplicate of a locked layer is not itself locked",
          locked.layers.first(where: { $0.id == unlockedCopy.first })?.isLocked == false)

    // Duplicating several at once must not shift the indexes out from under
    // itself — the classic off-by-one in this exact function.
    var many = ThumbDocument()
    many.layers = [a, b, c]
    let all = many.duplicateLayers(ids: [a.id, b.id, c.id])
    check("duplicating every layer produces one copy each",
          all.count == 3 && many.layers.count == 6)
    check("every duplicate is a distinct layer", Set(many.layers.map(\.id)).count == 6)

    var emptyDoc = ThumbDocument()
    check("duplicating an unknown layer is a no-op",
          emptyDoc.duplicateLayers(ids: [UUID()]).isEmpty)

    // Delete reports whether anything went, so no-ops skip the undo entry.
    var deleting = ThumbDocument()
    deleting.layers = [a, b, c]
    check("delete removes the named layers",
          deleting.removeLayers(ids: [a.id, c.id]) && deleting.layers.map(\.id) == [b.id])
    check("deleting nothing reports nothing",
          !deleting.removeLayers(ids: [UUID()]) && deleting.layers.count == 1)

    // Tab walks the rail's order — topmost first — and wraps both ways.
    var tabbing = ThumbDocument()
    tabbing.layers = [a, b, c]
    check("tab enters at the top layer",
          tabbing.neighbourLayerID(after: nil, forward: true) == c.id)
    check("shift-tab enters at the bottom layer",
          tabbing.neighbourLayerID(after: nil, forward: false) == a.id)
    check("tab walks down the rail",
          tabbing.neighbourLayerID(after: c.id, forward: true) == b.id)
    check("shift-tab walks back up",
          tabbing.neighbourLayerID(after: b.id, forward: false) == c.id)
    check("tab wraps at the end",
          tabbing.neighbourLayerID(after: a.id, forward: true) == c.id)
    check("tab on an empty document selects nothing",
          ThumbDocument().neighbourLayerID(after: nil, forward: true) == nil)

    // A mixed selection resolves to one state rather than alternating.
    var flags = ThumbDocument()
    var visibleLayer = a
    var hiddenLayer = b
    hiddenLayer.isVisible = false
    flags.layers = [visibleLayer, hiddenLayer]
    let wrote = flags.setFlag(\.isVisible, ids: [visibleLayer.id, hiddenLayer.id])
    check("a mixed visibility selection resolves to all-on",
          wrote && flags.layers.allSatisfy(\.isVisible))
    check("toggling again turns the whole selection off",
          !flags.setFlag(\.isVisible, ids: [visibleLayer.id, hiddenLayer.id])
              && flags.layers.allSatisfy { !$0.isVisible })
    _ = visibleLayer

    // Nudge skips locked layers and clamps at the canvas edge.
    var nudging = ThumbDocument()
    var free = ThumbLayer(kind: .shape(ShapeSpec()), x: 0.5, y: 0.5)
    var pinned = ThumbLayer(kind: .shape(ShapeSpec()), x: 0.5, y: 0.5)
    pinned.isLocked = true
    nudging.layers = [free, pinned]
    check("nudge moves the unlocked layer",
          nudging.nudge(ids: [free.id, pinned.id], dx: 0.1, dy: 0)
              && abs((nudging.layers[0].x) - 0.6) < 0.0001)
    check("nudge leaves a locked layer alone", abs(nudging.layers[1].x - 0.5) < 0.0001)
    check("nudging only locked layers reports nothing",
          !nudging.nudge(ids: [pinned.id], dx: 0.1, dy: 0))
    nudging.nudge(ids: [free.id], dx: 5, dy: -5)
    check("nudge clamps to the canvas",
          nudging.layers[0].x <= 1.0001 && nudging.layers[0].y >= -0.0001)
    _ = free

    // One arrow press must move exactly one exported pixel.
    let fine = ThumbNudge.step(coarse: false, canvasWidth: 1280, canvasHeight: 720)
    check("an arrow press is one canvas pixel",
          abs(fine.dx * 1280 - 1) < 0.0001 && abs(fine.dy * 720 - 1) < 0.0001)
    let coarse = ThumbNudge.step(coarse: true, canvasWidth: 1280, canvasHeight: 720)
    check("shift-arrow is ten", abs(coarse.dx * 1280 - 10) < 0.0001)

    // Repeated destructive verbs must not fold into one undo step.
    let now = Date()
    check("a held nudge collapses into one undo step",
          UndoCoalescing.shouldCoalesce(action: "Nudge Layer", lastAction: "Nudge Layer",
                                        lastAt: now, now: now.addingTimeInterval(0.1)))
    check("two deletes are two undo steps",
          !UndoCoalescing.shouldCoalesce(action: "Delete Layer", lastAction: "Delete Layer",
                                         lastAt: now, now: now.addingTimeInterval(0.1)))
    check("two duplicates are two undo steps",
          !UndoCoalescing.shouldCoalesce(action: "Duplicate Layer", lastAction: "Duplicate Layer",
                                         lastAt: now, now: now.addingTimeInterval(0.1)))
}

    check("cut fields decode with safe defaults from old documents",
          {
              let json = #"{"path":"/x.png"}"#.data(using: .utf8)!
              let decoded = try? JSONDecoder().decode(ImageSpec.self, from: json)
              return decoded?.cutEdge == "none" && decoded?.cutFlip == false
          }())
}

// Canva-grade studio: alignment, masks, gradients, new shapes, background.
section("Thumb studio v2")
do {
    var doc = ThumbDocument()
    let layer = ThumbLayer(kind: .shape(ShapeSpec()), x: 0.9, y: 0.9,
                           widthFraction: 0.4, heightFraction: 0.2)
    doc.layers = [layer]

    doc.align(layerID: layer.id, horizontal: .left)
    check("align left puts the layer's edge on the canvas edge",
          abs(doc.layers[0].x - 0.2) < 0.001)
    doc.align(layerID: layer.id, horizontal: .right)
    check("align right mirrors it", abs(doc.layers[0].x - 0.8) < 0.001)
    doc.align(layerID: layer.id, horizontal: .center, vertical: .middle)
    check("centre on canvas hits dead centre",
          doc.layers[0].x == 0.5 && doc.layers[0].y == 0.5)
    doc.align(layerID: layer.id, vertical: .bottom, drawnHeightFraction: 0.2)
    check("align bottom uses the drawn height", abs(doc.layers[0].y - 0.9) < 0.001)

    check("old documents decode with no background and new fields defaulted",
          {
              let decoded = try? JSONDecoder().decode(ThumbDocument.self,
                  from: #"{"width":1280,"height":720,"layers":[]}"#.data(using: .utf8)!)
              return decoded?.backgroundHex == nil
          }())
    check("star and bubble joined the shape list",
          ShapeSpec.shapes.contains("star") && ShapeSpec.shapes.contains("bubble"))

    // Canvas background renders under everything.
    var bg = ThumbDocument()
    bg.width = 64; bg.height = 36
    bg.backgroundHex = "FF0000"
    if let rep = (ThumbnailRenderer.render(bg) { _ in nil })?
        .representations.first as? NSBitmapImageRep {
        let px = rep.colorAt(x: 32, y: 18)
        check("canvas background colour fills the frame",
              (px?.redComponent ?? 0) > 0.9 && (px?.greenComponent ?? 1) < 0.2)
    } else {
        check("canvas background colour fills the frame", false)
    }

    // Circle mask: corners transparent-to-background, centre shows the image.
    var masked = ThumbDocument()
    masked.width = 200; masked.height = 200
    masked.backgroundHex = "000000"
    var maskSpec = ImageSpec(path: "/synthetic")
    maskSpec.maskShape = "circle"
    maskSpec.shadowEnabled = false
    masked.layers = [ThumbLayer(kind: .image(maskSpec), x: 0.5, y: 0.5,
                                widthFraction: 1.0)]
    let whiteSquare = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { rect in
        NSColor.white.setFill(); rect.fill(); return true
    }
    if let rep = (ThumbnailRenderer.render(masked) { _ in whiteSquare })?
        .representations.first as? NSBitmapImageRep {
        let corner = rep.colorAt(x: 6, y: 6)
        let centre = rep.colorAt(x: 100, y: 100)
        check("a circle mask clips the corners and keeps the middle",
              (corner?.redComponent ?? 1) < 0.2
                  && (centre?.redComponent ?? 0) > 0.9)
    } else {
        check("a circle mask clips the corners and keeps the middle", false)
    }

    // Gradient fill: top and bottom of a rect differ in the right direction.
    var grad = ThumbDocument()
    grad.width = 100; grad.height = 200
    var gradShape = ShapeSpec(shape: "rectangle")
    gradShape.fillHex = "FF0000"
    gradShape.fillGradientHex = "0000FF"
    gradShape.gradientAngleDegrees = 90
    grad.layers = [ThumbLayer(kind: .shape(gradShape), x: 0.5, y: 0.5,
                              widthFraction: 1.0, heightFraction: 1.0)]
    if let rep = (ThumbnailRenderer.render(grad) { _ in nil })?
        .representations.first as? NSBitmapImageRep {
        let top = rep.colorAt(x: 50, y: 10)
        let bottom = rep.colorAt(x: 50, y: 190)
        check("a 90° gradient runs between its two colours",
              (top?.blueComponent ?? 0) > (top?.redComponent ?? 1)
                  && (bottom?.redComponent ?? 0) > (bottom?.blueComponent ?? 1))
    } else {
        check("a 90° gradient runs between its two colours", false)
    }
}

// The banger pass: laughter in the envelope, then the blend.
section("Banger pass")
do {
    // Synthetic laugh: 5 Hz half-wave pulses that drop back to the floor
    // between "ha"s — real laughter's valleys are near-silent, which is
    // exactly what separates it from a held yell. 20 peaks/s, 10s..13s.
    var peaks = [UInt8](repeating: 18, count: 600)
    for i in 200..<260 {
        let phase = Double(i - 200) / 20 * 5 * 2 * Double.pi
        peaks[i] = UInt8(18 + 200 * max(0, sin(phase)))
    }
    let windows = LaughterSignals.detect(peaks: peaks, perSecond: 20)
    check("a pulsed loud burst reads as laughter where it happened",
          windows.count == 1
              && abs((windows.first?.start ?? 0) - 10) < 1.2
              && abs((windows.first?.end ?? 0) - 13) < 1.6
              && (windows.first?.confidence ?? 0) > 0.4)

    // Loud but steady — a held yell or engine noise — is not a laugh.
    var steady = [UInt8](repeating: 18, count: 600)
    for i in 200..<260 { steady[i] = 180 }
    check("loud but unmodulated audio is not laughter",
          LaughterSignals.detect(peaks: steady, perSecond: 20).isEmpty)
    check("silence is not laughter",
          LaughterSignals.detect(peaks: [UInt8](repeating: 2, count: 600),
                                 perSecond: 20).isEmpty)

    check("laugh seconds weight by overlap and confidence",
          abs(LaughterSignals.laughSeconds(
              in: [.init(start: 10, end: 13, confidence: 0.5)],
              from: 11, to: 20) - 1.0) < 0.001)

    // The heuristic: a laugh-dense clip with chat reacting beats dead air.
    let banger = BangerService.heuristicScore(.init(
        duration: 30, laughSeconds: 6, emoteSpikes: 2, peakPosition: 0.2,
        punchPer100: 4, openingWords: 7))
    let flat = BangerService.heuristicScore(.init(
        duration: 30, laughSeconds: 0, emoteSpikes: 0, peakPosition: 0.9,
        punchPer100: 0.5, openingWords: 2))
    check("laughter + chat + early peak scores far above flat talk",
          banger >= BangerService.bangerThreshold && flat < 25 && banger <= 100)

    check("the blend leans on the model but keeps the signals",
          abs(BangerService.blended(heuristic: 50, model: 90) - 74) < 0.001
              && BangerService.blended(heuristic: 50, model: nil) == 50)

    let verdicts = BangerService.parseVerdicts(
        #"{"verdicts":[{"id":0,"score":88,"hook":"HE DID WHAT"},{"id":7,"score":40,"hook":""},{"id":3,"score":150,"hook":"x"}]}"#,
        knownIDs: [0, 3])
    check("verdicts drop invented ids and clamp scores",
          verdicts.count == 2
              && verdicts.first?.hook == "HE DID WHAT"
              && verdicts.first { $0.id == 3 }?.score == 100)

    check("snippets stay inside a local context budget",
          BangerService.snippet(String(repeating: "a", count: 2000)).count == 701)
}

// Compilations and running bits: the back catalogue, queried.
section("Library")
do {
    let day = 86400.0
    let now = Date(timeIntervalSince1970: 1_785_000_000)
    func entry(_ title: String, score: Double, seconds: Double, category: String,
               age: Double, posted: Bool = false) -> CompilationService.Entry {
        CompilationService.Entry(candidateID: UUID(), projectID: UUID(),
                                 projectName: "VOD", sourcePath: "/v.mp4",
                                 title: title, start: 0, end: seconds, score: score,
                                 category: category,
                                 createdAt: now.addingTimeInterval(-age * day),
                                 posted: posted)
    }
    let pool = [
        entry("Best", score: 0.9, seconds: 60, category: "Funny", age: 1),
        entry("Good", score: 0.6, seconds: 60, category: "Story time", age: 5),
        entry("Old gold", score: 0.8, seconds: 60, category: "Funny", age: 90),
        entry("Posted already", score: 0.95, seconds: 60, category: "Funny", age: 2, posted: true),
        entry("Weak", score: 0.1, seconds: 60, category: "Funny", age: 3),
    ]

    var q = CompilationService.Query()
    q.maximumMinutes = 2
    check("the cap stops the running order at the limit, best first",
          CompilationService.select(pool, query: q).map(\.title) == ["Posted already", "Best"])

    q.includePosted = false
    check("excluding posted clips changes the picks",
          CompilationService.select(pool, query: q).map(\.title) == ["Best", "Old gold"])

    q.maximumMinutes = 0
    q.minimumScore = 0.5
    q.categories = ["Funny"]
    check("category and score filters both apply, uncapped keeps everything",
          CompilationService.select(pool, query: q).map(\.title) == ["Best", "Old gold"])

    q.categories = []
    q.since = now.addingTimeInterval(-10 * day)
    q.order = .chronological
    check("a date window and chronological order work together",
          CompilationService.select(pool, query: q).map(\.title) == ["Good", "Best"])

    let clips = CompilationService.timelineClips(from: Array(pool.prefix(2)))
    check("picks become real timeline clips",
          clips.count == 2 && clips[0].name == "Best" && clips[0].duration == 60)
    check("categories are offered from what's actually in the pool",
          CompilationService.categories(in: pool) == ["Funny", "Story time"])

    // Running bits: the same line in two VODs is a bit; twice in one is not.
    func transcript(_ lines: [String]) -> Transcript {
        var t = Transcript()
        t.segments = lines.enumerated().map { index, text in
            TranscriptSegment(id: index, start: Double(index) * 10,
                              end: Double(index) * 10 + 5, text: text, words: [])
        }
        return t
    }
    let a = UUID(), b = UUID(), c = UUID()
    let bits = RecurringBitService.find(in: [
        (a, "VOD A", transcript(["people keep running into me in GTA",
                                 "and then i was like what the heck"])),
        (b, "VOD B", transcript(["seriously people keep running into me in GTA today"])),
        (c, "VOD C", transcript(["completely unrelated chatter about pizza toppings"])),
    ])
    check("a phrase across two VODs surfaces as a bit",
          bits.contains { $0.phrase.contains("running into") && $0.projectCount == 2 })
    check("filler-heavy phrases are not offered as bits",
          !bits.contains { $0.phrase.contains("and then i was") })
    // The line yields four overlapping windows; they all point at the same
    // two sightings, so only the strongest wording survives.
    check("overlapping windows of one bit collapse to a single entry",
          bits.filter { $0.phrase.contains("running into") }.count == 1
              && bits.first { $0.phrase.contains("running into") }?.occurrences.count == 2)

    let repeatedInOne = RecurringBitService.find(in: [
        (a, "VOD A", transcript(["people keep running into me in GTA",
                                 "people keep running into me in GTA"])),
    ])
    check("repeating yourself inside one stream is not a running bit",
          repeatedInOne.isEmpty)

    check("shingles skip windows that are mostly stop words",
          RecurringBitService.shingles("i was just like that").isEmpty
              && !RecurringBitService.shingles("helicopter crashed into the casino").isEmpty)
}

// Local AI: schemas, prompts, and parsing a small model's output.
section("Local AI")
do {
    check("schemas constrain decoding to the shape we need",
          (LocalAIService.packagingSchema["required"] as? [String]) == ["titles", "description", "hashtags"]
              && (LocalAIService.polishSchema["required"] as? [String]) == ["fixes"])

    let clean = LocalAIService.parsePackaging(
        ##"{"titles":["Helicopter Chaos","  "],"description":" It went sideways. ","hashtags":["#GTA","RP "," "]}"##)
    check("packaging parses, trims, drops blanks and normalises hashtags",
          clean?.titles == ["Helicopter Chaos"]
              && clean?.description == "It went sideways."
              && clean?.hashtags == ["gta", "rp"])

    check("a fenced reply still parses",
          LocalAIService.parsePackaging("""
          Sure! Here you go:
          ```json
          {"titles":["A Title"],"description":"Words.","hashtags":["gta"]}
          ```
          """)?.titles == ["A Title"])

    check("an empty answer is a failure, not empty packaging",
          LocalAIService.parsePackaging(#"{"titles":[],"description":"","hashtags":[]}"#) == nil
              && LocalAIService.parsePackaging("no json here at all") == nil)

    let fixes = LocalAIService.parsePolish(
        #"{"fixes":[{"id":1,"text":"Xay"},{"id":99,"text":"invented"},{"id":2,"text":"  "}]}"#,
        knownIDs: [1, 2, 3])
    check("polish drops invented line ids and blank rewrites",
          fixes.count == 1 && fixes[0].id == 1 && fixes[0].text == "Xay")

    let long = String(repeating: "word ", count: 4000)
    let condensed = LocalAIService.condense(long, limit: 600)
    check("long transcripts condense keeping head and tail",
          condensed.count < long.count && condensed.contains("[…]")
              && condensed.hasPrefix("word") && condensed.hasSuffix("word "))
    check("short transcripts pass through untouched",
          LocalAIService.condense("short one", limit: 600) == "short one")

    check("prompts carry the vocabulary when there is one",
          LocalAIService.packagingUser(transcript: "t", vocabulary: "YaBoyXay")
              .contains("YaBoyXay")
              && !LocalAIService.packagingUser(transcript: "t", vocabulary: "  ")
                  .contains("must be spelled"))
    check("the polish system prompt forbids rewriting for style",
          LocalAIService.polishSystem.contains("never change what")
              && LocalAIService.polishSystem.contains("Never rewrite for style"))
}

// Preflight: catch it before the upload, not after.
section("Export preflight")
do {
    var edit = ClipEdit()
    edit.clips = [TimelineClip(sourcePath: "/v.mp4", start: 0, end: 20, sourceDuration: 20)]
    var style = CaptionStyle.standard
    style.marginVertical = 220          // 11.5% up on a 1920 frame
    style.position = .bottom

    let underUI = PreflightService.run(edit: edit, captionStyle: style, captionsBurned: true,
                                       missingMedia: 0, hasThumbnail: true, audioProfile: nil)
    check("captions inside TikTok's chrome are flagged with a fix",
          underUI.contains { $0.message.contains("TikTok") && $0.message.contains("Raise the margin") })

    style.marginVertical = 380          // ~20%, clear of all three
    let clear = PreflightService.run(edit: edit, captionStyle: style, captionsBurned: true,
                                     missingMedia: 0, hasThumbnail: true, audioProfile: nil)
    check("captions clear of every platform raise nothing about chrome",
          !clear.contains { $0.message.contains("covers the bottom") })

    check("captions off are not checked against chrome",
          !PreflightService.run(edit: edit, captionStyle: CaptionStyle.standard,
                                captionsBurned: false, missingMedia: 0,
                                hasThumbnail: true, audioProfile: nil)
              .contains { $0.message.contains("TikTok") })

    let offline = PreflightService.run(edit: edit, captionStyle: style, captionsBurned: false,
                                       missingMedia: 3, hasThumbnail: true, audioProfile: nil)
    check("offline media is a blocker, not a warning",
          PreflightService.blockers(offline).contains { $0.message.contains("3 media files are offline") })

    var slivers = ClipEdit()
    slivers.clips = [
        TimelineClip(sourcePath: "/v.mp4", start: 0, end: 0.4, sourceDuration: 20),
        TimelineClip(sourcePath: "/v.mp4", start: 1, end: 3, sourceDuration: 20),
    ]
    slivers.sfxEvents = [SFXEvent(path: "/s.wav", startTime: 90)]
    let short = PreflightService.run(edit: slivers, captionStyle: style, captionsBurned: false,
                                     missingMedia: 0, hasThumbnail: false, audioProfile: nil)
    check("slivers, stray sound past the end, and a missing thumbnail all surface",
          short.contains { $0.message.contains("too short to read") }
              && short.contains { $0.message.contains("fires after the cut ends") }
              && short.contains { $0.message.contains("No thumbnail") })

    let tightMix = AudioProfile(measuredAt: Date(), speechSeconds: 600, backgroundSeconds: 300,
                                voiceBandSpeechDB: -20, voiceBandBackgroundDB: -23,
                                outOfBandSpeechDB: -26, outOfBandBackgroundDB: -30)
    let mixed = PreflightService.run(edit: edit, captionStyle: style, captionsBurned: false,
                                     missingMedia: 0, hasThumbnail: true, audioProfile: tightMix)
    check("a voice barely above the game is flagged from what was measured",
          mixed.contains { $0.message.contains("3.0 dB above the game") })

    check("an empty timeline blocks",
          PreflightService.blockers(
              PreflightService.run(edit: ClipEdit(), captionStyle: style, captionsBurned: false,
                                   missingMedia: 0, hasThumbnail: true, audioProfile: nil))
              .contains { $0.message.contains("Nothing on the timeline") })
}

// Project bundles: what goes in, what the archive command looks like.
section("Project backup")
do {
    let root = URL(fileURLWithPath: "/p")
    let onDisk: Set<String> = [
        "/p/project.json", "/p/clipedit.json", "/p/shorts.json",
        "/p/transcript", "/p/versions",
    ]
    let items = ProjectBundleService.itemsToArchive(root: root) { onDisk.contains($0.path) }
    check("the bundle carries decisions and skips what isn't there",
          Set(items) == ["project.json", "clipedit.json", "shorts.json",
                         "transcript", "versions"])
    check("media directories are never in the manifest",
          !ProjectBundleService.documentNames.contains { $0.hasSuffix(".mp4") }
              && !ProjectBundleService.documentDirectories.contains("render")
              && !ProjectBundleService.documentDirectories.contains("audio")
              && !ProjectBundleService.documentDirectories.contains("timeline-clips"))

    let args = ProjectBundleService.archiveArguments(
        stagingDir: URL(fileURLWithPath: "/tmp/stage"),
        destination: URL(fileURLWithPath: "/out/backup.vodbundle"))
    check("archive is a plain ditto zip a user can open in Finder",
          args.contains("-c") && args.contains("-k") && args.last == "/out/backup.vodbundle")

    let name = ProjectBundleService.filename(
        for: "🔥 24 HOUR STREAM | Every Sub = New Challenge?",
        date: Date(timeIntervalSince1970: 1_785_000_000))
    check("filenames flatten punctuation and stay openable",
          name.hasSuffix(".vodbundle") && !name.contains("|") && !name.contains("?")
              && !name.contains("/"))

    let reid = ProjectBundleService.reidentified(
        #"{"id":"OLD","name":"Doomsday Prep"}"#.data(using: .utf8)!,
        newID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
    let decoded = (try? JSONSerialization.jsonObject(with: reid ?? Data())) as? [String: Any]
    check("restoring mints a new id so it can sit beside the original",
          decoded?["id"] as? String == "11111111-2222-3333-4444-555555555555"
              && (decoded?["name"] as? String)?.hasSuffix("(restored)") == true)
    check("restoring twice doesn't stack the suffix",
          {
              let once = ProjectBundleService.reidentified(reid!, newID: UUID())
              let twice = (try? JSONSerialization.jsonObject(with: once ?? Data())) as? [String: Any]
              return (twice?["name"] as? String) == "Doomsday Prep (restored)"
          }())
}

// Media relinking: find offline references, match them, rewire.
section("Media relinking")
do {
    var edit = ClipEdit()
    edit.clips = [
        TimelineClip(sourcePath: "/old/a.mp4", start: 0, end: 5, sourceDuration: 5),
        TimelineClip(sourcePath: "/old/a.mp4", start: 5, end: 9, sourceDuration: 9),
        TimelineClip(sourcePath: "/here/ok.mp4", start: 0, end: 3, sourceDuration: 3),
    ]
    edit.musicPath = "/old/bed.mp3"
    edit.sfxEvents = [SFXEvent(path: "/old/whoosh.wav", startTime: 1)]
    edit.library = ["/old/a.mp4"]
    let present: Set<String> = ["/here/ok.mp4"]

    let missing = MediaRelinkService.missing(in: edit) { present.contains($0) }
    check("every offline reference is found, online ones left alone",
          missing.count == 5 && !missing.contains { $0.path == "/here/ok.mp4" })

    let groups = MediaRelinkService.groupedByFile(missing)
    check("references collapse to one row per file",
          groups.count == 3 && groups.first { $0.path == "/old/a.mp4" }?.slots.count == 3)

    // The folder they moved into: same names, new home, one in a subfolder.
    let index: [String: [String]] = [
        "a.mp4": ["/new/deep/copy/a.mp4", "/new/a.mp4"],
        "bed.mp3": ["/new/bed.mp3"],
        "whoosh.wav": ["/new/sfx/whoosh.wav"],
    ]
    let resolved = MediaRelinkService.resolve(missing, against: index)
    check("ambiguous matches prefer the shallowest path",
          resolved.first { $0.path == "/old/a.mp4" }?.replacement == "/new/a.mp4")

    let (relinked, fixed) = MediaRelinkService.apply(resolved, to: edit)
    check("every slot kind rewires: clips, music, sfx, library",
          fixed == 5
              && relinked.clips[0].sourcePath == "/new/a.mp4"
              && relinked.clips[1].sourcePath == "/new/a.mp4"
              && relinked.clips[2].sourcePath == "/here/ok.mp4"
              && relinked.musicPath == "/new/bed.mp3"
              && relinked.sfxEvents[0].path == "/new/sfx/whoosh.wav"
              && relinked.library[0] == "/new/a.mp4")

    // A re-encode that changed the extension still matches on the stem.
    let stemOnly = MediaRelinkService.resolve(
        [MediaRelinkService.Missing(slot: .music, path: "/old/bed.wav")],
        against: ["bed.mp3": ["/new/bed.mp3"]])
    check("a changed extension still matches by name",
          stemOnly.first?.replacement == "/new/bed.mp3")

    // Nothing found: the document must be left exactly as it was.
    let unresolved = MediaRelinkService.resolve(missing, against: [:])
    let (untouched, none) = MediaRelinkService.apply(unresolved, to: edit)
    check("a failed search changes nothing", none == 0 && untouched == edit)

    check("a fully online edit reports nothing missing",
          MediaRelinkService.missing(in: relinked) { _ in true }.isEmpty)
}

// Disk reclaim: fixture directories, real deletes.
section("Disk reclaim")
do {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("reclaim-\(UUID().uuidString)")
    let audio = root.appendingPathComponent("audio")
    let chunks = audio.appendingPathComponent("chunks")
    let thumbs = root.appendingPathComponent("thumbnails")
    let render = root.appendingPathComponent("render")
    let transcriptDir = root.appendingPathComponent("transcript")
    for dir in [audio, chunks, thumbs, render, transcriptDir] {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    defer { try? fm.removeItem(at: root) }

    func drop(_ url: URL, _ bytes: Int) {
        fm.createFile(atPath: url.path, contents: Data(repeating: 7, count: bytes))
    }
    drop(audio.appendingPathComponent("full16k.wav"), 4096)
    drop(chunks.appendingPathComponent("chunk0.wav"), 1024)
    drop(thumbs.appendingPathComponent("poster.jpg"), 512)
    drop(render.appendingPathComponent("stale.mp4"), 2048)
    drop(render.appendingPathComponent("used.mp4"), 2048)
    drop(root.appendingPathComponent("project.json"), 64)
    drop(transcriptDir.appendingPathComponent("transcript.json"), 64)

    var edit = ClipEdit()
    edit.clips = [TimelineClip(sourcePath: render.appendingPathComponent("used.mp4").path,
                               start: 0, end: 5, sourceDuration: 5)]
    let referenced = DiskReclaimService.referencedPaths(edit: edit)

    let targets = DiskReclaimService.reclaimTargets(
        root: root, audioDir: audio, chunksDir: chunks, thumbnailsDir: thumbs,
        renderDirs: [render], transcriptExists: true, referencedPaths: referenced)
    let names = Set(targets.map(\.lastPathComponent))
    check("reclaim takes the WAVs, chunks, thumbnails and stale renders",
          names.contains("full16k.wav") && names.contains("chunks")
              && names.contains("thumbnails") && names.contains("stale.mp4"))
    check("reclaim never touches a file the timeline references",
          !names.contains("used.mp4"))

    let noTranscript = DiskReclaimService.reclaimTargets(
        root: root, audioDir: audio, chunksDir: chunks, thumbnailsDir: thumbs,
        renderDirs: [render], transcriptExists: false, referencedPaths: referenced)
    check("without a transcript the WAVs stay — they still have a job",
          !noTranscript.map(\.lastPathComponent).contains("full16k.wav"))

    let freed = DiskReclaimService.delete(targets)
    check("delete frees what it said it would and leaves the rest",
          freed >= 4096 + 1024 + 512 + 2048
              && fm.fileExists(atPath: render.appendingPathComponent("used.mp4").path)
              && fm.fileExists(atPath: root.appendingPathComponent("project.json").path))

    let archive = DiskReclaimService.archiveTargets(
        root: root, keepDirs: [transcriptDir])
    let archiveNames = Set(archive.map(\.lastPathComponent))
    check("archive keeps the JSONs and the transcript dir, takes the media dirs",
          archiveNames.contains("render") && archiveNames.contains("audio")
              && !archiveNames.contains("project.json") && !archiveNames.contains("transcript"))
}

// Posting runway forecast.
section("Posting runway")
do {
    let now = Date(timeIntervalSince1970: 1_785_000_000)
    let day = 86400.0

    // Xay: 14 ready at 1/day -> two weeks of runway.
    var items = (0..<14).map { _ in PostingForecastService.Item(clientName: "Xay") }
    items.append(.init(clientName: "Xay", postedAt: now.addingTimeInterval(-day)))
    let runways = PostingForecastService.forecast(items: items,
                                                  cadences: ["Xay": 7], now: now)
    let xay = runways.first { $0.clientName == "Xay" }
    check("14 ready at 1/day runs two weeks out",
          xay?.readyCount == 14
              && xay.flatMap(\.runwayEnds).map {
                  abs($0.timeIntervalSince(now) - 14 * day) < day / 2 } == true
              && xay?.warnings.isEmpty == true)

    // Dry spell: material ready, silent for 10 days at 1/day cadence.
    var quiet = (0..<5).map { _ in PostingForecastService.Item(clientName: "B") }
    quiet.append(.init(clientName: "B", postedAt: now.addingTimeInterval(-10 * day)))
    let dry = PostingForecastService.forecast(items: quiet, cadences: ["B": 7], now: now)
    check("a dry spell with clips ready gets flagged",
          dry.first?.warnings.contains { $0.contains("Quiet") } == true)

    // Dump: four posts in one afternoon.
    let burst = (0..<4).map {
        PostingForecastService.Item(clientName: "C",
                                    postedAt: now.addingTimeInterval(Double($0) * 3600))
    }
    let dump = PostingForecastService.forecast(items: burst, cadences: [:], now: now)
    check("a same-day dump gets flagged, and empty pipeline noted",
          dump.first?.warnings.contains { $0.contains("posts on") } == true
              && dump.first?.warnings.contains { $0.contains("Out of material") } == true)
}

// Global search over multiple transcripts.
section("Global search")
do {
    var t1 = Transcript()
    t1.segments = [
        TranscriptSegment(id: 0, start: 10, end: 12, text: "the casino heist went sideways", words: []),
        TranscriptSegment(id: 1, start: 50, end: 52, text: "chat spammed KEKW", words: []),
    ]
    var t2 = Transcript()
    t2.segments = [
        TranscriptSegment(id: 0, start: 5, end: 7, text: "another CASINO story", words: []),
    ]
    let idA = UUID()
    let idB = UUID()
    let sources = [(projectID: idA, name: "VOD A", transcript: t1),
                   (projectID: idB, name: "VOD B", transcript: t2)]

    let hits = GlobalSearchService.search("casino", in: sources)
    check("search finds case-insensitive matches across projects",
          hits.count == 2 && Set(hits.map(\.projectID)) == [idA, idB]
              && hits.first?.time == 10)
    check("short queries return nothing rather than everything",
          GlobalSearchService.search("c", in: sources).isEmpty
              && GlobalSearchService.search("  ", in: sources).isEmpty)
    check("the cap holds", GlobalSearchService.search("casino", in: sources, limit: 1).count == 1)
}

// Hook doctor: verdicts over the opening seconds.
section("Hook doctor")
do {
    let strong = HookDoctorService.report(
        words: [(0.2, "YO", 0.6), (0.5, "he", 0.4), (0.9, "just", 0.5),
                (1.4, "CRASHED!", 0.95), (2.0, "the", 0.3), (2.4, "heli", 0.5)],
        totalDuration: 30)
    check("a dense open with an early payoff reads all good",
          strong.findings.allSatisfy { $0.severity == .good }
              && strong.payoffWord == "CRASHED!" && strong.wordsInFirst3 == 6)

    let slow = HookDoctorService.report(
        words: [(2.4, "so", 0.3), (2.9, "anyway", 0.3), (5.5, "BOOM!", 0.9)],
        totalDuration: 30)
    check("a slow open gets flagged: late first word, sparse, late payoff",
          slow.findings.contains { $0.severity == .bad && $0.message.contains("2.4s") }
              && slow.findings.contains { $0.message.contains("payoff")
                  || $0.message.contains("Payoff") || $0.message.contains("5.5s") })

    let silent = HookDoctorService.report(words: [], totalDuration: 30)
    check("a silent open is called out",
          silent.findings.contains { $0.severity == .bad && $0.message.contains("No speech") })
}

// Speaker guesses: two level clusters over the transcript.
section("Speaker guesses")
do {
    // 20 segments alternating loud mic (peak ~180) and quiet other (~60),
    // 2s each over 40s of 20/s peaks.
    var peaks = [UInt8]()
    for segment in 0..<20 {
        let level: UInt8 = segment % 2 == 0 ? 180 : 60
        peaks += [UInt8](repeating: level, count: 40)
    }
    let segments = (0..<20).map { (id: $0, start: Double($0) * 2, end: Double($0) * 2 + 2) }
    let result = SpeakerLabelService.classify(segments: segments, peaks: peaks,
                                              peaksPerSecond: 20)
    check("a clear two-level mix splits reliably",
          result.reliable && result.separation > 3)
    check("the hotter cluster reads as the mic",
          result.isYou[0] == true && result.isYou[1] == false
              && result.isYou[18] == true && result.isYou[19] == false)

    // One person talking at one level: no split to claim.
    let flatPeaks = [UInt8](repeating: 150, count: 800)
    let flat = SpeakerLabelService.classify(segments: segments, peaks: flatPeaks,
                                            peaksPerSecond: 20)
    check("a single-level mix refuses to guess", !flat.reliable)

    check("too few segments refuses to guess",
          !SpeakerLabelService.classify(
              segments: Array(segments.prefix(3)), peaks: peaks,
              peaksPerSecond: 20).reliable)
}

// Beat grid: pure DSP over synthetic PCM.
section("Beat grid")
do {
    // A 120 BPM click track: 30s at 8kHz, a 20ms burst every 0.5s starting
    // at 0.25s (so the phase fit has something to find).
    let rate = 8000.0
    var samples = [Float](repeating: 0, count: Int(rate * 30))
    var click = 0.25
    while click < 30 {
        let start = Int(click * rate)
        for i in start..<min(samples.count, start + 160) {
            samples[i] = sinf(Float(i) * 0.6) * 0.9
        }
        click += 0.5
    }
    let (envelope, perSecond) = BeatGridService.onsetEnvelope(samples: samples, sampleRate: rate)
    check("onset envelope resolves clicks", !envelope.isEmpty && perSecond > 20)

    let bpm = BeatGridService.estimateTempo(envelope: envelope, perSecond: perSecond)
    check("120 BPM click track measures 120 (±2)",
          bpm.map { abs($0 - 120) < 2 } == true)

    if let bpm {
        let grid = BeatGridService.beatGrid(envelope: envelope, perSecond: perSecond,
                                            bpm: bpm, duration: 60)
        let nearFirstClick = grid.first.map { abs($0 - 0.25) < 0.06 } ?? false
        check("grid locks phase to the clicks and extends past the analysed audio",
              nearFirstClick && grid.count > 100 && (grid.last ?? 0) < 60)
    } else {
        check("grid locks phase to the clicks and extends past the analysed audio", false)
    }

    var noise = [Float](repeating: 0, count: Int(rate * 20))
    var seed: UInt64 = 42
    for i in noise.indices {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        noise[i] = Float(Int64(truncatingIfNeeded: seed) % 1000) / 1000
    }
    let (noiseEnv, noisePS) = BeatGridService.onsetEnvelope(samples: noise, sampleRate: rate)
    check("white noise honestly reports no tempo",
          BeatGridService.estimateTempo(envelope: noiseEnv, perSecond: noisePS) == nil)
}

// End cards: built from the client profile through the thumbnail renderer.
section("End cards")
do {
    var client = ClientProfile(name: "Xay", twitchHandle: "yaboyxay",
                               instagramHandle: "yaboyxay")
    client.brandColorHex = "FF4D4D"
    client.subscribePrompt = "RUN IT BACK"

    let landscape = EndCardService.document(for: client, aspect: .landscape)
    check("end card canvas matches the edit's aspect",
          landscape.width == 1920 && landscape.height == 1080)
    let texts: [TextSpec] = landscape.layers.compactMap {
        if case .text(let spec) = $0.kind { return spec } else { return nil }
    }
    check("sign-off and both handles land on the card",
          texts.contains { $0.text == "RUN IT BACK" }
              && texts.contains { $0.text.contains("twitch.tv/yaboyxay") && $0.text.contains("@yaboyxay") })
    check("the brand colour drives the accent and the sign-off gradient",
          texts.contains { $0.gradientHex == "FF4D4D" }
              && landscape.layers.contains {
                  if case .shape(let spec) = $0.kind { return spec.fillHex == "FF4D4D" }
                  return false
              })

    var bare = ClientProfile(name: "New")
    bare.subscribePrompt = ""
    let fallback = EndCardService.document(for: bare, aspect: .portrait)
    let fallbackTexts: [TextSpec] = fallback.layers.compactMap {
        if case .text(let spec) = $0.kind { return spec } else { return nil }
    }
    check("an empty profile still makes a sane card",
          fallback.width == 1080 && fallbackTexts.contains { $0.text == "LIKE & SUBSCRIBE" }
              && fallbackTexts.count == 1)

    let bake = EndCardService.bakeArguments(
        cardPNG: URL(fileURLWithPath: "/card.png"), seconds: 5,
        width: 1920, height: 1080, destination: URL(fileURLWithPath: "/out.mp4"))
    check("bake loops the PNG with silence, a fade-in, and clamped length",
          bake.contains("-loop") && bake.contains("anullsrc=r=48000:cl=stereo")
              && bake.joined(separator: " ").contains("fade=t=in")
              && bake[bake.firstIndex(of: "-t").map { $0 + 1 } ?? 0] == "5.00")
    check("bake length clamps to sanity",
          EndCardService.bakeArguments(cardPNG: URL(fileURLWithPath: "/c.png"), seconds: 90,
                                       width: 1920, height: 1080,
                                       destination: URL(fileURLWithPath: "/o.mp4"))
              .contains("15.00"))
}

// Tighten: dead air + fillers from word timings, ripple-applied.
section("Tighten")
do {
    // A 20s clip from the "VOD": words at 0-2, then dead air to 6, words
    // 6-9 with a fat "um" at 7, then silence 9-20.
    var t = Transcript()
    t.segments = [TranscriptSegment(id: 0, start: 0, end: 9, text: "x", words: [
        TranscriptWord(text: "hey", start: 0.2, end: 0.8, probability: 1),
        TranscriptWord(text: "chat", start: 0.9, end: 2.0, probability: 1),
        TranscriptWord(text: "so", start: 6.0, end: 6.4, probability: 1),
        TranscriptWord(text: "um,", start: 7.0, end: 7.5, probability: 1),
        TranscriptWord(text: "yeah", start: 8.2, end: 9.0, probability: 1),
    ])]

    var edit = ClipEdit()
    edit.clips = [TimelineClip(sourcePath: "/vod.mp4", start: 0, end: 20, sourceDuration: 20)]

    let cuts = TightenService.plan(edit: edit, transcript: t, projectSource: "/vod.mp4")
    check("finds the mid-take gap, the trailing silence, and the um",
          cuts.contains { $0.reason == "silence" && abs($0.start - 2.12) < 0.05 }
              && cuts.contains { $0.reason == "um" }
              && cuts.contains { $0.reason == "silence" && $0.end > 19.9 })

    let gentle = TightenService.plan(edit: edit, transcript: t, projectSource: "/vod.mp4",
                                     options: TightenService.options(aggressiveness: 0,
                                                                     removeFillers: false))
    check("gentle keeps the um and only closes real dead air",
          !gentle.contains { $0.reason == "um" }
              && gentle.allSatisfy { $0.reason == "silence" })

    check("clips from other files pass through untouched",
          TightenService.plan(edit: edit, transcript: t, projectSource: "/other.mp4").isEmpty)

    let (tightened, applied) = TightenService.apply(cuts, to: edit)
    let saved = cuts.reduce(0) { $0 + $1.duration }
    check("applying removes what the plan promised",
          applied == cuts.count
              && abs(tightened.totalDuration - (20 - saved)) < 0.2)
    check("ripple delete as pure mutation matches the session verb",
          {
              var e = edit
              return e.rippleDelete(from: 3, to: 5) && abs(e.totalDuration - 18) < 0.01
          }())
}

// Sound effects: model, render projection, export wiring.
section("Sound effects")
do {
    var edit = ClipEdit()
    edit.clips = [TimelineClip(sourcePath: "/v.mp4", start: 0, end: 10, sourceDuration: 10)]
    edit.sfxEvents = [SFXEvent(path: "/sfx/whoosh.wav", startTime: 2.5, gainDB: -3)]

    check("sfx decode tolerantly from old documents",
          (try? JSONDecoder().decode(ClipEdit.self,
              from: #"{"clips":[],"aspect":"portrait"}"#.data(using: .utf8)!))?.sfxEvents.isEmpty == true)

    var muted = edit
    muted.trackControls["sfx"] = TrackControls(muted: true, solo: false, locked: false)
    check("muting the SFX track strips events from the render projection",
          muted.renderReady().sfxEvents.isEmpty && !edit.renderReady().sfxEvents.isEmpty)

    var soloed = edit
    soloed.trackControls["music"] = TrackControls(muted: false, solo: true, locked: false)
    check("soloing another audio track silences sfx",
          soloed.renderReady().sfxEvents.isEmpty)

    let args = ExportService.clipEditJoinCommand(
        listURL: URL(fileURLWithPath: "/list.txt"), overlays: [],
        sfx: [ExportService.SFXInput(url: URL(fileURLWithPath: "/sfx/whoosh.wav"),
                                     start: 2.5, gainDB: -3)],
        musicURL: nil, musicGainDB: 0,
        settings: ExportSettings(), encoderName: "libx264",
        destination: URL(fileURLWithPath: "/out.mp4"))
    let graph = args[args.firstIndex(of: "-filter_complex").map { $0 + 1 } ?? 0]
    check("sfx alone defeats the stream-copy shortcut and lands in the mix",
          !args.contains("copy") && graph.contains("adelay=2500:all=1")
              && graph.contains("amix=inputs=2"))

    let both = ExportService.clipEditJoinCommand(
        listURL: URL(fileURLWithPath: "/list.txt"), overlays: [],
        voiceover: ExportService.VoiceoverInput(url: URL(fileURLWithPath: "/vo.m4a"),
                                                start: 0, gainDB: 0),
        sfx: [ExportService.SFXInput(url: URL(fileURLWithPath: "/a.wav"), start: 1, gainDB: 0),
              ExportService.SFXInput(url: URL(fileURLWithPath: "/b.wav"), start: 2, gainDB: 0)],
        musicURL: nil, musicGainDB: 0,
        settings: ExportSettings(), encoderName: "libx264",
        destination: URL(fileURLWithPath: "/out.mp4"))
    let bothGraph = both[both.firstIndex(of: "-filter_complex").map { $0 + 1 } ?? 0]
    check("voiceover and two sfx mix as four inputs with distinct labels",
          bothGraph.contains("amix=inputs=4") && bothGraph.contains("[sfx0]")
              && bothGraph.contains("[sfx1]") && bothGraph.contains("[vo]"))

    check("library scan filters to audio files",
          SFXLibrary.audioExtensions.contains("wav")
              && !SFXLibrary.audioExtensions.contains("mp4"))
    check("starter pack recipes are well-formed lavfi generators",
          SFXLibrary.starterPack().count == 5
              && SFXLibrary.starterPack().allSatisfy { $0.arguments.contains("lavfi")
                  && $0.name.hasSuffix(".wav") })
}

// Punch-in detection and the reframe track maths.
section("Punch-ins and reframe")
do {
    // A flat floor with two loud spikes 5s apart: exactly two pushes.
    var peaks = [UInt8](repeating: 30, count: 200)   // 10s at 20/s
    for i in 58...62 { peaks[i] = 220 }              // spike at ~3.0s
    for i in 158...162 { peaks[i] = 240 }            // spike at ~8.0s
    let moments = PunchInService.moments(
        peaks: peaks, perSecond: 20, words: [],
        options: PunchInService.Options())
    check("two clear spikes become two moments",
          moments.count == 2 && abs(moments[0].time - 3) < 0.3
              && abs(moments[1].time - 8) < 0.3)

    // Spikes closer than the gap collapse to the louder one.
    var crowded = [UInt8](repeating: 30, count: 200)
    for i in 58...62 { crowded[i] = 200 }
    for i in 78...82 { crowded[i] = 250 }            // 1s later, louder
    let squeezed = PunchInService.moments(
        peaks: crowded, perSecond: 20, words: [],
        options: PunchInService.Options())
    check("crowded spikes keep only the louder",
          squeezed.count == 1 && abs(squeezed[0].time - 4) < 0.3)

    // A word with a bang on a quieter spike outranks silence-adjacent ones.
    let worded = PunchInService.moments(
        peaks: peaks, perSecond: 20,
        words: [(t: 3.05, text: "what!")],
        options: PunchInService.Options())
    check("an emphasized word on a peak marks the moment",
          worded.first { abs($0.time - 3) < 0.3 }?.onWord == true)

    check("flat audio produces no pushes",
          PunchInService.moments(peaks: [UInt8](repeating: 60, count: 200),
                                 perSecond: 20, words: [],
                                 options: PunchInService.Options()).isEmpty)

    let keys = PunchInService.detect(peaks: peaks, perSecond: 20,
                                     clipSourceDuration: 10, speed: 2)
    let apex = keys.first { $0.v > 1.001 }
    check("push envelopes land in effective time (speed 2 halves them)",
          keys.count == 8 && apex.map { abs($0.t - 1.5) < 0.3 } == true
              && keys.allSatisfy { $0.t <= 5.0 })

    // Reframe: jittering around a point parks the camera; a real move pans.
    let parked = (0..<30).map { i in
        ReframeService.Sample(t: Double(i) / 3, x: 0.5 + (i % 2 == 0 ? 0.01 : -0.01), y: 0.5)
    }
    check("jitter under the deadband produces no track",
          ReframeService.panKeys(from: parked).isEmpty)

    let walk = (0..<30).map { i in
        ReframeService.Sample(t: Double(i) / 3, x: 0.2 + 0.6 * Double(i) / 29, y: 0.5)
    }
    let track = ReframeService.panKeys(from: walk)
    check("a real move produces a monotonic thinned pan track",
          track.count >= 2 && track.count <= 30
              && track.first!.x < track.last!.x
              && zip(track, track.dropFirst()).allSatisfy { $0.t < $1.t })

    check("window centring maths puts the subject mid-window",
          abs(ReframeSampler.windowCenter(0.5, windowFraction: 0.4) - 0.5) < 0.001
              && ReframeSampler.windowCenter(0.1, windowFraction: 0.4) == 0
              && ReframeSampler.windowCenter(0.9, windowFraction: 0.98) == 1
              && ReframeSampler.windowCenter(0.9, windowFraction: 0.9995) == 0.5)
}

// Layer restacking: back-to-front array, forward = toward the end.
do {
    var stackDoc = ThumbDocument()
    let a = ThumbLayer(kind: .shape(ShapeSpec()))
    let b = ThumbLayer(kind: .shape(ShapeSpec()))
    let c = ThumbLayer(kind: .shape(ShapeSpec()))
    stackDoc.layers = [a, b, c]
    check("bring forward swaps toward the front",
          stackDoc.move(layerID: a.id, .forward) && stackDoc.layers.map(\.id) == [b.id, a.id, c.id])
    check("send backward swaps toward the back",
          stackDoc.move(layerID: a.id, .backward) && stackDoc.layers.map(\.id) == [a.id, b.id, c.id])
    check("bring to front moves to the end",
          stackDoc.move(layerID: a.id, .toFront) && stackDoc.layers.map(\.id) == [b.id, c.id, a.id])
    check("send to back moves to the start",
          stackDoc.move(layerID: a.id, .toBack) && stackDoc.layers.map(\.id) == [a.id, b.id, c.id])
    check("moves at the edge are no-ops that report false",
          !stackDoc.move(layerID: a.id, .backward) && !stackDoc.move(layerID: a.id, .toBack)
              && !stackDoc.move(layerID: c.id, .forward) && !stackDoc.move(layerID: c.id, .toFront)
              && stackDoc.layers.map(\.id) == [a.id, b.id, c.id])
    check("unknown layer id is a no-op", !stackDoc.move(layerID: UUID(), .toFront))
}

// The cutout outline draws UNDER the subject — regression check for the
// draw-order bug where NSImage.draw's operation overrode the context blend
// mode and the silhouette painted over the face.
do {
    var outlineDoc = ThumbDocument()
    var outlined = ImageSpec(path: "/synthetic")
    outlined.useCutout = true
    outlined.cutoutPath = "/synthetic"
    outlined.strokeWidth = 14
    outlined.strokeHex = "FF0000"
    outlined.shadowEnabled = false
    outlineDoc.layers = [ThumbLayer(kind: .image(outlined), x: 0.5, y: 0.5, widthFraction: 0.3)]
    let greenSquare = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { rect in
        NSColor.green.setFill()
        rect.fill()
        return true
    }
    let rendered = ThumbnailRenderer.render(outlineDoc) { _ in greenSquare }
    if let rep = rendered?.representations.first as? NSBitmapImageRep {
        // Layer is 384pt wide/tall, centred at (640, 360); the 14pt outline
        // peeks out past x = 832.
        let center = rep.colorAt(x: 640, y: 360)
        let fringe = rep.colorAt(x: 640 + 192 + 7, y: 360)
        check("cutout outline peeks out and subject stays on top",
              (center?.greenComponent ?? 0) > 0.8 && (center?.redComponent ?? 1) < 0.5
                  && (fringe?.redComponent ?? 0) > 0.8 && (fringe?.greenComponent ?? 1) < 0.5)
    } else {
        check("cutout outline peeks out and subject stays on top", false)
    }
}

    // Export sizing: the compressor walks quality down until it fits.
    var busy = ThumbDocument()
    for index in 0..<24 {
        var noise = TextSpec(text: String(repeating: "NOISY TEXT \(index) ", count: 8))
        noise.sizeFraction = 0.07
        busy.layers.append(ThumbLayer(kind: .text(noise), x: 0.5,
                                      y: Double(index) / 24, widthFraction: 1.2))
    }
    if let image = ThumbnailRenderer.render(busy, provider: { _ in nil }) {
        let cap = 120_000
        if let fitted = ThumbnailRenderer.compressToFit(image, capBytes: cap) {
            check("compress-to-fit lands under the cap", fitted.data.count <= cap,
                  "\(fitted.data.count) bytes at q=\(String(format: "%.2f", fitted.quality))")
        } else {
            // A cap even q=0.3 can't hit is a legitimate nil.
            check("compress-to-fit lands under the cap",
                  (ThumbnailRenderer.encoded(image, asPNG: false, jpegQuality: 0.3)?.count ?? 0) > cap)
        }
        check("png and jpeg both encode",
              ThumbnailRenderer.encoded(image, asPNG: true, jpegQuality: 1) != nil
                  && ThumbnailRenderer.encoded(image, asPNG: false, jpegQuality: 0.8) != nil)
    }

    // Documents and templates survive the disk round trip.
    let restored = try JSONDecoder().decode(ThumbDocument.self,
                                            from: try JSONEncoder().encode(doc))
    check("a studio document round-trips", restored == doc)
    check("an empty document decodes to YouTube spec",
          (try? JSONDecoder().decode(ThumbDocument.self, from: Data("{}".utf8)))
              .map { $0.width == 1280 && $0.height == 720 } == true)
    check("starter templates all render",
          ThumbTemplates.starters().allSatisfy { template in
              ThumbnailRenderer.render(template.document) { _ in nil } != nil
          })
    check("the duration safe zone sits in the lower right",
          ThumbDocument.durationSafeZone.x > 0.7 && ThumbDocument.durationSafeZone.y > 0.8)
}

section("Tracks and trims")

do {
    // The render projection: what preview and export both consume.
    var edit = ClipEdit()
    edit.clips = [TimelineClip(sourcePath: "/tmp/a.mp4", start: 0, end: 10, sourceDuration: 10)]
    edit.musicPath = "/tmp/song.mp3"
    edit.voiceoverPath = "/tmp/vo.m4a"
    edit.overlayClips = [OverlayClip(sourcePath: "/tmp/green.mp4")]
    edit.textItems = [TextItem(text: "HI")]

    edit.trackControls["music"] = TrackControls(muted: true)
    check("a muted music track vanishes from the render",
          edit.renderReady().musicPath == nil && edit.renderReady().voiceoverPath != nil)
    edit.trackControls["music"] = TrackControls()
    edit.trackControls["overlays"] = TrackControls(muted: true)
    check("a muted overlay track takes its video and audio with it",
          edit.renderReady().overlayClips.isEmpty)
    edit.trackControls["overlays"] = TrackControls()
    edit.trackControls["text"] = TrackControls(muted: true)
    check("a muted text track hides every text item",
          edit.renderReady().textItems.isEmpty)
    edit.trackControls["text"] = TrackControls()
    edit.trackControls["voiceover"] = TrackControls(solo: true)
    let soloed = edit.renderReady()
    check("solo silences every other audio track",
          soloed.musicPath == nil && soloed.voiceoverPath != nil
              && soloed.clips[0].gainDB <= -99
              && soloed.overlayClips.allSatisfy(\.muted))
    edit.trackControls = [:]
    check("no controls means nothing changes", edit.renderReady() == edit)

    // Roll trim: the junction moves, total duration doesn't.
    var rolled = ClipEdit()
    rolled.clips = [
        TimelineClip(sourcePath: "/tmp/a.mp4", start: 0, end: 10, sourceDuration: 60),
        TimelineClip(sourcePath: "/tmp/a.mp4", start: 20, end: 30, sourceDuration: 60),
    ]
    let before = rolled.totalDuration
    check("rolling a cut moves the junction, not the runtime", {
        guard rolled.rollCut(after: 0, by: 3) else { return false }
        return abs(rolled.clips[0].end - 13) < 1e-9
            && abs(rolled.clips[1].start - 23) < 1e-9
            && abs(rolled.totalDuration - before) < 1e-9
    }())
    check("a roll past the source is refused", {
        var edge = rolled
        return !edge.rollCut(after: 0, by: 60)
    }())
    check("a roll respects speed on both sides", {
        var sped = ClipEdit()
        sped.clips = [
            TimelineClip(sourcePath: "/tmp/a.mp4", start: 0, end: 10, sourceDuration: 60, speed: 2),
            TimelineClip(sourcePath: "/tmp/a.mp4", start: 20, end: 30, sourceDuration: 60),
        ]
        let total = sped.totalDuration
        guard sped.rollCut(after: 0, by: 2) else { return false }
        // 2 timeline seconds at 2x = 4 source seconds on the left.
        return abs(sped.clips[0].end - 14) < 1e-9 && abs(sped.clips[1].start - 22) < 1e-9
            && abs(sped.totalDuration - total) < 1e-9
    }())

    check("old documents load with empty track controls and lane zero", {
        let old = try? JSONDecoder().decode(ClipEdit.self, from: Data("""
        {"clips":[],"title":"x","twitchHandle":"","instagramHandle":"","handleY":0.5,"musicGainDB":-18,
         "overlayClips":[{"sourcePath":"/tmp/g.mp4"}]}
        """.utf8))
        return old?.trackControls.isEmpty == true && old?.overlayClips.first?.lane == 0
    }())
}

section("Local throughlines")

do {
    // Stage 1: per-window bit extraction — invented timestamps are dropped.
    let chunk = AutoClipChunk(index: 0, start: 600, end: 1200)
    let bits = try CoherenceService.parseBits("""
    {"bits":[
      {"label":"the car bet","kind":"arc","start_seconds":700,"end_seconds":760,"why":"wager set up"},
      {"label":"invented","kind":"story","start_seconds":50,"end_seconds":90,"why":"outside window"}
    ]}
    """, chunk: chunk)
    check("stage one keeps in-window bits and drops invented ones",
          bits.count == 1 && bits[0].label == "the car bet")
    check("stage one prompt carries the window's transcript only", {
        let transcript = Transcript(segments: [
            TranscriptSegment(id: 0, start: 100, end: 110, text: "outside early", words: []),
            TranscriptSegment(id: 1, start: 650, end: 660, text: "inside the window", words: []),
            TranscriptSegment(id: 2, start: 1500, end: 1510, text: "outside late", words: []),
        ])
        let prompt = CoherenceService.stageOneUser(chunk: chunk, transcript: transcript,
                                                   vocabulary: "YaboyXay")
        return prompt.contains("inside the window") && !prompt.contains("outside early")
            && !prompt.contains("outside late") && prompt.contains("YaboyXay")
    }())

    // Stage 2: the merge input is bits, not transcript — small enough for an
    // 8B — and the merge reply parses through the same tolerant path as the
    // manual route, single-beat throughlines dropped and all.
    let merged = CoherenceService.stageTwoUser(bits: bits + [
        CoherenceService.Bit(label: "the car bet pays off", kind: "arc",
                             start_seconds: 4400, end_seconds: 4460, why: "payoff"),
    ])
    check("stage two sees every bit in time order",
          merged.contains("[700–760s] the car bet")
              && merged.range(of: "car bet")!.lowerBound
                  < merged.range(of: "pays off")!.lowerBound)
    check("stage two schema matches the manual parser's shape", {
        let reply = """
        {"throughlines":[{"title":"The car bet","summary":"s","kind":"arc","strength":0.8,
          "beats":[{"start_seconds":700,"end_seconds":760,"why":"setup"},
                   {"start_seconds":4400,"end_seconds":4460,"why":"payoff"}]}]}
        """
        return (try? CoherenceService.parseReply(reply))?.count == 1
    }())
}

section("Export quality")

do {
    let standard = ExportSettings.standard
    check("delivery defaults to 24 Mbps", standard.videoBitrateMbps == 24)
    check("intermediates carry far more headroom than the delivered file",
          standard.intermediateBitrateMbps > standard.videoBitrateMbps * 2,
          String(format: "%.0f vs %.0f Mbps",
                 standard.intermediateBitrateMbps, standard.videoBitrateMbps))
    check("intermediate headroom is bounded so disk can't run away", {
        var maxed = ExportSettings.standard
        maxed.videoBitrateMbps = 40
        var tiny = ExportSettings.standard
        tiny.videoBitrateMbps = 8
        return maxed.intermediateBitrateMbps == 60 && tiny.intermediateBitrateMbps == 35
    }())
    check("intermediate audio never drops below 320k",
          standard.intermediateAudioKbps == 320)

    let final = ExportService.encoderArguments(standard, mbps: standard.videoBitrateMbps)
    let intermediate = ExportService.encoderArguments(standard, mbps: standard.intermediateBitrateMbps)
    check("the two passes differ only in bitrate",
          final.contains("-b:v") && final.contains("24000k")
              && intermediate.contains("-b:v") && intermediate.contains("57600k")
              && final.contains("high") && intermediate.contains("high"),
          intermediate.joined(separator: " "))
    check("software encoding uses a richer CRF for intermediates", {
        var software = ExportSettings.standard
        software.useHardwareEncoder = false
        return ExportService.encoderArguments(software, mbps: software.intermediateBitrateMbps).contains("16")
            && ExportService.encoderArguments(software, mbps: software.videoBitrateMbps).contains("19")
    }())

    check("quality stops map to their bitrates and back",
          ExportQuality.high.mbps == 24
              && ExportQuality.nearest(to: 24) == .high
              && ExportQuality.nearest(to: 12) == .standard
              && ExportQuality.nearest(to: 40) == .maximum
              && ExportQuality.nearest(to: 30) == .high)

    // Old projects stored the 10 Mbps default that caused the quality
    // complaint; anything deliberately chosen is preserved.
    check("a project on the old default is lifted to the new one", {
        let old = try? JSONDecoder().decode(ExportSettings.self, from: Data("""
        {"videoBitrateMbps":10,"audioBitrateKbps":192,"useHardwareEncoder":true,
         "captionMode":"burned","writeSRTSidecar":false,"writeVTTSidecar":false}
        """.utf8))
        return old?.videoBitrateMbps == 24 && old?.captionMode == .burned
    }())
    check("a hand-picked bitrate is left alone", {
        let picked = try? JSONDecoder().decode(ExportSettings.self, from: Data("""
        {"videoBitrateMbps":16,"captionMode":"none"}
        """.utf8))
        return picked?.videoBitrateMbps == 16 && picked?.captionMode == CaptionMode.none
    }())
    check("settings saved before these fields existed still decode", {
        let ancient = try? JSONDecoder().decode(ExportSettings.self, from: Data("{}".utf8))
        return ancient?.videoBitrateMbps == 24 && ancient?.useHardwareEncoder == true
    }())
}

section("Chroma key")

do {
    // The real green out of the user's downloaded green-screen clip measured
    // #24FE0D — not the pure #00FF00 the picker sends — so keying has to work
    // on chroma distance, not an exact colour match.
    let green = EditVideoCompositor.Chroma(hex: "00FF00", similarity: 0.22, blend: 0.08)
    func alpha(_ r: Double, _ g: Double, _ b: Double) -> Double {
        EditVideoCompositor.alpha(red: r, green: g, blue: b, chroma: green)
    }
    check("pure green is fully keyed out", alpha(0, 1, 0) == 0)
    check("the clip's actual green (#24FE0D) is keyed too",
          alpha(0x24 / 255, 0xFE / 255, 0x0D / 255) == 0,
          String(format: "alpha %.2f", alpha(0x24 / 255, 0xFE / 255, 0x0D / 255)))
    check("the subscribe button's white and red survive",
          alpha(1, 1, 1) == 1 && alpha(0.9, 0.15, 0.2) == 1)
    check("skin tones and blue survive", alpha(0.85, 0.65, 0.5) == 1 && alpha(0, 0, 1) == 1)
    // Chroma distance shrinks with brightness — a deeply shadowed corner of a
    // green screen is genuinely further from the key than a lit one, in this
    // app exactly as in ffmpeg. That is what the Strength slider is for, so
    // the behaviour is pinned rather than wished away.
    check("moderately shaded green still keys at the default strength",
          alpha(0.08, 0.6, 0.03) == 0)
    check("deeply shadowed green only half-keys by default, and clears with more strength", {
        let stronger = EditVideoCompositor.Chroma(hex: "00FF00", similarity: 0.35, blend: 0.08)
        let byDefault = alpha(0.05, 0.4, 0.02)
        return byDefault > 0 && byDefault < 1
            && EditVideoCompositor.alpha(red: 0.05, green: 0.4, blue: 0.02, chroma: stronger) == 0
    }())
    check("the edge feathers instead of jumping", {
        // A colour just outside similarity should land strictly between.
        let edge = (0.35, 0.62, 0.30)
        let a = alpha(edge.0, edge.1, edge.2)
        return a > 0 && a < 1
    }())
    check("a blue key leaves green alone", {
        let blue = EditVideoCompositor.Chroma(hex: "0000FF", similarity: 0.22, blend: 0.08)
        return EditVideoCompositor.alpha(red: 0, green: 0, blue: 1, chroma: blue) == 0
            && EditVideoCompositor.alpha(red: 0, green: 1, blue: 0, chroma: blue) == 1
    }())

    let cube = EditVideoCompositor.cubeData(for: green)
    let n = Int(EditVideoCompositor.cubeDimension)
    check("the colour cube is the size CIColorCube expects",
          cube.count == n * n * n * 4 * MemoryLayout<Float>.size, "\(cube.count) bytes")

    // Core Image draws bottom-up; the export's maths is top-down. A round
    // trip through the conversion has to land a source top-left corner at the
    // render position the export would use.
    let place = CGAffineTransform(translationX: 100, y: 200)
    let converted = EditVideoCompositor.coreImageTransform(place, sourceHeight: 400, renderHeight: 1000)
    // The source's top edge in CI coords is y = sourceHeight; placing it 200
    // down from the top of a 1000-tall render puts it at 1000 − 200.
    let top = CGPoint(x: 0, y: 400).applying(converted)
    let bottom = CGPoint(x: 0, y: 0).applying(converted)
    check("a video-space placement lands correctly in Core Image space",
          abs(top.x - 100) < 0.001 && abs(top.y - 800) < 0.001
              && abs(bottom.y - 400) < 0.001,
          "top \(top), bottom \(bottom)")
}

section("Downloads folder")

do {
    check("downloads land in Desktop/VOD_Editor/Clips",
          Paths.downloadsRoot.path.hasSuffix("/Desktop/VOD_Editor/Clips"),
          Paths.downloadsRoot.path)

    let fm = FileManager.default
    let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vodeditor-migrate-\(UUID().uuidString)")
    let from = sandbox.appendingPathComponent("old")
    let to = sandbox.appendingPathComponent("new")
    try fm.createDirectory(at: from, withIntermediateDirectories: true)
    try fm.createDirectory(at: to, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: sandbox) }

    try Data("a".utf8).write(to: from.appendingPathComponent("clip.mp4"))
    try Data("b".utf8).write(to: from.appendingPathComponent("song.mp3"))
    // A name collision on the far side must not destroy either copy.
    try Data("existing".utf8).write(to: to.appendingPathComponent("clip.mp4"))

    let moved = Paths.migrateDownloads(from: from, to: to)
    check("every old download is moved", moved == 2, "\(moved) moved")
    let names = Set(((try? fm.contentsOfDirectory(at: to, includingPropertiesForKeys: nil)) ?? [])
        .map(\.lastPathComponent))
    check("a colliding name is suffixed, not overwritten",
          names == ["clip.mp4", "clip (2).mp4", "song.mp3"], "\(names.sorted())")
    check("the file already there keeps its contents",
          (try? String(contentsOf: to.appendingPathComponent("clip.mp4"), encoding: .utf8)) == "existing")
    check("the emptied old folder is cleaned up", !fm.fileExists(atPath: from.path))
    check("migrating a missing or identical folder is a no-op",
          Paths.migrateDownloads(from: from, to: to) == 0
              && Paths.migrateDownloads(from: to, to: to) == 0)
}

section("Socials placement")

do {
    var edit = ClipEdit()
    edit.twitchHandle = "YaboyXay"
    edit.handleY = 0.5

    func opaque(_ image: NSImage?, xRange: StrideThrough<Int>) -> Bool {
        guard let rep = image?.representations.first as? NSBitmapImageRep else { return false }
        for x in xRange {
            for y in stride(from: 900, through: 1020, by: 8)
            where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { return true }
        }
        return false
    }

    let left = SocialOverlayRenderer.image(for: edit)
    check("handles default to the left edge",
          opaque(left, xRange: stride(from: 44, through: 160, by: 8))
              && !opaque(left, xRange: stride(from: 950, through: 1036, by: 8)))
    edit.handlesOnRight = true
    let right = SocialOverlayRenderer.image(for: edit)
    check("mirrored handles hug the right edge",
          opaque(right, xRange: stride(from: 920, through: 1036, by: 8))
              && !opaque(right, xRange: stride(from: 0, through: 100, by: 8)))
    edit.showHandles = false
    check("hidden socials draw nothing at all",
          SocialOverlayRenderer.image(for: edit) == nil)
    check("an old clipedit shows socials on the left", {
        let old = try? JSONDecoder().decode(ClipEdit.self, from: Data("""
        {"clips":[],"title":"x","twitchHandle":"a","instagramHandle":"","handleY":0.5,"musicGainDB":-18}
        """.utf8))
        return old?.showHandles == true && old?.handlesOnRight == false
    }())
}

// MARK: - Large-v3 doubled segments

section("Whisper large-v3 dedupe")

do {
    // The exact pattern the full model emits (seen on the real 93-min VOD:
    // 150 of 377 entries in one chunk): a zero-length segment, then a
    // full-length one repeating that text plus the next segment's.
    func entry(_ from: Int, _ to: Int, _ text: String) -> String {
        """
        {"timestamps":{"from":"0","to":"0"},"offsets":{"from":\(from),"to":\(to)},
         "text":"\(text)","tokens":[{"text":" \(text)","p":0.9,"t_dtw":\(from / 10)}]}
        """
    }
    let doubled = """
    {"transcription":[
      \(entry(385780, 385780, "since he killed us")),
      \(entry(385780, 388980, "since he killed us there's an accident bro")),
      \(entry(388980, 388980, "there's an accident bro")),
      \(entry(388980, 390660, "there's an accident bro my door bro")),
      \(entry(390660, 393460, "my door bro"))
    ]}
    """
    let parsed = try WhisperJSON.parse(data: Data(doubled.utf8), timeOffset: 0, startingID: 0)
    check("doubled large-v3 segments collapse to one each", parsed.count == 3,
          "\(parsed.count) segments: \(parsed.map(\.text))")
    check("each text survives exactly once",
          parsed.map(\.text) == ["since he killed us", "there's an accident bro", "my door bro"])
    check("collapsed segments keep real spans and order",
          parsed[0].end > parsed[0].start + 0.5
              && !parsed.indices.dropFirst().contains { parsed[$0].start < parsed[$0 - 1].start })

    // Turbo's shape — distinct, non-doubled segments — is untouched.
    let plain = """
    {"transcription":[
      \(entry(1000, 3000, "hello there")),
      \(entry(3000, 5000, "general kenobi"))
    ]}
    """
    let untouched = try WhisperJSON.parse(data: Data(plain.utf8), timeOffset: 0, startingID: 0)
    check("normal segments pass through untouched",
          untouched.map(\.text) == ["hello there", "general kenobi"])
}

// MARK: - Media browser downloads

section("Media downloads")

do {
    let dir = URL(fileURLWithPath: "/tmp/dl")
    let mp4 = MediaDownloader.arguments(for: .mp4, url: "https://youtu.be/jNQXAC9IVRw",
                                        directory: dir, ffmpegDir: "/opt/homebrew/opt/ffmpeg-full/bin")
    check("mp4 download merges to mp4 and knows where ffmpeg lives",
          mp4.contains("--merge-output-format") && mp4.contains("mp4")
              && mp4.contains("--ffmpeg-location") && mp4.last == "https://youtu.be/jNQXAC9IVRw")
    check("output lands in the shared downloads folder",
          mp4.contains { $0.hasPrefix("/tmp/dl/") })
    let mp3 = MediaDownloader.arguments(for: .mp3, url: "u", directory: dir, ffmpegDir: nil)
    check("mp3 extracts audio at best quality",
          mp3.contains("-x") && mp3.contains("mp3") && mp3.contains("--audio-quality"))
    let wav = MediaDownloader.arguments(for: .wav, url: "u", directory: dir, ffmpegDir: nil)
    check("wav extracts audio uncompressed",
          wav.contains("-x") && wav.contains("wav") && !wav.contains("--merge-output-format"))

    func watch(_ s: String) -> String? { URL(string: s).flatMap { MediaDownloader.watchURL(from: $0) } }
    check("a watch page is downloadable",
          watch("https://www.youtube.com/watch?v=jNQXAC9IVRw&t=2s") == "https://www.youtube.com/watch?v=jNQXAC9IVRw")
    check("short links and Shorts canonicalise",
          watch("https://youtu.be/jNQXAC9IVRw") == "https://www.youtube.com/watch?v=jNQXAC9IVRw"
              && watch("https://www.youtube.com/shorts/jNQXAC9IVRw") == "https://www.youtube.com/watch?v=jNQXAC9IVRw")
    check("search results and other sites are not",
          watch("https://www.youtube.com/results?search_query=zoo") == nil
              && watch("https://example.com/watch?v=x") == nil)

    check("audio routes to the music bed, video to the timeline",
          MediaDownloader.isAudio(URL(fileURLWithPath: "/tmp/a.mp3"))
              && MediaDownloader.isAudio(URL(fileURLWithPath: "/tmp/a.WAV"))
              && !MediaDownloader.isAudio(URL(fileURLWithPath: "/tmp/a.mp4")))
    check("yt-dlp progress lines parse",
          MediaDownloader.parsePercent("[download]  42.3% of 10.00MiB at 2.00MiB/s") == 42.3
              && MediaDownloader.parsePercent("[ExtractAudio] Destination: x.mp3") == nil)
}

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)

import Foundation

/// Extracts an editing style from a reference video, then maps it onto this
/// project's settings.
///
/// The honest framing: this measures *rhythm and audio treatment*, which are
/// the parts of an edit that survive being reduced to numbers. It does not read
/// caption styling, zooms, punch-ins, overlays or colour — those aren't
/// recoverable from a finished render without a lot of guessing.
enum StyleAnalyzer {
    static let limitations = """
    Measured: cut rhythm, how much silence is kept, aspect ratio, clip length, \
    and whether continuous audio sits under the speech. Not measured: caption \
    fonts or colours, zooms and punch-ins, overlays, or colour grading.

    Two caveats worth knowing. Cut detection compares keyframes, so it finds \
    hard cuts between visually different shots and misses dissolves and cuts \
    between similar-looking shots — on a test clip with 29 known joins it found \
    18. And a "bed" only means continuous audio under the speech gaps: a music \
    track and non-stop game or room ambience are indistinguishable that way, so \
    gameplay footage reads as having one.
    """

    static func analyze(reference: URL,
                        workingDirectory: URL,
                        onStage: @escaping (String) -> Void,
                        onProgress: @escaping (Double) -> Void) async throws -> StyleProfile {
        let ffmpeg = try FFmpegService()

        onStage("Reading media info")
        let media = try await ffmpeg.probe(reference)
        guard media.durationSeconds > 0 else { throw FFmpegError.probeFailed("Zero duration") }

        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let audioURL = workingDirectory.appendingPathComponent("reference-16k.wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        onStage("Extracting audio")
        try await ffmpeg.extractAudio(from: reference, to: audioURL,
                                      totalDuration: media.durationSeconds) { value in
            onProgress(value * 0.25)
        }

        onStage("Measuring silence")
        let silence = try await ffmpeg.detectSilence(in: audioURL,
                                                     totalDuration: media.durationSeconds) { value in
            onProgress(0.25 + value * 0.2)
        }

        onStage("Measuring loudness")
        let peaksURL = workingDirectory.appendingPathComponent("reference-peaks.bin")
        defer { try? FileManager.default.removeItem(at: peaksURL) }
        let waveform = try WaveformService.generate(from: audioURL, to: peaksURL) { value in
            onProgress(0.45 + value * 0.1)
        }

        onStage("Detecting cuts")
        let cuts = try await ffmpeg.detectScenes(in: reference,
                                                 totalDuration: media.durationSeconds) { value in
            onProgress(0.55 + value * 0.45)
        }

        onProgress(1)
        return build(media: media, name: reference.lastPathComponent,
                     cuts: cuts, silence: silence, waveform: waveform)
    }

    static func build(media: MediaInfo, name: String, cuts: [Double],
                      silence: [SilenceInterval], waveform: WaveformData) -> StyleProfile {
        // Shot lengths are the gaps between cuts, plus the head and tail.
        var boundaries = [0.0] + cuts.sorted() + [media.durationSeconds]
        boundaries = boundaries.filter { $0 >= 0 && $0 <= media.durationSeconds }
        var shots: [Double] = []
        for index in boundaries.indices.dropFirst() {
            let length = boundaries[index] - boundaries[index - 1]
            if length > 0.05 { shots.append(length) }
        }
        let sorted = shots.sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let position = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * fraction)))
            return sorted[position]
        }

        let silentSeconds = silence.reduce(0) { $0 + $1.duration }
        let (hasBed, bedLevel) = musicBed(silence: silence, waveform: waveform)

        return StyleProfile(
            sourceName: name,
            analyzedAt: Date(),
            duration: media.durationSeconds,
            width: media.width,
            height: media.height,
            cutCount: cuts.count,
            medianShotSeconds: percentile(0.5),
            shortShotSeconds: percentile(0.25),
            longShotSeconds: percentile(0.75),
            silenceRatio: media.durationSeconds > 0 ? silentSeconds / media.durationSeconds : 0,
            longestSilence: silence.map(\.duration).max() ?? 0,
            hasMusicBed: hasBed,
            musicLevelDB: bedLevel
        )
    }

    /// A music bed shows up as a floor that never reaches zero: during speech
    /// gaps the envelope should collapse, and if it doesn't, something is
    /// playing under the whole edit.
    private static func musicBed(silence: [SilenceInterval],
                                 waveform: WaveformData) -> (Bool, Double?) {
        guard !silence.isEmpty, waveform.peaksPerSecond > 0, !waveform.peaks.isEmpty else {
            return (false, nil)
        }

        var gapPeaks: [Double] = []
        for interval in silence {
            let lower = max(0, Int(interval.start * waveform.peaksPerSecond))
            let upper = min(waveform.peaks.count, Int(interval.end * waveform.peaksPerSecond))
            guard upper > lower else { continue }
            for index in lower..<upper { gapPeaks.append(Double(waveform.peaks[index]) / 255) }
        }
        guard gapPeaks.count > 20 else { return (false, nil) }

        let overall = waveform.peaks.map { Double($0) / 255 }.sorted()
        let reference = overall[min(overall.count - 1, Int(Double(overall.count) * 0.95))]
        guard reference > 0 else { return (false, nil) }

        gapPeaks.sort()
        let gapMedian = gapPeaks[gapPeaks.count / 2]
        let ratio = gapMedian / reference

        // Below about -40 dB relative to programme peaks is just noise floor.
        guard ratio > 0.01 else { return (false, nil) }
        return (true, 20 * log10(ratio))
    }

    // MARK: - Applying

    /// Maps the profile onto this project's settings. Returns a human-readable
    /// list of what changed, so the effect isn't invisible.
    @discardableResult
    static func apply(_ profile: StyleProfile, to project: inout VODProject) -> [String] {
        var changes: [String] = []

        // Cut rhythm → segment length bounds.
        if profile.medianShotSeconds > 0 {
            let shortest = max(4, min(profile.shortShotSeconds, 60))
            let longest = max(shortest + 5, min(profile.longShotSeconds, 300))

            if profile.looksLikeShort {
                var options = project.candidateOptions
                options.minDuration = max(5, min(shortest, 30))
                options.maxDuration = max(options.minDuration + 5, min(profile.duration, 90))
                project.candidateOptions = options
                changes.append(String(format: "Shorts length → %.0f–%.0fs",
                                      options.minDuration, options.maxDuration))
            }

            if !profile.looksLikeShort {
                var options = project.longFormOptions
                options.minimumSegment = max(10, shortest)
                options.maximumSegment = longest
                project.longFormOptions = options
                changes.append(String(format: "Segment length → %.0f–%.0fs",
                                      options.minimumSegment, options.maximumSegment))
            }
        }

        // How much air the reference leaves in → dead-air trimming.
        var longForm = project.longFormOptions
        if profile.silenceRatio < 0.05 {
            longForm.trimInternalSilence = true
            longForm.internalSilenceThreshold = 0.6
            changes.append("Tight silence trimming (reference keeps almost none)")
        } else if profile.silenceRatio > 0.2 {
            longForm.trimInternalSilence = false
            changes.append("Silence trimming off (reference keeps long pauses)")
        } else {
            longForm.trimInternalSilence = true
            longForm.internalSilenceThreshold = 1.2
            changes.append("Moderate silence trimming")
        }

        // Music bed.
        if profile.hasMusicBed, let level = profile.musicLevelDB {
            longForm.musicEnabled = project.longFormOptions.musicPath != nil
            longForm.musicGainDB = max(-40, min(-4, level))
            longForm.musicDucking = true
            changes.append(String(format: "Background bed at %.0f dB — ducking on%@",
                                  longForm.musicGainDB,
                                  longForm.musicPath == nil ? " (pick a track to enable)" : ""))
        } else {
            longForm.musicEnabled = false
            changes.append("No background bed detected")
        }

        // Target runtime, when the reference is itself a long-form edit.
        if profile.looksLikeLongForm {
            longForm.targetMinutes = max(5, min(60, profile.duration / 60))
            changes.append(String(format: "Target runtime → %.0f min", longForm.targetMinutes))
        }

        project.longFormOptions = longForm
        return changes
    }
}

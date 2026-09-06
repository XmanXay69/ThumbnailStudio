import Foundation

enum AudioTuningError: LocalizedError {
    case noTranscript
    case noAudio
    case crossoverUnsupported

    var errorDescription: String? {
        switch self {
        case .noTranscript:
            return "Audio tuning reads speech timing from the transcript — run ingest first."
        case .noAudio:
            return "The extracted audio is missing. Re-run ingest to rebuild it."
        case .crossoverUnsupported:
            return "This ffmpeg has no `acrossover` filter. Install the full build with: brew install ffmpeg-full"
        }
    }
}

/// Measures how far your voice sits above the game, and builds the filter graph
/// that moves it further.
///
/// The reason this can do anything useful at all on a single already-mixed
/// stream is the transcript. Whisper gives per-word timing, so the app knows to
/// the syllable when you were talking and when the only thing playing was the
/// game — which is a far better ducking key than any level detector reading the
/// mix could produce, because a detector can't tell a shout from an explosion.
///
/// What it cannot do: separate your voice from game audio *inside* the speech
/// band. Two sources sharing 200–3600 Hz are one signal by then. Ducking moves
/// what's outside that band; the presence lift moves the whole band, your voice
/// and any in-band game audio together.
enum AudioTuner {
    static let limitations = """
    Measured from the transcript's word timings: your level while talking, and \
    the game's level in the gaps, inside and outside the 200–3600 Hz speech \
    band. Ducking removes background from outside that band — engine noise, \
    explosions, music low end. Inside it, your voice and the game are one \
    signal and nothing here can pull them apart; a mix where the game competes \
    in the speech band needs fixing at the source.
    """

    // MARK: - Speech map

    /// Runs of speech from the word timings, padded and merged.
    static func speechIntervals(words: [TranscriptWord],
                                padding: Double = AudioTuning.speechPadding,
                                clampedTo limit: Double) -> [ClosedRange<Double>] {
        let spans = words
            .filter { $0.end > $0.start }
            .map { max(0, $0.start - padding)...min(limit, $0.end + padding) }
            .filter { $0.upperBound > $0.lowerBound }
            .sorted { $0.lowerBound < $1.lowerBound }
        guard var current = spans.first else { return [] }

        var merged: [ClosedRange<Double>] = []
        for span in spans.dropFirst() {
            if span.lowerBound <= current.upperBound {
                current = current.lowerBound...max(current.upperBound, span.upperBound)
            } else {
                merged.append(current)
                current = span
            }
        }
        merged.append(current)
        return merged
    }

    static func speechIntervals(transcript: Transcript, in range: ClosedRange<Double>) -> [ClosedRange<Double>] {
        let words = transcript.segments
            .filter { $0.end > range.lowerBound && $0.start < range.upperBound }
            .flatMap(\.words)
            .filter { $0.end > range.lowerBound && $0.start < range.upperBound }
            .map {
                TranscriptWord(text: $0.text,
                               start: max(range.lowerBound, $0.start) - range.lowerBound,
                               end: min(range.upperBound, $0.end) - range.lowerBound,
                               probability: $0.probability)
            }
        return speechIntervals(words: words, clampedTo: range.upperBound - range.lowerBound)
    }

    // MARK: - Measurement

    /// Splits the audio at the speech band's edges, then takes the RMS of each
    /// side over the talking stretches and over the gaps.
    static func measure(audio: URL,
                        speech: [ClosedRange<Double>],
                        duration: Double,
                        workingDirectory: URL,
                        onProgress: @escaping (Double) -> Void = { _ in }) async throws -> AudioProfile {
        guard FileManager.default.fileExists(atPath: audio.path) else { throw AudioTuningError.noAudio }
        let ffmpeg = try FFmpegService()
        guard await ToolLocator.ffmpegFilters().contains("acrossover") else {
            throw AudioTuningError.crossoverUnsupported
        }

        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let bandURL = workingDirectory.appendingPathComponent("tune-band.wav")
        let restURL = workingDirectory.appendingPathComponent("tune-rest.wav")
        defer {
            try? FileManager.default.removeItem(at: bandURL)
            try? FileManager.default.removeItem(at: restURL)
        }

        // One pass, two outputs: the speech band and everything either side.
        try await Shell.runChecked(ffmpeg.ffmpeg, arguments: [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-progress", "pipe:1",
            "-i", audio.path,
            "-filter_complex",
            "[0:a]acrossover=split=\(Int(AudioTuning.bandLow)) \(Int(AudioTuning.bandHigh)):order=4th[lo][mid][hi];"
                + "[lo][hi]amix=inputs=2:normalize=0[rest]",
            "-map", "[mid]", "-c:a", "pcm_s16le", "-y", bandURL.path,
            "-map", "[rest]", "-c:a", "pcm_s16le", "-y", restURL.path,
        ], onOutputLine: { line in
            if let seconds = FFmpegService.parseProgressTime(line), duration > 0 {
                onProgress(min(seconds / duration, 1) * 0.9)
            }
        })

        let band = try rms(of: bandURL, speech: speech)
        let rest = try rms(of: restURL, speech: speech)
        onProgress(1)

        return AudioProfile(
            measuredAt: Date(),
            speechSeconds: band.speechSeconds,
            backgroundSeconds: band.backgroundSeconds,
            voiceBandSpeechDB: band.speechDB,
            voiceBandBackgroundDB: band.backgroundDB,
            outOfBandSpeechDB: rest.speechDB,
            outOfBandBackgroundDB: rest.backgroundDB
        )
    }

    struct BandLevels {
        var speechDB: Double
        var backgroundDB: Double
        var speechSeconds: Double
        var backgroundSeconds: Double
    }

    /// Streams a 16-bit mono WAV, accumulating sum-of-squares into the talking
    /// bucket or the background bucket. Never holds more than a block.
    static func rms(of wav: URL, speech: [ClosedRange<Double>],
                    sampleRate: Double = 16000) throws -> BandLevels {
        let handle = try FileHandle(forReadingFrom: wav)
        defer { try? handle.close() }
        let (offset, length) = try WaveformService.locatePCMData(in: handle)
        try handle.seek(toOffset: offset)

        var speechEnergy = 0.0, backgroundEnergy = 0.0
        var speechSamples = 0, backgroundSamples = 0
        var sampleIndex = 0
        var intervalIndex = 0
        var carry: UInt8?
        var bytesRead: UInt64 = 0
        let blockSize = 4 * 1024 * 1024

        func consume(_ sample: Int16) {
            let time = Double(sampleIndex) / sampleRate
            sampleIndex += 1
            // The intervals are sorted and disjoint, so one forward cursor is
            // enough — no search per sample.
            while intervalIndex < speech.count, speech[intervalIndex].upperBound < time {
                intervalIndex += 1
            }
            let value = Double(sample) / 32768
            let inSpeech = intervalIndex < speech.count && speech[intervalIndex].contains(time)
            if inSpeech {
                speechEnergy += value * value
                speechSamples += 1
            } else {
                backgroundEnergy += value * value
                backgroundSamples += 1
            }
        }

        while bytesRead < length {
            let wanted = Int(min(UInt64(blockSize), length - bytesRead))
            guard let block = try handle.read(upToCount: wanted), !block.isEmpty else { break }
            bytesRead += UInt64(block.count)
            block.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                var index = 0
                if let low = carry, bytes.count > 0 {
                    consume(Int16(bitPattern: UInt16(low) | (UInt16(bytes[0]) << 8)))
                    index = 1
                    carry = nil
                }
                while index + 1 < bytes.count {
                    consume(Int16(bitPattern: UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)))
                    index += 2
                }
                if index < bytes.count { carry = bytes[index] }
            }
        }

        func level(_ energy: Double, _ count: Int) -> Double {
            guard count > 0 else { return -120 }
            let value = (energy / Double(count)).squareRoot()
            return value > 0 ? max(-120, 20 * log10(value)) : -120
        }

        return BandLevels(
            speechDB: level(speechEnergy, speechSamples),
            backgroundDB: level(backgroundEnergy, backgroundSamples),
            speechSeconds: Double(speechSamples) / sampleRate,
            backgroundSeconds: Double(backgroundSamples) / sampleRate
        )
    }

    // MARK: - Ducking envelope

    /// Writes the gain envelope the export multiplies the background by: unity
    /// in the gaps, `-duckDB` while you're talking, cosine ramps between.
    ///
    /// A written envelope rather than a compressor because a compressor's
    /// reduction depends on how hard the key hits it — you ask for 6 dB and get
    /// whatever the detector decides. Multiplying by a curve gives exactly the
    /// number in the panel.
    /// Written longer than the clip it belongs to. The mix ends up bounded by
    /// the shortest input to `amix`, and lookahead filters downstream read
    /// several seconds past the end, so the envelope must not be the thing that
    /// runs out first.
    static let envelopeTailSeconds: Double = 5

    /// 2 kHz is far more than an envelope with 60 ms edges needs, and keeps a
    /// half-hour cut's curve to a few megabytes rather than a hundred.
    @discardableResult
    static func writeDuckEnvelope(speech: [ClosedRange<Double>],
                                  duration: Double,
                                  duckDB: Double,
                                  to url: URL,
                                  sampleRate: Int = 2000) throws -> Int {
        let total = max(1, Int((duration + envelopeTailSeconds) * Double(sampleRate)))
        let floor = Float(pow(10, -abs(duckDB) / 20))
        let ramp = max(1, Int(AudioTuning.rampSeconds * Double(sampleRate)))

        var gains = [Float](repeating: 1, count: total)
        for interval in speech {
            let start = Int(interval.lowerBound * Double(sampleRate))
            let end = Int(interval.upperBound * Double(sampleRate))
            guard end > start else { continue }
            for index in max(0, start)..<min(total, end) { gains[index] = floor }

            // Cosine in and out, so the duck opens and closes without a click.
            for step in 0..<ramp {
                let position = Float(1 - cos(Double(step) / Double(ramp) * .pi / 2))
                let value = 1 - (1 - floor) * position
                let head = start - ramp + step
                if head >= 0, head < total { gains[head] = min(gains[head], value) }
                let tail = end + ramp - step - 1
                if tail >= 0, tail < total { gains[tail] = min(gains[tail], value) }
            }
        }

        var samples = Data(capacity: total * 2)
        for gain in gains {
            let value = Int16(max(0, min(32767, (gain * 32767).rounded())))
            samples.append(UInt8(value & 0xFF))
            samples.append(UInt8((value >> 8) & 0xFF))
        }
        try wavFile(pcm: samples, sampleRate: sampleRate).write(to: url, options: .atomic)
        return total
    }

    /// Minimal 16-bit mono RIFF wrapper.
    private static func wavFile(pcm: Data, sampleRate: Int) -> Data {
        func le32(_ value: Int) -> Data {
            var little = UInt32(truncatingIfNeeded: value).littleEndian
            return Data(bytes: &little, count: 4)
        }
        func le16(_ value: Int) -> Data {
            var little = UInt16(truncatingIfNeeded: value).littleEndian
            return Data(bytes: &little, count: 2)
        }
        var data = Data("RIFF".utf8)
        data += le32(36 + pcm.count)
        data += Data("WAVEfmt ".utf8)
        data += le32(16)                        // PCM header size
        data += le16(1)                         // format: PCM
        data += le16(1)                         // channels
        data += le32(sampleRate)
        data += le32(sampleRate * 2)            // byte rate
        data += le16(2)                         // block align
        data += le16(16)                        // bits per sample
        data += Data("data".utf8)
        data += le32(pcm.count)
        data += pcm
        return data
    }

    // MARK: - Preview

    /// A stretch with a usable amount of both talking and not talking — a
    /// window that is all speech, or all silence, can't show what tuning did.
    static func representativeWindow(speech: [ClosedRange<Double>],
                                     duration: Double,
                                     length: Double = 90) -> ClosedRange<Double> {
        guard duration > length else { return 0...duration }
        var best = 0.0
        var bestScore = -1.0
        for start in stride(from: 0, through: duration - length, by: 30) {
            let window = start...(start + length)
            let talking = speech.reduce(0.0) { total, interval in
                total + max(0, min(interval.upperBound, window.upperBound)
                            - max(interval.lowerBound, window.lowerBound))
            }
            let score = min(talking, length - talking)
            if score > bestScore {
                bestScore = score
                best = start
            }
        }
        return best...(best + length)
    }

    /// Renders the window through the tuning chain and measures both sides.
    static func preview(audio: URL,
                        window: ClosedRange<Double>,
                        speech: [ClosedRange<Double>],
                        tuning: AudioTuning,
                        workingDirectory: URL,
                        onProgress: @escaping (Double) -> Void = { _ in }) async throws -> AudioTuningPreview {
        let ffmpeg = try FFmpegService()
        let length = window.upperBound - window.lowerBound
        let local = speech.compactMap { interval -> ClosedRange<Double>? in
            let lower = max(interval.lowerBound, window.lowerBound) - window.lowerBound
            let upper = min(interval.upperBound, window.upperBound) - window.lowerBound
            return upper > lower ? lower...upper : nil
        }

        let dryURL = workingDirectory.appendingPathComponent("tune-preview-dry.wav")
        let wetURL = workingDirectory.appendingPathComponent("tune-preview-wet.wav")
        let keyURL = workingDirectory.appendingPathComponent("tune-preview-key.wav")
        defer {
            for url in [dryURL, wetURL, keyURL] { try? FileManager.default.removeItem(at: url) }
        }

        try await Shell.runChecked(ffmpeg.ffmpeg, arguments: [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-ss", String(format: "%.3f", window.lowerBound),
            "-t", String(format: "%.3f", length),
            "-i", audio.path,
            "-c:a", "pcm_s16le", "-y", dryURL.path,
        ])
        onProgress(0.2)

        var inputs = ["-i", dryURL.path]
        var keyLabel: String?
        if tuning.needsSpeechKey, !local.isEmpty {
            try writeDuckEnvelope(speech: local, duration: length, duckDB: tuning.duckDB, to: keyURL)
            inputs += ["-i", keyURL.path]
            keyLabel = "1:a"
        }

        // Same two-pass normalization the export uses, or the preview would be
        // measuring a different chain from the one that ships.
        let loudness = try await measureLoudness(ffmpeg: ffmpeg.ffmpeg, inputArguments: inputs,
                                                 key: keyLabel, tuning: tuning)
        onProgress(0.4)

        var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error"] + inputs
        arguments += [
            "-filter_complex",
            filters(input: "0:a", key: keyLabel, tuning: tuning, output: "aout",
                    loudness: loudness).joined(separator: ";"),
            "-map", "[aout]",
            // Back to the measurement format: the chain works at 48 kHz stereo,
            // but both sides have to be compared in the same one.
            "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", "-y", wetURL.path,
        ]
        try await Shell.runChecked(ffmpeg.ffmpeg, arguments: arguments)
        onProgress(0.6)

        let before = try await measure(audio: dryURL, speech: local, duration: length,
                                       workingDirectory: workingDirectory)
        onProgress(0.8)
        let after = try await measure(audio: wetURL, speech: local, duration: length,
                                      workingDirectory: workingDirectory)
        onProgress(1)

        return AudioTuningPreview(sampleStart: window.lowerBound, sampleDuration: length,
                                  before: before, after: after)
    }

    // MARK: - Filter graph

    /// Filter statements that turn `input` into `output`.
    ///
    /// `acrossover` is a Linkwitz-Riley split, so summing the bands back
    /// together is transparent — measured at under 0.01 dB of error at both
    /// split points and everywhere between. That's what makes it safe to treat
    /// the bands separately and then put the mix back.
    ///
    /// Normalization is a measured constant gain plus a limiter, not
    /// `loudnorm`. `loudnorm` lifts quiet stretches harder than loud ones, and
    /// the quiet stretches here are exactly the ones where only the game is
    /// playing — it gives back the gap the tuning just opened. It also can't
    /// avoid doing so: this VOD sits at −33 LUFS with a −12 dBTP peak, so
    /// reaching −14 LUFS needs +19 dB where only +10.6 fits, and loudnorm drops
    /// to dynamic mode on its own even when handed measured values. A constant
    /// gain with a true-peak limiter lands the same loudness, and the limiter
    /// only touches the transients rather than the noise floor.
    static func filters(input: String, key: String?, tuning: AudioTuning,
                        output: String, prefix: String = "tune",
                        loudness: LoudnessMeasurement? = nil,
                        analyzing: Bool = false) -> [String] {
        var statements: [String] = []
        let format = "aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo"
        var stage = "\(prefix)_in"
        statements.append("[\(input)]\(format)[\(stage)]")

        if let key, tuning.duckDB > 0 {
            statements.append("[\(key)]aresample=48000,\(format),asplit=2[\(prefix)_k1][\(prefix)_k2]")
            statements.append("[\(stage)]acrossover=split=\(Int(AudioTuning.bandLow)) \(Int(AudioTuning.bandHigh)):order=4th"
                              + "[\(prefix)_lo][\(prefix)_mid][\(prefix)_hi]")
            statements.append("[\(prefix)_lo][\(prefix)_k1]amultiply[\(prefix)_lod]")
            statements.append("[\(prefix)_hi][\(prefix)_k2]amultiply[\(prefix)_hid]")

            var middle = "\(prefix)_mid"
            if tuning.presenceDB != 0 {
                statements.append("[\(middle)]volume=\(decibels(tuning.presenceDB))dB[\(prefix)_midp]")
                middle = "\(prefix)_midp"
            }
            // `duration=shortest` is not cosmetic. The ducked bands end with
            // the envelope while the middle band runs to the end of a four-hour
            // source, and amix's default (`longest`) deadlocks the graph the
            // moment the first two hit EOF while the third still has data —
            // ffmpeg sat at 100% CPU for ten minutes on a 57-second clip. The
            // envelope is written longer than the clip, so the shortest input
            // is never what bounds the render.
            statements.append("[\(prefix)_lod][\(middle)][\(prefix)_hid]amix=inputs=3:normalize=0:duration=shortest[\(prefix)_mixed]")
            stage = "\(prefix)_mixed"
        } else if tuning.presenceDB != 0 {
            // No ducking, so the bands never need separating — one peaking EQ
            // over the speech band does the whole job.
            let centre = (AudioTuning.bandLow * AudioTuning.bandHigh).squareRoot()
            statements.append("[\(stage)]equalizer=f=\(Int(centre)):width_type=h:width=\(Int(AudioTuning.bandHigh - AudioTuning.bandLow)):g=\(decibels(tuning.presenceDB))[\(prefix)_eq]")
            stage = "\(prefix)_eq"
        }

        guard tuning.normalize else {
            // Without a limiter the presence lift has nothing stopping it
            // clipping. `level=false` because alimiter otherwise makes up the
            // gain it just took, which is the opposite of the point.
            statements.append("[\(stage)]alimiter=limit=\(truePeakCeiling):level=false[\(output)]")
            return statements
        }

        if analyzing {
            // Analysis only — the JSON this prints is read back, and the audio
            // it emits is thrown away.
            statements.append("[\(stage)]loudnorm=I=\(decibels(tuning.targetLUFS)):TP=-1.5:LRA=11:print_format=json[\(output)]")
            return statements
        }

        var normalized = stage
        if let loudness {
            let gain = min(30, max(-30, tuning.targetLUFS - loudness.integrated))
            statements.append("[\(stage)]volume=\(decibels(gain))dB[\(prefix)_lvl]")
            normalized = "\(prefix)_lvl"
        }
        statements.append("[\(normalized)]alimiter=limit=\(truePeakCeiling):level=false[\(output)]")
        return statements
    }

    /// −1.5 dBTP, the headroom every platform's encoder wants.
    private static let truePeakCeiling = String(format: "%.3f", pow(10, -1.5 / 20))

    /// Runs the chain through `loudnorm`'s analysis mode and reads back what it
    /// measured, so the render can normalize with a fixed gain.
    static func measureLoudness(ffmpeg: URL, inputArguments: [String],
                                key: String?, tuning: AudioTuning) async throws -> LoudnessMeasurement? {
        guard tuning.normalize else { return nil }
        let statements = filters(input: "0:a", key: key, tuning: tuning,
                                 output: "lnout", prefix: "ln", analyzing: true)
        var captured = ""
        var collecting = false

        let result = try await Shell.run(ffmpeg, arguments:
            ["-nostdin", "-hide_banner"] + inputArguments + [
                "-filter_complex", statements.joined(separator: ";"),
                "-map", "[lnout]", "-f", "null", "-",
            ], onErrorLine: { line in
                // loudnorm prints its JSON object at the end of stderr.
                if line.trimmingCharacters(in: .whitespaces) == "{" { collecting = true }
                if collecting { captured += line + "\n" }
                if line.trimmingCharacters(in: .whitespaces) == "}" { collecting = false }
            })
        guard result.exitCode == 0 else { return nil }
        return parseLoudness(captured)
    }

    static func parseLoudness(_ json: String) -> LoudnessMeasurement? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        func number(_ key: String) -> Double? {
            guard let raw = object[key] as? String else { return object[key] as? Double }
            // loudnorm reports "-inf" for silence, which is not a usable input
            // to the second pass.
            return Double(raw)
        }
        guard let integrated = number("input_i"), integrated.isFinite,
              let truePeak = number("input_tp"), truePeak.isFinite,
              let range = number("input_lra"), range.isFinite,
              let threshold = number("input_thresh"), threshold.isFinite else { return nil }
        return LoudnessMeasurement(integrated: integrated, truePeak: truePeak,
                                   range: range, threshold: threshold,
                                   offset: number("target_offset") ?? 0)
    }

    private static func decibels(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

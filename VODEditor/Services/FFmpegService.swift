import Foundation

enum FFmpegError: LocalizedError {
    case toolMissing(String)
    case probeFailed(String)
    case noAudioStream

    var errorDescription: String? {
        switch self {
        case .toolMissing(let name): return "\(name) was not found. Install it with Homebrew: brew install ffmpeg"
        case .probeFailed(let detail): return "Could not read media info: \(detail)"
        case .noAudioStream: return "This file has no audio stream to transcribe."
        }
    }
}

/// All video/audio manipulation goes through the ffmpeg CLI. Nothing here ever
/// loads a whole file into memory — the source VOD is only ever streamed.
struct FFmpegService {
    let ffmpeg: URL
    let ffprobe: URL

    init() throws {
        guard let ffmpeg = ToolLocator.locate("ffmpeg") else { throw FFmpegError.toolMissing("ffmpeg") }
        guard let ffprobe = ToolLocator.locate("ffprobe") else { throw FFmpegError.toolMissing("ffprobe") }
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }

    // MARK: - Probe

    private struct ProbeOutput: Decodable {
        struct Stream: Decodable {
            let codec_type: String?
            let codec_name: String?
            let width: Int?
            let height: Int?
            let r_frame_rate: String?
            let sample_rate: String?
            let channels: Int?
        }
        struct Format: Decodable {
            let duration: String?
            let size: String?
        }
        let streams: [Stream]?
        let format: Format?
    }

    func probe(_ url: URL) async throws -> MediaInfo {
        var probeArguments = ["-v", "error"]
        if HLSSource.isPlaylist(url) {
            probeArguments += ["-protocol_whitelist", HLSSource.protocolWhitelist]
        }
        probeArguments += [
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            url.path,
        ]
        let result = try await Shell.runChecked(ffprobe, arguments: probeArguments)
        guard let data = result.stdout.data(using: .utf8),
              let output = try? JSONDecoder().decode(ProbeOutput.self, from: data) else {
            throw FFmpegError.probeFailed(String(result.stderr.suffix(500)))
        }

        let video = output.streams?.first { $0.codec_type == "video" }
        guard let audio = output.streams?.first(where: { $0.codec_type == "audio" }) else {
            throw FFmpegError.noAudioStream
        }

        return MediaInfo(
            durationSeconds: Double(output.format?.duration ?? "") ?? 0,
            width: video?.width ?? 0,
            height: video?.height ?? 0,
            fps: Self.parseRational(video?.r_frame_rate),
            videoCodec: video?.codec_name ?? "none",
            audioCodec: audio.codec_name ?? "unknown",
            audioSampleRate: Int(audio.sample_rate ?? "") ?? 0,
            audioChannels: audio.channels ?? 0,
            sizeBytes: Int64(output.format?.size ?? "") ?? 0
        )
    }

    private static func parseRational(_ value: String?) -> Double {
        guard let value else { return 0 }
        let parts = value.split(separator: "/")
        if parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den != 0 {
            return num / den
        }
        return Double(value) ?? 0
    }

    // MARK: - Audio extraction

    /// Decodes the source's audio to 16 kHz mono PCM — the only format
    /// whisper.cpp actually consumes, and ~115 MB per hour.
    func extractAudio(from source: URL, to destination: URL,
                      totalDuration: Double,
                      onProgress: @escaping (Double) -> Void) async throws {
        var arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-progress", "pipe:1",
        ]
        arguments += HLSSource.inputArguments(for: source)
        arguments += [
            "-vn", "-sn", "-dn",
            "-ac", "1", "-ar", "16000",
            "-c:a", "pcm_s16le",
            "-f", "wav", "-y", destination.path,
        ]
        try await Shell.runChecked(ffmpeg, arguments: arguments, onOutputLine: { line in
            if let seconds = Self.parseProgressTime(line), totalDuration > 0 {
                onProgress(min(seconds / totalDuration, 1))
            }
        })
    }

    /// ffmpeg's `-progress` stream emits `out_time=HH:MM:SS.micros`. (Its
    /// `out_time_ms` field is actually microseconds, so it's avoided here.)
    static func parseProgressTime(_ line: String) -> Double? {
        guard line.hasPrefix("out_time=") else { return nil }
        let value = line.dropFirst("out_time=".count)
        let parts = value.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2])
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    // MARK: - Silence detection

    /// Silence data feeds two things: chunk boundaries that don't cut words in
    /// half, and (later) dead-air trimming between kept segments.
    func detectSilence(in wav: URL, totalDuration: Double,
                       noiseFloorDB: Int = -32, minimumDuration: Double = 0.6,
                       onProgress: @escaping (Double) -> Void) async throws -> [SilenceInterval] {
        var intervals: [SilenceInterval] = []
        var pendingStart: Double?

        _ = try await Shell.runChecked(ffmpeg, arguments: [
            "-nostdin", "-hide_banner",
            "-progress", "pipe:1",
            "-i", wav.path,
            "-af", "silencedetect=noise=\(noiseFloorDB)dB:d=\(minimumDuration)",
            "-f", "null", "-",
        ], onOutputLine: { line in
            if let seconds = Self.parseProgressTime(line), totalDuration > 0 {
                onProgress(min(seconds / totalDuration, 1))
            }
        }, onErrorLine: { line in
            guard line.contains("silencedetect") else { return }
            if let value = Self.value(after: "silence_start:", in: line) {
                pendingStart = value
            } else if let value = Self.value(after: "silence_end:", in: line) {
                let start = pendingStart ?? max(0, value - minimumDuration)
                if value > start { intervals.append(SilenceInterval(start: start, end: value)) }
                pendingStart = nil
            }
        })

        if let start = pendingStart, totalDuration > start {
            intervals.append(SilenceInterval(start: start, end: totalDuration))
        }
        return intervals
    }

    private static func value(after key: String, in line: String) -> Double? {
        guard let range = line.range(of: key) else { return nil }
        let rest = line[range.upperBound...]
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ")
            .first ?? ""
        return Double(rest)
    }

    // MARK: - Scene detection

    /// Timestamps where the picture changes enough to read as a cut.
    ///
    /// Decodes **keyframes only**. A full decode of a four-hour 1080p60 source
    /// takes ~23 minutes; keyframe-only takes ~2.5 and finds essentially the
    /// same cuts (4 vs 5 over a 10-minute sample), because Twitch VODs carry a
    /// keyframe every couple of seconds.
    func detectScenes(in source: URL,
                      totalDuration: Double,
                      threshold: Double = 0.4,
                      keyframesOnly: Bool = true,
                      onProgress: @escaping (Double) -> Void) async throws -> [Double] {
        var scenes: [Double] = []

        var arguments = ["-nostdin", "-hide_banner"]
        if keyframesOnly { arguments += ["-skip_frame", "nokey"] }
        arguments += ["-progress", "pipe:1"]
        arguments += HLSSource.inputArguments(for: source)
        arguments += [
            "-an", "-sn",
            "-vf", "select='gt(scene,\(threshold))',showinfo",
            "-f", "null", "-",
        ]

        _ = try await Shell.runChecked(ffmpeg, arguments: arguments, onOutputLine: { line in
            if let seconds = Self.parseProgressTime(line), totalDuration > 0 {
                onProgress(min(seconds / totalDuration, 1))
            }
        }, onErrorLine: { line in
            // showinfo reports each surviving frame as `... pts_time:123.45 ...`
            guard line.contains("showinfo"), let range = line.range(of: "pts_time:") else { return }
            let rest = line[range.upperBound...]
                .prefix { !$0.isWhitespace }
            if let value = Double(rest) { scenes.append(value) }
        })

        return scenes.sorted()
    }

    // MARK: - Chunking

    /// Splits the extracted audio into transcription chunks at the supplied cut
    /// points, in a single pass.
    func splitIntoChunks(wav: URL, chunksDirectory: URL, cutPoints: [Double]) async throws -> [ChunkSpec] {
        let fm = FileManager.default
        if fm.fileExists(atPath: chunksDirectory.path) {
            try fm.removeItem(at: chunksDirectory)
        }
        try fm.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)

        // No cut points means the source is shorter than one chunk, and the
        // whole thing is a single chunk. It must not go through the segment
        // muxer: with no `-segment_times` that muxer falls back to its own
        // default of 2 seconds, which turned a 75-second clip into 38 chunks
        // and 38 whisper invocations — 0.8× realtime instead of 13×.
        if cutPoints.isEmpty {
            let single = chunksDirectory.appendingPathComponent("chunk_0000.wav")
            try await Shell.runChecked(ffmpeg, arguments: [
                "-nostdin", "-hide_banner", "-loglevel", "error",
                "-i", wav.path, "-c", "copy", "-y", single.path,
            ])
            let duration = try await durationOf(single)
            return [ChunkSpec(index: 0, startSeconds: 0, durationSeconds: duration)]
        }

        let pattern = chunksDirectory.appendingPathComponent("chunk_%04d.wav").path
        let arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-i", wav.path,
            "-f", "segment",
            "-c", "copy",
            "-reset_timestamps", "1",
            "-segment_times", cutPoints.map { String(format: "%.3f", $0) }.joined(separator: ","),
            "-y", pattern,
        ]

        try await Shell.runChecked(ffmpeg, arguments: arguments)

        // Measure what ffmpeg actually produced rather than trusting the plan.
        let files = try fm.contentsOfDirectory(at: chunksDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var specs: [ChunkSpec] = []
        var cursor: Double = 0
        for (index, file) in files.enumerated() {
            let duration = try await durationOf(file)
            specs.append(ChunkSpec(index: index, startSeconds: cursor, durationSeconds: duration))
            cursor += duration
        }
        return specs
    }

    func durationOf(_ url: URL) async throws -> Double {
        let result = try await Shell.runChecked(ffprobe, arguments: [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path,
        ])
        return Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Picks cut points near each target boundary, nudged onto the nearest
    /// silence so chunks don't split mid-word.
    static func planCutPoints(duration: Double, targetChunk: Double,
                              silence: [SilenceInterval], searchWindow: Double = 45) -> [Double] {
        guard duration > targetChunk else { return [] }

        var cuts: [Double] = []
        var target = targetChunk
        while target < duration - 60 {
            let candidate = silence
                .filter { abs($0.midpoint - target) <= searchWindow && $0.duration >= 0.4 }
                .min { abs($0.midpoint - target) < abs($1.midpoint - target) }?
                .midpoint ?? target

            // Keep cuts strictly increasing and never absurdly short.
            if let last = cuts.last, candidate - last < 60 {
                cuts.append(target)
            } else {
                cuts.append(candidate)
            }
            target += targetChunk
        }
        return cuts
    }
}

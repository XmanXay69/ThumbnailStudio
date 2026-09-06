import Foundation

enum WhisperError: LocalizedError {
    case toolMissing
    case noModel
    case outputMissing(URL)

    var errorDescription: String? {
        switch self {
        case .toolMissing:
            return "whisper-cli was not found. Install it with Homebrew: brew install whisper-cpp"
        case .noModel:
            return "No whisper model found in Application Support/VODEditor/models."
        case .outputMissing(let url):
            return "whisper-cli finished but wrote no JSON at \(url.lastPathComponent)."
        }
    }
}

struct WhisperRunInfo {
    var gpuName: String?
    var usedMetal: Bool
    var flashAttention: Bool
}

struct WhisperService {
    let binary: URL

    init() throws {
        guard let binary = ToolLocator.locate("whisper-cli") else { throw WhisperError.toolMissing }
        self.binary = binary
    }

    /// whisper.cpp is Metal-accelerated on Apple silicon, but it silently falls
    /// back to CPU if the backend fails to load — so the run is inspected and
    /// the result surfaced in the UI rather than assumed.
    static var threadCount: Int {
        max(4, min(8, ProcessInfo.processInfo.activeProcessorCount))
    }

    @discardableResult
    func transcribe(chunkAudio: URL,
                    outputBase: URL,
                    model: WhisperModel,
                    prompt: String,
                    language: String,
                    chunkDuration: Double,
                    accuracy: Bool = false,
                    onProgress: @escaping (Double) -> Void,
                    onLog: @escaping (String) -> Void) async throws -> WhisperRunInfo {
        var arguments = [
            "-m", model.url.path,
            "-f", chunkAudio.path,
            "-of", outputBase.path,
            "-oj", "-ojf",
            "-l", language,
            "-t", String(Self.threadCount),
            // Wider beam than the default 5, and more candidates when the
            // decoder falls back to sampling. Fast, overlapping stream speech
            // is exactly where greedy decoding takes wrong turns, and Metal
            // absorbs the extra cost without moving the wall clock much.
            "-bs", "8", "-bo", "8",
        ]
        if accuracy {
            // A lower entropy threshold falls back to temperature sampling
            // sooner when the beam is unsure — slower, but it rescues exactly
            // the mumbled stretches that come out as nonsense otherwise.
            // Beam stays at 8: beam 12 combined with this fallback trips a
            // Metal residency assert in Homebrew's ggml on the full large-v3
            // (reproduced ~half the time; beam 8 ran clean every attempt).
            arguments += ["--entropy-thold", "2.0", "--temperature-inc", "0.2"]
        }
        if let alias = model.dtwAlias {
            // Token-level timestamps, needed for karaoke-style captions later.
            // Flash attention defaults to on in the Homebrew build and silently
            // suppresses DTW alignment — every token comes back `t_dtw: -1`.
            // Disabling it costs nothing measurable on Metal.
            arguments += ["-dtw", alias, "-nfa"]
        }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty {
            arguments += ["--prompt", trimmedPrompt]
        }

        var info = WhisperRunInfo(gpuName: nil, usedMetal: false, flashAttention: false)

        try await Shell.runChecked(binary, arguments: arguments, onOutputLine: { line in
            if let seconds = Self.parseSegmentEnd(line), chunkDuration > 0 {
                onProgress(min(seconds / chunkDuration, 1))
            }
        }, onErrorLine: { line in
            if line.contains("loaded MTL backend") || line.contains("ggml_metal_device_init") {
                info.usedMetal = true
            }
            if let range = line.range(of: "GPU name:") {
                info.gpuName = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            }
            if line.contains("flash_attn = 1") || line.contains("flash attn = 1") {
                info.flashAttention = true
            }
            if line.contains("error") || line.contains("failed") {
                onLog(line)
            }
        })

        let json = outputBase.appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: json.path) else {
            throw WhisperError.outputMissing(json)
        }
        onProgress(1)
        return info
    }

    /// whisper-cli streams `[00:00:00.000 --> 00:00:05.000]   text` as it
    /// decodes; the end timestamp gives progress inside a chunk.
    static func parseSegmentEnd(_ line: String) -> Double? {
        guard line.hasPrefix("["), let arrow = line.range(of: " --> ") else { return nil }
        let remainder = line[arrow.upperBound...]
        guard let close = remainder.firstIndex(of: "]") else { return nil }
        return parseTimestamp(String(remainder[remainder.startIndex..<close]))
    }

    static func parseTimestamp(_ value: String) -> Double? {
        let parts = value.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2])
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}

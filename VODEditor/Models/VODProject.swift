import Foundation

struct MediaInfo: Codable, Equatable {
    var durationSeconds: Double
    var width: Int
    var height: Int
    var fps: Double
    var videoCodec: String
    var audioCodec: String
    var audioSampleRate: Int
    var audioChannels: Int
    var sizeBytes: Int64

    var resolutionLabel: String { "\(width)×\(height)" }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

enum IngestStage: String, Codable, CaseIterable {
    case created
    case probing
    case extractingAudio
    case detectingSilence
    case generatingWaveform
    case transcribing
    case merging
    case ready
    case failed

    var label: String {
        switch self {
        case .created: return "Not started"
        case .probing: return "Reading media info"
        case .extractingAudio: return "Extracting audio"
        case .detectingSilence: return "Detecting silence"
        case .generatingWaveform: return "Generating waveform"
        case .transcribing: return "Transcribing"
        case .merging: return "Merging transcript"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }

    /// Ordered stages shown in the ingest progress list.
    static var pipeline: [IngestStage] {
        [.probing, .extractingAudio, .detectingSilence, .generatingWaveform, .transcribing, .merging]
    }

    var isTerminal: Bool { self == .ready || self == .failed }
}

/// One transcription unit. Chunking keeps memory bounded and — more importantly
/// — makes a multi-hour run resumable: each chunk's JSON lands on disk as soon
/// as it finishes, so a crash costs one chunk, not the whole VOD.
struct ChunkSpec: Codable, Equatable, Identifiable {
    var index: Int
    var startSeconds: Double
    var durationSeconds: Double

    var id: Int { index }
    var endSeconds: Double { startSeconds + durationSeconds }
}

struct SilenceInterval: Codable, Equatable {
    var start: Double
    var end: Double

    var duration: Double { end - start }
    var midpoint: Double { (start + end) / 2 }
}

struct VODProject: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var sourcePath: String
    var createdAt: Date = Date()
    var media: MediaInfo?

    /// Passed to whisper as `--prompt`. Streamer name, co-streamers, game
    /// titles, recurring bits — cuts down misheard proper nouns a lot.
    var vocabularyPrompt: String = ""

    /// Max-accuracy transcription: the full large-v3 model when installed,
    /// an earlier sampling fallback. Roughly 3–4× slower.
    var useAccurateTranscription: Bool = false

    var stage: IngestStage = .created
    var lastError: String?

    var chunkPlan: [ChunkSpec] = []
    var completedChunkIndices: Set<Int> = []

    var modelFileName: String?
    var language: String = "en"

    var transcriptSegmentCount: Int = 0
    var waveformPeakCount: Int = 0
    var waveformPeaksPerSecond: Double = 20

    /// Wall-clock seconds the transcription pass took, for benchmarking against
    /// source duration.
    var transcriptionElapsedSeconds: Double?

    // MARK: Phase 2 — shorts

    var scoreWeights: ScoreWeights = .standard
    /// What the analysis hunts for — scales the weights at scoring time.
    var contentFocus: ContentFocus = .balanced
    /// The clip finder's category roster — editable per streamer, seeded from
    /// the defaults. Descriptions feed the analysis prompt directly.
    var clipCategories: [ClipCategory] = ClipCategory.defaults
    /// The find-clips sheet offers itself once per project, then stays out of
    /// the way (it remains reachable from the Shorts tab).
    var autoClipPromptShown: Bool = false
    var candidateOptions: CandidateOptions = .standard
    /// The framing new shorts inherit — the webcam box is constant for a
    /// streamer, so it's set once and reused.
    var defaultShortLayout: ShortLayout = .fill
    var captionStyle: CaptionStyle = .standard
    var exportSettings: ExportSettings = .standard
    var chatPath: String?
    var shortsGeneratedAt: Date?

    // MARK: Phase 3 — long form
    var longFormOptions: LongFormOptions = .standard

    var audioTuning: AudioTuning = .standard

    // MARK: Packaging
    var thumbnail: ThumbnailDraft = ThumbnailDraft()

    // MARK: Client and lifecycle
    /// Which client profile was applied, and their name kept denormalised so
    /// the dashboard still shows it if the profile is later deleted.
    var clientProfileID: UUID?
    var clientName: String = ""
    /// Set by hand from the dashboard once the content actually went up —
    /// the app can't know, so the editor records it.
    var postedAt: Date?

    /// Set when the VOD is being edited over the network instead of from a
    /// downloaded file. `sourcePath` then points at a local playlist.
    var remote: RemoteSource?

    var chatURL: URL? { chatPath.map { URL(fileURLWithPath: $0) } }

    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
    var sourceExists: Bool { FileManager.default.fileExists(atPath: sourcePath) }

    /// Edited over the network rather than from a downloaded file.
    var isStreamed: Bool { remote != nil }

    /// What the player should open. A streamed project can't hand AVFoundation
    /// a local playlist full of remote segments, so it gets the CDN URL.
    var playbackURL: URL? {
        guard let remote else { return sourceExists ? sourceURL : nil }
        return remote.remotePlaybackURL
    }
    var paths: Paths.Project { Paths.Project(id) }

    var chunkProgress: Double {
        guard !chunkPlan.isEmpty else { return 0 }
        return Double(completedChunkIndices.count) / Double(chunkPlan.count)
    }

    var transcriptionSpeedLabel: String? {
        guard let elapsed = transcriptionElapsedSeconds, elapsed > 0,
              let duration = media?.durationSeconds, duration > 0 else { return nil }
        return String(format: "%.1f× realtime", duration / elapsed)
    }
}

extension VODProject {
    /// Hand-written so that adding a field never invalidates a project already
    /// on disk. Swift's synthesized decoder ignores property defaults and
    /// treats every non-optional key as required, which would have made the
    /// Phase 2 fields a breaking change for existing projects.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }

        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sourcePath = try container.decode(String.self, forKey: .sourcePath)

        createdAt = value(.createdAt, Date())
        media = try? container.decodeIfPresent(MediaInfo.self, forKey: .media)
        vocabularyPrompt = value(.vocabularyPrompt, "")
        useAccurateTranscription = value(.useAccurateTranscription, false)
        stage = value(.stage, IngestStage.created)
        lastError = try? container.decodeIfPresent(String.self, forKey: .lastError)
        chunkPlan = value(.chunkPlan, [ChunkSpec]())
        completedChunkIndices = value(.completedChunkIndices, Set<Int>())
        modelFileName = try? container.decodeIfPresent(String.self, forKey: .modelFileName)
        language = value(.language, "en")
        transcriptSegmentCount = value(.transcriptSegmentCount, 0)
        waveformPeakCount = value(.waveformPeakCount, 0)
        waveformPeaksPerSecond = value(.waveformPeaksPerSecond, 20)
        transcriptionElapsedSeconds = try? container.decodeIfPresent(Double.self, forKey: .transcriptionElapsedSeconds)

        scoreWeights = value(.scoreWeights, ScoreWeights.standard)
        contentFocus = value(.contentFocus, ContentFocus.balanced)
        clipCategories = value(.clipCategories, ClipCategory.defaults)
        autoClipPromptShown = value(.autoClipPromptShown, false)
        candidateOptions = value(.candidateOptions, CandidateOptions.standard)
        defaultShortLayout = value(.defaultShortLayout, ShortLayout.fill)
        captionStyle = value(.captionStyle, CaptionStyle.standard)
        exportSettings = value(.exportSettings, ExportSettings.standard)
        chatPath = try? container.decodeIfPresent(String.self, forKey: .chatPath)
        shortsGeneratedAt = try? container.decodeIfPresent(Date.self, forKey: .shortsGeneratedAt)
        longFormOptions = value(.longFormOptions, LongFormOptions.standard)
        audioTuning = value(.audioTuning, AudioTuning.standard)
        thumbnail = value(.thumbnail, ThumbnailDraft())
        clientProfileID = try? container.decodeIfPresent(UUID.self, forKey: .clientProfileID)
        clientName = value(.clientName, "")
        postedAt = try? container.decodeIfPresent(Date.self, forKey: .postedAt)
        remote = try? container.decodeIfPresent(RemoteSource.self, forKey: .remote)
    }
}

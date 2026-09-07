import AppKit
import AVFoundation
import Foundation

/// Drives one project's ingest pipeline and holds the artifacts the review UI
/// reads. Every stage writes its output to disk before the next one starts, so
/// an interrupted run resumes instead of restarting.
@MainActor
final class ProjectSession: ObservableObject {
    @Published private(set) var project: VODProject
    @Published private(set) var transcript = Transcript()
    /// The whole transcript regrouped into render-ready cues, in source time.
    /// Rebuilt only when the transcript or a cue-shaping style field changes —
    /// the Browse preview looks up into it rather than re-deriving per frame.
    @Published private(set) var previewCues: [CaptionLine] = []
    @Published private(set) var waveform: WaveformData?
    @Published private(set) var silence: [SilenceInterval] = []

    // Phase 2
    @Published private(set) var scoreCurve = ScoreCurve()
    @Published private(set) var shorts: [ShortCandidate] = []
    @Published private(set) var chat: [ChatMessage] = []
    @Published private(set) var scenes: [Double] = []
    @Published private(set) var isDetectingScenes = false
    @Published private(set) var sceneProgress: Double = 0
    @Published private(set) var throughlines: [Throughline] = []
    @Published private(set) var coherenceError: String?
    @Published private(set) var styleProfile: StyleProfile?
    @Published private(set) var isAnalyzingStyle = false
    @Published private(set) var styleProgress: Double = 0
    @Published private(set) var styleStage = ""
    @Published private(set) var appliedStyleChanges: [String] = []
    @Published private(set) var audioProfile: AudioProfile?
    @Published private(set) var isMeasuringAudio = false
    @Published private(set) var audioProgress: Double = 0
    @Published private(set) var audioStage = ""
    @Published private(set) var audioPreview: AudioTuningPreview?
    @Published private(set) var audioError: String?

    // Packaging
    @Published private(set) var ideas: IdeaPack?
    @Published private(set) var frames: [FrameCandidate] = []
    @Published private(set) var isExtractingFrames = false
    @Published private(set) var frameProgress: Double = 0
    @Published private(set) var lastThumbnailPath: String?
    @Published private(set) var publishError: String?
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Double = 0
    @Published private(set) var lastExport: ExportResult?

    // Phase 3
    @Published private(set) var longForm = LongFormEdit()
    @Published private(set) var assembled = AssembledEdit()
    @Published private(set) var previewComposition: AVComposition?
    @Published private(set) var isBuildingPreview = false

    @Published private(set) var isRunning = false
    @Published private(set) var stageProgress: Double = 0 { didSet { reportProgress() } }
    @Published private(set) var statusDetail = ""
    @Published private(set) var backendNote: String?
    @Published private(set) var log: [String] = []

    private let store: ProjectStore
    private var pipeline: Task<Void, Never>?
    private var shortsPersistTask: Task<Void, Never>?
    private var longFormPersistTask: Task<Void, Never>?
    private var transcriptPersistTask: Task<Void, Never>?
    private var previewRebuildTask: Task<Void, Never>?

    /// Target length of one transcription chunk. Ten minutes keeps whisper's
    /// memory flat and bounds what a crash can cost.
    private let targetChunkSeconds: Double = 600

    init(project: VODProject, store: ProjectStore) {
        self.project = project
        self.store = store
        loadArtifacts()
    }

    deinit { pipeline?.cancel() }

    var stage: IngestStage { project.stage }
    var isReady: Bool { project.stage == .ready }

    // MARK: - Artifacts

    func loadArtifacts() {
        let paths = project.paths
        if let data = try? Data(contentsOf: paths.mergedTranscript),
           let decoded = try? JSONDecoder().decode(Transcript.self, from: data) {
            transcript = decoded
        }
        if FileManager.default.fileExists(atPath: paths.waveform.path) {
            waveform = try? WaveformService.load(from: paths.waveform,
                                                 peaksPerSecond: project.waveformPeaksPerSecond)
        }
        if let data = try? Data(contentsOf: paths.silence),
           let decoded = try? JSONDecoder().decode([SilenceInterval].self, from: data) {
            silence = decoded
        }
        if let data = try? Data(contentsOf: paths.score),
           let decoded = try? JSONDecoder().decode(ScoreCurve.self, from: data) {
            scoreCurve = decoded
        }
        if let data = try? Data(contentsOf: paths.shorts),
           let decoded = try? JSONDecoder().decode([ShortCandidate].self, from: data) {
            shorts = decoded
        }
        if let url = project.chatURL, let messages = try? ChatReplay.load(from: url) {
            chat = messages
        }
        if let data = try? Data(contentsOf: paths.scenes),
           let decoded = try? JSONDecoder().decode([Double].self, from: data) {
            scenes = decoded
        }
        if let data = try? Data(contentsOf: paths.throughlines),
           let decoded = try? JSONDecoder().decode([Throughline].self, from: data) {
            throughlines = decoded
        }
        if let data = try? Data(contentsOf: paths.styleProfile),
           let decoded = try? JSONDecoder().decode(StyleProfile.self, from: data) {
            styleProfile = decoded
        }
        if let data = try? Data(contentsOf: paths.audioProfile),
           let decoded = try? JSONDecoder().decode(AudioProfile.self, from: data) {
            audioProfile = decoded
        }
        if let data = try? Data(contentsOf: paths.ideas),
           let decoded = try? JSONDecoder().decode(IdeaPack.self, from: data) {
            ideas = decoded
        }
        if let data = try? Data(contentsOf: paths.clipEdit),
           let decoded = try? JSONDecoder().decode(ClipEdit.self, from: data) {
            clipEdit = decoded
            rebuildEditOverlay()
            scheduleEditPreview()
        }
        if let data = try? Data(contentsOf: paths.autoClips),
           let decoded = try? JSONDecoder().decode(AutoClipRun.self, from: data) {
            autoClipRun = decoded
        }
        if let data = try? Data(contentsOf: paths.thumbStudio),
           let decoded = try? JSONDecoder().decode(ThumbDocument.self, from: data) {
            thumbDoc = decoded
        }
        // Frames already on disk from a previous session, so the strip isn't
        // empty until they're re-extracted.
        if let files = try? FileManager.default.contentsOfDirectory(at: paths.thumbnailsDir,
                                                                    includingPropertiesForKeys: nil) {
            frames = files
                .filter { $0.pathExtension == "jpg" && $0.lastPathComponent.hasPrefix("frame_") }
                .compactMap { url -> FrameCandidate? in
                    let stem = url.deletingPathExtension().lastPathComponent
                    guard let seconds = Double(stem.replacingOccurrences(of: "frame_", with: "")) else {
                        return nil
                    }
                    return FrameCandidate(id: Int(seconds), time: seconds, path: url.path,
                                          caption: "", score: 0)
                }
                .sorted { $0.time < $1.time }
        }
        if let data = try? Data(contentsOf: paths.longForm),
           let decoded = try? JSONDecoder().decode(LongFormEdit.self, from: data) {
            longForm = decoded
            rebuildAssembly()
        }
        rebuildPreviewCues()
    }

    func rebuildPreviewCues() {
        previewCues = CaptionBuilder.lines(transcript: transcript, style: project.captionStyle)
    }

    /// Opt-in: the only analysis that has to touch the video stream. Decoding
    /// keyframes only keeps it to ~2.5 minutes on a four-hour source instead of
    /// the ~23 a full decode would cost.
    /// Scene detection walks the whole video. On a streamed project that means
    /// pulling every segment — the entire download this mode exists to avoid —
    /// so it is refused rather than started and left to surprise someone.
    var canDetectScenes: Bool { !project.isStreamed }

    var sceneDetectionBlockedReason: String? {
        guard project.isStreamed else { return nil }
        let size = project.remote?.fullVideoBytes
            .map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "the whole video"
        return "Scene detection reads every frame of the video, which on a streamed project means pulling \(size). Download the VOD if you want it."
    }

    func detectScenes() {
        guard canDetectScenes else {
            append(sceneDetectionBlockedReason ?? "Scene detection needs a downloaded VOD")
            return
        }
        guard !isDetectingScenes, let media = project.media else { return }
        isDetectingScenes = true
        sceneProgress = 0

        Task { [weak self] in
            guard let self else { return }
            do {
                let ffmpeg = try FFmpegService()
                let found = try await ffmpeg.detectScenes(
                    in: self.project.sourceURL,
                    totalDuration: media.durationSeconds,
                    onProgress: { progress in
                        Task { @MainActor in self.sceneProgress = progress }
                    }
                )
                self.scenes = found
                try? JSONEncoder().encode(found).write(to: self.project.paths.scenes, options: .atomic)
                self.isDetectingScenes = false
                self.append("Scene detection: \(found.count) cuts")
                self.analyzeShorts()
            } catch {
                self.isDetectingScenes = false
                self.append("Scene detection failed: \(error.localizedDescription)")
            }
        }
    }

    func clearScenes() {
        scenes = []
        try? FileManager.default.removeItem(at: project.paths.scenes)
        analyzeShorts()
    }

    // MARK: - Coherence pass

    var canRunCoherence: Bool { !transcript.isEmpty }

    /// The whole-transcript throughlines prompt for a claude.ai chat.
    func throughlinesPrompt() -> String? {
        guard !transcript.isEmpty else { return nil }
        return CoherenceService.manualPrompt(transcript: transcript,
                                             vocabulary: project.vocabularyPrompt)
    }

    /// Applies a pasted throughlines reply, so the long-form pass doesn't keep
    /// one beat of a running bit and drop the setup.
    func applyThroughlinesReply(_ reply: String) throws -> String {
        coherenceError = nil
        do {
            let found = try CoherenceService.parseReply(reply)
            adoptThroughlines(found)
            return "\(found.count) throughlines applied."
        } catch {
            coherenceError = error.localizedDescription
            append("Coherence reply failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func adoptThroughlines(_ found: [Throughline]) {
        throughlines = found
        try? JSONEncoder().encode(found).write(to: project.paths.throughlines,
                                               options: .atomic)
        append("Coherence: \(found.count) throughlines across \(found.reduce(0) { $0 + $1.beats.count }) beats")
        // Selection weights throughline beats, so regenerate.
        analyzeShorts()
        if !longForm.segments.isEmpty { generateLongForm() }
    }

    @Published private(set) var isFindingThroughlinesLocally = false
    @Published private(set) var localThroughlineStatus = ""

    /// The brief's original intent, finally on-device: per-chunk bit
    /// extraction through the local model, then one merge pass over the bits.
    /// No key, no network, no paste — just a few minutes of background time.
    func findThroughlinesLocally() {
        guard !isFindingThroughlinesLocally, !transcript.isEmpty,
              let media = project.media else { return }
        isFindingThroughlinesLocally = true
        coherenceError = nil
        localThroughlineStatus = "starting local model…"
        let vocabulary = project.vocabularyPrompt
        let duration = media.durationSeconds

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isFindingThroughlinesLocally = false
                self.localThroughlineStatus = ""
            }
            guard await OllamaClient.ensureServer(),
                  let installed = await OllamaClient.installedModels(),
                  let model = OllamaClient.chooseModel(
                      installed: installed, ramBytes: ProcessInfo.processInfo.physicalMemory)
            else {
                self.coherenceError = "No local model — install Ollama and pull one (Setup & Tools has the commands), or use the copy/paste panel below."
                return
            }
            let client = OllamaClient()
            let chunks = ClipSignals.planChunks(windows: [0...duration],
                                                chunkSeconds: 600, overlap: 60)
            var bits: [CoherenceService.Bit] = []
            for (offset, chunk) in chunks.enumerated() {
                if Task.isCancelled { return }
                self.localThroughlineStatus = "\(model) · window \(offset + 1) of \(chunks.count)"
                do {
                    let reply = try await client.analyze(
                        model: model,
                        system: CoherenceService.stageOneSystem(),
                        user: CoherenceService.stageOneUser(chunk: chunk,
                                                            transcript: self.transcript,
                                                            vocabulary: vocabulary),
                        schema: CoherenceService.stageOneSchema)
                    bits += (try? CoherenceService.parseBits(reply, chunk: chunk)) ?? []
                } catch {
                    self.append("Throughlines: window \(offset + 1) skipped (\(error.localizedDescription))")
                }
            }
            guard !bits.isEmpty else {
                self.coherenceError = "The local model found no recurring bits — worth trying the copy/paste panel, which reads the whole transcript at once."
                return
            }
            self.localThroughlineStatus = "\(model) · merging \(bits.count) bits"
            do {
                let reply = try await client.analyze(
                    model: model,
                    system: CoherenceService.stageTwoSystem(),
                    user: CoherenceService.stageTwoUser(bits: bits),
                    schema: CoherenceService.stageTwoSchema)
                let found = try CoherenceService.parseReply(reply)
                self.adoptThroughlines(found)
            } catch {
                self.coherenceError = "Merge pass failed: \(error.localizedDescription)"
            }
        }
    }

    func clearThroughlines() {
        throughlines = []
        try? FileManager.default.removeItem(at: project.paths.throughlines)
    }

    // MARK: - Style mimicry

    /// Measures an edit you like and maps its rhythm onto this project.
    func analyzeStyle(reference: URL) {
        guard !isAnalyzingStyle else { return }
        isAnalyzingStyle = true
        styleProgress = 0
        appliedStyleChanges = []

        Task { [weak self] in
            guard let self else { return }
            do {
                try self.project.paths.createDirectories()
                let profile = try await StyleAnalyzer.analyze(
                    reference: reference,
                    workingDirectory: self.project.paths.renderDir,
                    onStage: { stage in Task { @MainActor in self.styleStage = stage } },
                    onProgress: { value in Task { @MainActor in self.styleProgress = value } }
                )
                self.styleProfile = profile
                try? JSONEncoder().encode(profile)
                    .write(to: self.project.paths.styleProfile, options: .atomic)
                self.isAnalyzingStyle = false
                self.styleStage = ""
                self.append(String(format: "Style: %d cuts, median shot %.1fs, %.0f%% silence, music bed %@",
                                   profile.cutCount, profile.medianShotSeconds,
                                   profile.silenceRatio * 100,
                                   profile.hasMusicBed ? "yes" : "no"))
            } catch {
                self.isAnalyzingStyle = false
                self.styleStage = ""
                self.append("Style analysis failed: \(error.localizedDescription)")
            }
        }
    }

    func applyStyleProfile() {
        guard let profile = styleProfile else { return }
        var updated = project
        let changes = StyleAnalyzer.apply(profile, to: &updated)
        project = updated
        appliedStyleChanges = changes
        persist()
        analyzeShorts()
        if !longForm.segments.isEmpty { generateLongForm() }
        for change in changes { append("Style applied: \(change)") }
    }

    func clearStyleProfile() {
        styleProfile = nil
        appliedStyleChanges = []
        try? FileManager.default.removeItem(at: project.paths.styleProfile)
    }

    // MARK: - Audio tuning

    var canTuneAudio: Bool { !transcript.isEmpty && project.media != nil }

    /// Speech runs inside a clip, in clip time.
    func speechIntervals(for candidate: ShortCandidate) -> [ClosedRange<Double>] {
        AudioTuner.speechIntervals(transcript: transcript, in: candidate.start...candidate.end)
    }

    /// Speech runs across the assembled cut, in composition time.
    func speechIntervalsForAssembly() -> [ClosedRange<Double>] {
        var words: [TranscriptWord] = []
        for piece in assembled.pieces {
            for segment in transcript.segments where segment.end > piece.source.start
                && segment.start < piece.source.end {
                for word in segment.words where word.end > piece.source.start
                    && word.start < piece.source.end {
                    words.append(TranscriptWord(
                        text: word.text,
                        start: max(piece.source.start, word.start) - piece.source.start + piece.compositionStart,
                        end: min(piece.source.end, word.end) - piece.source.start + piece.compositionStart,
                        probability: word.probability
                    ))
                }
            }
        }
        return AudioTuner.speechIntervals(words: words, clampedTo: assembled.duration)
    }

    /// Measures how far the voice sits above the game, using the transcript to
    /// say which stretches are which.
    func measureAudio() {
        guard !isMeasuringAudio, let media = project.media, !transcript.isEmpty else { return }
        isMeasuringAudio = true
        audioProgress = 0
        audioError = nil
        audioPreview = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                let paths = self.project.paths
                try paths.createDirectories()
                let audio = try await self.ensureExtractedAudio(duration: media.durationSeconds)

                self.audioStage = "Measuring levels"
                let intervals = AudioTuner.speechIntervals(transcript: self.transcript,
                                                           in: 0...media.durationSeconds)
                let profile = try await AudioTuner.measure(
                    audio: audio,
                    speech: intervals,
                    duration: media.durationSeconds,
                    workingDirectory: paths.renderDir,
                    onProgress: { value in Task { @MainActor in self.audioProgress = value } }
                )
                self.audioProfile = profile
                try? JSONEncoder().encode(profile).write(to: paths.audioProfile, options: .atomic)
                self.isMeasuringAudio = false
                self.audioStage = ""
                self.append(String(format: "Audio: voice %.1f dB, game %.1f dB in band (%.1f dB clear), %.1f dB under the voice out of band (clarity %.1f dB)",
                                   profile.voiceBandSpeechDB, profile.voiceBandBackgroundDB,
                                   profile.voiceToBackgroundDB, profile.outOfBandSpeechDB,
                                   profile.clarityDB))
            } catch {
                self.isMeasuringAudio = false
                self.audioStage = ""
                self.audioError = error.localizedDescription
                self.append("Audio measurement failed: \(error.localizedDescription)")
            }
        }
    }

    /// Renders a 90-second sample through the tuning chain and measures it, so
    /// the settings can be checked instead of taken on faith.
    func previewTuning() {
        guard !isMeasuringAudio, let media = project.media, !transcript.isEmpty else { return }
        isMeasuringAudio = true
        audioProgress = 0
        audioError = nil
        let tuning = project.audioTuning

        Task { [weak self] in
            guard let self else { return }
            do {
                let paths = self.project.paths
                try paths.createDirectories()
                let audio = try await self.ensureExtractedAudio(duration: media.durationSeconds)

                self.audioStage = "Rendering sample"
                let whole = AudioTuner.speechIntervals(transcript: self.transcript,
                                                       in: 0...media.durationSeconds)
                let window = AudioTuner.representativeWindow(speech: whole,
                                                             duration: media.durationSeconds)
                let result = try await AudioTuner.preview(
                    audio: audio, window: window, speech: whole, tuning: tuning,
                    workingDirectory: paths.renderDir,
                    onProgress: { value in Task { @MainActor in self.audioProgress = value } }
                )
                self.audioPreview = result
                self.isMeasuringAudio = false
                self.audioStage = ""
                self.append(String(format: "Tuning preview at %@: clarity %.1f → %.1f dB (%+.1f), in-band ratio %.1f → %.1f dB (%+.1f, should not move)",
                                   window.lowerBound.timecode,
                                   result.before.clarityDB, result.after.clarityDB,
                                   result.improvementDB,
                                   result.before.voiceToBackgroundDB,
                                   result.after.voiceToBackgroundDB,
                                   result.inBandChangeDB))
            } catch {
                self.isMeasuringAudio = false
                self.audioStage = ""
                self.audioError = error.localizedDescription
                self.append("Tuning preview failed: \(error.localizedDescription)")
            }
        }
    }

    /// Pulls every segment of a playlist in parallel and returns a local
    /// playlist ffmpeg can read.
    ///
    /// Twitch caps one connection to about 340 KB/s; six of them reach roughly
    /// 16 MB/s, which is the difference between this taking half a minute and
    /// most of an hour.
    private func fetchSegments(playlist: URL,
                               into directory: URL,
                               label: String,
                               onProgress: @escaping @MainActor (SegmentProgress) -> Void) async throws -> URL {
        let text = try String(contentsOf: playlist, encoding: .utf8)
        let segments = SegmentDownloader.segments(inPlaylist: text)
        append("Fetching \(segments.count) \(label) segments over \(SegmentDownloader.defaultConcurrency) connections")

        let started = Date()
        let local = try await SegmentDownloader.fetch(
            segments: segments,
            into: directory,
            onProgress: { progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    onProgress(progress)
                    let done = ByteCountFormatter.string(fromByteCount: progress.bytes, countStyle: .file)
                    self.statusDetail = "\(progress.completed)/\(progress.total) segments · \(done)"
                        + (progress.speedLabel.map { " at \($0)" } ?? "")
                        + (progress.etaLabel.map { " · \($0) left" } ?? "")
                }
            }
        )

        let elapsed = Date().timeIntervalSince(started)
        let bytes = directorySize(of: directory)
        append(String(format: "Fetched %@ of %@ in %@ (%@/s)",
                      ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                      label, elapsed.timecode,
                      ByteCountFormatter.string(fromByteCount: Int64(Double(bytes) / max(elapsed, 1)),
                                                countStyle: .file)))
        return local
    }

    private func directorySize(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// The extracted 16 kHz mono audio, rebuilt if it was purged.
    private func ensureExtractedAudio(duration: Double) async throws -> URL {
        let url = project.paths.fullAudio
        if FileManager.default.fileExists(atPath: url.path) { return url }

        // On a streamed project the source is the *video* playlist. Decoding
        // audio out of it would pull all nine gigabytes to recover something the
        // audio-only rendition carries in 388 MB — so this goes back to the
        // rendition, the same way ingest does.
        var source = project.sourceURL
        if let remote = project.remote, let playlist = remote.audioPlaylistURL {
            audioStage = "Fetching audio"
            source = try await fetchSegments(playlist: playlist,
                                             into: project.paths.remoteSegments,
                                             label: "audio") { [weak self] progress in
                self?.audioProgress = progress.fraction * 0.4
            }
        }

        audioStage = "Extracting audio"
        let ffmpeg = try FFmpegService()
        try await ffmpeg.extractAudio(from: source, to: url,
                                      totalDuration: duration) { [weak self] value in
            Task { @MainActor in self?.audioProgress = 0.4 + value * 0.1 }
        }
        if project.isStreamed { try? FileManager.default.removeItem(at: project.paths.remoteSegments) }
        return url
    }

    func applyRecommendedTuning() {
        guard let profile = audioProfile else { return }
        updateAudioTuning(AudioTuning.recommended(for: profile))
        append(String(format: "Audio tuning: duck %.0f dB, presence %+.0f dB",
                      project.audioTuning.duckDB, project.audioTuning.presenceDB))
    }

    func updateAudioTuning(_ tuning: AudioTuning) {
        project.audioTuning = tuning
        audioPreview = nil
        persist()
    }

    func clearAudioProfile() {
        audioProfile = nil
        audioPreview = nil
        try? FileManager.default.removeItem(at: project.paths.audioProfile)
    }

    // MARK: - Clip editor timeline

    @Published private(set) var clipEdit = ClipEdit()
    @Published private(set) var editComposition: AVComposition?
    @Published private(set) var editVideoComposition: AVVideoComposition?
    @Published private(set) var editAudioMix: AVAudioMix?
    @Published private(set) var editOverlay: NSImage?
    private var editPreviewTask: Task<Void, Never>?

    @Published private(set) var isPreparingTimelineClip = false
    @Published private(set) var prepareProgress: Double = 0

    /// Sends a shorts candidate to the timeline — rendered first through the
    /// real shorts export, so what lands on the timeline is a finished
    /// 1080×1920 portrait piece with the clip's own framing (single crop or
    /// cam+gameplay split), captions and audio tuning, not the raw landscape
    /// source. Handles are remembered across projects.
    func addToTimeline(_ candidate: ShortCandidate) {
        guard !isPreparingTimelineClip else { return }
        var edit = clipEdit
        if edit.twitchHandle.isEmpty {
            edit.twitchHandle = UserDefaults.standard.string(forKey: "socialTwitch") ?? ""
        }
        if edit.instagramHandle.isEmpty {
            edit.instagramHandle = UserDefaults.standard.string(forKey: "socialInstagram") ?? ""
        }
        if edit.title.isEmpty { edit.title = candidate.title }
        applyClipEdit(edit)

        isPreparingTimelineClip = true
        prepareProgress = 0
        Task { [weak self] in
            guard let self else { return }
            do {
                let withCaptions = self.project.exportSettings.captionMode.burnsIn
                let url = try await self.renderTimelineClip(for: candidate, withCaptions: withCaptions)
                let duration = (try? await FFmpegService().durationOf(url)) ?? candidate.duration
                var current = self.clipEdit
                current.clips.append(TimelineClip(
                    sourcePath: url.path, start: 0, end: duration,
                    sourceDuration: duration,
                    name: candidate.title.isEmpty ? "Clip" : candidate.title,
                    candidateID: candidate.id, hasCaptions: withCaptions
                ))
                self.applyClipEdit(current, action: "Add Clip")
                self.append("Timeline: added \(candidate.start.timecode) as a portrait piece")
            } catch {
                self.statusDetail = error.localizedDescription
                self.append("Couldn't prepare the clip: \(error.localizedDescription)")
            }
            self.isPreparingTimelineClip = false
        }
    }

    /// Re-renders a candidate-born piece with or without burned captions and
    /// swaps it into the timeline. Captions in a rendered piece are pixels, so
    /// this is the only honest way to "remove" them.
    func setTimelineClipCaptions(_ clip: TimelineClip, on: Bool) {
        guard clip.hasCaptions != on, !isPreparingTimelineClip else { return }
        guard let id = clip.candidateID,
              let candidate = shorts.first(where: { $0.id == id }) else {
            append("The candidate this clip came from is gone — it can't be re-rendered")
            return
        }
        isPreparingTimelineClip = true
        prepareProgress = 0
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.renderTimelineClip(for: candidate, withCaptions: on)
                let duration = (try? await FFmpegService().durationOf(url)) ?? clip.duration
                var edit = self.clipEdit
                if let index = edit.clips.firstIndex(where: { $0.id == clip.id }) {
                    var updated = edit.clips[index]
                    updated.sourcePath = url.path
                    updated.hasCaptions = on
                    updated.sourceDuration = duration
                    updated.start = min(updated.start, max(0, duration - 0.5))
                    updated.end = min(max(updated.end, updated.start + 0.5), duration)
                    edit.clips[index] = updated
                    self.applyClipEdit(edit, action: "Re-render Captions")
                }
                self.append("Re-rendered \(on ? "with" : "without") captions")
            } catch {
                self.statusDetail = error.localizedDescription
                self.append("Couldn't re-render: \(error.localizedDescription)")
            }
            self.isPreparingTimelineClip = false
        }
    }

    // MARK: Prompts for claude.ai

    /// Ready-made prompts for the Copy-for-Claude buttons — the manual route:
    /// paste into a claude.ai chat, covered by the subscription, no API key
    /// spent. Nil when the timeline has no transcript under it.
    func editorTitlePrompt() -> String? {
        let content = timelineTranscript()
        guard !content.isEmpty else { return nil }
        return ManualPrompts.titles(transcript: String(content.prefix(6000)),
                                    vocabulary: effectiveVocabulary())
    }

    func editorPostPrompt() -> String? {
        let content = timelineTranscript()
        guard !content.isEmpty else { return nil }
        return ManualPrompts.post(transcript: String(content.prefix(6000)),
                                  title: clipEdit.title,
                                  vocabulary: effectiveVocabulary())
    }

    /// The transcript under what's actually on the timeline — candidate-born
    /// clips resolve through their candidate's window, clips cut straight from
    /// this VOD through their trim range.
    private func timelineTranscript() -> String {
        var excerpts: [String] = []
        for clip in clipEdit.clips {
            if let id = clip.candidateID, let candidate = shorts.first(where: { $0.id == id }) {
                excerpts.append(transcriptText(in: candidate.start...candidate.end))
            } else if clip.sourcePath == project.sourcePath {
                excerpts.append(transcriptText(in: clip.start...clip.end))
            }
        }
        return excerpts.filter { !$0.isEmpty }.joined(separator: "\n---\n")
    }

    private func transcriptText(in range: ClosedRange<Double>) -> String {
        transcript.segments
            .filter { $0.end > range.lowerBound && $0.start < range.upperBound }
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
    }

    /// The portrait piece for a candidate, rendered once and reused — keyed on
    /// the trim points, so re-trimming the candidate renders a fresh piece.
    private func renderTimelineClip(for candidate: ShortCandidate,
                                    withCaptions: Bool) async throws -> URL {
        try project.paths.createDirectories()
        let name = String(format: "tl-%@-%d-%d-%@.mp4", candidate.id.uuidString,
                          Int(candidate.start * 10), Int(candidate.end * 10),
                          withCaptions ? "cap" : "clean")
        let destination = project.paths.timelineClipsDir.appendingPathComponent(name)
        if let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 {
            return destination
        }
        guard let media = project.media else { throw ExportError.noMediaInfo }
        let service = try ExportService()
        let style = candidate.styleOverride ?? project.captionStyle
        // Empty lines is exactly how captionMode == .none exports — nothing to
        // burn, nothing to embed.
        let lines = withCaptions ? captionLines(for: candidate) : []
        _ = try await service.exportShort(
            candidate: candidate, source: project.sourceURL, media: media,
            lines: lines, style: style, settings: project.exportSettings,
            tuning: project.audioTuning,
            speech: project.audioTuning.needsSpeechKey ? speechIntervals(for: candidate) : [],
            destination: destination,
            workingDirectory: project.paths.renderDir,
            onProgress: { [weak self] value in
                Task { @MainActor in self?.prepareProgress = value }
            },
            onLog: { _ in }
        )
        return destination
    }

    /// Adds any video file the user picks, full length, trimmable after.
    /// A drop time inserts at the nearest cut instead of appending.
    func addTimelineClip(from url: URL, at timelineTime: Double? = nil) {
        Task { [weak self] in
            guard let self else { return }
            let duration = (try? await FFmpegService().durationOf(url)) ?? 0
            guard duration > 0.2 else {
                self.append("Couldn't read a duration from \(url.lastPathComponent)")
                return
            }
            var edit = self.clipEdit
            let clip = TimelineClip(sourcePath: url.path, start: 0, end: duration,
                                    sourceDuration: duration)
            if let timelineTime, let (index, offset) = self.clipAt(timelineTime: timelineTime) {
                // Land before or after the clip under the drop, whichever cut
                // is closer.
                let insertAt = offset > edit.clips[index].effectiveDuration / 2 ? index + 1 : index
                edit.clips.insert(clip, at: min(insertAt, edit.clips.count))
            } else {
                edit.clips.append(clip)
            }
            self.applyClipEdit(edit, action: "Add Clip")
            self.append("Timeline: added \(url.lastPathComponent)")
        }
    }

    func updateTimelineClip(_ clip: TimelineClip) {
        var edit = clipEdit
        guard let index = edit.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        edit.clips[index] = clip
        applyClipEdit(edit, action: "Edit Clip")
    }

    func removeTimelineClip(_ clip: TimelineClip) {
        var edit = clipEdit
        edit.clips.removeAll { $0.id == clip.id }
        applyClipEdit(edit, action: "Delete Clip")
    }

    func moveTimelineClip(_ clip: TimelineClip, forward: Bool) {
        var edit = clipEdit
        guard let index = edit.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        let target = forward ? index + 1 : index - 1
        guard edit.clips.indices.contains(target) else { return }
        edit.clips.swapAt(index, target)
        applyClipEdit(edit, action: "Reorder Clips")
    }

    func setTimelineMusic(_ url: URL?) {
        var edit = clipEdit
        edit.musicPath = url?.path
        applyClipEdit(edit, action: "Music")
    }

    // MARK: - Auto clips

    @Published private(set) var autoClipRun: AutoClipRun?
    @Published private(set) var isFindingClips = false
    /// "llama3.1:8b · chunk 4 of 9" or "heuristics only — Ollama not found".
    @Published private(set) var autoClipStatus = ""

    /// The whole background pipeline: pre-filter, heuristics, chunked local
    /// inference, dedupe, balance. Results land incrementally so a crash at
    /// chunk 30 of 36 keeps 30, and the UI stays fully usable while it runs.
    func startAutoClips(request: AutoClipRequest) {
        guard !isFindingClips, !transcript.isEmpty, let media = project.media else { return }
        isFindingClips = true
        autoClipStatus = "preparing…"
        project.autoClipPromptShown = true
        persist()

        let categories = project.clipCategories.filter {
            $0.enabled && request.categoryIDs.contains($0.id)
        }
        let duration = media.durationSeconds

        Task { [weak self] in
            guard let self else { return }

            // Resume an unfinished run with the same shape instead of
            // starting over; anything else begins fresh.
            var run: AutoClipRun
            if let existing = self.autoClipRun, !existing.isFinished,
               existing.request == request, existing.categories == categories {
                run = existing
                self.append("Clip finder: resuming at chunk \(existing.completedChunks.count + 1) of \(existing.chunks.count)")
            } else {
                run = AutoClipRun(request: request, categories: categories)
            }

            // Step 1 + 1.5 — free signals, computed up front.
            let spikes = ClipSignals.emoteSpikes(chat: self.chat, categories: categories)
            let reads = ClipSignals.chatReadingMoments(transcript: self.transcript, chat: self.chat)
            let monologues = ClipSignals.monologues(transcript: self.transcript, chat: self.chat)
            if run.chunks.isEmpty {
                let windows = ClipSignals.interestWindows(
                    curve: self.scoreCurve, duration: duration, monologues: monologues)
                run.chunks = ClipSignals.planChunks(windows: windows)
            }

            // Step 2 — the local model, if this machine has one ready.
            var model: String?
            if await OllamaClient.ensureServer(),
               let installed = await OllamaClient.installedModels(), !installed.isEmpty {
                model = OllamaClient.chooseModel(installed: installed,
                                                 ramBytes: ProcessInfo.processInfo.physicalMemory)
            }
            run.backend = model ?? "heuristics"
            if model == nil {
                self.append("Clip finder: Ollama isn't available — running on chat/audio heuristics only. Setup & Tools has the install steps.")
            }
            let client = OllamaClient()
            let system = AutoClipService.systemPrompt(categories: categories)

            for chunk in run.chunks where !run.completedChunks.contains(chunk.index) {
                if Task.isCancelled { break }
                self.autoClipStatus = "\(run.backend) · chunk \(run.completedChunks.count + 1) of \(run.chunks.count)"
                let hints = AutoClipService.hints(for: chunk, spikes: spikes, chatReads: reads,
                                                  monologues: monologues, categories: categories)
                var found: [AutoClipCandidate] = []
                if let model {
                    let user = AutoClipService.userPrompt(
                        chunk: chunk, transcript: self.transcript, chat: self.chat,
                        categories: categories, streamer: self.project.clientName,
                        vocabulary: self.effectiveVocabulary(), hints: hints)
                    // One retry, then skip the chunk and keep going — a bad
                    // chunk costs one window, not the run.
                    for attempt in 1...2 {
                        do {
                            let reply = try await client.analyze(model: model, system: system,
                                                                 user: user,
                                                                 schema: AutoClipService.schema)
                            found = try AutoClipService.parseReply(reply, chunk: chunk,
                                                                   categories: categories)
                            break
                        } catch {
                            if attempt == 2 {
                                run.failedChunks.insert(chunk.index)
                                self.append("Clip finder: chunk \(chunk.index) skipped (\(error.localizedDescription))")
                            }
                        }
                    }
                }
                if model == nil {
                    found = AutoClipService.heuristicCandidates(
                        chunk: chunk, transcript: self.transcript, spikes: spikes,
                        chatReads: reads, monologues: monologues,
                        categories: categories, request: request)
                }
                let snapped = found.map {
                    AutoClipService.snapBoundaries($0, transcript: self.transcript,
                                                   request: request, duration: duration)
                }
                run.completedChunks.insert(chunk.index)
                run.candidates = AutoClipService.dedupe(run.candidates + snapped)
                self.persistAutoClips(run)
            }

            if !Task.isCancelled {
                run.candidates = AutoClipService.select(run.candidates, request: request)
                run.finishedAt = Date()
                self.persistAutoClips(run)
                let suggested = run.candidates.filter { $0.state == .suggested }.count
                let surplus = run.candidates.filter { $0.state == .surplus }.count
                self.append("Clip finder: \(suggested) clips suggested, \(surplus) more in reserve (\(run.backend))")
            }
            self.autoClipStatus = ""
            self.isFindingClips = false
        }
    }

    private func persistAutoClips(_ run: AutoClipRun) {
        autoClipRun = run
        try? JSONEncoder().encode(run).write(to: project.paths.autoClips, options: .atomic)
    }

    /// One-click fix for a wrong label — no re-run.
    func recategorizeAutoClip(_ candidate: AutoClipCandidate, to categoryID: UUID) {
        guard var run = autoClipRun,
              let index = run.candidates.firstIndex(where: { $0.id == candidate.id }) else { return }
        run.candidates[index].categoryID = categoryID
        persistAutoClips(run)
    }

    /// Reject pulls the next surplus candidate of the same category forward,
    /// so a rejection has a replacement ready without re-running anything.
    func rejectAutoClip(_ candidate: AutoClipCandidate) {
        guard var run = autoClipRun,
              let index = run.candidates.firstIndex(where: { $0.id == candidate.id }) else { return }
        run.candidates[index].state = .rejected
        if let promoted = run.candidates.indices.first(where: {
            run.candidates[$0].state == .surplus
                && run.candidates[$0].categoryID == candidate.categoryID
        }) ?? run.candidates.indices.first(where: { run.candidates[$0].state == .surplus }) {
            run.candidates[promoted].state = .suggested
        }
        persistAutoClips(run)
    }

    /// Hands the moment to the existing shorts machinery — trim, captions,
    /// framing, export all work on it from here.
    func addAutoClipToShorts(_ candidate: AutoClipCandidate) {
        guard var run = autoClipRun,
              let index = run.candidates.firstIndex(where: { $0.id == candidate.id }) else { return }
        run.candidates[index].state = .added
        persistAutoClips(run)
        let short = ShortCandidate(
            start: candidate.start, end: candidate.end,
            peakTime: (candidate.start + candidate.end) / 2,
            score: candidate.confidence,
            title: candidate.title,
            status: .candidate,
            layout: project.defaultShortLayout)
        shorts.insert(short, at: 0)
        try? JSONEncoder().encode(shorts).write(to: project.paths.shorts, options: .atomic)
        append("Clip finder: \(candidate.title.isEmpty ? "clip" : candidate.title) added to Shorts")
    }

    func updateClipCategories(_ categories: [ClipCategory]) {
        project.clipCategories = categories
        persist()
    }

    func markAutoClipPromptShown() {
        guard !project.autoClipPromptShown else { return }
        project.autoClipPromptShown = true
        persist()
    }

    // MARK: - Thumbnail Studio

    @Published private(set) var thumbDoc = ThumbDocument()
    @Published private(set) var isCuttingOut = false
    @Published private(set) var thumbStudioError: String?

    /// Same command pattern as the timeline: one choke point, whole-document
    /// snapshot undo, named steps, the same coalescing for slider streams.
    /// Clears the undo-coalescing window so the next mutation starts its own
    /// step. Named separately from the protocol method because the protocol
    /// requirement cannot see this type's private state from an extension.
    func endThumbUndoRun() {
        lastUndoAction = nil
        lastUndoRegistration = .distantPast
    }

    func applyThumbDoc(_ document: ThumbDocument, action: String? = nil) {
        thumbStudioError = nil
        let previous = thumbDoc
        if let action, previous != document {
            if !UndoCoalescing.shouldCoalesce(action: action, lastAction: lastUndoAction,
                                              lastAt: lastUndoRegistration, now: Date()) {
                registerThumbUndo(returningTo: previous, action: action)
            }
            lastUndoAction = action
            lastUndoRegistration = Date()
        }
        thumbDoc = document
        try? JSONEncoder().encode(document).write(to: project.paths.thumbStudio, options: .atomic)
        lastSavedAt = Date()
    }

    private func registerThumbUndo(returningTo previous: ThumbDocument, action: String) {
        guard let undo = timelineUndoManager else { return }
        undo.registerUndo(withTarget: self) { session in
            let current = session.thumbDoc
            session.registerThumbUndo(returningTo: current, action: action)
            session.lastUndoAction = nil
            session.thumbDoc = previous
            try? JSONEncoder().encode(previous).write(to: session.project.paths.thumbStudio,
                                                      options: .atomic)
        }
        undo.setActionName(action)
    }

    /// Grabs the exact frame under the editor playhead — through the same
    /// composition and video composition the preview plays, so the grab is
    /// what you were looking at — and drops it on the canvas as a layer.
    func grabTimelineFrame(at time: Double) {
        thumbStudioError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let destination = self.project.paths.thumbnailsDir
                    .appendingPathComponent("grab-\(Int(Date().timeIntervalSince1970)).png")
                try self.project.paths.createDirectories()
                if let composition = self.editComposition {
                    let generator = AVAssetImageGenerator(asset: composition)
                    generator.videoComposition = self.editVideoComposition
                    generator.requestedTimeToleranceBefore = .zero
                    generator.requestedTimeToleranceAfter = .zero
                    let (cg, _) = try await generator.image(
                        at: CMTime(seconds: time, preferredTimescale: 600))
                    let rep = NSBitmapImageRep(cgImage: cg)
                    guard let png = rep.representation(using: .png, properties: [:]) else {
                        throw CutoutService.CutoutError.unreadable
                    }
                    try png.write(to: destination, options: .atomic)
                } else if self.project.sourceExists {
                    try await self.grabSourceFrame(at: time, to: destination)
                } else {
                    self.thumbStudioError = "Nothing to grab — the timeline is empty and the source isn't reachable."
                    return
                }
                var document = self.thumbDoc
                document.layers.append(ThumbLayer(
                    name: "Frame \(time.shortTimecode)",
                    kind: .image(ImageSpec(path: destination.path)),
                    widthFraction: 0.62))
                self.applyThumbDoc(document, action: "Grab Frame")
                self.append("Thumbnail: grabbed the frame at \(time.shortTimecode)")
            } catch {
                self.thumbStudioError = "Frame grab failed: \(error.localizedDescription)"
            }
        }
    }

    /// A frame from the source VOD at an arbitrary time — the picker's path.
    func grabSourceFrame(at time: Double, to destination: URL) async throws {
        let asset = AVURLAsset(url: project.sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        let (cg, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CutoutService.CutoutError.unreadable
        }
        try png.write(to: destination, options: .atomic)
    }

    func addSourceGrabToCanvas(path: String, time: Double) {
        var document = thumbDoc
        document.layers.append(ThumbLayer(
            name: "Frame \(time.shortTimecode)",
            kind: .image(ImageSpec(path: path)),
            widthFraction: 0.62))
        applyThumbDoc(document, action: "Grab Frame")
    }

    /// One-click background removal on an image layer, entirely on this
    /// Mac. The original stays; the cutout is a separate PNG the layer
    /// toggles.
    func removeBackground(layerID: UUID) {
        guard case .image(let spec)? = thumbDoc.layers.first(where: { $0.id == layerID })?.kind,
              !spec.path.isEmpty else { return }
        isCuttingOut = true
        thumbStudioError = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = CutoutRun.perform(spec: spec)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isCuttingOut = false
                switch result {
                case .success(let cutout):
                    // Re-read now, not before: Vision took a moment and the
                    // user may have moved, typed or deleted something in it.
                    var document = self.thumbDoc
                    guard let index = document.layers.firstIndex(where: { $0.id == layerID }),
                          case .image(var current) = document.layers[index].kind
                    else { return }
                    CutoutRun.applyResult(cutout, to: &current)
                    document.layers[index].kind = .image(current)
                    AdjustedImageCache.shared.invalidate()
                    self.applyThumbDoc(document, action: "Remove Background")
                    self.append("Thumbnail: background removed")
                case .failure(let error):
                    self.thumbStudioError = error.localizedDescription
                }
            }
        }
    }

    // MARK: Long-form in the editor

    /// Loads the long-form cut onto the editor timeline, in landscape — every
    /// included segment becomes a trimmable clip reading the project source.
    func sendLongFormToEditor() {
        let segments = longForm.segments.filter(\.isIncluded)
        guard !segments.isEmpty else { return }
        var edit = clipEdit
        edit.aspect = .landscape
        edit.clips = segments.map { segment in
            TimelineClip(sourcePath: project.sourcePath,
                         start: segment.start, end: segment.end,
                         sourceDuration: project.media?.durationSeconds ?? segment.end,
                         name: segment.title.isEmpty ? segment.start.timecode : segment.title)
        }
        applyClipEdit(edit, action: "Load Long-form Cut")
        append("Editor: loaded the long-form cut — \(edit.clips.count) segments, 16:9")
    }

    // MARK: Freeze frames and overlays

    /// Which clip sits under a timeline time, with the offset into it.
    func clipAt(timelineTime: Double) -> (index: Int, offset: Double)? {
        var cursor: Double = 0
        for (index, clip) in clipEdit.clips.enumerated() {
            let width = clip.effectiveDuration
            if timelineTime < cursor + width || index == clipEdit.clips.count - 1 {
                return (index, min(max(0, timelineTime - cursor), width))
            }
            cursor += width
        }
        return nil
    }

    /// Inserts a held still of whatever the playhead is on, right after the
    /// clip it came from.
    func addFreezeFrame(at timelineTime: Double) {
        guard let (index, offset) = clipAt(timelineTime: timelineTime) else { return }
        var edit = clipEdit
        let clip = edit.clips[index]
        let sourceTime = clip.isFreeze
            ? clip.start
            : min(clip.start + offset * clip.clampedSpeed, max(clip.start, clip.end - 0.05))
        let freeze = TimelineClip(
            sourcePath: clip.sourcePath,
            start: sourceTime, end: sourceTime + 3,
            sourceDuration: clip.sourceDuration,
            name: "Freeze", isFreeze: true)
        edit.clips.insert(freeze, at: index + 1)
        applyClipEdit(edit, action: "Freeze Frame")
        append("Freeze frame at \(timelineTime.shortTimecode), held 3s")
    }

    /// The blade: splits whatever the playhead is on into two independent
    /// clips. Cutting is non-destructive — both halves keep the full source
    /// range available to their trim handles.
    func splitClip(at timelineTime: Double) {
        guard let (index, offset) = clipAt(timelineTime: timelineTime) else { return }
        var edit = clipEdit
        guard let (first, second) = edit.clips[index].split(atOffset: offset) else {
            append("Blade: too close to a cut point")
            return
        }
        edit.clips[index] = first
        edit.clips.insert(second, at: index + 1)
        applyClipEdit(edit, action: "Split Clip")
        append("Split at \(timelineTime.shortTimecode)")
    }

    /// Roll the cut between a clip and its right neighbour.
    func rollCut(after index: Int, by delta: Double) {
        var edit = clipEdit
        guard edit.rollCut(after: index, by: delta) else { return }
        applyClipEdit(edit, action: "Roll Cut")
    }

    /// Ripple-deletes a timeline range: blades both ends, drops everything
    /// between, downstream closes the gap by construction.
    func deleteRange(from rangeStart: Double, to rangeEnd: Double) {
        guard rangeEnd > rangeStart + 0.2, !clipEdit.clips.isEmpty else { return }
        var edit = clipEdit
        guard edit.rippleDelete(from: rangeStart, to: rangeEnd) else { return }
        applyClipEdit(edit, action: "Ripple Delete Range")
        append(String(format: "Ripple-deleted %.1fs", rangeEnd - rangeStart))
    }

    // MARK: Hook doctor — the first three seconds, read like a viewer

    /// Words in the cut's opening mapped to timeline time with a loudness
    /// reading each, fed to the pure report.
    func hookReport() -> HookDoctorService.Report {
        var words: [(t: Double, text: String, peak: Double)] = []
        var cursor: Double = 0
        for clip in clipEdit.clips {
            defer { cursor += clip.effectiveDuration }
            guard cursor < 12, !clip.isFreeze,
                  clip.sourcePath == project.sourcePath else { continue }
            for segment in transcript.segments
            where segment.end > clip.start && segment.start < clip.end {
                for word in segment.words
                where word.start >= clip.start && word.start <= clip.end {
                    let timelineT = cursor + (word.start - clip.start) / clip.clampedSpeed
                    guard timelineT < 12 else { continue }
                    var peak = 0.0
                    if let waveform {
                        let index = Int(word.start * waveform.peaksPerSecond)
                        if waveform.peaks.indices.contains(index) {
                            peak = Double(waveform.peaks[index]) / 255
                        }
                    }
                    words.append((timelineT, word.text, peak))
                }
            }
        }
        return HookDoctorService.report(words: words,
                                        totalDuration: clipEdit.totalDuration)
    }

    // MARK: Banger pass — which clips would stop a scroll

    @Published var isRankingBangers = false
    @Published var bangerStatus = ""

    /// Heuristic instantly, then the local model over the top of the list.
    /// Results land on each candidate's `marketability` / `hookLine`.
    func rankBangers() {
        guard !isRankingBangers, !shorts.isEmpty else { return }
        isRankingBangers = true
        bangerStatus = "reading the signals…"

        // Stage 1 — pure signals, applied to every candidate right away.
        let laughter = waveform.map {
            LaughterSignals.detect(peaks: $0.peaks, perSecond: $0.peaksPerSecond)
        } ?? []
        let spikes = chat.isEmpty ? [] : ClipSignals.emoteSpikes(
            chat: chat, categories: project.clipCategories)
        for index in shorts.indices {
            let candidate = shorts[index]
            let words = transcript.segments
                .filter { $0.end > candidate.start && $0.start < candidate.end }
                .flatMap(\.words)
                .filter { $0.start >= candidate.start && $0.start <= candidate.end }
            let punch = words.filter { $0.text.contains("!") || $0.text.contains("?") }.count
            let opening = words.filter { $0.start < candidate.start + 3 }.count
            let inputs = BangerService.Inputs(
                duration: candidate.duration,
                laughSeconds: LaughterSignals.laughSeconds(
                    in: laughter, from: candidate.start, to: candidate.end),
                emoteSpikes: spikes.filter {
                    $0.time >= candidate.start && $0.time <= candidate.end
                }.count,
                peakPosition: candidate.duration > 0
                    ? min(1, max(0, (candidate.peakTime - candidate.start) / candidate.duration))
                    : 0.5,
                punchPer100: words.isEmpty ? 0 : Double(punch) * 100 / Double(words.count),
                openingWords: opening)
            shorts[index].marketability = BangerService.heuristicScore(inputs)
        }
        persistShorts()

        // Stage 2 — the model reads the top of the list, if one is around.
        let ranked = shorts.enumerated()
            .sorted { ($0.element.marketability ?? 0) > ($1.element.marketability ?? 0) }
            .prefix(16)
        let batchInputs: [(id: Int, title: String, transcript: String)] = ranked.map { pair in
            let candidate = pair.element
            let text = transcript.segments
                .filter { $0.end > candidate.start && $0.start < candidate.end }
                .map(\.text).joined(separator: " ")
            return (pair.offset,
                    candidate.title.isEmpty ? candidate.start.shortTimecode : candidate.title,
                    BangerService.snippet(text))
        }
        Task { [weak self] in
            guard let self else { return }
            guard await OllamaClient.ensureServer(),
                  let installed = await OllamaClient.installedModels(),
                  let model = OllamaClient.chooseModel(
                      installed: installed, ramBytes: ProcessInfo.processInfo.physicalMemory)
            else {
                await MainActor.run {
                    self.isRankingBangers = false
                    self.bangerStatus = ""
                    self.append("Bangers ranked from signals alone — pull an Ollama model for the sharper second opinion")
                }
                return
            }
            var verdicts: [(id: Int, score: Double, hook: String)] = []
            let batches = stride(from: 0, to: batchInputs.count, by: 8).map {
                Array(batchInputs[$0..<min($0 + 8, batchInputs.count)])
            }
            for (number, batch) in batches.enumerated() {
                await MainActor.run {
                    self.bangerStatus = "judging \(number * 8 + 1)–\(number * 8 + batch.count) of \(batchInputs.count)…"
                }
                if let raw = try? await OllamaClient().analyze(
                    model: model,
                    system: BangerService.judgeSystem,
                    user: BangerService.judgeUser(batch: batch),
                    schema: BangerService.judgeSchema) {
                    verdicts += BangerService.parseVerdicts(raw, knownIDs: Set(batch.map(\.id)))
                }
            }
            await MainActor.run {
                for verdict in verdicts where self.shorts.indices.contains(verdict.id) {
                    let heuristic = self.shorts[verdict.id].marketability ?? 0
                    self.shorts[verdict.id].marketability =
                        BangerService.blended(heuristic: heuristic, model: verdict.score)
                    if !verdict.hook.isEmpty {
                        self.shorts[verdict.id].hookLine = verdict.hook
                    }
                }
                self.persistShorts()
                self.isRankingBangers = false
                self.bangerStatus = ""
                let flames = self.shorts.filter {
                    ($0.marketability ?? 0) >= BangerService.bangerThreshold
                }.count
                self.append(verdicts.isEmpty
                    ? "Bangers ranked from signals alone — the model's reply didn't parse"
                    : "Banger pass done: \(flames) clip(s) earn the flame")
            }
        }
    }

    // MARK: Local AI — the copy-paste flows, run on this machine

    @Published var localJobRunning: LocalAIService.Job?
    @Published var localJobError: String?
    @Published var localPackaging: LocalAIService.Packaging?

    /// Resolves a usable local model, or explains why there isn't one.
    private func localModel() async -> String? {
        guard await OllamaClient.ensureServer(),
              let installed = await OllamaClient.installedModels(),
              let model = OllamaClient.chooseModel(
                  installed: installed, ramBytes: ProcessInfo.processInfo.physicalMemory)
        else { return nil }
        return model
    }

    private static let noModelMessage =
        "No local model available — install Ollama and pull one (Setup & Tools has the commands), or use the copy/paste panel."

    /// Titles, description and hashtags for the current cut, locally.
    func runLocalPackaging(vertical: Bool) {
        guard localJobRunning == nil, !transcript.isEmpty else { return }
        localJobRunning = .packaging
        localJobError = nil
        let vocabulary = project.vocabularyPrompt
        let text = LocalAIService.condense(transcript.plainText)
        Task { [weak self] in
            guard let self else { return }
            guard let model = await self.localModel() else {
                await MainActor.run {
                    self.localJobRunning = nil
                    self.localJobError = Self.noModelMessage
                }
                return
            }
            do {
                let raw = try await OllamaClient().analyze(
                    model: model,
                    system: LocalAIService.packagingSystem(vertical: vertical),
                    user: LocalAIService.packagingUser(transcript: text, vocabulary: vocabulary),
                    schema: LocalAIService.packagingSchema)
                await MainActor.run {
                    self.localJobRunning = nil
                    guard let packaging = LocalAIService.parsePackaging(raw) else {
                        self.localJobError = "The local model's reply didn't parse — try again, or use the copy/paste panel."
                        return
                    }
                    self.localPackaging = packaging
                    self.append("Local packaging: \(packaging.titles.count) title(s), \(packaging.hashtags.count) hashtags")
                }
            } catch {
                await MainActor.run {
                    self.localJobRunning = nil
                    self.localJobError = error.localizedDescription
                }
            }
        }
    }

    /// Applies a generated title to the editor document.
    func adoptLocalTitle(_ title: String) {
        var edit = clipEdit
        edit.title = title
        applyClipEdit(edit, action: "Set Title")
    }

    /// Transcript polish over the current cursor batch, locally.
    func runLocalPolish() {
        guard localJobRunning == nil, !transcript.isEmpty else { return }
        localJobRunning = .polish
        localJobError = nil
        let batch = transcript.segments
            .dropFirst(polishCursor)
            .prefix(120)
            .map { (id: $0.id, text: $0.text) }
        guard !batch.isEmpty else {
            localJobRunning = nil
            localJobError = "Every line has been through polish already."
            return
        }
        let vocabulary = project.vocabularyPrompt
        let knownIDs = Set(batch.map(\.id))
        Task { [weak self] in
            guard let self else { return }
            guard let model = await self.localModel() else {
                await MainActor.run {
                    self.localJobRunning = nil
                    self.localJobError = Self.noModelMessage
                }
                return
            }
            do {
                let raw = try await OllamaClient().analyze(
                    model: model,
                    system: LocalAIService.polishSystem,
                    user: LocalAIService.polishUser(segments: Array(batch), vocabulary: vocabulary),
                    schema: LocalAIService.polishSchema)
                await MainActor.run {
                    self.localJobRunning = nil
                    let fixes = LocalAIService.parsePolish(raw, knownIDs: knownIDs)
                    var applied = 0
                    for fix in fixes {
                        guard let index = self.transcript.segments.firstIndex(where: { $0.id == fix.id }),
                              self.transcript.segments[index].text != fix.text else { continue }
                        self.updateTranscriptLine(id: fix.id, text: fix.text)
                        applied += 1
                    }
                    self.polishCursor = min(self.transcript.segments.count,
                                            self.polishCursor + batch.count)
                    self.append(applied == 0
                        ? "Local polish: nothing needed fixing in this batch"
                        : "Local polish: \(applied) line(s) corrected")
                }
            } catch {
                await MainActor.run {
                    self.localJobRunning = nil
                    self.localJobError = error.localizedDescription
                }
            }
        }
    }

    // MARK: Backup — the decisions, portable

    @Published var isBundling = false

    /// Writes the project's documents, transcript and analysis to a single
    /// .vodbundle. Media stays behind by design — this is the part that
    /// can't be re-derived.
    func exportBundle(to destination: URL) {
        guard !isBundling else { return }
        isBundling = true
        let root = project.paths.root
        let items = ProjectBundleService.itemsToArchive(root: root)
        Task { [weak self] in
            do {
                let fm = FileManager.default
                let staging = fm.temporaryDirectory
                    .appendingPathComponent("bundle-\(UUID().uuidString)/\(destination.deletingPathExtension().lastPathComponent)",
                                            isDirectory: true)
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: staging.deletingLastPathComponent()) }
                for item in items {
                    try? fm.copyItem(at: root.appendingPathComponent(item),
                                     to: staging.appendingPathComponent(item))
                }
                try? fm.removeItem(at: destination)
                try await Shell.runChecked(
                    URL(fileURLWithPath: "/usr/bin/ditto"),
                    arguments: ProjectBundleService.archiveArguments(
                        stagingDir: staging, destination: destination),
                    onOutputLine: { _ in }, onErrorLine: { _ in })
                let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                await MainActor.run {
                    self?.isBundling = false
                    self?.append("Backup written: \(destination.lastPathComponent) · \(DiskReclaimService.formatBytes(Int64(size)))")
                }
            } catch {
                await MainActor.run {
                    self?.isBundling = false
                    self?.append("Backup failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: Offline media — detect and relink

    @Published private(set) var missingMedia: [MediaRelinkService.Missing] = []
    @Published var isRelinking = false

    /// Cheap enough to run on open and after any relink.
    func refreshMissingMedia() {
        missingMedia = MediaRelinkService.missing(in: clipEdit)
    }

    func isOffline(_ clip: TimelineClip) -> Bool {
        missingMedia.contains { $0.slot == .clip(clip.id) }
    }

    /// Searches a folder for everything that's missing and rewires whatever
    /// it finds — one folder pick fixes every broken path at once.
    func relinkAll(searching folder: URL) {
        guard !isRelinking else { return }
        isRelinking = true
        let missing = missingMedia
        Task { [weak self] in
            let index = await Task.detached(priority: .userInitiated) {
                MediaRelinkService.index(folder: folder)
            }.value
            let resolved = MediaRelinkService.resolve(missing, against: index)
            await MainActor.run {
                guard let self else { return }
                self.isRelinking = false
                let (updated, fixed) = MediaRelinkService.apply(resolved, to: self.clipEdit)
                guard fixed > 0 else {
                    self.append("Relink: nothing matching found in \(folder.lastPathComponent)")
                    return
                }
                self.applyClipEdit(updated, action: "Relink Media")
                self.refreshMissingMedia()
                let remaining = self.missingMedia.count
                self.append(remaining == 0
                    ? "Relinked \(fixed) reference(s) — everything is online"
                    : "Relinked \(fixed); \(remaining) still missing")
            }
        }
    }

    /// Points one specific missing file at a replacement the user picked.
    func relinkOne(path: String, to replacement: URL) {
        let entries = missingMedia
            .filter { $0.path == path }
            .map { entry -> MediaRelinkService.Missing in
                var updated = entry
                updated.replacement = replacement.path
                return updated
            }
        guard !entries.isEmpty else { return }
        let (updated, fixed) = MediaRelinkService.apply(entries, to: clipEdit)
        guard fixed > 0 else { return }
        applyClipEdit(updated, action: "Relink Media")
        refreshMissingMedia()
        append("Relinked \(fixed) reference(s) to \(replacement.lastPathComponent)")
    }

    // MARK: Speaker guesses — "you vs someone else" from mic-level clustering

    @Published var speakerGuesses = SpeakerLabelService.Result()

    /// Instant — everything it needs is already in memory.
    func labelSpeakers() {
        guard let waveform else {
            append("Speaker guesses need the audio analysis from ingest")
            return
        }
        speakerGuesses = SpeakerLabelService.classify(
            segments: transcript.segments.map { ($0.id, $0.start, $0.end) },
            peaks: waveform.peaks,
            peaksPerSecond: waveform.peaksPerSecond)
        if speakerGuesses.reliable {
            let you = speakerGuesses.isYou.values.filter { $0 }.count
            append("Speaker guess: \(you) segment(s) read as your mic, \(speakerGuesses.isYou.count - you) as others — a level heuristic, not diarization")
        } else {
            append("Speaker guess: the mix doesn't split into two clear levels here — guesses hidden rather than shown wrong")
        }
    }

    /// Fraction of a time range whose transcript reads as the user's mic.
    func youFraction(from start: Double, to end: Double) -> Double? {
        guard speakerGuesses.reliable else { return nil }
        let inRange = transcript.segments.filter { $0.end > start && $0.start < end }
        guard !inRange.isEmpty else { return nil }
        var youTime = 0.0
        var total = 0.0
        for segment in inRange {
            let span = min(segment.end, end) - max(segment.start, start)
            guard span > 0 else { continue }
            total += span
            if speakerGuesses.isYou[segment.id] == true { youTime += span }
        }
        return total > 0 ? youTime / total : nil
    }

    // MARK: Beat grid — cuts that land on the downbeat

    @Published var beatGrid: [Double] = []
    @Published var beatBPM: Double?
    @Published var isDetectingBeats = false

    /// Decodes the music bed to mono floats and fits the grid. A few
    /// seconds for a typical bed; the grid extends across the whole cut
    /// because the bed loops.
    func detectBeats() {
        guard !isDetectingBeats else { return }
        guard let musicURL = clipEdit.musicURL,
              FileManager.default.fileExists(atPath: musicURL.path) else {
            append("Beat sync needs a music bed on the timeline first")
            return
        }
        isDetectingBeats = true
        let duration = clipEdit.totalDuration
        Task { [weak self] in
            guard let self else { return }
            var grid: [Double] = []
            var bpm: Double?
            do {
                let service = try ExportService()
                let raw = FileManager.default.temporaryDirectory
                    .appendingPathComponent("beats-\(UUID().uuidString).f32")
                defer { try? FileManager.default.removeItem(at: raw) }
                try await Shell.runChecked(
                    service.ffmpeg,
                    arguments: ["-hide_banner", "-nostdin", "-i", musicURL.path,
                                "-t", "90", "-ac", "1", "-ar", "8000",
                                "-f", "f32le", "-y", raw.path],
                    onOutputLine: { _ in }, onErrorLine: { _ in })
                let data = try Data(contentsOf: raw)
                let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                let (envelope, perSecond) = BeatGridService.onsetEnvelope(
                    samples: samples, sampleRate: 8000)
                if let tempo = BeatGridService.estimateTempo(envelope: envelope,
                                                             perSecond: perSecond) {
                    bpm = tempo
                    grid = BeatGridService.beatGrid(envelope: envelope, perSecond: perSecond,
                                                    bpm: tempo, duration: max(duration, 1))
                }
            } catch {
                // Fall through with an empty grid.
            }
            await MainActor.run {
                self.isDetectingBeats = false
                self.beatGrid = grid
                self.beatBPM = bpm
                if let bpm {
                    self.append(String(format: "Beat grid: %.0f BPM, %d beats — snapping now lands cuts on them",
                                       bpm, grid.count))
                } else {
                    self.append("No steady beat found in this bed — snapping stays on cuts and markers")
                }
            }
        }
    }

    // MARK: Bookends — end card and intro sting from the client profile

    @Published var isBakingEndCard = false

    /// The project's client, if one was applied.
    var clientProfile: ClientProfile? {
        guard let id = project.clientProfileID else { return nil }
        return ClientStore.shared.clients.first { $0.id == id }
    }

    /// Renders the client's end card and appends it to the timeline as a
    /// normal clip — trimmable, movable, no special export path.
    func addEndCard(seconds: Double = 5) {
        guard !isBakingEndCard else { return }
        guard let client = clientProfile else {
            append("End cards come from the client profile — apply a client to this project first")
            return
        }
        isBakingEndCard = true
        let aspect = clipEdit.aspect
        let doc = EndCardService.document(for: client, aspect: aspect)
        Task { [weak self] in
            guard let self else { return }
            let dir = self.project.paths.renderDir
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let png = dir.appendingPathComponent("endcard.png")
            let mp4 = dir.appendingPathComponent("endcard-\(aspect.rawValue).mp4")
            let rendered = ThumbnailRenderer.renderForStudio(doc)
            guard let rendered,
                  let data = ThumbnailRenderer.encoded(rendered, asPNG: true, jpegQuality: 1) else {
                self.isBakingEndCard = false
                self.append("End card: render failed")
                return
            }
            try? data.write(to: png, options: .atomic)
            do {
                let service = try ExportService()
                try await Shell.runChecked(
                    service.ffmpeg,
                    arguments: EndCardService.bakeArguments(
                        cardPNG: png, seconds: seconds,
                        width: aspect.width, height: aspect.height,
                        destination: mp4),
                    onOutputLine: { _ in }, onErrorLine: { _ in })
                await MainActor.run {
                    self.isBakingEndCard = false
                    var edit = self.clipEdit
                    let clamped = min(15, max(2, seconds))
                    edit.clips.append(TimelineClip(
                        sourcePath: mp4.path, start: 0, end: clamped,
                        sourceDuration: clamped, name: "\(client.name) end card"))
                    self.applyClipEdit(edit, action: "Add End Card")
                    self.append("End card appended — \(client.name), \(Int(clamped))s")
                }
            } catch {
                await MainActor.run {
                    self.isBakingEndCard = false
                    self.append("End card: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Prepends the client's intro sting (or any picked file) at the head.
    func addIntro(url: URL) {
        let asset = AVURLAsset(url: url)
        Task { [weak self] in
            let seconds = (try? await asset.load(.duration))?.seconds ?? 0
            await MainActor.run {
                guard let self, seconds > 0.2 else { return }
                var edit = self.clipEdit
                edit.clips.insert(TimelineClip(
                    sourcePath: url.path, start: 0, end: seconds,
                    sourceDuration: seconds,
                    name: url.deletingPathExtension().lastPathComponent), at: 0)
                self.applyClipEdit(edit, action: "Add Intro")
                self.append(String(format: "Intro prepended — %.1fs", seconds))
            }
        }
    }

    // MARK: Version snapshots — named cuts that survive closing the project

    struct EditSnapshot: Identifiable, Equatable {
        var id: String { url.path }
        var url: URL
        var name: String
        var savedAt: Date
        var clipCount: Int
        var duration: Double
    }

    @Published private(set) var editSnapshots: [EditSnapshot] = []

    private struct SnapshotFile: Codable {
        var name: String
        var savedAt: Date
        var edit: ClipEdit
    }

    func loadSnapshots() {
        let dir = project.paths.versionsDir
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        editSnapshots = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let file = try? JSONDecoder().decode(SnapshotFile.self, from: data)
                else { return nil }
                return EditSnapshot(url: url, name: file.name, savedAt: file.savedAt,
                                    clipCount: file.edit.clips.count,
                                    duration: file.edit.totalDuration)
            }
            .sorted { $0.savedAt > $1.savedAt }
    }

    func saveSnapshot(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let dir = project.paths.versionsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = SnapshotFile(name: trimmed, savedAt: Date(), edit: clipEdit)
        let url = dir.appendingPathComponent("\(UUID().uuidString).json")
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: url, options: .atomic)
            loadSnapshots()
            append("Snapshot saved: \(trimmed)")
        }
    }

    /// Restoring goes through the same undo choke point as everything else,
    /// so ⌘Z brings the pre-restore cut straight back.
    func restoreSnapshot(_ snapshot: EditSnapshot) {
        guard let data = try? Data(contentsOf: snapshot.url),
              let file = try? JSONDecoder().decode(SnapshotFile.self, from: data)
        else { return }
        applyClipEdit(file.edit, action: "Restore \(snapshot.name)")
        append("Restored snapshot: \(snapshot.name)")
    }

    func deleteSnapshot(_ snapshot: EditSnapshot) {
        try? FileManager.default.removeItem(at: snapshot.url)
        loadSnapshots()
    }

    // MARK: Tighten — dead air and fillers out, one undo step

    /// The current plan at the given aggressiveness; pure and cheap enough
    /// to recompute on every slider move.
    func tightenPlan(aggressiveness: Double, removeFillers: Bool) -> [TightenService.Cut] {
        TightenService.plan(edit: clipEdit, transcript: transcript,
                            projectSource: project.sourcePath,
                            options: TightenService.options(
                                aggressiveness: aggressiveness,
                                removeFillers: removeFillers))
    }

    func applyTighten(_ cuts: [TightenService.Cut]) {
        guard !cuts.isEmpty else { return }
        let saved = cuts.reduce(0) { $0 + $1.duration }
        let (tightened, applied) = TightenService.apply(cuts, to: clipEdit)
        guard applied > 0 else {
            append("Tighten: nothing could be cut")
            return
        }
        applyClipEdit(tightened, action: "Tighten")
        append(String(format: "Tightened: %d cut(s), %.1fs removed", applied, saved))
    }

    // MARK: Motion — punch-ins and auto-reframe

    @Published var isReframing = false
    @Published var isDetectingPeaks = false

    /// Detects punch-in moments for one clip from data already in memory:
    /// its waveform slice and any transcript words in its source range.
    func detectPunchIns(clipID: UUID, intensity: Double) {
        guard let index = clipEdit.clips.firstIndex(where: { $0.id == clipID }) else { return }
        let clip = clipEdit.clips[index]
        guard let peaks = waveformSlice(for: clip) else {
            // An imported clip has no waveform on disk, so decode one for
            // just its range rather than refusing the whole feature.
            decodePeaksThenPunchIn(clip: clip, intensity: intensity)
            return
        }
        var words: [(t: Double, text: String)] = []
        if clip.sourcePath == project.sourcePath {
            for segment in transcript.segments
            where segment.end > clip.start && segment.start < clip.end {
                for word in segment.words where word.start >= clip.start && word.start <= clip.end {
                    words.append((t: word.start - clip.start, text: word.text))
                }
            }
        }
        let keys = PunchInService.detect(
            peaks: peaks, perSecond: waveform?.peaksPerSecond ?? 20,
            words: words, clipSourceDuration: clip.duration,
            speed: clip.clampedSpeed,
            options: PunchInService.Options(intensity: intensity))
        guard !keys.isEmpty else {
            append("No punch-in moments found — the clip's audio is even throughout")
            return
        }
        var edit = clipEdit
        edit.clips[index].zoomKeys = keys
        applyClipEdit(edit, action: "Detect Punch-ins")
        append("Punch-ins: \(keys.count / 4) push(es)")
    }

    /// Decodes an imported clip's own audio to a peak envelope, then runs the
    /// same detector. A few seconds for a clip-length range.
    private func decodePeaksThenPunchIn(clip: TimelineClip, intensity: Double) {
        guard !isDetectingPeaks else { return }
        isDetectingPeaks = true
        Task { [weak self] in
            guard let self else { return }
            var peaks: [UInt8] = []
            let perSecond = 20.0
            do {
                let service = try ExportService()
                let raw = FileManager.default.temporaryDirectory
                    .appendingPathComponent("peaks-\(UUID().uuidString).f32")
                defer { try? FileManager.default.removeItem(at: raw) }
                try await Shell.runChecked(
                    service.ffmpeg,
                    arguments: ["-hide_banner", "-nostdin",
                                "-ss", String(format: "%.3f", clip.start),
                                "-t", String(format: "%.3f", clip.duration),
                                "-i", clip.sourcePath,
                                "-ac", "1", "-ar", "8000",
                                "-f", "f32le", "-y", raw.path],
                    onOutputLine: { _ in }, onErrorLine: { _ in })
                let data = try Data(contentsOf: raw)
                let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                let bucket = Int(8000 / perSecond)
                var index = 0
                while index + bucket <= samples.count {
                    var peak: Float = 0
                    for j in index..<(index + bucket) { peak = max(peak, abs(samples[j])) }
                    peaks.append(UInt8(min(255, max(0, peak * 255))))
                    index += bucket
                }
            } catch {
                // Falls through to the empty-peaks message below.
            }
            let captured = peaks
            await MainActor.run {
                self.isDetectingPeaks = false
                guard captured.count > 4 else {
                    self.append("Punch-ins: couldn't read audio from \(clip.displayName)")
                    return
                }
                let keys = PunchInService.detect(
                    peaks: captured, perSecond: perSecond, words: [],
                    clipSourceDuration: clip.duration, speed: clip.clampedSpeed,
                    options: PunchInService.Options(intensity: intensity))
                guard !keys.isEmpty else {
                    self.append("No punch-in moments found — the clip's audio is even throughout")
                    return
                }
                guard let liveIndex = self.clipEdit.clips.firstIndex(where: { $0.id == clip.id })
                else { return }
                var edit = self.clipEdit
                edit.clips[liveIndex].zoomKeys = keys
                self.applyClipEdit(edit, action: "Detect Punch-ins")
                self.append("Punch-ins: \(keys.count / 4) push(es) from the clip's own audio")
            }
        }
    }

    /// One manual push at the playhead, on whatever clip sits under it.
    func addPunchIn(atTimeline time: Double, intensity: Double) {
        guard let (index, offset) = clipAt(timelineTime: time) else { return }
        var edit = clipEdit
        let clip = edit.clips[index]
        let envelope = PunchInService.envelopes(
            for: [offset], effectiveDuration: clip.effectiveDuration,
            options: PunchInService.Options(intensity: intensity))
        guard !envelope.isEmpty else { return }
        edit.clips[index].zoomKeys = (clip.zoomKeys + envelope).sorted { $0.t < $1.t }
        applyClipEdit(edit, action: "Add Punch-in")
    }

    func clearMotion(clipID: UUID, zoom: Bool, pan: Bool) {
        guard let index = clipEdit.clips.firstIndex(where: { $0.id == clipID }) else { return }
        var edit = clipEdit
        if zoom { edit.clips[index].zoomKeys = [] }
        if pan { edit.clips[index].panKeys = [] }
        applyClipEdit(edit, action: zoom && pan ? "Clear Motion"
                          : zoom ? "Clear Punch-ins" : "Clear Reframe")
    }

    /// Samples the clip at ~3 fps, finds the subject per frame (largest
    /// face; motion centroid when no face shows), and writes a smoothed
    /// pan track. Local Vision — a few seconds per clip.
    func detectReframe(clipID: UUID) {
        guard let index = clipEdit.clips.firstIndex(where: { $0.id == clipID }),
              !isReframing else { return }
        let clip = clipEdit.clips[index]
        guard !clip.isFreeze, clip.duration > 1 else { return }
        isReframing = true
        let renderSize = CGSize(width: clipEdit.aspect.width, height: clipEdit.aspect.height)
        Task { [weak self] in
            let samples = await ReframeSampler.samples(for: clip, renderSize: renderSize)
            await MainActor.run {
                guard let self else { return }
                self.isReframing = false
                let keys = ReframeService.panKeys(from: samples)
                guard !keys.isEmpty else {
                    self.append("Reframe: the subject holds still — no pan needed")
                    return
                }
                guard let liveIndex = self.clipEdit.clips.firstIndex(where: { $0.id == clipID })
                else { return }
                var edit = self.clipEdit
                edit.clips[liveIndex].panKeys = keys
                self.applyClipEdit(edit, action: "Auto-Reframe")
                self.append("Reframe: \(keys.count) pan keyframes following the subject")
            }
        }
    }

    // MARK: Sound effects

    @Published var sfxSounds: [SFXLibrary.Sound] = []
    @Published var isGeneratingSFX = false

    func rescanSFX() {
        sfxSounds = SFXLibrary.scan()
    }

    /// Drops a sound at the playhead (or wherever). Hotkeys 1–9 land here.
    func addSFX(path: String, atTimeline time: Double) {
        var edit = clipEdit
        edit.sfxEvents.append(SFXEvent(path: path, startTime: max(0, time)))
        edit.sfxEvents.sort { $0.startTime < $1.startTime }
        applyClipEdit(edit, action: "Add Sound Effect")
        append("SFX: \(URL(fileURLWithPath: path).lastPathComponent) at \(time.shortTimecode)")
    }

    func removeSFX(id: UUID) {
        var edit = clipEdit
        edit.sfxEvents.removeAll { $0.id == id }
        applyClipEdit(edit, action: "Remove Sound Effect")
    }

    func moveSFX(id: UUID, to time: Double) {
        guard let index = clipEdit.sfxEvents.firstIndex(where: { $0.id == id }) else { return }
        var edit = clipEdit
        edit.sfxEvents[index].startTime = max(0, time)
        applyClipEdit(edit, action: "Move Sound Effect")
    }

    func setSFXGain(id: UUID, gainDB: Double) {
        guard let index = clipEdit.sfxEvents.firstIndex(where: { $0.id == id }) else { return }
        var edit = clipEdit
        edit.sfxEvents[index].gainDB = gainDB
        applyClipEdit(edit, action: "Sound Effect Volume")
    }

    /// Synthesizes the placeholder starter pack into the library folder —
    /// local ffmpeg generators, nothing shipped, nothing fetched.
    func generateSFXStarterPack() {
        guard !isGeneratingSFX else { return }
        isGeneratingSFX = true
        Task { [weak self] in
            let root = Paths.sfxRoot.appendingPathComponent("starter", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (name, arguments) in SFXLibrary.starterPack() {
                let destination = root.appendingPathComponent(name)
                guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
                if let service = try? ExportService() {
                    try? await Shell.runChecked(
                        service.ffmpeg,
                        arguments: ["-hide_banner", "-nostdin"] + arguments + ["-y", destination.path],
                        onOutputLine: { _ in }, onErrorLine: { _ in })
                }
            }
            await MainActor.run {
                self?.isGeneratingSFX = false
                self?.rescanSFX()
                self?.append("SFX starter pack ready — replace with real packs any time")
            }
        }
    }

    // MARK: Clipboard

    private(set) var clipClipboard: TimelineClip?

    func copyClip(_ clip: TimelineClip) {
        clipClipboard = clip
        append("Copied \(clip.displayName)")
    }

    func cutClip(_ clip: TimelineClip) {
        clipClipboard = clip
        var edit = clipEdit
        edit.clips.removeAll { $0.id == clip.id }
        applyClipEdit(edit, action: "Cut Clip")
    }

    /// Pastes after the reference clip, or at the playhead's clip when nil.
    /// A copy of the clip dropped in right after it, without disturbing the
    /// clipboard.
    func duplicateClip(_ clip: TimelineClip) {
        var edit = clipEdit
        guard let index = edit.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        var copy = clip
        copy.id = UUID()
        edit.clips.insert(copy, at: index + 1)
        applyClipEdit(edit, action: "Duplicate Clip")
        append("Duplicated \(clip.displayName)")
    }

    /// Where a clip sits on the timeline, in seconds.
    func startTime(of clip: TimelineClip) -> Double? {
        var cursor: Double = 0
        for candidate in clipEdit.clips {
            if candidate.id == clip.id { return cursor }
            cursor += candidate.effectiveDuration
        }
        return nil
    }

    func pasteClip(after reference: TimelineClip?, playhead: Double) {
        guard var pasted = clipClipboard else { return }
        pasted.id = UUID()
        var edit = clipEdit
        let index: Int
        if let reference, let found = edit.clips.firstIndex(where: { $0.id == reference.id }) {
            index = found + 1
        } else if let (found, _) = clipAt(timelineTime: playhead) {
            index = found + 1
        } else {
            index = edit.clips.count
        }
        edit.clips.insert(pasted, at: min(index, edit.clips.count))
        applyClipEdit(edit, action: "Paste Clip")
    }

    // MARK: Tracks

    func setTrackControls(_ track: String, _ controls: TrackControls) {
        var edit = clipEdit
        edit.trackControls[track] = controls
        applyClipEdit(edit, action: "Track Controls")
    }

    func isTrackLocked(_ track: String) -> Bool {
        clipEdit.controls(track).locked
    }

    /// Waveform peaks for a clip's source range — only clips cut straight
    /// from this VOD have peaks on disk; pieces and imports show filmstrips
    /// only.
    func waveformSlice(for clip: TimelineClip) -> [UInt8]? {
        guard clip.sourcePath == project.sourcePath,
              let waveform, !waveform.peaks.isEmpty else { return nil }
        let perSecond = waveform.peaksPerSecond
        let lower = max(0, Int(clip.start * perSecond))
        let upper = min(waveform.peaks.count, Int(clip.end * perSecond))
        guard upper > lower else { return nil }
        return Array(waveform.peaks[lower..<upper])
    }

    func addMarker(at time: Double, note: String = "") {
        var edit = clipEdit
        // Tapping M twice on the same spot removes rather than stacking.
        if let existing = edit.markers.first(where: { abs($0.time - time) < 0.25 }) {
            edit.markers.removeAll { $0.id == existing.id }
            applyClipEdit(edit, action: "Remove Marker")
            return
        }
        edit.markers.append(TimelineMarker(time: time, note: note))
        edit.markers.sort { $0.time < $1.time }
        applyClipEdit(edit, action: "Add Marker")
    }

    func removeMarker(_ marker: TimelineMarker) {
        var edit = clipEdit
        edit.markers.removeAll { $0.id == marker.id }
        applyClipEdit(edit, action: "Remove Marker")
    }

    /// Adds a video overlay — green-screen content, reactions — starting at
    /// the playhead.
    func addOverlayVideo(from url: URL, at timelineTime: Double) {
        Task { [weak self] in
            guard let self else { return }
            let duration = (try? await FFmpegService().durationOf(url)) ?? 0
            guard duration > 0.2 else {
                self.append("Couldn't read a duration from \(url.lastPathComponent)")
                return
            }
            var edit = self.clipEdit
            let start = min(max(0, timelineTime), max(0, edit.totalDuration - 0.5))
            edit.overlayClips.append(OverlayClip(
                sourcePath: url.path,
                duration: min(duration, max(0.5, edit.totalDuration - start)),
                startTime: start))
            self.applyClipEdit(edit, action: "Add Overlay")
            self.append("Overlay: \(url.lastPathComponent) at \(start.shortTimecode) — green keyed on export")
        }
    }

    func removeOverlayClip(_ overlay: OverlayClip) {
        var edit = clipEdit
        edit.overlayClips.removeAll { $0.id == overlay.id }
        applyClipEdit(edit, action: "Remove Overlay")
    }

    // MARK: Voice-over

    /// Stores a finished recording, anchored where recording started.
    func setVoiceover(url: URL?, at start: Double) {
        var edit = clipEdit
        if let old = edit.voiceoverURL, old != url {
            try? FileManager.default.removeItem(at: old)
        }
        edit.voiceoverPath = url?.path
        edit.voiceoverStart = max(0, start)
        applyClipEdit(edit, action: "Voice-over")
        if url != nil { append("Voice-over recorded at \(start.shortTimecode)") }
    }

    // MARK: Client profiles

    /// Stamps a client's whole look onto this project: handles, caption style,
    /// webcam framing, vocabulary, logo layer.
    func applyClientProfile(_ profile: ClientProfile) {
        let (updatedProject, updatedEdit) = profile.applied(to: project, edit: clipEdit)
        project = updatedProject
        persist()
        applyClipEdit(updatedEdit, action: "Apply Client Profile")
        rebuildPreviewCues()
        append("Applied client profile: \(profile.name)")
    }

    /// Lifts this project's current look into a reusable profile.
    func captureClientProfile(named name: String) -> ClientProfile {
        ClientProfile.captured(from: project, edit: clipEdit, named: name)
    }

    // MARK: Export queue

    /// Snapshots the timeline into the app-wide queue — the render runs
    /// unattended, and later edits here don't change the queued job.
    func queueTimelineExport(to destination: URL, platformSet: Bool) {
        ExportQueue.shared.enqueue(
            projectName: project.name,
            clientName: project.clientName,
            edit: clipEdit.renderReady(),
            settings: project.exportSettings,
            renderDir: project.paths.renderDir,
            destination: destination,
            platformSet: platformSet)
        append(platformSet
               ? "Queued a platform-set export (\(clipEdit.clips.count) clips)"
               : "Queued an export (\(clipEdit.clips.count) clips)")
    }

    // MARK: Library

    func addToLibrary(_ url: URL) {
        var edit = clipEdit
        let path = url.standardizedFileURL.path
        guard !edit.library.contains(path) else { return }
        edit.library.append(path)
        applyClipEdit(edit, action: "Library")
        append("Library: added \(url.lastPathComponent)")
    }

    func removeFromLibrary(_ path: String) {
        var edit = clipEdit
        edit.library.removeAll { $0 == path }
        applyClipEdit(edit, action: "Library")
    }

    // MARK: Undo

    /// The window's undo manager, lent by the editor view. Registrations are
    /// removed when the view detaches, so a stale command can't target a
    /// deallocated session.
    weak var timelineUndoManager: UndoManager?
    private var lastUndoAction: String?
    private var lastUndoRegistration = Date.distantPast
    @Published private(set) var lastSavedAt: Date?

    func detachUndo() {
        timelineUndoManager?.removeAllActions(withTarget: self)
        timelineUndoManager = nil
    }

    private func registerUndo(returningTo previous: ClipEdit, action: String) {
        guard let undo = timelineUndoManager else { return }
        undo.registerUndo(withTarget: self) { session in
            let current = session.clipEdit
            session.registerUndo(returningTo: current, action: action)
            session.lastUndoAction = nil
            session.applyClipEditRaw(previous)
        }
        undo.setActionName(action)
        if undo.levelsOfUndo < 80 { undo.levelsOfUndo = 80 }
    }

    /// The single mutation path. Every timeline change — trim, move, split,
    /// delete, property change, AI-generated or hand-made — comes through
    /// here with an action name, which is what makes undo/redo and the Edit
    /// menu label possible. ClipEdit is a value type, so the inverse of any
    /// command is simply the previous document.
    func applyClipEdit(_ edit: ClipEdit, action: String? = nil) {
        let previous = clipEdit
        if let action, previous != edit {
            if !UndoCoalescing.shouldCoalesce(action: action, lastAction: lastUndoAction,
                                              lastAt: lastUndoRegistration, now: Date()) {
                registerUndo(returningTo: previous, action: action)
            }
            lastUndoAction = action
            lastUndoRegistration = Date()
        }
        applyClipEditRaw(edit)
    }

    /// Persists, re-renders the overlay, and rebuilds the preview composition
    /// (debounced — trim sliders fire per tick). Undo restoration lands here
    /// directly so it never re-registers.
    private func applyClipEditRaw(_ edit: ClipEdit) {
        clipEdit = edit
        if !edit.twitchHandle.trimmingCharacters(in: .whitespaces).isEmpty {
            UserDefaults.standard.set(edit.twitchHandle, forKey: "socialTwitch")
        }
        if !edit.instagramHandle.trimmingCharacters(in: .whitespaces).isEmpty {
            UserDefaults.standard.set(edit.instagramHandle, forKey: "socialInstagram")
        }
        try? JSONEncoder().encode(edit).write(to: project.paths.clipEdit, options: .atomic)
        lastSavedAt = Date()
        rebuildEditOverlay()
        scheduleEditPreview()
    }

    /// A timed text item rendered for the preview, shown while the playhead is
    /// inside its window.
    struct TimedTextPreview: Identifiable {
        let id: UUID
        let image: NSImage
        let start: Double
        let end: Double
    }
    @Published private(set) var editTimedTexts: [TimedTextPreview] = []

    private func rebuildEditOverlay() {
        let ready = clipEdit.renderReady()
        editOverlay = SocialOverlayRenderer.image(for: ready)
        editTimedTexts = ready.textItems
            .filter { $0.isTimed && !$0.isBlank }
            .compactMap { item in
                SocialOverlayRenderer.image(for: item).map {
                    TimedTextPreview(id: item.id, image: $0,
                                     start: item.startTime, end: item.endTime)
                }
            }
    }

    private func scheduleEditPreview() {
        editPreviewTask?.cancel()
        let edit = clipEdit.renderReady()
        editPreviewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            guard !edit.isEmpty else {
                self.editComposition = nil
                self.editVideoComposition = nil
                self.editAudioMix = nil
                return
            }
            let built = try? await ClipEditPreview.build(edit)
            guard !Task.isCancelled else { return }
            self.editComposition = built?.0
            self.editVideoComposition = built?.1
            self.editAudioMix = built?.2
        }
    }

    /// Renders the timeline with the overlay and music burned in.
    func exportClipEdit(to destination: URL) {
        guard !isExporting, !clipEdit.isEmpty else { return }
        isExporting = true
        exportProgress = 0
        lastExport = nil
        let edit = clipEdit.renderReady()

        Task { [weak self] in
            guard let self else { return }
            do {
                try self.project.paths.createDirectories()
                // The always-on overlay first, then one gated input per timed
                // text item — same enable windows the preview honours.
                var overlays: [ExportService.TimedOverlay] = []
                if let png = SocialOverlayRenderer.pngData(for: edit) {
                    let url = self.project.paths.renderDir.appendingPathComponent("social-overlay.png")
                    try png.write(to: url, options: .atomic)
                    overlays.append(ExportService.TimedOverlay(url: url, start: nil, end: nil))
                }
                for item in edit.textItems where item.isTimed && !item.isBlank {
                    guard let png = SocialOverlayRenderer.pngData(for: item, aspect: edit.aspect) else { continue }
                    let url = self.project.paths.renderDir
                        .appendingPathComponent("text-\(item.id.uuidString).png")
                    try png.write(to: url, options: .atomic)
                    overlays.append(ExportService.TimedOverlay(url: url, start: item.startTime,
                                                               end: item.endTime))
                }
                let videoOverlays = await ExportService.videoOverlayInputs(for: edit)
                var voiceover: ExportService.VoiceoverInput?
                if let voURL = edit.voiceoverURL, FileManager.default.fileExists(atPath: voURL.path) {
                    voiceover = .init(url: voURL, start: edit.voiceoverStart,
                                      gainDB: edit.voiceoverGainDB)
                }
                let service = try ExportService()
                let result = try await service.exportClipEdit(
                    clips: edit.clips, overlays: overlays,
                    videoOverlays: videoOverlays, voiceover: voiceover,
                    sfx: ExportService.sfxInputs(for: edit),
                    musicURL: edit.musicURL, musicGainDB: edit.musicGainDB,
                    crossfade: edit.crossfadeDuration,
                    transition: edit.transitionStyle,
                    renderWidth: edit.aspect.width, renderHeight: edit.aspect.height,
                    settings: self.project.exportSettings,
                    destination: destination,
                    workingDirectory: self.project.paths.renderDir,
                    onProgress: { [weak self] value in
                        Task { @MainActor in self?.exportProgress = value }
                    },
                    onLog: { [weak self] line in
                        Task { @MainActor in self?.append(line) }
                    }
                )
                self.isExporting = false
                self.lastExport = result
                self.append("Exported \(result.url.lastPathComponent) · \(String(format: "%.0fs", result.elapsed)) · \(result.encoderName)")
            } catch {
                self.isExporting = false
                self.statusDetail = error.localizedDescription
                self.append("Timeline export failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Packaging: titles and thumbnails

    var canGenerateIdeas: Bool { !transcript.isEmpty }

    /// Pulls stills from the moments the scorer rated highest, plus the model's
    /// pick if the packaging pass has already run.
    func extractFrames(count: Int = 12) {
        guard !isExtractingFrames, project.media != nil else { return }
        isExtractingFrames = true
        frameProgress = 0
        publishError = nil

        var times = shorts
            .filter { $0.status != .discarded }
            .sorted { $0.score > $1.score }
            .prefix(count)
            .map(\.peakTime)
        if let pick = ideas?.bestMomentSeconds, !times.contains(where: { abs($0 - pick) < 2 }) {
            times.insert(pick, at: 0)
        }
        let ordered = Array(Set(times.map { ($0 * 4).rounded() / 4 })).sorted()

        Task { [weak self] in
            guard let self else { return }
            do {
                let paths = self.project.paths
                try paths.createDirectories()
                let urls = try await ThumbnailService.extractFrames(
                    source: self.project.sourceURL,
                    times: ordered,
                    into: paths.thumbnailsDir,
                    onProgress: { value in Task { @MainActor in self.frameProgress = value } }
                )
                self.frames = zip(ordered, urls).enumerated().map { index, pair in
                    FrameCandidate(
                        id: index,
                        time: pair.0,
                        path: pair.1.path,
                        caption: self.transcript.indexOfSegment(at: pair.0)
                            .map { self.transcript.segments[$0].text } ?? "",
                        score: self.shorts.first { abs($0.peakTime - pair.0) < 2 }?.score ?? 0
                    )
                }
                if self.project.thumbnail.frameTime == nil,
                   self.project.thumbnail.generatedImagePath == nil,
                   let first = self.frames.first {
                    self.selectThumbnailFrame(first.time)
                }
                self.isExtractingFrames = false
                self.append("Thumbnails: pulled \(urls.count) frames")
            } catch {
                self.isExtractingFrames = false
                self.publishError = error.localizedDescription
                self.append("Frame extraction failed: \(error.localizedDescription)")
            }
        }
    }

    func frameURL(at time: Double) -> URL? {
        frames.first { abs($0.time - time) < 0.3 }?.url
    }

    var thumbnailBackgroundURL: URL? {
        if let generated = project.thumbnail.generatedImageURL,
           FileManager.default.fileExists(atPath: generated.path) {
            return generated
        }
        return project.thumbnail.frameTime.flatMap { frameURL(at: $0) }
    }

    func selectThumbnailFrame(_ time: Double) {
        var draft = project.thumbnail
        draft.frameTime = time
        draft.generatedImagePath = nil
        updateThumbnail(draft)
    }

    func updateThumbnail(_ draft: ThumbnailDraft) {
        project.thumbnail = draft
        persist()
    }

    // MARK: Thumbnail layers


    /// Copies a file the user brought into the project so the draft doesn't
    /// break if they move or delete the original.
    func addThumbnailLayer(from source: URL) {
        do {
            try project.paths.createDirectories()
            let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
            let destination = project.paths.thumbnailsDir
                .appendingPathComponent("layer-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: source, to: destination)
            var draft = project.thumbnail
            draft.layers.append(ThumbnailLayer(path: destination.path, origin: .file,
                                               name: source.deletingPathExtension().lastPathComponent))
            updateThumbnail(draft)
            append("Added layer \(source.lastPathComponent)")
        } catch {
            publishError = "Couldn't add that image: \(error.localizedDescription)"
        }
    }

    func updateLayer(_ layer: ThumbnailLayer) {
        var draft = project.thumbnail
        guard let index = draft.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        draft.layers[index] = layer
        updateThumbnail(draft)
    }

    func removeLayer(_ layer: ThumbnailLayer) {
        var draft = project.thumbnail
        draft.layers.removeAll { $0.id == layer.id }
        updateThumbnail(draft)
        if layer.path.contains(project.paths.thumbnailsDir.path) {
            try? FileManager.default.removeItem(at: layer.url)
        }
    }

    func moveLayer(_ layer: ThumbnailLayer, up: Bool) {
        var draft = project.thumbnail
        guard let index = draft.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        let target = up ? index + 1 : index - 1
        guard draft.layers.indices.contains(target) else { return }
        draft.layers.swapAt(index, target)
        updateThumbnail(draft)
    }

    var canDesignOverlays: Bool { true }

    /// The overlay-drawing prompt for a claude.ai chat.
    func overlayPrompt(brief: String) -> String {
        OverlayDesigner.manualPrompt(brief: brief,
                                     context: ideas?.titles.first?.text ?? project.name)
    }

    /// Applies a pasted SVG reply: sanitizes, rasterises locally to reject SVG
    /// AppKit can't draw, and adds it as a layer.
    func applyOverlayReply(_ reply: String, name: String) throws -> String {
        publishError = nil
        do {
            try project.paths.createDirectories()
            let svg = try OverlayDesigner.parseReply(reply)
            let svgURL = project.paths.thumbnailsDir
                .appendingPathComponent("overlay-\(UUID().uuidString).svg")
            try svg.write(to: svgURL, atomically: true, encoding: .utf8)

            // Rendered once here purely to reject SVG AppKit can't draw,
            // before it becomes a layer that silently contributes nothing.
            let probe = svgURL.deletingPathExtension().appendingPathExtension("probe.png")
            _ = try LayerRasterizer.rasterize(svgURL, to: probe, targetWidth: 400)
            try? FileManager.default.removeItem(at: probe)

            var draft = project.thumbnail
            let layerName = name.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Claude design" : name
            draft.layers.append(ThumbnailLayer(path: svgURL.path, origin: .designed,
                                               name: layerName, width: 0.4))
            updateThumbnail(draft)
            append("Designed overlay: \(layerName) — \(svg.count) bytes of SVG")
            return "Overlay added as a layer."
        } catch {
            publishError = "Overlay design failed: \(error.localizedDescription)"
            append("Overlay design failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// The scope the next pasted ideas reply is labelled with — set when the
    /// prompt is copied, so the pack remembers what it covered.
    private var pendingIdeasScope: (range: ClosedRange<Double>?, label: String) = (nil, "whole stream")

    /// The packaging prompt for a claude.ai chat.
    func ideasPrompt(range: ClosedRange<Double>? = nil, scopeLabel: String = "whole stream") -> String? {
        guard !transcript.isEmpty else { return nil }
        pendingIdeasScope = (range, scopeLabel)
        let moments = shorts
            .filter { $0.status != .discarded }
            .sorted { $0.score > $1.score }
            .prefix(24)
            .map { candidate in
                IdeaService.Moment(
                    start: candidate.start,
                    score: candidate.score,
                    text: transcript.segments
                        .filter { $0.start >= candidate.start && $0.start < candidate.end }
                        .map(\.text)
                        .joined(separator: " ")
                        .prefix(400)
                        .description
                )
            }
        return IdeaService.manualPrompt(transcript: transcript,
                                        range: pendingIdeasScope.range,
                                        moments: moments,
                                        vocabulary: project.vocabularyPrompt)
    }

    /// Applies a pasted packaging reply.
    func applyIdeasReply(_ reply: String) throws -> String {
        publishError = nil
        do {
            let pack = try IdeaService.parseReply(reply, scopeLabel: pendingIdeasScope.label)
            ideas = pack
            try? JSONEncoder().encode(pack).write(to: project.paths.ideas, options: .atomic)
            if project.thumbnail.text.isEmpty, let first = pack.thumbnailTexts.first {
                var draft = project.thumbnail
                draft.text = first
                updateThumbnail(draft)
            }
            append("Packaging: \(pack.titles.count) titles, \(pack.hooks.count) hooks, \(pack.tags.count) tags")
            return "\(pack.titles.count) titles, \(pack.hooks.count) hooks, \(pack.tags.count) tags applied."
        } catch {
            publishError = error.localizedDescription
            append("Packaging reply failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Writes the 1280×720 thumbnail, and the 1080×1920 cover beside it.
    func exportThumbnail(to destination: URL) {
        guard let background = thumbnailBackgroundURL else {
            publishError = ThumbnailError.noBackground.localizedDescription
            return
        }
        let draft = project.thumbnail
        let workingDirectory = project.paths.renderDir

        Task { [weak self] in
            guard let self else { return }
            do {
                try self.project.paths.createDirectories()
                try await ThumbnailService.render(
                    draft: draft, background: background,
                    width: ThumbnailDraft.horizontalSize.width,
                    height: ThumbnailDraft.horizontalSize.height,
                    cropToFill: true,
                    workingDirectory: workingDirectory, destination: destination
                )
                let vertical = destination.deletingPathExtension().path + "-vertical.jpg"
                try await ThumbnailService.render(
                    draft: draft, background: background,
                    width: ThumbnailDraft.verticalSize.width,
                    height: ThumbnailDraft.verticalSize.height,
                    cropToFill: true,
                    workingDirectory: workingDirectory,
                    destination: URL(fileURLWithPath: vertical)
                )
                self.lastThumbnailPath = destination.path
                self.append("Exported \(destination.lastPathComponent) and its vertical cover")
            } catch {
                self.publishError = error.localizedDescription
                self.append("Thumbnail export failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Phase 3: long-form assembly

    var longFormDuration: Double { assembled.duration }

    /// Crossfades overlap the joins, so the rendered cut is shorter than the
    /// hard-cut preview by (pieces − 1) × fade.
    var longFormExportDuration: Double {
        ExportService.expectedDuration(pieceDurations: assembled.pieces.map(\.duration),
                                       options: project.longFormOptions)
    }

    var longFormDurationLabel: String {
        String(format: "%.1f min", longFormExportDuration / 60)
    }

    /// Whether the assembly is inside the 25–30 minute band the brief targets.
    var longFormOnTarget: Bool {
        let minutes = longFormExportDuration / 60
        return minutes >= 25 && minutes <= 30
    }

    func generateLongForm() {
        guard let media = project.media, !scoreCurve.isEmpty else { return }
        longForm = LongFormService.generate(
            curve: scoreCurve,
            transcript: transcript,
            silence: silence,
            duration: media.durationSeconds,
            throughlines: throughlines,
            options: project.longFormOptions
        )
        rebuildAssembly()
        persistLongForm()
        append("Long-form: \(longForm.included.count) segments · \(longFormDurationLabel)")
    }

    func updateLongFormOptions(_ options: LongFormOptions) {
        project.longFormOptions = options
        persist()
        rebuildAssembly()
        persistLongForm()
    }

    func setIncluded(_ included: Bool, for segment: LongFormSegment) {
        guard let index = longForm.segments.firstIndex(where: { $0.id == segment.id }) else { return }
        longForm.segments[index].isIncluded = included
        if included {
            // Dropped back onto the timeline: place it chronologically.
            longForm.segments[index].order = (longForm.included.map(\.order).max() ?? -1) + 1
            renumberChronologically()
        }
        rebuildAssembly()
        persistLongForm()
    }

    func updateLongFormSegment(_ segment: LongFormSegment) {
        guard let index = longForm.segments.firstIndex(where: { $0.id == segment.id }) else { return }
        longForm.segments[index] = segment
        rebuildAssembly()
        schedulePersistLongForm()
    }

    /// Moves a segment to a new slot in the sequence.
    func moveLongFormSegment(id: UUID, before targetID: UUID?) {
        var ordered = longForm.included
        guard let fromIndex = ordered.firstIndex(where: { $0.id == id }) else { return }
        let moved = ordered.remove(at: fromIndex)
        let insertIndex = targetID.flatMap { target in ordered.firstIndex { $0.id == target } } ?? ordered.count
        ordered.insert(moved, at: insertIndex)

        for (position, segment) in ordered.enumerated() {
            if let index = longForm.segments.firstIndex(where: { $0.id == segment.id }) {
                longForm.segments[index].order = position
            }
        }
        rebuildAssembly()
        persistLongForm()
    }

    func sortLongFormChronologically() {
        renumberChronologically()
        rebuildAssembly()
        persistLongForm()
    }

    private func renumberChronologically() {
        let ordered = longForm.segments.filter(\.isIncluded).sorted { $0.start < $1.start }
        for (position, segment) in ordered.enumerated() {
            if let index = longForm.segments.firstIndex(where: { $0.id == segment.id }) {
                longForm.segments[index].order = position
            }
        }
    }

    /// Recomputing the piece list is cheap and happens on every edit; rebuilding
    /// the AVComposition touches the asset, so it's debounced.
    func rebuildAssembly() {
        assembled = LongFormService.assemble(edit: longForm, silence: silence,
                                             options: project.longFormOptions)
        schedulePreviewRebuild()
    }

    private func schedulePreviewRebuild() {
        previewRebuildTask?.cancel()
        let pieces = assembled
        let source = project.sourceURL
        previewRebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            guard !pieces.isEmpty else {
                await MainActor.run { self.previewComposition = nil }
                return
            }
            await MainActor.run { self.isBuildingPreview = true }
            let composition = try? await LongFormService.buildComposition(sourceURL: source,
                                                                          assembled: pieces)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.previewComposition = composition
                self.isBuildingPreview = false
            }
        }
    }

    /// Captions for the assembled cut, with every timestamp rebased from source
    /// time onto composition time.
    func longFormCaptionLines() -> [CaptionLine] {
        let style = project.captionStyle
        var lines: [CaptionLine] = []
        for piece in assembled.pieces {
            let segments = transcript.segments.filter {
                $0.end > piece.source.start && $0.start < piece.source.end
            }
            for segment in segments {
                let start = max(piece.source.start, segment.start) - piece.source.start + piece.compositionStart
                let end = min(piece.source.end, segment.end) - piece.source.start + piece.compositionStart
                guard end > start else { continue }
                let text = style.uppercase ? segment.text.uppercased() : segment.text
                let words = segment.words.compactMap { word -> TranscriptWord? in
                    guard word.end > piece.source.start, word.start < piece.source.end else { return nil }
                    return TranscriptWord(
                        text: style.uppercase ? word.text.uppercased() : word.text,
                        start: max(piece.source.start, word.start) - piece.source.start + piece.compositionStart,
                        end: min(piece.source.end, word.end) - piece.source.start + piece.compositionStart,
                        probability: word.probability
                    )
                }
                lines.append(CaptionLine(id: segment.id, start: start, end: end, text: text, words: words))
            }
        }
        lines.sort { $0.start < $1.start }
        for index in lines.indices.dropLast() where lines[index].end > lines[index + 1].start {
            lines[index].end = lines[index + 1].start
        }
        return CaptionPhraser.regroup(lines.filter { $0.end > $0.start }, style: style)
    }

    func exportLongForm(to destination: URL) {
        guard !isExporting else { return }
        Task { [weak self] in
            try? await self?.performLongFormExport(to: destination)
        }
    }

    @discardableResult
    private func performLongFormExport(to destination: URL) async throws -> ExportResult {
        guard let media = project.media else { throw ExportError.noMediaInfo }
        isExporting = true
        exportProgress = 0
        lastExport = nil

        do {
            let service = try ExportService()
            try project.paths.createDirectories()
            let result = try await service.exportLongForm(
                pieces: assembled.pieces,
                source: project.sourceURL,
                media: media,
                settings: project.exportSettings,
                // Always computed: soft tracks and sidecars need them too, not
                // just burn-in.
                captionLines: project.exportSettings.captionMode == .none
                    && !project.exportSettings.wantsSidecars ? [] : longFormCaptionLines(),
                style: project.captionStyle,
                tuning: project.audioTuning,
                speech: project.audioTuning.needsSpeechKey ? speechIntervalsForAssembly() : [],
                options: project.longFormOptions,
                destination: destination,
                workingDirectory: project.paths.renderDir,
                onProgress: { [weak self] progress in
                    Task { @MainActor in self?.exportProgress = progress }
                },
                onLog: { [weak self] line in
                    Task { @MainActor in self?.append(line) }
                }
            )
            isExporting = false
            lastExport = result
            append("Exported \(result.url.lastPathComponent) · \(String(format: "%.0fs", result.elapsed)) · \(result.encoderName)")
            return result
        } catch {
            isExporting = false
            statusDetail = error.localizedDescription
            append("Long-form export failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func persistLongForm() {
        try? JSONEncoder().encode(longForm).write(to: project.paths.longForm, options: .atomic)
    }

    private func schedulePersistLongForm() {
        longFormPersistTask?.cancel()
        longFormPersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.persistLongForm() }
        }
    }

    // MARK: - Phase 2: scoring and candidates

    var canAnalyze: Bool { !transcript.isEmpty && waveform != nil }
    var hasShorts: Bool { !shorts.isEmpty }

    /// Scoring and candidate selection are pure computation over artifacts
    /// Changes what the analysis hunts for, and rebuilds everything driven by
    /// the curve — candidates and, if one exists, the long-form selection.
    func setContentFocus(_ focus: ContentFocus) {
        guard focus != project.contentFocus else { return }
        project.contentFocus = focus
        persist()
        analyzeShorts()
        if !longForm.segments.isEmpty { generateLongForm() }
        append("Focus: \(focus.label)")
    }

    /// already on disk — no ffmpeg, no model. Re-running after a weight change
    /// takes well under a second, so it's safe to treat as interactive.
    func analyzeShorts() {
        guard let media = project.media else { return }
        let curve = ScoringService.score(
            duration: media.durationSeconds,
            waveform: waveform,
            transcript: transcript,
            chat: chat,
            scenes: scenes,
            weights: project.scoreWeights.focused(project.contentFocus)
        )
        scoreCurve = curve

        let generated = CandidateService.generate(
            curve: curve,
            transcript: transcript,
            silence: silence,
            duration: media.durationSeconds,
            options: project.candidateOptions
        )

        // Preserve decisions and edits already made about overlapping clips.
        // Fresh candidates inherit the project's default framing (the webcam
        // box doesn't move between clips), and a clip the user already framed
        // keeps its own.
        let previous = shorts
        shorts = generated.map { fresh in
            guard let match = previous.first(where: {
                fresh.overlap(with: $0) > 0.6 * min(fresh.duration, $0.duration)
            }) else {
                var seeded = fresh
                seeded.layout = project.defaultShortLayout
                return seeded
            }
            var merged = fresh
            merged.id = match.id
            merged.status = match.status
            merged.cropCenterX = match.cropCenterX
            merged.layout = match.layout
            merged.captionEdits = match.captionEdits
            merged.styleOverride = match.styleOverride
            merged.exportedPath = match.exportedPath
            if match.status != .candidate {
                // A clip the user already trimmed keeps its in/out points.
                merged.start = match.start
                merged.end = match.end
            }
            return merged
        }

        project.shortsGeneratedAt = Date()
        persistAnalysis()
        append("Scored \(curve.values.count) windows → \(shorts.count) candidates")
    }

    func updateWeights(_ weights: ScoreWeights) {
        project.scoreWeights = weights
        persist()
        analyzeShorts()
    }

    func updateCandidateOptions(_ options: CandidateOptions) {
        project.candidateOptions = options
        persist()
        analyzeShorts()
    }

    /// Trim handles fire on every drag tick, so the write to disk is debounced
    /// rather than run per frame.
    func update(_ candidate: ShortCandidate) {
        guard let index = shorts.firstIndex(where: { $0.id == candidate.id }) else { return }
        shorts[index] = candidate
        shortsPersistTask?.cancel()
        shortsPersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.persistShorts() }
        }
    }

    func setStatus(_ status: ShortStatus, for candidate: ShortCandidate) {
        var updated = candidate
        updated.status = status
        update(updated)
    }

    /// Sets a clip's framing, and remembers it as the project default so the
    /// next clips inherit the same webcam box.
    func updateLayout(_ layout: ShortLayout, for candidate: ShortCandidate) {
        var updated = candidate
        updated.layout = layout
        update(updated)
        project.defaultShortLayout = layout
        // Debounced: sliders call this on every tick, and a synchronous
        // encode-and-write of the whole project per mouse move was a good part
        // of why dragging the boxes felt laggy.
        projectPersistTask?.cancel()
        projectPersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.persist() }
        }
    }

    private var projectPersistTask: Task<Void, Never>?

    // MARK: - Output preview

    @Published var showsOutputPreview = false
    @Published private(set) var outputPreviewImage: NSImage?
    @Published private(set) var isRenderingPreview = false
    private var outputPreviewTask: Task<Void, Never>?
    private var outputPreviewGeneration = 0

    /// Renders one composed output frame for the sidebar, through the exact
    /// graph the export uses. Debounced, and only the newest request wins — a
    /// drag fires many, and rendering every one would queue ffmpeg calls faster
    /// than they finish.
    func refreshOutputPreview(for candidate: ShortCandidate, at time: Double) {
        guard showsOutputPreview, let media = project.media else { return }
        outputPreviewTask?.cancel()
        outputPreviewGeneration += 1
        let generation = outputPreviewGeneration
        let clamped = min(max(time, candidate.start), max(candidate.start, candidate.end - 0.05))

        outputPreviewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run { self.isRenderingPreview = true }
            do {
                try self.project.paths.createDirectories()
                let destination = self.project.paths.renderDir
                    .appendingPathComponent("preview-\(candidate.id.uuidString).jpg")
                let service = try ExportService()

                // Burn the caption under the playhead into the preview, the
                // same way the export does — as one static cue, because the
                // ass filter sees t=0 on a single-frame render, not clip time.
                var assURL: URL?
                if self.project.exportSettings.captionMode.burnsIn {
                    let clipTime = clamped - candidate.start
                    if var active = self.captionLines(for: candidate)
                        .last(where: { clipTime >= $0.start && clipTime < $0.end }) {
                        active.start = 0
                        active.end = 10
                        var style = candidate.styleOverride ?? self.project.captionStyle
                        style.karaoke = false
                        let url = self.project.paths.renderDir
                            .appendingPathComponent("preview-caption-\(candidate.id.uuidString).ass")
                        try ASSBuilder.makeFile(lines: [active], style: style)
                            .write(to: url, atomically: true, encoding: .utf8)
                        assURL = url
                    }
                }
                try await service.renderPreviewFrame(candidate: candidate, source: self.project.sourceURL,
                                                     media: media, time: clamped,
                                                     assURL: assURL, destination: destination)
                let image = NSImage(contentsOf: destination)
                guard generation == self.outputPreviewGeneration else { return }
                self.outputPreviewImage = image
                self.isRenderingPreview = false
            } catch {
                if generation == self.outputPreviewGeneration { self.isRenderingPreview = false }
            }
        }
    }

    func toggleOutputPreview(for candidate: ShortCandidate?, at time: Double) {
        showsOutputPreview.toggle()
        if showsOutputPreview, let candidate {
            refreshOutputPreview(for: candidate, at: time)
        } else {
            outputPreviewImage = nil
        }
    }

    /// Copies one clip's framing onto every candidate — the usual case, since
    /// the webcam sits in the same place all stream.
    func applyLayoutToAllShorts(_ layout: ShortLayout) {
        for index in shorts.indices { shorts[index].layout = layout }
        project.defaultShortLayout = layout
        persist()
        persistShorts()
        append("Applied \(layout.mode.label) framing to all \(shorts.count) clips")
    }

    func updateCaptionStyle(_ style: CaptionStyle) {
        let reshapesCues = style.grouping != project.captionStyle.grouping
            || style.wordsPerCue != project.captionStyle.wordsPerCue
            || style.uppercase != project.captionStyle.uppercase
        project.captionStyle = style
        persist()
        if reshapesCues { rebuildPreviewCues() }
    }

    func updateExportSettings(_ settings: ExportSettings) {
        project.exportSettings = settings
        persist()
    }

    /// Saved options win over shipped defaults on load, so there has to be a
    /// way back when a default improves.
    func resetAnalysisSettings() {
        project.scoreWeights = .standard
        project.candidateOptions = .standard
        persist()
        analyzeShorts()
    }

    func importChat(from url: URL) {
        do {
            let messages = try ChatReplay.load(from: url)
            chat = messages
            project.chatPath = url.path
            persist()
            append("Loaded \(messages.count) chat messages")
            if canAnalyze { analyzeShorts() }
        } catch {
            append("Chat import failed: \(error.localizedDescription)")
            statusDetail = error.localizedDescription
        }
    }

    func clearChat() {
        chat = []
        project.chatPath = nil
        persist()
        if canAnalyze { analyzeShorts() }
    }

    func captionLines(for candidate: ShortCandidate) -> [CaptionLine] {
        CaptionBuilder.lines(for: candidate, transcript: transcript,
                             style: candidate.styleOverride ?? project.captionStyle)
    }

    /// Sentence-level lines for the caption editor — corrections are made once
    /// per transcript segment, not once per rendered phrase.
    func editableCaptionLines(for candidate: ShortCandidate) -> [CaptionLine] {
        CaptionBuilder.editableLines(for: candidate, transcript: transcript,
                                     style: candidate.styleOverride ?? project.captionStyle)
    }

    private func persistAnalysis() {
        let paths = project.paths
        try? JSONEncoder().encode(scoreCurve).write(to: paths.score, options: .atomic)
        persistShorts()
        persist()
    }

    private func persistShorts() {
        try? JSONEncoder().encode(shorts).write(to: project.paths.shorts, options: .atomic)
    }

    // MARK: - Phase 2: export

    func exportShort(_ candidate: ShortCandidate, to destination: URL) {
        guard !isExporting else { return }
        Task { [weak self] in
            try? await self?.performExport(candidate, to: destination)
        }
    }

    @discardableResult
    private func performExport(_ candidate: ShortCandidate, to destination: URL) async throws -> ExportResult {
        guard let media = project.media else { throw ExportError.noMediaInfo }
        isExporting = true
        exportProgress = 0
        lastExport = nil

        do {
            let service = try ExportService()
            let style = candidate.styleOverride ?? project.captionStyle
            let lines = captionLines(for: candidate)
            try project.paths.createDirectories()

            let result = try await service.exportShort(
                candidate: candidate,
                source: project.sourceURL,
                media: media,
                lines: lines,
                style: style,
                settings: project.exportSettings,
                tuning: project.audioTuning,
                speech: project.audioTuning.needsSpeechKey ? speechIntervals(for: candidate) : [],
                destination: destination,
                workingDirectory: project.paths.renderDir,
                onProgress: { [weak self] progress in
                    Task { @MainActor in self?.exportProgress = progress }
                },
                onLog: { [weak self] line in
                    Task { @MainActor in self?.append(line) }
                }
            )

            isExporting = false
            lastExport = result
            var updated = candidate
            updated.exportedPath = result.url.path
            updated.status = .accepted
            update(updated)

            let speed = result.averageFPS.map { String(format: " · %.0f fps", $0) } ?? ""
            append("Exported \(result.url.lastPathComponent) in \(String(format: "%.1fs", result.elapsed))\(speed) using \(result.encoderName)")
            if !result.usedHardwareEncoder {
                append("Warning: hardware encoder was not confirmed in ffmpeg output")
            }
            return result
        } catch {
            isExporting = false
            statusDetail = error.localizedDescription
            append("Export failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Renders the top-scoring candidates to a directory without any UI.
    func runHeadlessExports(to directory: URL, count: Int) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ranked = shorts.sorted { $0.score > $1.score }.prefix(max(1, count))
        for (index, candidate) in ranked.enumerated() {
            let name = String(format: "short-%02d-%d.mp4", index + 1, Int(candidate.start))
            let destination = directory.appendingPathComponent(name)
            LaunchOptions.report("Exporting \(name) — \(candidate.start.timecode) +\(String(format: "%.1fs", candidate.duration))")
            do {
                let result = try await performExport(candidate, to: destination)
                LaunchOptions.report("  \(result.encoderName) · hardware=\(result.usedHardwareEncoder) · \(String(format: "%.1fs", result.elapsed)) · \(ByteCountFormatter.string(fromByteCount: result.sizeBytes, countStyle: .file))")
            } catch {
                LaunchOptions.report("  FAILED: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Editing

    /// Whisper mishears slang, usernames and game terms constantly. Fixing a
    /// line here rewrites the transcript itself, so the correction reaches
    /// captions, scoring and every export rather than one clip.
    func updateTranscriptLine(id: Int, text: String) {
        guard let index = transcript.segments.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != transcript.segments[index].text else { return }

        let segment = transcript.segments[index]
        transcript.segments[index].text = trimmed
        // The original word timings described different words; an even split
        // keeps karaoke highlighting roughly in sync.
        transcript.segments[index].words = CaptionBuilder.redistribute(
            text: trimmed, from: segment.start, to: segment.end
        )
        rebuildPreviewCues()
        scheduleTranscriptPersist()
    }

    private func scheduleTranscriptPersist() {
        transcriptPersistTask?.cancel()
        transcriptPersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                try? JSONEncoder().encode(self.transcript)
                    .write(to: self.project.paths.mergedTranscript, options: .atomic)
            }
        }
    }

    /// The vocabulary hint whisper gets: the user's own terms, plus the most
    /// active chatters' usernames — exactly the names the streamer keeps
    /// saying out loud, and exactly what whisper mangles without help.
    func effectiveVocabulary() -> String {
        var parts: [String] = []
        let user = project.vocabularyPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty { parts.append(user) }
        if !chat.isEmpty {
            var counts: [String: Int] = [:]
            for message in chat { counts[message.author, default: 0] += 1 }
            let top = counts.sorted { $0.value > $1.value }.prefix(20).map(\.key)
                .filter { !user.localizedCaseInsensitiveContains($0) }
            if !top.isEmpty { parts.append(top.joined(separator: ", ")) }
        }
        return parts.joined(separator: ", ")
    }

    /// Throws the transcript away and redoes it with the current vocabulary,
    /// chat names and decoder settings. Needed because resume treats existing
    /// chunk transcripts as done — improved settings would otherwise never
    /// apply to a finished project.
    func retranscribe(maxAccuracy: Bool = false) {
        guard !isRunning else { return }
        try? FileManager.default.removeItem(at: project.paths.transcriptDir)
        project.completedChunkIndices = []
        project.transcriptionElapsedSeconds = nil
        project.useAccurateTranscription = maxAccuracy
        persist()
        let model = ToolLocator.preferredModel(accurate: maxAccuracy)
        append("Re-transcribing with \(model?.displayName ?? "?") · beam 8\(maxAccuracy ? " + tuned fallback" : "")"
               + (chat.isEmpty ? "" : " and \(min(chat.count, 20)) chat names"))
        startIngest()
    }

    // MARK: - Transcript polish

    /// Where the manual polish loop is up to: index of the first line the next
    /// copied batch starts from.
    @Published private(set) var polishCursor = 0
    @Published private(set) var polishError: String?

    var canPolish: Bool { !transcript.isEmpty }

    /// What the next Copy-batch button covers, nil when the whole transcript
    /// has been through.
    var nextPolishBatch: Range<Int>? {
        guard polishCursor < transcript.segments.count else { return nil }
        return polishCursor..<min(polishCursor + TranscriptPolisher.batchSize,
                                  transcript.segments.count)
    }

    /// The prompt for the next batch of lines. Applying only line-level text
    /// corrections keeps timing untouched; a correction with the same word
    /// count even keeps its per-word DTW timing.
    func polishPrompt() -> String? {
        guard let batch = nextPolishBatch else { return nil }
        let lines = transcript.segments[batch].map { (id: $0.id, text: $0.text) }
        return TranscriptPolisher.manualPrompt(segments: lines,
                                               vocabulary: effectiveVocabulary())
    }

    /// Applies a pasted corrections reply and advances the cursor to the next
    /// batch.
    func applyPolishReply(_ reply: String) throws -> String {
        polishError = nil
        do {
            let corrections = try TranscriptPolisher.parseReply(reply)
            var applied = 0
            for correction in corrections {
                guard let position = transcript.segments
                    .firstIndex(where: { $0.id == correction.id }) else { continue }
                let fixed = TranscriptPolisher.corrected(
                    segment: transcript.segments[position], text: correction.text)
                if fixed != transcript.segments[position] {
                    transcript.segments[position] = fixed
                    applied += 1
                }
            }
            let covered = nextPolishBatch
            polishCursor = covered?.upperBound ?? transcript.segments.count
            try? JSONEncoder().encode(transcript)
                .write(to: project.paths.mergedTranscript, options: .atomic)
            rebuildPreviewCues()
            analyzeShorts()
            append("Polish: corrected \(applied) lines in this batch")
            let remaining = transcript.segments.count - polishCursor
            return remaining > 0
                ? "\(applied) lines fixed. \(remaining) lines left — copy the next batch."
                : "\(applied) lines fixed. Whole transcript done."
        } catch {
            polishError = error.localizedDescription
            append("Polish reply failed: \(error.localizedDescription)")
            throw error
        }
    }

    func restartPolish() { polishCursor = 0 }

    func updateVocabulary(_ text: String) {
        project.vocabularyPrompt = text
        persist()
    }

    func updateName(_ name: String) {
        project.name = name
        persist()
    }

    private func persist() {
        try? store.save(project)
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 400 { log.removeFirst(log.count - 400) }
        LaunchOptions.report(line)
    }

    private var lastReportedProgress: Double = -1

    private func reportProgress() {
        guard LaunchOptions.isHeadlessRun else { return }
        guard stageProgress - lastReportedProgress >= 0.05 || stageProgress >= 1 else { return }
        lastReportedProgress = stageProgress
        LaunchOptions.report("  \(project.stage.label): \(Int(stageProgress * 100))% \(statusDetail)")
    }

    private func setStage(_ stage: IngestStage, detail: String = "") {
        project.stage = stage
        lastReportedProgress = -1
        stageProgress = 0
        statusDetail = detail
        persist()
        LaunchOptions.report("STAGE \(stage.label)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    // MARK: - Pipeline

    func startIngest() {
        guard !isRunning else { return }
        guard project.sourceExists else {
            fail(with: "Source file no longer exists at \(project.sourcePath)")
            return
        }
        isRunning = true
        project.lastError = nil
        log.removeAll()

        pipeline = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runPipeline()
            } catch is CancellationError {
                await MainActor.run {
                    self.append("Cancelled. Completed work is kept — re-running resumes.")
                    self.isRunning = false
                    self.statusDetail = "Cancelled"
                    self.persist()
                }
            } catch {
                await MainActor.run { self.fail(with: error.localizedDescription) }
            }
        }
    }

    func cancelIngest() {
        pipeline?.cancel()
        pipeline = nil
    }

    /// Awaitable form, for the batch runner. The UI path stays fire-and-forget.
    func runIngestToCompletion() async {
        startIngest()
        await pipeline?.value
    }

    private func fail(with message: String) {
        project.stage = .failed
        project.lastError = message
        isRunning = false
        statusDetail = message
        append("Error: \(message)")
        persist()

        if LaunchOptions.exitsAfterIngest {
            LaunchOptions.report("INGEST FAILED")
            exit(1)
        }
    }

    private func runPipeline() async throws {
        let ffmpeg = try FFmpegService()
        let paths = project.paths
        try paths.createDirectories()

        // 1. Probe
        if project.media == nil {
            setStage(.probing, detail: "Reading media info")
            var info = try await ffmpeg.probe(project.sourceURL)
            // A playlist has no file size of its own; show what the video would
            // have weighed, since that's the number worth knowing.
            if let estimated = project.remote?.fullVideoBytes {
                info.sizeBytes = estimated
            }
            project.media = info
            append("\(info.resolutionLabel) @ \(String(format: "%.0f", info.fps))fps · \(info.durationSeconds.timecode) · \(info.sizeLabel)")
            persist()
        }
        guard let media = project.media, media.durationSeconds > 0 else {
            throw FFmpegError.probeFailed("Zero duration")
        }
        try Task.checkCancellation()

        // 2. Extract 16 kHz mono audio
        if !audioIsComplete(paths.fullAudio, duration: media.durationSeconds) {
            // A streamed project fetches the audio-only rendition rather than
            // the video: on the test VOD that's 388 MB instead of 9.31 GB, and
            // it's all transcription ever needed.
            var audioSource = project.sourceURL
            if let remote = project.remote, let playlist = remote.audioPlaylistURL {
                setStage(.extractingAudio, detail: "Fetching audio")
                audioSource = try await fetchSegments(
                    playlist: playlist,
                    into: paths.remoteSegments,
                    label: "audio"
                ) { [weak self] progress in
                    self?.stageProgress = progress.fraction * 0.9
                }
            }

            statusDetail = "Decoding audio"
            try await ffmpeg.extractAudio(from: audioSource, to: paths.fullAudio,
                                          totalDuration: media.durationSeconds) { [weak self] progress in
                Task { @MainActor in
                    self?.stageProgress = self?.project.isStreamed == true
                        ? 0.9 + progress * 0.1
                        : progress
                }
            }
            append("Extracted audio to \(paths.fullAudio.lastPathComponent)")
            // The fetched segments have done their job once the 16 kHz copy
            // exists, and they're the bulk of what a streamed project holds.
            if project.isStreamed { try? FileManager.default.removeItem(at: paths.remoteSegments) }
        }
        try Task.checkCancellation()

        // 3. Silence map
        if silence.isEmpty || !FileManager.default.fileExists(atPath: paths.silence.path) {
            setStage(.detectingSilence, detail: "Scanning for dead air")
            let intervals = try await ffmpeg.detectSilence(in: paths.fullAudio,
                                                           totalDuration: media.durationSeconds) { [weak self] progress in
                Task { @MainActor in self?.stageProgress = progress }
            }
            silence = intervals
            try? JSONEncoder().encode(intervals).write(to: paths.silence, options: .atomic)
            append("Found \(intervals.count) silent stretches")
        }
        try Task.checkCancellation()

        // 4. Waveform peaks
        if waveform == nil || !FileManager.default.fileExists(atPath: paths.waveform.path) {
            setStage(.generatingWaveform, detail: "Building waveform")
            let peaksPerSecond = project.waveformPeaksPerSecond
            let destination = paths.waveform
            let source = paths.fullAudio
            let data = try await Task.detached(priority: .userInitiated) {
                try WaveformService.generate(from: source, to: destination,
                                             peaksPerSecond: peaksPerSecond) { progress in
                    Task { @MainActor in self.stageProgress = progress }
                }
            }.value
            waveform = data
            project.waveformPeakCount = data.peaks.count
            append("Waveform: \(data.peaks.count) peaks")
            persist()
        }
        try Task.checkCancellation()

        // 5. Chunk plan
        if project.chunkPlan.isEmpty || !chunkAudioComplete() {
            setStage(.transcribing, detail: "Splitting audio into chunks")
            let cuts = FFmpegService.planCutPoints(duration: media.durationSeconds,
                                                   targetChunk: targetChunkSeconds,
                                                   silence: silence)
            let specs = try await ffmpeg.splitIntoChunks(wav: paths.fullAudio,
                                                        chunksDirectory: paths.chunksDir,
                                                        cutPoints: cuts)
            project.chunkPlan = specs
            project.completedChunkIndices = []
            append("Split into \(specs.count) chunks (~\(Int(targetChunkSeconds / 60)) min each)")
            persist()
        }
        try Task.checkCancellation()

        // 6. Transcribe, resuming past chunks already on disk
        let whisper = try WhisperService()
        guard let model = ToolLocator.preferredModel(accurate: project.useAccurateTranscription)
        else { throw WhisperError.noModel }
        project.modelFileName = model.id
        setStage(.transcribing, detail: "Transcribing with \(model.displayName)")

        // A chunk counts as done only if its JSON actually parses. Existence is
        // not enough: a run killed mid-write leaves a zero-byte or truncated
        // file, which the old check accepted — and then the merge threw
        // "data couldn't be read", failing the whole project over one chunk
        // that just needed doing again.
        var completed = project.completedChunkIndices
        var discarded = 0
        for spec in project.chunkPlan {
            let url = paths.chunkTranscript(spec.index)
            guard FileManager.default.fileExists(atPath: url.path) else {
                completed.remove(spec.index)
                continue
            }
            if (try? WhisperJSON.parse(data: Data(contentsOf: url), timeOffset: 0, startingID: 0)) != nil {
                completed.insert(spec.index)
            } else {
                try? FileManager.default.removeItem(at: url)
                completed.remove(spec.index)
                discarded += 1
            }
        }
        if discarded > 0 {
            append("Discarded \(discarded) unreadable chunk transcript(s) — they'll be redone")
        }
        project.completedChunkIndices = completed
        persist()

        let started = Date()
        var didRunAnyChunk = false

        for spec in project.chunkPlan {
            try Task.checkCancellation()
            if project.completedChunkIndices.contains(spec.index) { continue }

            didRunAnyChunk = true
            let index = spec.index
            let total = project.chunkPlan.count
            statusDetail = "Chunk \(index + 1) of \(total) · \(spec.startSeconds.timecode)"
            stageProgress = Double(index) / Double(total)

            let info = try await whisper.transcribe(
                chunkAudio: paths.chunkAudio(index),
                outputBase: paths.chunkTranscriptBase(index),
                model: model,
                prompt: effectiveVocabulary(),
                language: project.language,
                chunkDuration: spec.durationSeconds,
                accuracy: project.useAccurateTranscription,
                onProgress: { [weak self] inner in
                    Task { @MainActor in
                        guard let self else { return }
                        self.stageProgress = (Double(index) + inner) / Double(total)
                    }
                },
                onLog: { [weak self] line in
                    Task { @MainActor in self?.append(line) }
                }
            )

            if backendNote == nil {
                backendNote = info.usedMetal
                    ? "Metal GPU\(info.gpuName.map { " · \($0)" } ?? "")"
                    : "CPU only — Metal backend did not load"
                append(backendNote ?? "")
            }

            project.completedChunkIndices.insert(index)
            persist()
        }

        if didRunAnyChunk {
            project.transcriptionElapsedSeconds = Date().timeIntervalSince(started)
        }

        // 7. Merge
        setStage(.merging, detail: "Merging transcript")
        var segments: [TranscriptSegment] = []
        for spec in project.chunkPlan {
            let url = paths.chunkTranscript(spec.index)
            guard let data = try? Data(contentsOf: url) else { continue }
            let parsed = try WhisperJSON.parse(data: data,
                                               timeOffset: spec.startSeconds,
                                               startingID: segments.count)
            segments.append(contentsOf: parsed)
        }
        let merged = Transcript(segments: segments)
        try JSONEncoder().encode(merged).write(to: paths.mergedTranscript, options: .atomic)
        transcript = merged
        project.transcriptSegmentCount = segments.count
        rebuildPreviewCues()

        setStage(.ready, detail: "Ready")
        isRunning = false
        append("Transcript: \(segments.count) segments")
        if let speed = project.transcriptionSpeedLabel { append("Transcription speed: \(speed)") }
        persist()

        // Scoring is cheap and reads only what ingest just produced, so a
        // finished project arrives with candidates already waiting. The
        // long-form pass only runs when there's no edit to clobber.
        if let chatFile = LaunchOptions.chatPath, chat.isEmpty {
            importChat(from: URL(fileURLWithPath: chatFile))
        }
        if LaunchOptions.wantsSceneDetection, scenes.isEmpty {
            detectScenes()
            while isDetectingScenes {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        if let styleFile = LaunchOptions.stylePath {
            analyzeStyle(reference: URL(fileURLWithPath: styleFile))
            while isAnalyzingStyle {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            applyStyleProfile()
        }
        if canAnalyze {
            analyzeShorts()
            if longForm.segments.isEmpty { generateLongForm() }
        }
        if let output = LaunchOptions.thumbnailOutput {
            extractFrames()
            while isExtractingFrames { try? await Task.sleep(nanoseconds: 300_000_000) }
            if let text = LaunchOptions.thumbnailText {
                var draft = project.thumbnail
                draft.text = text
                updateThumbnail(draft)
            }
            LaunchOptions.report("Thumbnail background: \(thumbnailBackgroundURL?.lastPathComponent ?? "none")")
            exportThumbnail(to: URL(fileURLWithPath: output))
            // exportThumbnail is fire-and-forget; wait for the file to appear.
            for _ in 0..<60 where !FileManager.default.fileExists(atPath: output) {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            LaunchOptions.report("THUMBNAIL COMPLETE")
        }
        if LaunchOptions.wantsAudioTuning {
            measureAudio()
            while isMeasuringAudio { try? await Task.sleep(nanoseconds: 500_000_000) }
            applyRecommendedTuning()
            previewTuning()
            while isMeasuringAudio { try? await Task.sleep(nanoseconds: 500_000_000) }
        }

        if LaunchOptions.exitsAfterIngest {
            LaunchOptions.report("INGEST COMPLETE")
            if let directory = LaunchOptions.exportDirectory {
                await runHeadlessExports(to: URL(fileURLWithPath: directory),
                                         count: LaunchOptions.exportCount)
                LaunchOptions.report("EXPORTS COMPLETE")
            }
            if let output = LaunchOptions.longFormOutput {
                LaunchOptions.report("Long-form: \(longForm.included.count) segments · \(assembled.pieces.count) pieces · \(longFormDurationLabel)")
                do {
                    let result = try await performLongFormExport(to: URL(fileURLWithPath: output))
                    LaunchOptions.report("  \(result.encoderName) · hardware=\(result.usedHardwareEncoder) · \(String(format: "%.0fs", result.elapsed)) · \(ByteCountFormatter.string(fromByteCount: result.sizeBytes, countStyle: .file))")
                } catch {
                    LaunchOptions.report("  LONGFORM FAILED: \(error.localizedDescription)")
                }
                LaunchOptions.report("LONGFORM COMPLETE")
            }
            exit(0)
        }
    }

    // MARK: - Helpers

    /// Whether the extracted audio covers the whole source.
    ///
    /// Existence isn't enough. Over the network the extract takes twenty
    /// minutes, and an interrupted one leaves a perfectly valid WAV holding the
    /// first few minutes — which the old "is the file there" check would accept,
    /// producing a transcript of the opening and nothing else. 16 kHz mono
    /// 16-bit is exactly 32000 bytes per second, so the file's own size says how
    /// much audio it holds.
    private func audioIsComplete(_ url: URL, duration: Double) -> Bool {
        guard duration > 0 else { return fileExists(url, minimumBytes: 1024) }
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return false }
        let expected = duration * 32000
        return Double(size) >= expected * 0.98
    }

    private func fileExists(_ url: URL, minimumBytes: Int) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return false }
        return size >= minimumBytes
    }

    private func chunkAudioComplete() -> Bool {
        project.chunkPlan.allSatisfy {
            FileManager.default.fileExists(atPath: project.paths.chunkAudio($0.index).path)
        }
    }

    /// Frees the biggest artifact once transcription is done — the chunk WAVs
    /// and full WAV are re-derivable from the source and dominate disk use.
    func purgeIntermediateAudio() {
        let paths = project.paths
        try? FileManager.default.removeItem(at: paths.chunksDir)
        try? FileManager.default.removeItem(at: paths.fullAudio)
        append("Removed intermediate audio")
    }
}

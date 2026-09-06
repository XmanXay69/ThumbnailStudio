import SwiftUI
import AppKit

struct ProjectView: View {
    /// Borrowed from the registry, never owned: the session (and any ingest
    /// it's running) survives this view being torn down by navigation.
    @ObservedObject private var session: ProjectSession
    @StateObject private var player = PlayerController()

    @State private var zoomSeconds: Double = 60
    @State private var showInspector = true
    @State private var vocabularyDraft: String
    /// Which tab you were last on — reopening a project on Browse when you
    /// left it mid-edit was a papercut.
    @AppStorage("projectMode") private var mode: EditorMode = .browse
    @State private var captionStyleDraft: CaptionStyle
    @State private var showCaptionPreview = true
    @State private var showAutoClipPrompt = false

    enum EditorMode: String, CaseIterable {
        // String-backed so @AppStorage can persist it.
        case browse, shorts, editor, longform, thumb, publish

        var label: String {
            switch self {
            case .browse: return "Browse"
            case .shorts: return "Shorts"
            case .editor: return "Editor"
            case .longform: return "Long-form"
            case .thumb: return "Thumb"
            case .publish: return "Publish"
            }
        }

        var icon: String {
            switch self {
            case .browse: return "rectangle.and.text.magnifyingglass"
            case .shorts: return "rectangle.portrait.on.rectangle.portrait"
            case .editor: return "timeline.selection"
            case .longform: return "film.stack"
            case .thumb: return "photo.on.rectangle.angled"
            case .publish: return "paperplane"
            }
        }
    }

    init(project: VODProject, store: ProjectStore) {
        session = SessionRegistry.shared.session(for: project, store: store)
        _vocabularyDraft = State(initialValue: project.vocabularyPrompt)
        _captionStyleDraft = State(initialValue: project.captionStyle)
    }

    var body: some View {
        HStack(spacing: 0) {
            modeRail
            VStack(spacing: 0) {
                headerBar
                Group {
                    switch mode {
                    case .browse: browsePane
                    case .shorts: ShortsPane(session: session, player: player,
                                             onOpenEditor: { mode = .editor })
                    case .editor: ClipEditorPane(session: session, player: player)
                    case .longform: LongFormPane(session: session, player: player,
                                                 onOpenEditor: { mode = .editor })
                    case .thumb: ThumbnailStudioPane(
                        store: session,
                        frameSource: ProjectFrameSource(session: session, player: player))
                    case .publish: PublishPane(session: session)
                    }
                }
                .transition(.opacity)
                .animation(.easeOut(duration: 0.15), value: mode)
                .clipped()
                .padding(12)
            }
        }
        .onChange(of: mode) { _, newMode in
            // Long-form previews an AVComposition; the other modes scrub the
            // source file, so the player's asset is swapped on the way out.
            player.pause()
            if newMode != .longform, newMode != .editor, newMode != .thumb,
               let url = session.project.playbackURL {
                player.load(url: url)
            }
        }
        .background(Theme.background)
        .inspector(isPresented: Binding(
            get: { showInspector && mode == .browse },
            set: { showInspector = $0 }
        )) {
            InspectorPane(session: session,
                          vocabularyDraft: $vocabularyDraft,
                          captionStyleDraft: $captionStyleDraft,
                          showCaptionPreview: $showCaptionPreview)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 400)
        }
        .onAppear {
            // A streamed project plays from the CDN: AVFoundation can't open a
            // local playlist whose segments are remote.
            if let url = session.project.playbackURL { player.load(url: url) }
            offerAutoClips()
            consumePendingSeek()
            // A project stranded mid-ingest (the app quit or crashed under
            // it) picks itself back up — every stage resumes from disk.
            if !session.isReady, !session.isRunning,
               session.project.stage != .created, session.project.stage != .failed,
               !LaunchOptions.isHeadlessRun {
                session.startIngest()
            }
        }
        .onReceive(ProjectStore.shared.$pendingSeek) { _ in consumePendingSeek() }
        .onChange(of: session.isReady) { _, _ in offerAutoClips() }
        .sheet(isPresented: $showAutoClipPrompt) {
            AutoClipSheet(session: session)
                .frame(width: 560, height: 640)
        }
        .onDisappear {
            player.pause()
        }
    }

    // MARK: - Mode rail and header (UI v2)

    /// The vertical tool rail — the app's new silhouette. One icon per
    /// mode, gradient pill on the active one, ⌘1–⌘6 to jump.
    private var modeRail: some View {
        VStack(spacing: 6) {
            ForEach(Array(EditorMode.allCases.enumerated()), id: \.element) { index, target in
                Button {
                    mode = target
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: target.icon)
                            .font(.system(size: 16, weight: .medium))
                        Text(target.label)
                            .font(.system(size: 8, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(mode == target ? .white : Theme.textFaint)
                    .frame(width: 52, height: 46)
                    .background {
                        if mode == target {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Theme.accentGradient)
                                .shadow(color: Theme.accent.opacity(0.4), radius: 6)
                        }
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .disabled(!session.isReady && target != .browse)
                .help("\(target.label) (⌘\(index + 1))")
            }
            Spacer()
            Button {
                importChat()
            } label: {
                Image(systemName: session.chat.isEmpty ? "bubble.left" : "bubble.left.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(session.chat.isEmpty ? Theme.textFaint : Theme.accent)
                    .frame(width: 52, height: 34)
            }
            .buttonStyle(.plain)
            .help(session.chat.isEmpty
                  ? "Import Twitch chat replay JSON"
                  : "\(session.chat.count) chat messages loaded")
            if mode == .browse {
                Button {
                    showInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textFaint)
                        .frame(width: 52, height: 34)
                }
                .buttonStyle(.plain)
                .help("Toggle inspector")
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 5)
        .frame(width: 62)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.25))
    }

    /// Who and what you're working on, always in view.
    private var headerBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.project.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    if let media = session.project.media {
                        Text(media.durationSeconds.shortTimecode)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textFaint)
                    }
                    Text(session.project.stage.label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(session.isReady ? Theme.positive : Theme.warning)
                    if !session.project.clientName.isEmpty {
                        Text(session.project.clientName)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.accent.opacity(0.15))
                            .clipShape(Capsule())
                            .lineLimit(1)
                            .frame(maxWidth: 160)
                    }
                }
            }
            Spacer(minLength: 20)
            if session.isRankingBangers {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(session.bangerStatus.isEmpty ? "ranking…" : session.bangerStatus)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            let flames = session.shorts.filter {
                ($0.marketability ?? 0) >= BangerService.bangerThreshold
            }.count
            if flames > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "flame.fill").font(.system(size: 10))
                    Text("\(flames)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(.orange)
                .help("\(flames) banger\(flames == 1 ? "" : "s") found — Shorts tab, Hottest first")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.surface.opacity(0.6))
    }

    /// Global search landed here: jump to the moment it found, once.
    private func consumePendingSeek() {
        guard let pending = ProjectStore.shared.pendingSeek,
              pending.projectID == session.project.id else { return }
        ProjectStore.shared.pendingSeek = nil
        mode = .browse
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            player.seek(to: pending.time, precise: true)
        }
    }

    /// Offered once per project, right after ingest lands — and never again
    /// unless asked for from the Shorts tab.
    private func offerAutoClips() {
        guard session.isReady, !session.transcript.isEmpty,
              !session.project.autoClipPromptShown,
              !LaunchOptions.isHeadlessRun else { return }
        showAutoClipPrompt = true
    }

    /// Chat replay is optional, but for IRL and Just Chatting content message
    /// density beats audio energy as an excitement signal.
    private func importChat() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a Twitch chat replay JSON (TwitchDownloaderCLI export)"
        if let last = UserDefaults.standard.string(forKey: "lastChatFolder") {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "lastChatFolder")
        session.importChat(from: url)
    }

    private var browsePane: some View {
        VStack(spacing: 12) {
            playerSection
            transportBar

            WaveformScrubber(
                waveform: session.waveform,
                silence: session.silence,
                duration: displayDuration,
                currentTime: player.currentTime,
                zoomSeconds: $zoomSeconds,
                onSeek: { time, precise in player.seek(to: time, precise: precise) }
            )

            HStack(alignment: .top, spacing: 12) {
                TranscriptPane(
                    transcript: session.transcript,
                    currentTime: player.currentTime,
                    onSeek: { player.seek(to: $0, precise: true) },
                    onEdit: { id, text in session.updateTranscriptLine(id: id, text: text) },
                    speakerGuesses: session.speakerGuesses.reliable
                        ? session.speakerGuesses.isYou : nil,
                    onLabelSpeakers: { session.labelSpeakers() }
                )
                .frame(minHeight: 180)

                if !session.isReady || session.isRunning {
                    IngestPanel(session: session)
                        .frame(width: 320)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var displayDuration: Double {
        session.project.media?.durationSeconds ?? player.duration
    }

    // MARK: - Player

    private var playerSection: some View {
        ZStack {
            PlayerSurface(player: player.player)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Live WYSIWYG captions — the styling values are abstract numbers
            // until you can see them on the video.
            if showCaptionPreview, session.project.exportSettings.captionMode != .none {
                CaptionOverlay(
                    line: CaptionPreview.line(at: player.currentTime, in: session.previewCues),
                    style: captionStyleDraft,
                    time: player.currentTime,
                    referenceHeight: 1080
                )
                .padding(.bottom, 34)   // clear of AVPlayerView's inline controls
            }

            if !session.project.sourceExists {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.warning)
                    Text("Source file not found")
                        .foregroundStyle(Theme.textPrimary)
                    Text(session.project.sourcePath)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
                .padding()
                .background(Theme.surface.opacity(0.95))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(minHeight: 280)
    }

    private var transportBar: some View {
        HStack(spacing: 12) {
            Button { player.skip(-10) } label: { Image(systemName: "gobackward.10") }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .keyboardShortcut(.space, modifiers: [])
            Button { player.skip(10) } label: { Image(systemName: "goforward.10") }
                .keyboardShortcut(.rightArrow, modifiers: [])

            Text(player.currentTime.timecode)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
            Text("/ \(displayDuration.timecode)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textFaint)

            Spacer()

            Picker("Speed", selection: $player.rate) {
                Text("0.5×").tag(Float(0.5))
                Text("1×").tag(Float(1.0))
                Text("1.5×").tag(Float(1.5))
                Text("2×").tag(Float(2.0))
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 200)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 2)
    }
}

// MARK: - Inspector

private struct InspectorPane: View {
    @ObservedObject var session: ProjectSession
    @Binding var vocabularyDraft: String
    @Binding var captionStyleDraft: CaptionStyle
    @Binding var showCaptionPreview: Bool
    @State private var artifactSize: Int64 = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CaptionSettingsPanel(session: session,
                                     styleDraft: $captionStyleDraft,
                                     showPreview: $showCaptionPreview)

                AudioTuningPanel(session: session)

                StyleMatchPanel(session: session)

                if let media = session.project.media {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: "Source")
                        if let remote = session.project.remote {
                            Label("Streamed — not downloaded", systemImage: "antenna.radiowaves.left.and.right")
                                .font(.caption)
                                .foregroundStyle(Theme.positive)
                            if let saved = remote.savedBytes {
                                Text("\(ByteCountFormatter.string(fromByteCount: saved, countStyle: .file)) of video stayed on Twitch. Exports pull only the parts you keep.")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textFaint)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        InfoRow("Duration", media.durationSeconds.timecode)
                        InfoRow("Resolution", "\(media.resolutionLabel) @ \(String(format: "%.0f", media.fps))fps")
                        InfoRow("Video", media.videoCodec)
                        InfoRow("Audio", "\(media.audioCodec) · \(media.audioChannels)ch · \(media.audioSampleRate / 1000)kHz")
                        InfoRow("Size", media.sizeLabel)
                    }
                    .panel()
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Vocabulary hint")
                    Text("Streamer and co-streamer names, game titles, recurring bits. Passed to whisper as an initial prompt to cut down misheard proper nouns.")
                        .font(.caption)
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                    TextEditor(text: $vocabularyDraft)
                        .font(.system(size: 12))
                        .frame(height: 90)
                        .scrollContentBackground(.hidden)
                        .background(Theme.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    HStack {
                        Spacer()
                        Button("Save") { session.updateVocabulary(vocabularyDraft) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(vocabularyDraft == session.project.vocabularyPrompt)
                    }
                    if session.isReady, vocabularyDraft != session.project.vocabularyPrompt {
                        Text("Changing this only affects future transcription runs.")
                            .font(.caption2)
                            .foregroundStyle(Theme.warning)
                    }
                }
                .panel()

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Transcription")
                    InfoRow("Model", session.project.modelFileName.map {
                        $0.replacingOccurrences(of: "ggml-", with: "").replacingOccurrences(of: ".bin", with: "")
                    } ?? "—")
                    InfoRow("Chunks", session.project.chunkPlan.isEmpty ? "—" :
                                "\(session.project.completedChunkIndices.count)/\(session.project.chunkPlan.count)")
                    InfoRow("Segments", "\(session.project.transcriptSegmentCount)")
                    if let speed = session.project.transcriptionSpeedLabel {
                        InfoRow("Speed", speed)
                    }
                    if let note = session.backendNote {
                        InfoRow("Backend", note)
                    }

                    // The ingest panel hides itself once a project is ready, so
                    // re-running has to be reachable from here.
                    if session.isReady, !session.isRunning {
                        Divider().overlay(Theme.border)
                        HStack {
                            Button("Re-run ingest") { session.startIngest() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            Button("Re-transcribe") { session.retranscribe() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Throws the transcript away and redoes it with wider beam search, the vocabulary hint, and chat usernames. Takes as long as the first transcription did.")
                            Button("Max accuracy") { session.retranscribe(maxAccuracy: true) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(!ToolLocator.hasAccurateModel)
                                .help(ToolLocator.hasAccurateModel
                                      ? "Re-transcribes with the full large-v3 model and an earlier sampling fallback — the best this machine can do, at roughly 3–4× the time."
                                      : "Needs the full large-v3 model — Setup has the download command.")
                        }
                        if !ToolLocator.hasAccurateModel {
                            Text("Max accuracy needs the full large-v3 model (~3 GB) — the download command is in Setup & Tools.")
                                .font(.caption2)
                                .foregroundStyle(Theme.textFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Divider().overlay(Theme.border)
                    if session.canPolish {
                        Text("Fix mishearings with Claude — manually, in batches: copy a batch prompt into a claude.ai chat (covered by your plan), paste the reply back, repeat. Only line-level corrections are applied; timing untouched.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                        ManualClaudePanel(
                            copyLabel: session.nextPolishBatch.map {
                                "Copy lines \($0.lowerBound + 1)–\($0.upperBound) of \(session.transcript.segments.count)"
                            } ?? "All lines done",
                            makePrompt: { session.polishPrompt() },
                            notReadyText: "The whole transcript has been through — Restart to run it again.",
                            apply: { try session.applyPolishReply($0) }
                        )
                        if session.polishCursor > 0 {
                            Button("Restart from the top") { session.restartPolish() }
                                .buttonStyle(.link)
                                .controlSize(.small)
                        }
                    } else if session.isReady {
                        Text("Transcribe first — polish reads the transcript.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .panel()

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Working files")
                    InfoRow("On disk", ByteCountFormatter.string(fromByteCount: artifactSize, countStyle: .file))
                    HStack {
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([session.project.paths.root])
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if session.isReady {
                            Button("Purge audio") {
                                session.purgeIntermediateAudio()
                                artifactSize = 0
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Deletes the extracted WAV and chunk files. They can be regenerated from the source.")
                        }
                    }
                }
                .panel()
            }
            .padding(12)
        }
        .background(Theme.background)
        .task(id: session.stage) {
            artifactSize = await Self.directorySize(of: session.project.paths.root)
        }
    }

    /// Walks the project folder off the main actor — a finished project holds
    /// hundreds of files.
    private static func directorySize(of root: URL) async -> Int64 {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
            var total: Int64 = 0
            for case let url as URL in enumerator {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return total
        }.value
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textFaint)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

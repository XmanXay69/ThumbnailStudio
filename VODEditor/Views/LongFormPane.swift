import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Phase 3 review surface: the assembled 25–30 minute cut, previewed through an
/// AVComposition so the player shows the real edit rather than the raw source.
struct LongFormPane: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var player: PlayerController

    var onOpenEditor: () -> Void = {}

    @State private var selectedID: UUID?
    @State private var pixelsPerSecond: Double = 6
    @State private var optionsDraft = LongFormOptions.standard

    private var included: [LongFormSegment] { session.longForm.included }
    private var binned: [LongFormSegment] { session.longForm.binned }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            bin.frame(width: 230)
            center
            inspector.frame(width: 290)
        }
        .onAppear {
            optionsDraft = session.project.longFormOptions
            loadPreview()
        }
        .onChange(of: session.previewComposition) { _, _ in loadPreview() }
    }

    /// The composition is rebuilt (debounced) after every edit, so the player is
    /// reloaded whenever a new one lands.
    private func loadPreview() {
        guard let composition = session.previewComposition else { return }
        let wasPlaying = player.isPlaying
        let position = player.currentTime
        player.load(asset: composition)
        if position > 0, position < session.assembled.duration {
            player.seek(to: position)
        }
        if wasPlaying { player.play() }
    }

    // MARK: - Bin

    private var bin: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel(text: "Not in cut")
                Spacer()
                Text("\(binned.count)")
                    .font(.caption)
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(10)

            Divider().overlay(Theme.border)

            if binned.isEmpty {
                Text("Everything is on the timeline.\nRemove a block to park it here.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textFaint)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(binned) { segment in
                            binRow(segment)
                                .draggable(segment.id.uuidString)
                                .onTapGesture { session.setIncluded(true, for: segment) }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        
        // Dropping a timeline block here removes it from the cut.
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let id = UUID(uuidString: raw),
                  let segment = session.longForm.segments.first(where: { $0.id == id }),
                  segment.isIncluded else { return false }
            session.setIncluded(false, for: segment)
            return true
        }
    }

    private func binRow(_ segment: LongFormSegment) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(segment.start.timecode)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
                Text(String(format: "%.0fs", segment.duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                Image(systemName: "plus.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
            }
            Text(segment.title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(Theme.surfaceRaised.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .help("Click or drag onto the timeline to include")
    }

    // MARK: - Centre

    private var center: some View {
        VStack(spacing: 10) {
            ZStack {
                PlayerSurface(player: player.player)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if session.assembled.isEmpty {
                    Text("Timeline is empty")
                        .foregroundStyle(Theme.textSecondary)
                        .padding()
                        .background(Theme.surface.opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if session.isBuildingPreview {
                    ProgressView("Rebuilding preview…")
                        .controlSize(.small)
                        .padding(10)
                        .background(Theme.surface.opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(minHeight: 240)

            transport

            TimelineTrack(
                segments: included,
                assembled: session.assembled,
                waveform: session.waveform,
                captionLines: session.longFormCaptionLines(),
                currentTime: player.currentTime,
                selectedID: $selectedID,
                pixelsPerSecond: $pixelsPerSecond,
                onSeek: { player.seek(to: $0) },
                onTrim: { id, start, end in
                    guard var segment = session.longForm.segments.first(where: { $0.id == id }) else { return }
                    segment.start = max(0, start)
                    segment.end = min(session.project.media?.durationSeconds ?? end, end)
                    session.updateLongFormSegment(segment)
                },
                onReorder: { id, target in session.moveLongFormSegment(id: id, before: target) },
                onRemove: { id in
                    guard let segment = session.longForm.segments.first(where: { $0.id == id }) else { return }
                    session.setIncluded(false, for: segment)
                },
                onDropFromBin: { id, target in
                    guard let segment = session.longForm.segments.first(where: { $0.id == id }) else { return }
                    session.setIncluded(true, for: segment)
                    session.moveLongFormSegment(id: id, before: target)
                }
            )
            .frame(minHeight: 190)
        }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 14)
            }
            Button { player.skip(-10) } label: { Image(systemName: "gobackward.10") }
            Button { player.skip(10) } label: { Image(systemName: "goforward.10") }

            Text("\(player.currentTime.timecode) / \(session.assembled.duration.timecode)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            runtimeBadge
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// The 25–30 minute band is the whole point of the long-form pass, so the
    /// current runtime is always on screen.
    private var runtimeBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: session.longFormOnTarget ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(session.longFormOnTarget ? Theme.positive : Theme.warning)
            Text(session.longFormDurationLabel)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(session.longFormOnTarget ? Theme.positive : Theme.warning)
            Text("target 25–30 min")
                .font(.caption2)
                .foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.surfaceRaised)
        .clipShape(Capsule())
    }

    // MARK: - Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Assembly")
                    HStack {
                        Button("Regenerate") { session.generateLongForm() }
                        Button("Sort by time") { session.sortLongFormChronologically() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        session.sendLongFormToEditor()
                        onOpenEditor()
                    } label: {
                        Label("Open in Editor", systemImage: "slider.horizontal.below.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.small)
                    .disabled(session.longForm.segments.filter(\.isIncluded).isEmpty)
                    .help("Loads the cut onto the editor timeline in 16:9 — text, overlays, voice-over, speed, transitions, the lot")

                    Text("Chronological order is the default — a best-of that jumps around in time reads as chaotic. Drag blocks to override.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .panel()

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Selection")

                    LabeledContent("Focus") {
                        Picker("", selection: Binding(
                            get: { session.project.contentFocus },
                            set: { session.setContentFocus($0) }
                        )) {
                            ForEach(ContentFocus.allCases) { focus in
                                Text(focus.label).tag(focus)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Text(session.project.contentFocus.explainer)
                        .font(.caption2)
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)

                    LabeledContent("Length") {
                        Picker("", selection: Binding(
                            get: { Int(optionsDraft.targetMinutes) },
                            set: { optionsDraft.targetMinutes = Double($0); commitOptions() }
                        )) {
                            ForEach([5, 10, 15, 20, 30, 45, 50, 60], id: \.self) { minutes in
                                Text("\(minutes) min").tag(minutes)
                            }
                            if ![5, 10, 15, 20, 30, 45, 50, 60].contains(Int(optionsDraft.targetMinutes)) {
                                Text("\(Int(optionsDraft.targetMinutes)) min")
                                    .tag(Int(optionsDraft.targetMinutes))
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    LabeledContent("Fine target") {
                        HStack {
                            Slider(value: $optionsDraft.targetMinutes, in: 5...60, step: 1) { editing in
                                if !editing { commitOptions() }
                            }
                            Text("\(Int(optionsDraft.targetMinutes)) min")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 46)
                        }
                    }

                    LabeledContent("Max segment") {
                        HStack {
                            Slider(value: $optionsDraft.maximumSegment, in: 60...300, step: 10) { editing in
                                if !editing { commitOptions() }
                            }
                            Text("\(Int(optionsDraft.maximumSegment))s")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 46)
                        }
                    }

                    Text("Changing these takes effect on the next Regenerate.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textFaint)
                }
                .panel()
                .font(.caption)

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Dead air")
                    Toggle("Trim silence inside segments", isOn: $optionsDraft.trimInternalSilence)
                        .onChange(of: optionsDraft.trimInternalSilence) { _, _ in commitOptions() }
                    if optionsDraft.trimInternalSilence {
                        LabeledContent("Longer than") {
                            HStack {
                                Slider(value: $optionsDraft.internalSilenceThreshold, in: 0.6...5, step: 0.1) { editing in
                                    if !editing { commitOptions() }
                                }
                                Text(String(format: "%.1fs", optionsDraft.internalSilenceThreshold))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 40)
                            }
                        }
                        Text("Cuts show as dashed seams on the timeline. Ingest only detects gaps of 0.6s or more.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .panel()
                .font(.caption)
                .toggleStyle(.switch)
                .controlSize(.small)

                analysisPanel
                polishPanel
                exportPanel
            }
            .padding(2)
        }
    }

    /// Optional analyses: the two signals that cost real time or money, so both
    /// are opt-in rather than part of ingest.
    private var analysisPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Extra signals")

            // Scene detection
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Scene changes")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if session.scenes.isEmpty {
                        Button("Detect") { session.detectScenes() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(session.isDetectingScenes || !session.canDetectScenes)
                    } else {
                        Text("\(session.scenes.count) cuts")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.positive)
                        Button("Clear") { session.clearScenes() }
                            .buttonStyle(.link)
                            .controlSize(.small)
                    }
                }
                if let reason = session.sceneDetectionBlockedReason, session.scenes.isEmpty {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if session.isDetectingScenes {
                    ProgressView(value: session.sceneProgress).tint(Theme.accent)
                    Text("Scanning video… \(Int(session.sceneProgress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                } else if session.scenes.isEmpty {
                    Text("The only analysis that reads the video stream. Decodes keyframes only — about 2.5 minutes for a four-hour VOD.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider().overlay(Theme.border)

            // Coherence pass
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Throughlines")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if !session.throughlines.isEmpty {
                        Text("\(session.throughlines.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.positive)
                        Button("Clear") { session.clearThroughlines() }
                            .buttonStyle(.link)
                            .controlSize(.small)
                    }
                }
                Text("Which moments belong together, so a cut never keeps one beat of a running bit and drops the setup.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                if session.isFindingThroughlinesLocally {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(session.localThroughlineStatus)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                } else {
                    Button {
                        session.findThroughlinesLocally()
                    } label: {
                        Label("Find with local model", systemImage: "cpu")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.small)
                    .disabled(session.transcript.isEmpty)
                    .help("Fully on-device via Ollama — a few minutes in the background. The copy/paste route below reads the whole transcript at once and is usually sharper.")
                }
                Text("Or the manual route — Claude reads the whole transcript in one pass, which catches bits an 8B model working in windows can miss:")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                ManualClaudePanel(
                    makePrompt: { session.throughlinesPrompt() },
                    notReadyText: "This project has no transcript yet.",
                    apply: { try session.applyThroughlinesReply($0) }
                )

                ForEach(session.throughlines) { throughline in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(throughline.kind.label)
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Theme.accent.opacity(0.25))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                            Text(throughline.title)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(String(format: "%.0f%%", throughline.strength * 100))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Theme.textFaint)
                        }
                        Text(throughline.beats.map { $0.start.shortTimecode }.joined(separator: " · "))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(6)
                    .background(Theme.surfaceRaised.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .onTapGesture {
                        if let first = throughline.beats.first,
                           let composition = session.assembled.compositionTime(forSource: first.start) {
                            player.seek(to: composition, precise: true)
                        }
                    }
                }
            }
        }
        .panel()
        .font(.caption)
    }

    /// Phase 4 polish: dissolves between segments and an optional music bed.
    private var polishPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Transitions")
            Toggle("Crossfade between segments", isOn: $optionsDraft.crossfadeEnabled)
                .onChange(of: optionsDraft.crossfadeEnabled) { _, _ in commitOptions() }
            if optionsDraft.crossfadeEnabled {
                LabeledContent("Length") {
                    HStack {
                        Slider(value: $optionsDraft.crossfadeDuration, in: 0.2...2, step: 0.1) { editing in
                            if !editing { commitOptions() }
                        }
                        Text(String(format: "%.1fs", optionsDraft.crossfadeDuration))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 36)
                    }
                }
                Text("Shortens the cut by \(String(format: "%.0fs", Double(max(0, session.assembled.pieces.count - 1)) * optionsDraft.crossfadeDuration)) overall. The preview plays hard cuts.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(Theme.border)

            SectionLabel(text: "Music bed")
            HStack {
                Button(optionsDraft.musicPath == nil ? "Choose track…" : "Replace…") { chooseMusic() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if optionsDraft.musicPath != nil {
                    Button("Remove") {
                        optionsDraft.musicPath = nil
                        optionsDraft.musicEnabled = false
                        commitOptions()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if let path = optionsDraft.musicPath {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Toggle("Mix under the cut", isOn: $optionsDraft.musicEnabled)
                    .onChange(of: optionsDraft.musicEnabled) { _, _ in commitOptions() }

                if optionsDraft.musicEnabled {
                    LabeledContent("Level") {
                        HStack {
                            Slider(value: $optionsDraft.musicGainDB, in: -40...0, step: 1) { editing in
                                if !editing { commitOptions() }
                            }
                            Text("\(Int(optionsDraft.musicGainDB)) dB")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 46)
                        }
                    }
                    Toggle("Duck under speech", isOn: $optionsDraft.musicDucking)
                        .onChange(of: optionsDraft.musicDucking) { _, _ in commitOptions() }
                    if optionsDraft.musicDucking {
                        LabeledContent("Strength") {
                            HStack {
                                Slider(value: $optionsDraft.duckRatio, in: 2...20, step: 1) { editing in
                                    if !editing { commitOptions() }
                                }
                                Text("\(Int(optionsDraft.duckRatio)):1")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 36)
                            }
                        }
                    }
                    Text("Shorter tracks loop to cover the cut. Music is mixed at export — the preview plays program audio only.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .panel()
        .font(.caption)
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private func chooseMusic() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        panel.message = "Choose a background music track"
        if let last = UserDefaults.standard.string(forKey: "lastMusicFolder") {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "lastMusicFolder")
        optionsDraft.musicPath = url.path
        optionsDraft.musicEnabled = true
        commitOptions()
    }

    private var exportPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Export")

            if session.project.exportSettings.captionMode.burnsIn {
                Text("Burned-in captions require a second encode pass over the whole cut. A toggleable track doesn't.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("1920×1080 H.264/AAC MP4")
                .font(.caption2)
                .foregroundStyle(Theme.textFaint)

            if session.isExporting {
                ProgressView(value: session.exportProgress).tint(Theme.accent)
                Text("Rendering… \(Int(session.exportProgress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Button {
                    presentSavePanel()
                } label: {
                    Label("Export long-form MP4…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(session.assembled.isEmpty)
            }

            if let result = session.lastExport {
                VStack(alignment: .leading, spacing: 3) {
                    Label(result.usedHardwareEncoder ? "Hardware encoded" : "Software encoded",
                          systemImage: result.usedHardwareEncoder ? "bolt.fill" : "cpu")
                        .font(.caption2)
                        .foregroundStyle(result.usedHardwareEncoder ? Theme.positive : Theme.warning)
                    Text("\(String(format: "%.0fs", result.elapsed)) · \(ByteCountFormatter.string(fromByteCount: result.sizeBytes, countStyle: .file))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textFaint)
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
        }
        .panel()
    }

    private func commitOptions() {
        session.updateLongFormOptions(optionsDraft)
    }

    private func presentSavePanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.mpeg4Movie]
        panel.nameFieldStringValue = "\(session.project.name)-bestof.mp4"
        panel.message = "Export long-form cut (1920×1080 H.264/AAC)"
        if let last = UserDefaults.standard.string(forKey: "lastExportFolder") {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "lastExportFolder")
        session.exportLongForm(to: url)
    }
}

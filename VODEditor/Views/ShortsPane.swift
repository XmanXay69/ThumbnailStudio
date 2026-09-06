import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Phase 2 review surface: candidate bin on the left, clip under the playhead
/// in the middle, framing/style/export on the right.
struct ShortsPane: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var player: PlayerController
    /// Switches the window to the Editor tab after a clip is sent there.
    var onOpenEditor: () -> Void = {}

    @State private var selectedID: UUID?
    @State private var styleDraft = CaptionStyle.standard
    @State private var isPreviewing = false
    @State private var showDiscarded = false
    @State private var mostlyMe = false
    @AppStorage("hottestFirst") private var hottestFirst = false
    @State private var showCaptionPreview = true
    /// Which framing box is being edited in split mode.
    @State private var selectedBox: FrameBox? = .cam
    @State private var showAutoClipSheet = false
    @FocusState private var binFocused: Bool

    /// The caption line under the playhead, in clip-relative time.
    private func activeCaptionLine(for candidate: ShortCandidate) -> CaptionLine? {
        let offset = player.currentTime - candidate.start
        guard offset >= 0, offset <= candidate.duration else { return nil }
        return session.captionLines(for: candidate)
            .last { offset >= $0.start && offset < $0.end }
    }

    private var selected: ShortCandidate? {
        session.shorts.first { $0.id == selectedID }
    }

    private var visibleShorts: [ShortCandidate] {
        let filtered = session.shorts.filter { candidate in
            guard showDiscarded || candidate.status != .discarded else { return false }
            if mostlyMe, session.speakerGuesses.reliable {
                return (session.youFraction(from: candidate.start, to: candidate.end) ?? 1) >= 0.6
            }
            return true
        }
        guard hottestFirst else { return filtered }
        return filtered.sorted {
            ($0.marketability ?? -1, $0.score) > ($1.marketability ?? -1, $1.score)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            bin.frame(width: 230).clipped()

            if let candidate = selected {
                center(for: candidate).frame(minWidth: 340, maxWidth: .infinity)
                if session.showsOutputPreview {
                    OutputPreviewColumn(session: session,
                                        layout: candidate.layout,
                                        onLayout: { session.updateLayout($0, for: candidate) })
                        .frame(width: 190)
                        .clipped()
                }
                inspector(for: candidate).frame(width: 280).clipped()
            } else {
                emptySelection
            }
        }
        .clipped()
        .onAppear {
            styleDraft = session.project.captionStyle
            if selectedID == nil { selectedID = visibleShorts.first?.id }
        }
        .onChange(of: selectedID) { _, _ in
            isPreviewing = false
            if let candidate = selected {
                styleDraft = candidate.styleOverride ?? session.project.captionStyle
                player.seek(to: candidate.start, precise: true)
                refreshPreview()
            }
        }
        // Reframing changes the output, so re-render the sidebar.
        .onChange(of: selected?.layout) { _, _ in refreshPreview() }
        .onChange(of: session.showsOutputPreview) { _, _ in refreshPreview() }
        .sheet(isPresented: $showAutoClipSheet) {
            AutoClipSheet(session: session)
                .frame(width: 560, height: 640)
        }
        .onChange(of: player.currentTime) { _, time in
            // Preview plays only the clip, then stops at the out point.
            if isPreviewing, let candidate = selected, time >= candidate.end {
                player.pause()
                isPreviewing = false
            }
            // Re-render the output sidebar for the frame under the playhead,
            // but not while playing — that would queue an ffmpeg call 30×/sec.
            if session.showsOutputPreview, !player.isPlaying { refreshPreview() }
        }
    }

    private func refreshPreview() {
        guard session.showsOutputPreview, let candidate = selected else { return }
        session.refreshOutputPreview(for: candidate, at: player.currentTime)
    }

    // MARK: - Bin

    private var bin: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel(text: "Candidates")
                Spacer()
                Text("\(visibleShorts.count)")
                    .font(.caption)
                    .foregroundStyle(Theme.textFaint)
                Menu {
                    Button {
                        session.rankBangers()
                    } label: {
                        Label(session.isRankingBangers
                              ? "Ranking… \(session.bangerStatus)"
                              : "Rank bangers", systemImage: "flame")
                    }
                    .disabled(session.isRankingBangers)
                    Toggle("Hottest first", isOn: $hottestFirst)
                    Divider()
                    Toggle("Show discarded", isOn: $showDiscarded)
                    Toggle("Mostly my voice", isOn: $mostlyMe)
                    Button(session.speakerGuesses.reliable
                           ? "Re-guess speakers" : "Guess speakers (mic level)") {
                        session.labelSpeakers()
                    }
                    Divider()
                    Picker("Focus", selection: Binding(
                        get: { session.project.contentFocus },
                        set: { session.setContentFocus($0) }
                    )) {
                        ForEach(ContentFocus.allCases) { focus in
                            Text(focus.label).tag(focus)
                        }
                    }
                    Divider()
                    Button("Find clips (AI)…") { showAutoClipSheet = true }
                    Divider()
                    Button("Re-run scoring") { session.analyzeShorts() }
                    Button("Reset scoring settings") { session.resetAnalysisSettings() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 22)
                InfoTip("Click the list, then: J/K move · space previews · A accepts · X discards · R resets · E sends to the editor.")
            }
            .padding(10)

            Divider().overlay(Theme.border)

            if session.shorts.isEmpty {
                VStack(spacing: 8) {
                    Text("No candidates yet")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                    Button("Analyze") { session.analyzeShorts() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .disabled(!session.canAnalyze)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        autoClipSection
                        ForEach(visibleShorts) { candidate in
                            CandidateRow(candidate: candidate,
                                         isSelected: candidate.id == selectedID,
                                         posterURL: session.project.playbackURL)
                                .onTapGesture { selectedID = candidate.id }
                                .contextMenu {
                                    Button("Keep") { session.setStatus(.accepted, for: candidate) }
                                    Button("Discard") { session.setStatus(.discarded, for: candidate) }
                                    Button("Reset") { session.setStatus(.candidate, for: candidate) }
                                    if candidate.exportedPath != nil {
                                        Divider()
                                        Button(candidate.postedAt == nil
                                               ? "Mark posted" : "Mark not posted") {
                                            var updated = candidate
                                            updated.postedAt = updated.postedAt == nil ? Date() : nil
                                            session.update(updated)
                                        }
                                    }
                                }
                        }
                    }
                    .padding(8)
                    .animation(.easeOut(duration: 0.18), value: visibleShorts.map(\.id))
                }
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(binFocused ? Theme.accent.opacity(0.6) : Theme.border, lineWidth: 1))
        .focusable()
        .focused($binFocused)
        .onKeyPress(phases: .down) { press in handleBinKey(press) }
        .contentShape(Rectangle())
        .onTapGesture { binFocused = true }
    }

    /// Triage without the mouse: 180 candidates a week is a lot of clicking.
    private func handleBinKey(_ press: KeyPress) -> KeyPress.Result {
        let list = visibleShorts
        guard !list.isEmpty else { return .ignored }
        let index = list.firstIndex { $0.id == selectedID } ?? 0

        func select(_ next: Int) {
            guard list.indices.contains(next) else { return }
            selectedID = list[next].id
        }

        switch press.key {
        case KeyEquivalent("j"), .downArrow:
            select(min(list.count - 1, index + 1))
        case KeyEquivalent("k"), .upArrow:
            select(max(0, index - 1))
        case .space:
            if let candidate = selected { previewCandidate(candidate) }
        case KeyEquivalent("a"):
            guard let candidate = selected else { return .ignored }
            session.setStatus(.accepted, for: candidate)
            select(min(list.count - 1, index + 1))
        case KeyEquivalent("x"):
            guard let candidate = selected else { return .ignored }
            session.setStatus(.discarded, for: candidate)
            select(min(list.count - 1, index + 1))
        case KeyEquivalent("r"):
            guard let candidate = selected else { return .ignored }
            session.setStatus(.candidate, for: candidate)
        case KeyEquivalent("e"):
            guard let candidate = selected else { return .ignored }
            session.addToTimeline(candidate)
            onOpenEditor()
        default:
            return .ignored
        }
        return .handled
    }

    /// Plays just the selected clip, stopping at its out point.
    private func previewCandidate(_ candidate: ShortCandidate) {
        if player.isPlaying {
            player.pause()
            isPreviewing = false
        } else {
            player.seek(to: candidate.start, precise: true)
            isPreviewing = true
            player.play()
        }
    }

    /// The clip finder's suggestions, grouped by category, above the scored
    /// candidates. Everything stays editable — Add hands the moment to the
    /// normal shorts flow.
    @ViewBuilder
    private var autoClipSection: some View {
        if session.isFindingClips {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    ProgressView(value: session.autoClipRun?.progress ?? 0)
                        .tint(Theme.accent)
                    Text(session.autoClipStatus)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Text("Finding clips in the background — keep editing.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(7)
            .background(Theme.surfaceRaised.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        if let run = session.autoClipRun {
            let suggested = run.candidates.filter { $0.state == .suggested }
            if !suggested.isEmpty {
                HStack {
                    Text("AI CLIPS")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text(run.backend)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(run.backend == "heuristics" ? Theme.warning : Theme.textFaint)
                    Spacer()
                    Text("\(run.candidates.filter { $0.state == .surplus }.count) in reserve")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.textFaint)
                }
                .padding(.top, 2)
                let grouped = Dictionary(grouping: suggested, by: \.categoryID)
                ForEach(run.categories.filter { grouped[$0.id] != nil }) { category in
                    Text(category.name.uppercased())
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(grouped[category.id] ?? []) { candidate in
                        autoClipRow(candidate, run: run)
                    }
                }
                Divider().padding(.vertical, 4)
            }
        }
    }

    private func autoClipRow(_ candidate: AutoClipCandidate, run: AutoClipRun) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(candidate.title.isEmpty ? "Clip" : candidate.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text(String(format: "%.0fs · %.0f%%", candidate.duration, candidate.confidence * 100))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
            }
            if !candidate.why.isEmpty {
                Text(candidate.why)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Button {
                    player.seek(to: candidate.start, precise: true)
                    player.play()
                } label: {
                    Image(systemName: "play.fill").font(.system(size: 8))
                }
                Button("Add") { session.addAutoClipToShorts(candidate) }
                    .font(.system(size: 9))
                Menu {
                    ForEach(run.categories) { category in
                        Button(category.name) {
                            session.recategorizeAutoClip(candidate, to: category.id)
                        }
                    }
                } label: {
                    Image(systemName: "tag").font(.system(size: 8))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Recategorize — the label will be wrong sometimes; this is the one-click fix")
                Spacer()
                Button {
                    session.rejectAutoClip(candidate)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 8))
                }
                .help("Reject — pulls the next reserve candidate forward")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(6)
        .background(Theme.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Theme.accent.opacity(0.3), lineWidth: 1))
    }

    private var emptySelection: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                .font(.system(size: 36))
                .foregroundStyle(Theme.textFaint)
            Text("Select a candidate to review it")
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Centre

    private func center(for candidate: ShortCandidate) -> some View {
        VStack(spacing: 10) {
            ZStack {
                PlayerSurface(player: player.player)
                    .background(Color.black)
                CropFrameOverlay(
                    sourceWidth: session.project.media?.width ?? 1920,
                    sourceHeight: session.project.media?.height ?? 1080,
                    layout: Binding(
                        get: { candidate.layout },
                        set: { session.updateLayout($0, for: candidate) }
                    ),
                    selection: $selectedBox,
                    captionLine: activeCaptionLine(for: candidate),
                    captionStyle: candidate.styleOverride ?? session.project.captionStyle,
                    captionTime: player.currentTime - candidate.start,
                    showsCaptions: showCaptionPreview
                        && session.project.exportSettings.captionMode.burnsIn
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(minHeight: 200)

            transport(for: candidate)

            ClipTrimBar(
                waveform: session.waveform,
                curve: session.scoreCurve,
                duration: session.project.media?.durationSeconds ?? 0,
                currentTime: player.currentTime,
                start: Binding(
                    get: { candidate.start },
                    set: { var updated = candidate; updated.start = $0; session.update(updated) }
                ),
                end: Binding(
                    get: { candidate.end },
                    set: { var updated = candidate; updated.end = $0; session.update(updated) }
                ),
                minDuration: session.project.candidateOptions.minDuration,
                maxDuration: session.project.candidateOptions.maxDuration,
                onSeek: { player.seek(to: $0) }
            )

            CaptionEditor(
                lines: session.editableCaptionLines(for: candidate),
                candidate: candidate,
                currentTimeInClip: player.currentTime - candidate.start,
                onEdit: { id, text in
                    var updated = candidate
                    updated.captionEdits[String(id)] = text
                    session.update(updated)
                },
                onResetLine: { id in
                    var updated = candidate
                    updated.captionEdits.removeValue(forKey: String(id))
                    session.update(updated)
                },
                onSeek: { player.seek(to: candidate.start + $0, precise: true) }
            )
            .frame(minHeight: 110, maxHeight: 180)
        }
    }

    private func transport(for candidate: ShortCandidate) -> some View {
        HStack(spacing: 10) {
            Button {
                player.seek(to: candidate.start, precise: true)
                isPreviewing = true
                player.play()
            } label: {
                Label("Preview clip", systemImage: "play.rectangle")
            }
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 14)
            }
            Text(clipPosition(for: candidate))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            Button {
                session.addToTimeline(candidate)
                onOpenEditor()
            } label: {
                Label(session.isPreparingTimelineClip ? "Rendering…" : "Timeline",
                      systemImage: "timeline.selection")
            }
            .disabled(session.isPreparingTimelineClip)
            .help("Renders this clip as a portrait piece — its framing, captions and tuning — and sends it to the Editor tab.")
            Spacer()
            statusControl(for: candidate)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func clipPosition(for candidate: ShortCandidate) -> String {
        let offset = player.currentTime - candidate.start
        guard offset >= 0, offset <= candidate.duration else { return "—" }
        return String(format: "%.1f / %.1fs", offset, candidate.duration)
    }

    private func statusControl(for candidate: ShortCandidate) -> some View {
        Picker("", selection: Binding(
            get: { candidate.status },
            set: { session.setStatus($0, for: candidate) }
        )) {
            Text("Candidate").tag(ShortStatus.candidate)
            Text("Keep").tag(ShortStatus.accepted)
            Text("Discard").tag(ShortStatus.discarded)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 210)
    }

    // MARK: - Inspector

    private func inspector(for candidate: ShortCandidate) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Color.clear.frame(height: 0)
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Why this clip")
                    if let hook = candidate.hookLine, !hook.isEmpty {
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                            Text("Open on: \u{201C}\(hook)\u{201D}")
                                .font(.caption2)
                                .foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(6)
                        .background(Color.orange.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    if let heat = candidate.marketability {
                        LabeledContent("Marketability") {
                            Text("\(Int(heat))/100")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(heat >= BangerService.bangerThreshold
                                                 ? .orange : Theme.textSecondary)
                        }
                        .font(.caption2)
                    }
                    ForEach(candidate.components.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HStack(spacing: 6) {
                            Text(key.capitalized)
                                .font(.caption2)
                                .foregroundStyle(Theme.textFaint)
                                .frame(width: 64, alignment: .leading)
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.surfaceRaised)
                                    Capsule().fill(Theme.accent)
                                        .frame(width: geometry.size.width * CGFloat(min(1, value)))
                                }
                            }
                            .frame(height: 6)
                            Text(String(format: "%.2f", value))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 30)
                        }
                    }
                    if !session.scoreCurve.hasChat {
                        Text("No chat loaded — chat velocity is often the strongest signal for IRL content.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .panel()

                FramingPanel(candidate: candidate, session: session, selectedBox: $selectedBox)

                CaptionSettingsPanel(session: session,
                                     styleDraft: $styleDraft,
                                     showPreview: $showCaptionPreview)

                AudioTuningPanel(session: session)

                exportPanel(for: candidate)
            }
            .padding(2)
        }
    }

    private func exportPanel(for candidate: ShortCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Export")

            Toggle("Hardware encode (VideoToolbox)", isOn: Binding(
                get: { session.project.exportSettings.useHardwareEncoder },
                set: { var settings = session.project.exportSettings; settings.useHardwareEncoder = $0; session.updateExportSettings(settings) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.caption)

            LabeledContent("Quality") {
                Picker("", selection: Binding(
                    get: { ExportQuality.nearest(to: session.project.exportSettings.videoBitrateMbps) },
                    set: {
                        var settings = session.project.exportSettings
                        settings.videoBitrateMbps = $0.mbps
                        session.updateExportSettings(settings)
                    }
                )) {
                    ForEach(ExportQuality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                .pickerStyle(.menu)
            }
            .font(.caption)
            Text(ExportQuality.nearest(to: session.project.exportSettings.videoBitrateMbps).explainer)
                .font(.caption2)
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Bitrate") {
                HStack {
                    Slider(value: Binding(
                        get: { session.project.exportSettings.videoBitrateMbps },
                        set: { var settings = session.project.exportSettings; settings.videoBitrateMbps = $0; session.updateExportSettings(settings) }
                    ), in: 8...50, step: 1)
                    Text("\(Int(session.project.exportSettings.videoBitrateMbps)) Mbps")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 56)
                }
            }
            .font(.caption)

            if session.isExporting {
                ProgressView(value: session.exportProgress)
                    .tint(Theme.accent)
                Text("Rendering… \(Int(session.exportProgress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Button {
                    presentSavePanel(for: candidate)
                } label: {
                    Label("Export vertical MP4…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }

            if let result = session.lastExport {
                VStack(alignment: .leading, spacing: 3) {
                    Label(result.usedHardwareEncoder ? "Hardware encoded" : "Software encoded",
                          systemImage: result.usedHardwareEncoder ? "bolt.fill" : "cpu")
                        .font(.caption2)
                        .foregroundStyle(result.usedHardwareEncoder ? Theme.positive : Theme.warning)
                    Text("\(result.encoderName) · \(String(format: "%.1fs", result.elapsed)) · \(ByteCountFormatter.string(fromByteCount: result.sizeBytes, countStyle: .file))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textFaint)
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([result.url])
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }
        }
        .panel()
    }

    /// Every export goes through a save panel — no hidden output folder — and
    /// the last destination is remembered.
    private func presentSavePanel(for candidate: ShortCandidate) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.mpeg4Movie]
        panel.nameFieldStringValue = suggestedFilename(for: candidate)
        panel.message = "Export vertical short (1080×1920 H.264/AAC)"
        if let last = UserDefaults.standard.string(forKey: "lastExportFolder") {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "lastExportFolder")
        session.exportShort(candidate, to: url)
    }

    private func suggestedFilename(for candidate: ShortCandidate) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let cleaned = candidate.title.unicodeScalars
            .filter { allowed.contains($0) }
            .map(String.init).joined()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        let stem = cleaned.isEmpty ? "short" : String(cleaned.prefix(40))
        return "\(stem)-\(Int(candidate.start)).mp4"
    }
}

// MARK: - Rows and overlays

private struct CandidateRow: View {
    let candidate: ShortCandidate
    let isSelected: Bool
    /// The source VOD, for the poster frame; nil shows the placeholder.
    var posterURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The picture is the information: one frame from the moment's
            // peak, with the duration where YouTube puts it.
            PosterFrame(url: posterURL, time: candidate.peakTime)
                .overlay(alignment: .bottomTrailing) {
                    Text(String(format: "%.0fs", candidate.duration))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.black.opacity(0.72))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .padding(5)
                }
                .overlay(alignment: .topLeading) {
                    Text(candidate.start.timecode)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.black.opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .padding(5)
                }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 3) {
                        if (candidate.marketability ?? 0) >= BangerService.bangerThreshold {
                            HStack(spacing: 2) {
                                Image(systemName: "flame.fill").font(.system(size: 8))
                                Text("\(Int(candidate.marketability ?? 0))")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.orange.gradient)
                            .clipShape(Capsule())
                            .help("Banger — \(Int(candidate.marketability ?? 0))/100 for stopping a scroll")
                        }
                        statusBadge
                    }
                    .padding(5)
                }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(candidate.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if candidate.postedAt != nil {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.positive)
                            .help("Posted")
                    }
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surfaceRaised)
                        Capsule().fill(scoreColor)
                            .frame(width: geometry.size.width * CGFloat(min(1, candidate.score / 0.7)))
                    }
                }
                .frame(height: 3)
            }
            .padding(8)
        }
        .background(isSelected ? Theme.accent.opacity(0.14) : Theme.surfaceRaised.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.7) : Theme.border.opacity(0.4),
                              lineWidth: 1)
        )
        .opacity(candidate.status == .discarded ? 0.45 : 1)
        .contentShape(Rectangle())
    }

    private var scoreColor: Color {
        candidate.score >= 0.45 ? Theme.positive
            : candidate.score >= 0.25 ? Theme.accent : Theme.warning
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch candidate.status {
        case .accepted:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 9)).foregroundStyle(Theme.positive)
        case .discarded:
            Image(systemName: "xmark.circle.fill").font(.system(size: 9)).foregroundStyle(Theme.textFaint)
        case .candidate:
            EmptyView()
        }
    }
}

/// The two regions of a split layout the user can select and edit.
enum FrameBox: Equatable { case cam, gameplay }

/// What gets cropped out of the source, drawn over the preview. In single mode
/// it's one aspect-locked 9:16 window; in split mode it's two click-to-select
/// boxes — cam and gameplay — each movable and resizable on its own.
///
/// Two hard-won rules keep this responsive. Edits are echoed into a local
/// draft while a drag is in flight and committed to the session once on
/// release — routing every tick through the session re-rendered the whole pane
/// and rewrote the project file per mouse move. And the boxes keep a stable
/// position in the view tree, with the selected one *raised* by zIndex rather
/// than reordered: swapping their order on selection recreated both views on
/// the first drag tick, which cancelled the gesture mid-flight — the box would
/// highlight and then refuse to move.
private struct CropFrameOverlay: View {
    let sourceWidth: Int
    let sourceHeight: Int
    @Binding var layout: ShortLayout
    /// Which box the user is editing; only the selected one is raised and
    /// shows resize handles, so the two never fight over a drag.
    @Binding var selection: FrameBox?
    /// Captions are previewed inside the crop frame, because that rectangle is
    /// what actually gets exported.
    var captionLine: CaptionLine?
    var captionStyle: CaptionStyle = .standard
    var captionTime: Double = 0
    var showsCaptions: Bool = false

    /// Local echo of the layout while a drag is in flight.
    @State private var draft: ShortLayout?
    /// The rectangle as it was when the drag began — translation is cumulative
    /// from the start of the gesture, so it applies to this, not per-tick.
    @State private var dragStart: NormalizedRect?

    private var effective: ShortLayout { draft ?? layout }

    var body: some View {
        GeometryReader { geometry in
            let video = Self.videoRect(in: geometry.size,
                                       aspect: Double(sourceWidth) / Double(max(sourceHeight, 1)))
            let scale = video.width / Double(max(sourceWidth, 1))
            ZStack(alignment: .topLeading) {
                if effective.mode == .split {
                    splitEditor(video: video, scale: scale)
                } else {
                    fillEditor(video: video, scale: scale)
                }
            }
        }
    }

    // MARK: - Single crop

    private func fillEditor(video: CGRect, scale: Double) -> some View {
        let frame = screenRect(effective.fillRect, video: video, scale: scale)
        let heightPerWidth = (Double(sourceWidth) / Double(max(sourceHeight, 1)))
            * (Double(ASSBuilder.renderHeight) / Double(ASSBuilder.renderWidth))
        let maxWidth = min(1.0, 1.0 / heightPerWidth)
        return ZStack(alignment: .topLeading) {
            dimming(video: video, holes: [frame]).allowsHitTesting(false)
            if showsCaptions {
                CaptionOverlay(line: captionLine, style: captionStyle,
                               time: captionTime, referenceHeight: 1920)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .allowsHitTesting(false)
            }
            editableBox(\.fillRect, select: nil, screen: frame, video: video,
                        color: Theme.accent, label: "9:16", isSelected: true,
                        aspectLock: heightPerWidth, maxWidth: maxWidth)
        }
    }

    // MARK: - Split editor

    private func splitEditor(video: CGRect, scale: Double) -> some View {
        let cam = screenRect(effective.camRect, video: video, scale: scale)
        let game = screenRect(effective.gameRect, video: video, scale: scale)
        return ZStack(alignment: .topLeading) {
            dimming(video: video, holes: [game, cam]).allowsHitTesting(false)
            editableBox(\.gameRect, select: .gameplay, screen: game, video: video,
                        color: Theme.accent, label: "GAMEPLAY",
                        isSelected: selection == .gameplay, aspectLock: nil, maxWidth: 1)
                .zIndex(selection == .gameplay ? 2 : 1)
            editableBox(\.camRect, select: .cam, screen: cam, video: video,
                        color: Theme.positive, label: "CAM",
                        isSelected: selection == .cam, aspectLock: nil, maxWidth: 1)
                .zIndex(selection == .cam ? 2 : 1)
            if showsCaptions, let line = captionLine {
                splitCaption(line: line, cam: cam, game: game)
                    .allowsHitTesting(false)
                    .zIndex(3)
            }
        }
    }

    /// Live captions in split mode, drawn on the band they land in on the
    /// 1080×1920 output — bottom band for bottom-positioned captions, top band
    /// for top. Slightly approximate (the box shows a source crop, the band is
    /// cover-fit); the output sidebar shows the exact burn.
    private func splitCaption(line: CaptionLine, cam: CGRect, game: CGRect) -> some View {
        var camHeight = Int((Double(ASSBuilder.renderHeight) * effective.camFraction).rounded())
        camHeight -= camHeight % 2
        let gameHeight = ASSBuilder.renderHeight - camHeight
        let topIsCam = effective.camOnTop
        let onTopBand = captionStyle.position == .top
        let target = onTopBand ? (topIsCam ? cam : game) : (topIsCam ? game : cam)
        let bandHeight = onTopBand ? (topIsCam ? camHeight : gameHeight)
                                   : (topIsCam ? gameHeight : camHeight)
        return CaptionOverlay(line: line, style: captionStyle, time: captionTime,
                              referenceHeight: CGFloat(bandHeight))
            .frame(width: target.width, height: target.height)
            .offset(x: target.minX, y: target.minY)
    }

    // MARK: - The box itself

    private func editableBox(_ keyPath: WritableKeyPath<ShortLayout, NormalizedRect>,
                             select: FrameBox?, screen: CGRect, video: CGRect,
                             color: Color, label: String, isSelected: Bool,
                             aspectLock: Double?, maxWidth: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(color.opacity(isSelected ? 0.10 : 0.02))
                .frame(width: screen.width, height: screen.height)
                .overlay(Rectangle().strokeBorder(color, lineWidth: isSelected ? 3 : 1.5)
                    .opacity(isSelected ? 1 : 0.65))
                .overlay(alignment: .topLeading) {
                    // Inset past the corner handle's reach so the two never
                    // collide.
                    Text(label)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(3)
                        .background(color.opacity(isSelected ? 1 : 0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.black)
                        .padding(.leading, 14)
                        .padding(.top, 14)
                }
                .contentShape(Rectangle())
                .offset(x: screen.minX, y: screen.minY)
                .gesture(moveGesture(keyPath, select: select, video: video))

            if isSelected {
                ForEach(BoxCorner.allCases, id: \.self) { corner in
                    handle(corner, keyPath: keyPath, screen: screen, video: video,
                           color: color, aspectLock: aspectLock, maxWidth: maxWidth)
                }
            }
        }
    }

    private func moveGesture(_ keyPath: WritableKeyPath<ShortLayout, NormalizedRect>,
                             select: FrameBox?, video: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard video.width > 0 else { return }
                if dragStart == nil {
                    dragStart = effective[keyPath: keyPath]
                    if let select, selection != select { selection = select }
                }
                guard let base = dragStart else { return }
                var moved = base
                moved.x = base.x + value.translation.width / video.width
                moved.y = base.y + value.translation.height / video.height
                var next = effective
                next[keyPath: keyPath] = moved.clamped()
                draft = next
            }
            .onEnded { value in
                // A click (no meaningful movement) only selects; a real drag
                // commits once, here, rather than on every tick.
                let dragged = abs(value.translation.width) + abs(value.translation.height) > 3
                if dragged, let done = draft {
                    layout = done
                } else if let select {
                    selection = select
                }
                draft = nil
                dragStart = nil
            }
    }

    /// A corner knob with a 44pt grab area — and a high-priority gesture, so a
    /// press near a corner resizes instead of moving the box under it.
    private func handle(_ corner: BoxCorner, keyPath: WritableKeyPath<ShortLayout, NormalizedRect>,
                        screen: CGRect, video: CGRect, color: Color,
                        aspectLock: Double?, maxWidth: Double) -> some View {
        let point = corner.point(in: screen)
        return ZStack {
            Color.clear.frame(width: 44, height: 44).contentShape(Rectangle())
            Circle()
                .fill(color)
                .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
                .frame(width: 22, height: 22)
        }
        .offset(x: point.x - 22, y: point.y - 22)
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard video.width > 0 else { return }
                    if dragStart == nil { dragStart = effective[keyPath: keyPath] }
                    guard let base = dragStart else { return }
                    let dx = value.translation.width / video.width
                    let dy = value.translation.height / video.height
                    // Aspect-locked for the single crop, free for the boxes.
                    let resized = aspectLock.map {
                        corner.resizeLocked(base, dx: dx, heightPerWidth: $0, maxWidth: maxWidth)
                    } ?? corner.resize(base, dx: dx, dy: dy)
                    var next = effective
                    next[keyPath: keyPath] = resized.clamped()
                    draft = next
                }
                .onEnded { _ in
                    if let done = draft { layout = done }
                    draft = nil
                    dragStart = nil
                }
        )
    }

    // MARK: - Geometry and drawing

    private func screenRect(_ rect: NormalizedRect, video: CGRect, scale: Double) -> CGRect {
        let px = ExportService.pixelRect(rect, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        return CGRect(x: video.minX + Double(px.x) * scale, y: video.minY + Double(px.y) * scale,
                      width: Double(px.width) * scale, height: Double(px.height) * scale)
    }

    private func dimming(video: CGRect, holes: [CGRect]) -> some View {
        Path { path in
            path.addRect(video)
            for hole in holes { path.addRect(hole) }
        }
        .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
    }

    /// AVPlayerView uses `resizeAspect`, so the video is letterboxed inside the
    /// view and the overlay has to match that rect, not the view bounds.
    static func videoRect(in size: CGSize, aspect: Double) -> CGRect {
        guard size.width > 0, size.height > 0, aspect > 0 else { return .zero }
        let containerAspect = size.width / size.height
        if containerAspect > aspect {
            let height = size.height
            let width = height * aspect
            return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: height)
        } else {
            let width = size.width
            let height = width / aspect
            return CGRect(x: 0, y: (size.height - height) / 2, width: width, height: height)
        }
    }
}

/// Framing controls for the selected clip: single vs. two-box, and the cam box
/// setup.
private struct FramingPanel: View {
    let candidate: ShortCandidate
    @ObservedObject var session: ProjectSession
    @Binding var selectedBox: FrameBox?

    private var layout: ShortLayout { candidate.layout }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Vertical framing")

            Picker("Layout", selection: Binding(
                get: { layout.mode },
                set: { var l = layout; l.mode = $0; session.updateLayout(l, for: candidate) }
            )) {
                ForEach(ShortLayoutMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if layout.mode == .fill {
                Text("Drag the frame to move it, or drag a corner to crop — or just use the sliders below. It stays 9:16, so the box is exactly the exported clip.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)

                if let media = session.project.media {
                    let heightPerWidth = (Double(media.width) / Double(max(media.height, 1)))
                        * (1920.0 / 1080.0)
                    let fullWidth = min(1.0, 1.0 / heightPerWidth)

                    sliderRow("Zoom",
                              value: max(1, fullWidth / max(0.001, layout.fillRect.width)),
                              range: 1...3, suffix: "×") { zoom in
                        var l = layout
                        let cx = l.fillRect.centerX, cy = l.fillRect.centerY
                        let w = fullWidth / zoom
                        let h = w * heightPerWidth
                        l.fillRect = NormalizedRect(x: cx - w / 2, y: cy - h / 2,
                                                    width: w, height: h).clamped()
                        session.updateLayout(l, for: candidate)
                    }
                    sliderRow("Left–right", value: layout.fillRect.centerX, range: 0...1) { cx in
                        var l = layout
                        l.fillRect.x = cx - l.fillRect.width / 2
                        l.fillRect = l.fillRect.clamped()
                        session.updateLayout(l, for: candidate)
                    }
                    if layout.fillRect.height < 0.999 {
                        sliderRow("Up–down", value: layout.fillRect.centerY, range: 0...1) { cy in
                            var l = layout
                            l.fillRect.y = cy - l.fillRect.height / 2
                            l.fillRect = l.fillRect.clamped()
                            session.updateLayout(l, for: candidate)
                        }
                    }
                }

                Button("Reset crop") {
                    var l = layout; l.fillRect = .defaultFill
                    session.updateLayout(l, for: candidate)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Text("Pick which box to edit, then drag it on the preview or use the sliders. Green is your webcam, purple is the gameplay. The green line on the output preview moves the border between them.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Editing", selection: $selectedBox) {
                    Text("Webcam").tag(FrameBox?.some(.cam))
                    Text("Gameplay").tag(FrameBox?.some(.gameplay))
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // Size and position sliders for whichever box is selected.
                let isCam = selectedBox != .gameplay
                let boxRect = isCam ? layout.camRect : layout.gameRect
                let boxName = isCam ? "Webcam" : "Gameplay"
                Text("\(boxName) box").font(.caption2.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                sliderRow("Width", value: boxRect.width, range: 0.05...1) { w in
                    setBoxRect(isCam: isCam) { $0.width = w }
                }
                sliderRow("Height", value: boxRect.height, range: 0.05...1) { h in
                    setBoxRect(isCam: isCam) { $0.height = h }
                }
                sliderRow("Left–right", value: boxRect.centerX, range: 0...1) { cx in
                    setBoxRect(isCam: isCam) { $0.x = cx - $0.width / 2 }
                }
                sliderRow("Up–down", value: boxRect.centerY, range: 0...1) { cy in
                    setBoxRect(isCam: isCam) { $0.y = cy - $0.height / 2 }
                }

                Toggle("Cam on top", isOn: Binding(
                    get: { layout.camOnTop },
                    set: { var l = layout; l.camOnTop = $0; session.updateLayout(l, for: candidate) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)

                sliderRow("Cam height", value: layout.camFraction, range: 0.15...0.5, suffix: "%",
                          display: layout.camFraction * 100) { f in
                    var l = layout; l.camFraction = f; session.updateLayout(l, for: candidate)
                }
            }

            Toggle("Show output preview", isOn: Binding(
                get: { session.showsOutputPreview },
                set: { _ in session.toggleOutputPreview(for: candidate, at: candidate.start) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            Button("Use this framing for all clips") {
                session.applyLayoutToAllShorts(layout)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .font(.caption)
        .panel()
    }

    /// A labelled slider with a numeric readout. `display` overrides the shown
    /// value (e.g. a percentage) when it differs from the bound value.
    private func sliderRow(_ label: String, value: Double, range: ClosedRange<Double>,
                           suffix: String = "", display: Double? = nil,
                           set: @escaping (Double) -> Void) -> some View {
        LabeledContent(label) {
            HStack {
                Slider(value: Binding(get: { value }, set: set), in: range)
                Text(suffix == "×"
                     ? String(format: "%.1f×", display ?? value)
                     : suffix == "%"
                        ? "\(Int(display ?? value))%"
                        : "\(Int((display ?? value) * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }

    /// Mutates the selected split box's rectangle and saves.
    private func setBoxRect(isCam: Bool, _ mutate: (inout NormalizedRect) -> Void) {
        var l = layout
        if isCam { mutate(&l.camRect); l.camRect = l.camRect.clamped() }
        else { mutate(&l.gameRect); l.gameRect = l.gameRect.clamped() }
        session.updateLayout(l, for: candidate)
    }
}

/// The sidebar showing the composed 1080×1920 output, rendered through the
/// same graph the export uses. In split mode the border between the cam and
/// gameplay bands is draggable right here — this is the only place that border
/// actually exists, since in the source preview the two boxes are separate
/// rectangles.
private struct OutputPreviewColumn: View {
    @ObservedObject var session: ProjectSession
    let layout: ShortLayout
    let onLayout: (ShortLayout) -> Void

    /// Live position while the border is being dragged; committed on release.
    @State private var dragFraction: Double?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                SectionLabel(text: "Output")
                Spacer()
                if session.isRenderingPreview {
                    ProgressView().controlSize(.small)
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black)
                if let image = session.outputPreviewImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(9.0 / 16.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "rectangle.portrait")
                            .font(.system(size: 24))
                            .foregroundStyle(Theme.textFaint)
                        Text("Rendering…")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .overlay {
                if layout.mode == .split { borderHandle }
            }
            

            Text(layout.mode == .split
                 ? "Drag the green line to move the border between the cam and the gameplay."
                 : "Exactly what exports at the playhead — captions included when burn-in is on.")
                .font(.caption2)
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
    }

    /// The cam/gameplay boundary, live while dragging, committed once on
    /// release so the session isn't hit per tick.
    private var borderHandle: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let fraction = dragFraction ?? layout.camFraction
            let y = (layout.camOnTop ? fraction : 1 - fraction) * height

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Theme.positive)
                    .frame(height: 3)
                    .offset(y: y - 1.5)
                Capsule()
                    .fill(Theme.positive)
                    .overlay(Capsule().strokeBorder(.black, lineWidth: 1))
                    .frame(width: 44, height: 12)
                    .offset(x: geometry.size.width / 2 - 22, y: y - 6)
                Color.white.opacity(0.001)
                    .frame(height: 28)
                    .offset(y: y - 14)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard height > 0 else { return }
                                let raw = layout.camOnTop
                                    ? value.location.y / height
                                    : 1 - value.location.y / height
                                dragFraction = min(0.5, max(0.15, raw))
                            }
                            .onEnded { _ in
                                if let fraction = dragFraction {
                                    var updated = layout
                                    updated.camFraction = fraction
                                    onLayout(updated)
                                }
                                dragFraction = nil
                            }
                    )
            }
        }
    }
}

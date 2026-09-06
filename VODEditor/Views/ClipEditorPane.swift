import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// The Editor tab: a timeline of clips from anywhere, music underneath, and
/// the social overlay — title at the top, Twitch and Instagram handles beside
/// their logos — burned onto the 1080×1920 output.
struct ClipEditorPane: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var player: PlayerController

    @State private var selectedClipID: UUID?
    @AppStorage("punchIntensity") private var punchIntensity = 1.12

    /// In-flight text drag: position applied to where the item was when the
    /// gesture started, echoed into a locally rendered overlay, committed once
    /// on release. Routing per-tick through the session would persist and
    /// invalidate on every mouse move.
    private struct TextDraft {
        let id: UUID
        let baseX: Double
        let baseY: Double
        var x: Double
        var y: Double
    }
    @State private var textDraft: TextDraft?
    @State private var draftOverlay: NSImage?
    @State private var hoveredTextID: UUID?
    @State private var lastDraftRender = Date.distantPast
    @State private var titlePromptNote: String?
    @State private var postPromptNote: String?
    @State private var clipDrag: (id: UUID, translation: CGFloat)?
    @State private var sfxDrag: (id: UUID, delta: Double)?
    @State private var sfxFilter = ""
    @AppStorage("tightenAggressiveness") private var tightenAggressiveness = 0.5
    @AppStorage("tightenFillers") private var tightenFillers = true
    @State private var tightenCuts: [TightenService.Cut]?
    @State private var showSnapshotNamer = false
    @State private var snapshotName = ""
    @AppStorage("snapToBeats") private var snapToBeats = true
    @AppStorage("editorInspectorTab") private var inspectorTab: InspectorTab = .clip
    @AppStorage("editorShowLibrary") private var showLibraryRail = true
    @AppStorage("editorShowInspector") private var showInspectorRail = true
    @State private var hookReport: HookDoctorService.Report?
    @State private var hookLooping = false
    @State private var preflight: [PreflightService.Finding]?

    @State private var timelineDropTargeted = false
    @State private var libraryDropTargeted = false
    /// The timeline's core scale — everything derives from pixels-per-second.
    @AppStorage("timelinePPS") private var pixelsPerSecond = 6.0
    @AppStorage("timelineSnap") private var snapEnabled = true
    @State private var timelineViewportWidth: CGFloat = 800
    @State private var timelineFocused = false
    /// J/K/L shuttle rate; repeat presses accelerate.
    @State private var shuttleRate: Float = 0
    @ObservedObject private var clientStore = ClientStore.shared
    @ObservedObject private var exportQueue = ExportQueue.shared
    @ObservedObject private var downloader = MediaDownloader.shared
    @Environment(\.undoManager) private var undoManager

    private var edit: ClipEdit { session.clipEdit }
    private var selectedClip: TimelineClip? {
        edit.clips.first { $0.id == selectedClipID }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showLibraryRail {
                libraryColumn.frame(width: 170).clipped()
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(spacing: 10) {
                offlineBanner
                preview
                transport
                timeline
            }
            if showInspectorRail {
                inspector
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
                .animation(.easeOut(duration: 0.15), value: showLibraryRail)
        .animation(.easeOut(duration: 0.15), value: showInspectorRail)
        // ⌥1 / ⌥2 collapse the rails — the viewer is the star; everything
        // else is dismissible.
        .background {
            Group {
                Button("") { showLibraryRail.toggle() }
                    .keyboardShortcut("1", modifiers: .option)
                Button("") { showInspectorRail.toggle() }
                    .keyboardShortcut("2", modifiers: .option)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .clipped()
        .onAppear {
            reloadPlayer()
            session.timelineUndoManager = undoManager
            session.refreshMissingMedia()
        }
        .onChange(of: edit.clips.map(\.sourcePath)) { _, _ in session.refreshMissingMedia() }
        .onChange(of: undoManager) { _, manager in
            session.timelineUndoManager = manager
        }
        .onDisappear { session.detachUndo() }
        .onChange(of: session.editComposition) { _, _ in reloadPlayer() }
        .onChange(of: edit.clips.map(\.id)) { _, ids in
            if selectedClipID == nil || !ids.contains(selectedClipID!) {
                selectedClipID = ids.first
            }
        }
        .onChange(of: selectedClipID) { _, id in
            if id != nil { inspectorTab = .clip }
        }
    }

    private func reloadPlayer() {
        player.pause()
        guard let composition = session.editComposition else { return }
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = session.editVideoComposition
        item.audioMix = session.editAudioMix
        player.load(item: item)
    }

    // MARK: - Preview

    private var preview: some View {
        // Color.clear takes exactly the size the layout proposes and the
        // stage renders inside it — an aspect view participating in the
        // HStack directly bargains for height×ratio width and shoves the
        // fixed rails off the window. Measured at 1280: 812px demanded.
        Color.clear
            .overlay {
            ZStack {
                Color.black
                if edit.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 34))
                            .foregroundStyle(Theme.textFaint)
                        Text("Nothing on the timeline yet")
                            .foregroundStyle(Theme.textSecondary)
                        Text("Send a clip here from the Shorts tab, or add any video below.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textFaint)
                    }
                } else {
                    PlayerSurface(player: player.player)
                }
                // The exact overlay the export burns — same renderer, same PNG.
                // During a text drag the locally rendered echo stands in.
                if let overlay = draftOverlay ?? session.editOverlay {
                    Image(nsImage: overlay)
                        .resizable()
                        .aspectRatio(edit.aspect.ratio, contentMode: .fit)
                        .allowsHitTesting(false)
                }
                // Timed text, gated by the playhead exactly as the export gates it.
                // The one being dragged is hidden — its echo is in draftOverlay.
                ForEach(session.editTimedTexts) { timed in
                    if textDraft?.id != timed.id,
                       player.currentTime >= timed.start, player.currentTime < timed.end {
                        Image(nsImage: timed.image)
                            .resizable()
                            .aspectRatio(edit.aspect.ratio, contentMode: .fit)
                            .allowsHitTesting(false)
                    }
                }
                overlayBoxes
                textHandles
            }
                .aspectRatio(edit.aspect.ratio, contentMode: .fit)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Dashed frames over each overlay video while it's on screen — drag to
    /// reposition. The preview shows the raw footage; chroma keys on export.
    private var overlayBoxes: some View {
        GeometryReader { geo in
            ForEach(edit.overlayClips.filter {
                overlayDrag?.id == $0.id
                    || (player.currentTime >= $0.startTime && player.currentTime < $0.endTime)
            }) { overlay in
                let dragging = overlayDrag?.id == overlay.id
                let x = dragging ? overlayDrag!.x : overlay.rect.x
                let y = dragging ? overlayDrag!.y : overlay.rect.y
                let width = geo.size.width * CGFloat(overlay.rect.width)
                let height = width * 9 / 16
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(dragging ? Theme.accent : Theme.accent.opacity(0.4),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(width: width, height: height)
                    .contentShape(Rectangle())
                    .position(x: geo.size.width * CGFloat(x) + width / 2,
                              y: geo.size.height * CGFloat(y) + height / 2)
                    .gesture(overlayDragGesture(for: overlay, in: geo.size))
            }
        }
    }

    private struct OverlayDrag {
        let id: UUID
        let baseX: Double
        let baseY: Double
        var x: Double
        var y: Double
    }
    @State private var overlayDrag: OverlayDrag?

    private func overlayDragGesture(for overlay: OverlayClip, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                var draft = overlayDrag ?? OverlayDrag(id: overlay.id,
                                                       baseX: overlay.rect.x, baseY: overlay.rect.y,
                                                       x: overlay.rect.x, y: overlay.rect.y)
                draft.x = min(0.98 - overlay.rect.width, max(0, draft.baseX + Double(value.translation.width / size.width)))
                draft.y = min(0.95, max(0, draft.baseY + Double(value.translation.height / size.height)))
                overlayDrag = draft
            }
            .onEnded { _ in
                guard let draft = overlayDrag else { return }
                var e = edit
                if let index = e.overlayClips.firstIndex(where: { $0.id == draft.id }) {
                    e.overlayClips[index].rect.x = draft.x
                    e.overlayClips[index].rect.y = draft.y
                    session.applyClipEdit(e, action: "Move Overlay")
                }
                overlayDrag = nil
            }
    }

    /// Grab areas over each text element, sized from the renderer's own
    /// measurement so what you grab is exactly what's drawn.
    private var textHandles: some View {
        GeometryReader { geo in
            ForEach(edit.textItems.filter {
                !$0.isBlank && (textDraft?.id == $0.id || $0.visible(at: player.currentTime))
            }) { item in
                let dragging = textDraft?.id == item.id
                let x = dragging ? textDraft!.x : item.x
                let y = dragging ? textDraft!.y : item.y
                let block = SocialOverlayRenderer.textBlockSize(for: item, aspect: edit.aspect)
                let scale = geo.size.width / CGFloat(edit.aspect.width)
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(dragging ? Theme.accent
                                  : hoveredTextID == item.id ? Theme.accent.opacity(0.55) : .clear,
                                  style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: max(44, block.width * scale + 8),
                           height: max(32, block.height * scale + 8))
                    .contentShape(Rectangle())
                    .position(x: geo.size.width * CGFloat(x), y: geo.size.height * CGFloat(y))
                    .onHover { hoveredTextID = $0 ? item.id : nil }
                    .gesture(textDragGesture(for: item, in: geo.size))
            }
        }
    }

    private func textDragGesture(for item: TextItem, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                // Translation is cumulative from the gesture's start, so it is
                // applied to the position captured then — not the current one.
                var draft = textDraft ?? TextDraft(id: item.id, baseX: item.x, baseY: item.y,
                                                   x: item.x, y: item.y)
                draft.x = min(0.98, max(0.02, draft.baseX + Double(value.translation.width / size.width)))
                draft.y = min(0.98, max(0.02, draft.baseY + Double(value.translation.height / size.height)))
                textDraft = draft
                if Date().timeIntervalSince(lastDraftRender) > 1.0 / 30 {
                    lastDraftRender = Date()
                    draftOverlay = SocialOverlayRenderer.image(for: echoEdit(applying: draft))
                }
            }
            .onEnded { _ in
                guard let draft = textDraft else { return }
                session.applyClipEdit(draftEdit(applying: draft), action: "Move Text")
                textDraft = nil
                draftOverlay = nil
            }
    }

    private func draftEdit(applying draft: TextDraft) -> ClipEdit {
        var e = session.clipEdit
        if let index = e.textItems.firstIndex(where: { $0.id == draft.id }) {
            e.textItems[index].x = draft.x
            e.textItems[index].y = draft.y
        }
        return e
    }

    /// The edit rendered as the live echo during a drag: same as the commit,
    /// except the dragged item is forced untimed so the static render shows it
    /// wherever the playhead happens to be. Timing is untouched on commit.
    private func echoEdit(applying draft: TextDraft) -> ClipEdit {
        var e = draftEdit(applying: draft)
        if let index = e.textItems.firstIndex(where: { $0.id == draft.id }) {
            e.textItems[index].duration = 0
        }
        return e
    }

    private func frameTimecode(_ time: Double) -> String {
        let total = max(0, time)
        let frames = Int(((total - floor(total)) * 60).rounded(.down))
        return String(format: "%d:%02d:%02d:%02d",
                      Int(total) / 3600, (Int(total) % 3600) / 60, Int(total) % 60, frames)
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 14)
            }
            .keyboardShortcut(.space, modifiers: [])
            Text("\(frameTimecode(player.currentTime)) / \(edit.exportDuration.shortTimecode)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .help("Position as H:MM:SS:frames at 60fps · sequence duration")
            if let clip = selectedClip {
                Text(String(format: "sel %.1fs", clip.effectiveDuration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
            }
            HStack(spacing: 2) {
                Button { showLibraryRail.toggle() } label: {
                    Image(systemName: "sidebar.left")
                        .foregroundStyle(showLibraryRail ? Theme.accent : Theme.textFaint)
                }
                .help("Library rail (⌥1)")
                Button { showInspectorRail.toggle() } label: {
                    Image(systemName: "sidebar.right")
                        .foregroundStyle(showInspectorRail ? Theme.accent : Theme.textFaint)
                }
                .help("Inspector rail (⌥2)")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            HStack(spacing: 2) {
                Button { undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!(undoManager?.canUndo ?? false))
                Button { undoManager?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!(undoManager?.canRedo ?? false))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help("Undo/redo every timeline change (⌘Z / ⇧⌘Z) — the Edit menu names each step")
            if session.lastSavedAt != nil {
                Label("autosaved", systemImage: "checkmark.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textFaint)
                    .help("Every change writes to the project immediately — there is no unsaved state to lose")
            }
            Menu {
                Button("Save snapshot…") { showSnapshotNamer = true }
                if !session.editSnapshots.isEmpty {
                    Divider()
                    ForEach(session.editSnapshots) { snapshot in
                        Menu("\(snapshot.name) — \(snapshot.duration.shortTimecode), \(snapshot.clipCount) clips") {
                            Button("Restore") { session.restoreSnapshot(snapshot) }
                            Button("Delete", role: .destructive) { session.deleteSnapshot(snapshot) }
                        }
                    }
                }
            } label: {
                Label("Versions", systemImage: "clock.arrow.circlepath")
                    .font(.caption2)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .onAppear { session.loadSnapshots() }
            .help("Named cuts that survive closing the project — save before trying something bold; restoring is one undo step")
            .alert("Save snapshot", isPresented: $showSnapshotNamer) {
                TextField("Name (e.g. v1 safe cut)", text: $snapshotName)
                Button("Save") {
                    session.saveSnapshot(named: snapshotName.isEmpty
                        ? "Cut \(Date().formatted(date: .abbreviated, time: .shortened))"
                        : snapshotName)
                    snapshotName = ""
                }
                Button("Cancel", role: .cancel) { snapshotName = "" }
            } message: {
                Text("Saves the whole timeline as a named version you can restore any time.")
            }
            if session.isPreparingTimelineClip {
                ProgressView(value: session.prepareProgress)
                    .frame(width: 90)
                Text("Rendering clip…")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Text("\(edit.clips.count) clip\(edit.clips.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(Theme.textFaint)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Icon cluster with tooltips — the labeled version demanded 814pt
            // minimum and pushed the inspector off any window under ~1500.
            HStack(spacing: 8) {
                SectionLabel(text: "Timeline")
                Picker("", selection: bind(\.aspect, action: "Change Aspect")) {
                    Image(systemName: "rectangle.portrait").tag(EditAspect.portrait)
                    Image(systemName: "rectangle").tag(EditAspect.landscape)
                }
                .pickerStyle(.segmented)
                .frame(width: 84)
                .help("Output frame: 9:16 vertical or 16:9 landscape")
                HStack(spacing: 2) {
                    Button {
                        session.addFreezeFrame(at: player.currentTime)
                    } label: {
                        Image(systemName: "pause.rectangle")
                    }
                    .disabled(edit.isEmpty)
                    .help("Freeze the frame under the playhead for 3 seconds")
                    Button {
                        session.splitClip(at: player.currentTime)
                    } label: {
                        Image(systemName: "scissors")
                    }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(edit.isEmpty)
                    .help("Blade the clip under the playhead (⌘B, or S when the timeline is focused)")
                    Toggle(isOn: $snapEnabled) {
                        Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
                    }
                    .toggleStyle(.button)
                    .help("Snapping — hold ⌥ to bypass")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                HStack(spacing: 2) {
                    Button { zoom(to: pixelsPerSecond / 1.4, proxy: scrollProxy) } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .keyboardShortcut("-", modifiers: .command)
                    Button { zoom(to: pixelsPerSecond * 1.4, proxy: scrollProxy) } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .keyboardShortcut("=", modifiers: .command)
                    Button { zoomToFit() } label: {
                        Image(systemName: "rectangle.arrowtriangle.2.inward")
                    }
                    .keyboardShortcut("0", modifiers: .command)
                    .help("Fit the whole sequence (⌘0)")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer(minLength: 4)
                Menu {
                    Button("Video file…") { addClipFile() }
                    if !session.shorts.isEmpty {
                        Menu("From this VOD's candidates") {
                            ForEach(session.shorts.filter { $0.status != .discarded }) { candidate in
                                Button("\(candidate.start.timecode) · \(candidate.title.isEmpty ? "clip" : candidate.title)") {
                                    session.addToTimeline(candidate)
                                }
                            }
                        }
                    }
                    Divider()
                    Button(edit.musicURL == nil ? "Add music…" : "Remove music") {
                        edit.musicURL == nil ? addMusicFile() : session.setTimelineMusic(nil)
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.accent)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a clip, a candidate, or the music bed")
            }

            HStack(spacing: 8) {
                Text("Crossfade")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Slider(value: Binding(
                    get: { edit.crossfadeDuration },
                    set: { var e = edit; e.crossfadeDuration = ($0 < 0.08 ? 0 : $0); session.applyClipEdit(e, action: "Crossfade") }
                ), in: 0...1.5)
                .frame(maxWidth: 180)
                Text(edit.crossfadeDuration > 0
                     ? String(format: "%.1fs", edit.crossfadeDuration) : "off")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 34)
                if edit.crossfadeDuration > 0 {
                    Picker("", selection: bind(\.transitionStyle)) {
                        ForEach(ClipEdit.transitions, id: \.name) { transition in
                            Text(transition.label).tag(transition.name)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help("The transition between clips — rendered on export; this preview cuts hard")
                    Text("Renders on export — this preview cuts hard.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textFaint)
                }
                Spacer()
            }

            HStack(alignment: .top, spacing: 0) {
                trackHeaderColumn
                GeometryReader { outer in
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: true) {
                            timelineContent
                        }
                        .onAppear {
                            scrollProxy = proxy
                            timelineViewportWidth = outer.size.width
                        }
                        .onChange(of: outer.size.width) { _, width in
                            timelineViewportWidth = width
                        }
                        .onChange(of: player.currentTime) { _, time in
                            // Auto-scroll follows the playhead during playback,
                            // throttled to once a second.
                            guard player.isPlaying,
                                  Date().timeIntervalSince(lastFollowScroll) > 1 else { return }
                            lastFollowScroll = Date()
                            proxy.scrollTo("playhead", anchor: UnitPoint(x: 0.35, y: 0.5))
                        }
                    }
                }
            }
            .frame(height: laneStackHeight)
            .background(timelineDropTargeted ? Theme.accent.opacity(0.12) : Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(timelineFocused ? Theme.accent.opacity(0.5)
                              : timelineDropTargeted ? Theme.accent : .clear,
                              lineWidth: timelineDropTargeted ? 2 : 1))
            .onDrop(of: [UTType.fileURL, UTType.plainText], isTargeted: $timelineDropTargeted) {
                handleTimelineDrop($0)
            }

            if let musicURL = edit.musicURL {
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                    Text(musicURL.lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Slider(value: Binding(
                        get: { edit.musicGainDB },
                        set: { var e = edit; e.musicGainDB = $0; session.applyClipEdit(e, action: "Music Volume") }
                    ), in: -40...0)
                    Text(String(format: "%.0f dB", edit.musicGainDB))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 46)
                    Divider().frame(height: 12)
                    Button {
                        session.detectBeats()
                    } label: {
                        if session.isDetectingBeats {
                            HStack(spacing: 3) {
                                ProgressView().controlSize(.mini)
                                Text("Listening…").font(.caption2)
                            }
                        } else if let bpm = session.beatBPM {
                            Text(String(format: "%.0f BPM", bpm)).font(.caption2)
                        } else {
                            Label("Beats", systemImage: "metronome").font(.caption2)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(session.isDetectingBeats)
                    .help("Find the bed's beat grid — steady beds only; drags and trims then snap to the downbeats")
                    if !session.beatGrid.isEmpty {
                        Toggle("Snap", isOn: $snapToBeats)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(.caption2)
                            .help("Snap clip edges to beats while dragging")
                    }
                }
            }
        }
    }

    @State private var scrollProxy: ScrollViewProxy?
    @State private var lastFollowScroll = Date.distantPast
    @State private var inPoint: Double?
    @State private var outPoint: Double?
    @State private var pinchStartPPS: Double?

    /// Which lanes exist right now, and how tall the whole stack is. The
    /// header column and the scroll content build from the same list so they
    /// can never misalign.
    private var overlayLaneCount: Int {
        edit.overlayClips.isEmpty ? 0 : (edit.overlayClips.map(\.lane).max() ?? 0) + 1
    }
    private var hasTextLane: Bool { edit.textItems.contains { $0.isTimed && !$0.isBlank } }
    private var laneStackHeight: CGFloat {
        var height: CGFloat = 22 + 68 + 8 + 14   // ruler + V1 + padding + scrollbar
        height += CGFloat(overlayLaneCount) * 28
        if hasTextLane { height += 30 }
        if edit.musicURL != nil { height += 20 }
        if edit.voiceoverPath != nil { height += 20 }
        return height
    }

    /// Ruler + every lane in one linear pixels-per-second space, the playhead
    /// across all of them, keyboard handling when focused.
    private var timelineContent: some View {
        let total = max(1, edit.totalDuration)
        let width = max(timelineViewportWidth, total * pixelsPerSecond + 40)
        return VStack(alignment: .leading, spacing: 2) {
            ruler(width: width, total: total)
            HStack(spacing: 0) {
                ForEach(Array(edit.clips.enumerated()), id: \.element.id) { index, clip in
                    clipBlock(clip)
                    if index < edit.clips.count - 1 {
                        rollHandle(after: index)
                    } else {
                        Color.clear.frame(width: 1)
                    }
                }
            }
            .frame(height: 68, alignment: .leading)
            ForEach(0..<overlayLaneCount, id: \.self) { lane in
                overlayLaneRow(lane: lane, total: total)
            }
            if hasTextLane {
                textLaneRow(total: total)
            }
            if !edit.sfxEvents.isEmpty {
                sfxLaneRow(total: total)
            }
            if let musicURL = edit.musicURL {
                bedRow(icon: "music.note", label: musicURL.deletingPathExtension().lastPathComponent,
                       from: 0, to: total, total: total, tint: Theme.positive)
                    .overlay(alignment: .topLeading) {
                        if !session.beatGrid.isEmpty {
                            ForEach(Array(session.beatGrid.enumerated()), id: \.offset) { _, beat in
                                Rectangle()
                                    .fill(Theme.playhead.opacity(0.8))
                                    .frame(width: 1, height: 5)
                                    .offset(x: beat * pixelsPerSecond, y: 0)
                            }
                        }
                    }
            }
            if edit.voiceoverPath != nil {
                bedRow(icon: "waveform", label: "voice-over",
                       from: edit.voiceoverStart, to: total, total: total, tint: Theme.warning)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(width: width + 12, alignment: .leading)
        .overlay(alignment: .topLeading) {
            // I/O range tint, under the playhead.
            if let inPoint, let outPoint, outPoint > inPoint {
                Rectangle()
                    .fill(Theme.accent.opacity(0.10))
                    .frame(width: (outPoint - inPoint) * pixelsPerSecond)
                    .offset(x: 6 + inPoint * pixelsPerSecond)
                    .allowsHitTesting(false)
            }
            // The playhead, spanning every lane.
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 1.5)
                .offset(x: 6 + player.currentTime * pixelsPerSecond)
                .allowsHitTesting(false)
            Color.clear.frame(width: 1, height: 1)
                .offset(x: 6 + player.currentTime * pixelsPerSecond)
                .id("playhead")
        }
        .focusable()
        .focused($timelineKeyFocus)
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .onChange(of: timelineKeyFocus) { _, value in timelineFocused = value }
        .contentShape(Rectangle())
        .onTapGesture { timelineKeyFocus = true }
        .simultaneousGesture(MagnifyGesture()
            .onChanged { value in
                if pinchStartPPS == nil { pinchStartPPS = pixelsPerSecond }
                zoom(to: (pinchStartPPS ?? pixelsPerSecond) * value.magnification,
                     proxy: scrollProxy)
            }
            .onEnded { _ in pinchStartPPS = nil })
        .dropDestination(for: URL.self) { urls, location in
            // Finder drop, placed where it lands: import and insert in one
            // action at the drop position.
            let time = min(max(0, Double(location.x - 6) / pixelsPerSecond), edit.totalDuration)
            for url in urls {
                session.addToLibrary(url)
                if MediaDownloader.isAudio(url) {
                    session.setTimelineMusic(url)
                } else {
                    session.addTimelineClip(from: url, at: time)
                }
            }
            return !urls.isEmpty
        }
    }

    /// The fixed column on the left: one header per lane, mute/solo/lock.
    private var trackHeaderColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 22)
            trackHeader("video", name: "V1", hasAudio: true).frame(height: 68)
            ForEach(0..<overlayLaneCount, id: \.self) { lane in
                trackHeader("overlays", name: "V\(lane + 2)", hasAudio: true).frame(height: 26)
            }
            if hasTextLane {
                trackHeader("text", name: "TEXT", hasAudio: false).frame(height: 28)
            }
            if !edit.sfxEvents.isEmpty {
                trackHeader("sfx", name: "SFX", hasAudio: true).frame(height: 22)
            }
            if edit.musicURL != nil {
                trackHeader("music", name: "MUS", hasAudio: true).frame(height: 18)
            }
            if edit.voiceoverPath != nil {
                trackHeader("voiceover", name: "VO", hasAudio: true).frame(height: 18)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .frame(width: 108)
        .background(Theme.surfaceRaised.opacity(0.35))
    }

    private func trackHeader(_ track: String, name: String, hasAudio: Bool) -> some View {
        let controls = edit.controls(track)
        return HStack(spacing: 3) {
            Text(name)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(controls.muted ? Theme.textFaint : Theme.textSecondary)
                .frame(width: 28, alignment: .leading)
            Button {
                var updated = controls; updated.muted.toggle()
                session.setTrackControls(track, updated)
            } label: {
                Image(systemName: controls.muted ? "speaker.slash.fill" : "speaker.wave.2")
                    .font(.system(size: 8))
                    .foregroundStyle(controls.muted ? Theme.danger : Theme.textFaint)
            }
            .buttonStyle(.plain)
            .help(track == "text" || track == "overlays"
                  ? "Mute hides this track in preview and export"
                  : "Mute silences this track in preview and export")
            if hasAudio {
                Button {
                    var updated = controls; updated.solo.toggle()
                    session.setTrackControls(track, updated)
                } label: {
                    Image(systemName: "headphones")
                        .font(.system(size: 8))
                        .foregroundStyle(controls.solo ? Theme.warning : Theme.textFaint)
                }
                .buttonStyle(.plain)
                .help("Solo — silences every non-soloed audio track")
            }
            Button {
                var updated = controls; updated.locked.toggle()
                session.setTrackControls(track, updated)
            } label: {
                Image(systemName: controls.locked ? "lock.fill" : "lock.open")
                    .font(.system(size: 8))
                    .foregroundStyle(controls.locked ? Theme.warning : Theme.textFaint)
            }
            .buttonStyle(.plain)
            .help("Lock — the track ignores edits until unlocked")
        }
    }

    /// The grab zone between two clips: drag to roll the cut — the left side
    /// grows as the right side shrinks, nothing downstream moves.
    private func rollHandle(after index: Int) -> some View {
        Rectangle()
            .fill(Theme.accent.opacity(0.001))
            .frame(width: 7, height: 68)
            .overlay(Rectangle().fill(Theme.border).frame(width: 1))
            .contentShape(Rectangle())
            .gesture(session.isTrackLocked("video") ? nil : DragGesture(minimumDistance: 3)
                .onEnded { value in
                    session.rollCut(after: index, by: Double(value.translation.width) / pixelsPerSecond)
                })
            .help("Drag to roll this cut — left side grows, right side shrinks")
    }

    private func overlayLaneRow(lane: Int, total: Double) -> some View {
        let locked = session.isTrackLocked("overlays")
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.surfaceRaised.opacity(0.25))
            ForEach(edit.overlayClips.filter { $0.lane == lane }) { overlay in
                let x = (overlayLaneDrag?.id == overlay.id ? overlayLaneDrag!.start : overlay.startTime)
                    * pixelsPerSecond
                Text(overlay.url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .frame(width: max(24, overlay.duration * pixelsPerSecond), height: 22,
                           alignment: .leading)
                    .background(Theme.accent.opacity(overlayLaneDrag?.id == overlay.id ? 0.5 : 0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .offset(x: x, y: 2)
                    .gesture(locked ? nil : DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            var draft = overlayLaneDrag
                                ?? (overlay.id, overlay.startTime, overlay.startTime)
                            draft.start = min(max(0, draft.base + Double(value.translation.width) / pixelsPerSecond),
                                              max(0, total - overlay.duration))
                            if snapEnabled, !NSEvent.modifierFlags.contains(.option),
                               let snapped = TimelineSnap.snapped(draft.start, to: snapTargets,
                                                                  threshold: 8 / max(0.4, pixelsPerSecond)) {
                                draft.start = min(max(0, snapped), max(0, total - overlay.duration))
                            }
                            overlayLaneDrag = draft
                        }
                        .onEnded { _ in
                            guard let draft = overlayLaneDrag else { return }
                            bindOverlay(overlay.id, \.startTime, action: "Move Overlay").wrappedValue = draft.start
                            overlayLaneDrag = nil
                        })
            }
        }
        .frame(height: 26)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @State private var overlayLaneDrag: (id: UUID, base: Double, start: Double)?

    private func textLaneRow(total: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.surface)
            ForEach(edit.textItems.filter { $0.isTimed && !$0.isBlank }) { item in
                textLaneBlock(item, width: total * pixelsPerSecond, total: total)
            }
        }
        .frame(height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// The SFX lane: one chip per event, draggable along the lane,
    /// right-click to remove or nudge volume.
    private func sfxLaneRow(total: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.surface)
            ForEach(edit.sfxEvents) { event in
                HStack(spacing: 3) {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 7))
                    Text(event.displayName).font(.system(size: 8)).lineLimit(1)
                    if abs(event.gainDB) > 0.05 {
                        Text(String(format: "%+.0f", event.gainDB))
                            .font(.system(size: 7, design: .monospaced))
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(Theme.danger.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .offset(x: (sfxDrag?.id == event.id
                            ? max(0, event.startTime + sfxDrag!.delta)
                            : event.startTime) * pixelsPerSecond,
                        y: 3)
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        sfxDrag = (event.id, Double(value.translation.width) / pixelsPerSecond)
                    }
                    .onEnded { value in
                        sfxDrag = nil
                        let target = max(0, min(total,
                            event.startTime + Double(value.translation.width) / pixelsPerSecond))
                        session.moveSFX(id: event.id, to: target)
                    })
                .contextMenu {
                    Button("Louder (+6 dB)") { session.setSFXGain(id: event.id, gainDB: event.gainDB + 6) }
                    Button("Quieter (−6 dB)") { session.setSFXGain(id: event.id, gainDB: event.gainDB - 6) }
                    Divider()
                    Button("Remove", role: .destructive) { session.removeSFX(id: event.id) }
                }
                .help("\(event.displayName) at \(event.startTime.shortTimecode) — drag to move")
            }
        }
        .frame(height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func bedRow(icon: String, label: String, from: Double, to: Double,
                        total: Double, tint: Color) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.surfaceRaised.opacity(0.2))
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 8))
                Text(label).font(.system(size: 8)).lineLimit(1)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 5)
            .frame(width: max(24, (to - from) * pixelsPerSecond), height: 14, alignment: .leading)
            .background(tint.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .offset(x: from * pixelsPerSecond, y: 2)
        }
        .frame(height: 18)
    }

    @FocusState private var timelineKeyFocus: Bool

    private func ruler(width: CGFloat, total: Double) -> some View {
        // Tick spacing: a nice step that lands roughly every 90 points.
        let roughStep = 90.0 / pixelsPerSecond
        let step = [1.0, 2, 5, 10, 15, 30, 60, 120, 300, 600]
            .first { $0 >= roughStep } ?? 600
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.surfaceRaised.opacity(0.4))
            ForEach(Array(stride(from: 0.0, through: total, by: step)), id: \.self) { tick in
                VStack(alignment: .leading, spacing: 0) {
                    Text(tick.shortTimecode)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.textFaint)
                    Rectangle().fill(Theme.border).frame(width: 1, height: 5)
                }
                .offset(x: tick * pixelsPerSecond)
            }
            ForEach(edit.markers) { marker in
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.warning)
                    .offset(x: marker.time * pixelsPerSecond - 4, y: 2)
                    .help(marker.note.isEmpty ? marker.time.shortTimecode : marker.note)
                    .onTapGesture { player.seek(to: marker.time, precise: true) }
                    .contextMenu {
                        Button("Remove Marker") { session.removeMarker(marker) }
                    }
            }
        }
        .frame(width: width, height: 22, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                let time = min(max(0, Double(value.location.x) / pixelsPerSecond), total)
                player.seek(to: time, precise: true)
            })
        .help("Click or drag to seek; M drops a marker at the playhead")
    }

    /// The focused-timeline keyboard layer. Text fields keep their keys —
    /// these only fire when the strip itself has focus.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let frame = 1.0 / 60
        switch press.key {
        case .space:
            player.togglePlay(); shuttleRate = 0
        case KeyEquivalent("j"):
            shuttleRate = shuttleRate < 0 ? max(-8, shuttleRate * 2) : -1
            player.player.rate = shuttleRate
        case KeyEquivalent("k"):
            shuttleRate = 0; player.pause()
        case KeyEquivalent("l"):
            shuttleRate = shuttleRate > 0 ? min(8, shuttleRate * 2) : 1
            player.player.rate = shuttleRate
        case KeyEquivalent("s"):
            session.splitClip(at: player.currentTime)
        case KeyEquivalent("m"):
            session.addMarker(at: player.currentTime)
        case KeyEquivalent("i"):
            inPoint = player.currentTime
            if let out = outPoint, out <= player.currentTime { outPoint = nil }
        case KeyEquivalent("o"):
            outPoint = player.currentTime
            if let inp = inPoint, inp >= player.currentTime { inPoint = nil }
        case KeyEquivalent("c") where press.modifiers.contains(.command):
            if let clip = selectedClip { session.copyClip(clip) }
        case KeyEquivalent("x") where press.modifiers.contains(.command):
            if let clip = selectedClip, !session.isTrackLocked("video") { session.cutClip(clip) }
        case KeyEquivalent("v") where press.modifiers.contains(.command):
            if !session.isTrackLocked("video") {
                session.pasteClip(after: selectedClip, playhead: player.currentTime)
            }
        case .leftArrow:
            player.seek(to: max(0, player.currentTime - (press.modifiers.contains(.shift) ? 1 : frame)),
                        precise: true)
        case .rightArrow:
            player.seek(to: min(edit.totalDuration,
                                player.currentTime + (press.modifiers.contains(.shift) ? 1 : frame)),
                        precise: true)
        case .home:
            player.seek(to: 0, precise: true)
        case .end:
            player.seek(to: edit.totalDuration, precise: true)
        case .deleteForward, .delete:
            guard !session.isTrackLocked("video") else { return .handled }
            if press.modifiers.contains(.shift), let inp = inPoint, let out = outPoint, out > inp {
                // Ripple delete the marked I/O range.
                session.deleteRange(from: inp, to: out)
                inPoint = nil
                outPoint = nil
            } else if let clip = selectedClip {
                session.removeTimelineClip(clip)
            }
        default:
            // 1–9 fire the first nine library sounds at the playhead.
            if let digit = press.key.character.wholeNumberValue, (1...9).contains(digit),
               press.modifiers.isEmpty {
                let sounds = session.sfxSounds
                guard sounds.indices.contains(digit - 1) else { return .ignored }
                session.addSFX(path: sounds[digit - 1].path, atTimeline: player.currentTime)
                return .handled
            }
            return .ignored
        }
        return .handled
    }

    private func blockWidth(_ clip: TimelineClip) -> CGFloat {
        max(26, clip.effectiveDuration * pixelsPerSecond)
    }

    private func zoom(to newValue: Double, proxy: ScrollViewProxy?) {
        pixelsPerSecond = min(80, max(0.4, newValue))
        // Anchor to the playhead — zoom that recentres on the start feels
        // broken.
        if let proxy {
            DispatchQueue.main.async {
                withAnimation(.none) { proxy.scrollTo("playhead", anchor: .center) }
            }
        }
    }

    private func zoomToFit() {
        let total = max(1, edit.totalDuration)
        pixelsPerSecond = min(80, max(0.4, (timelineViewportWidth - 40) / total))
    }

    /// Snap targets in seconds: playhead, every cut point, markers, start —
    /// and the beat grid when the bed's been analysed and snapping is on.
    private var snapTargets: [Double] {
        var targets: [Double] = [0, player.currentTime]
        var cursor: Double = 0
        for clip in edit.clips {
            cursor += clip.effectiveDuration
            targets.append(cursor)
        }
        targets += edit.markers.map(\.time)
        if snapToBeats, !session.beatGrid.isEmpty {
            targets += session.beatGrid
        }
        return targets
    }

    private func clipBlock(_ clip: TimelineClip) -> some View {
        let isSelected = selectedClipID == clip.id
        let isDragging = clipDrag?.id == clip.id
        let locked = session.isTrackLocked("video")
        let width = blockWidth(clip)
        return ZStack(alignment: .topLeading) {
            FilmstripView(clip: clip, width: width, fine: pixelsPerSecond >= 4)
            if let peaks = session.waveformSlice(for: clip) {
                ClipWaveformView(peaks: peaks)
                    .frame(height: 16)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .opacity(0.85)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(clip.displayName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.9), radius: 1.5)
                    .lineLimit(1)
                Text(clip.isFreeze
                     ? String(format: "❄︎ %.1fs", clip.effectiveDuration)
                     : abs(clip.speed - 1) > 0.001
                       ? String(format: "%.1fs · %.2g×", clip.effectiveDuration, clip.clampedSpeed)
                       : String(format: "%.1fs", clip.effectiveDuration))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.9), radius: 1.5)
            }
            .padding(4)
            // Motion keyframes: push apexes as diamonds, pan keys as dots.
            if clip.hasMotion {
                ForEach(Array(clip.zoomKeys.enumerated()), id: \.offset) { _, key in
                    if key.v > 1.001 {
                        Rectangle()
                            .fill(Theme.playhead)
                            .frame(width: 5, height: 5)
                            .rotationEffect(.degrees(45))
                            .position(x: key.t * pixelsPerSecond, y: 60)
                    }
                }
                ForEach(Array(clip.panKeys.enumerated()), id: \.offset) { _, key in
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 4, height: 4)
                        .position(x: key.t * pixelsPerSecond, y: 53)
                }
            }
        }
        .frame(width: width, height: 68, alignment: .topLeading)
        .background(Theme.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(alignment: .center) {
            // Offline media reads as a normal clip that renders nothing —
            // so it has to look wrong.
            if session.isOffline(clip) {
                ZStack {
                    Color.black.opacity(0.55)
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text("OFFLINE")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(Theme.danger)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .allowsHitTesting(false)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(session.isOffline(clip) ? Theme.danger
                          : isSelected ? Theme.accent : Theme.border.opacity(0.6),
                          lineWidth: session.isOffline(clip) || isSelected ? 2 : 1))
        .contentShape(Rectangle())
        .opacity(isDragging ? 0.85 : 1)
        .offset(x: isDragging ? clipDrag!.translation : 0)
        .zIndex(isDragging ? 1 : 0)
        .onTapGesture { selectedClipID = clip.id }
        .contextMenu { clipMenu(clip, locked: locked) }
        .gesture(locked ? nil : DragGesture(minimumDistance: 5)
            .onChanged { value in
                clipDrag = (clip.id, value.translation.width)
                selectedClipID = clip.id
            }
            .onEnded { value in
                clipDrag = nil
                reorderClip(clip, by: value.translation.width)
            })
    }

    private var preflightPanel: some View {
        preflightSection.panel()
    }

    /// The check you'd otherwise do by uploading and looking.
    @ViewBuilder
    private var preflightSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(text: "Preflight")
                InfoTip("Checks captions against TikTok/Reels/Shorts chrome, offline media, slivers, stray text and sound, and how your voice sits against the game — all before you spend a render.")
                Spacer()
                Button("Check") { runPreflight() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if let findings = preflight {
                if findings.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.positive)
                        Text("Nothing to flag.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    ForEach(findings) { finding in
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: finding.severity == .blocker ? "xmark.octagon.fill"
                                  : finding.severity == .warning ? "exclamationmark.triangle.fill"
                                  : "info.circle")
                                .font(.system(size: 9))
                                .foregroundStyle(finding.severity == .blocker ? Theme.danger
                                                 : finding.severity == .warning ? Theme.warning
                                                 : Theme.textFaint)
                            Text(finding.message)
                                .font(.caption2)
                                .foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let at = finding.at {
                                Spacer()
                                Button {
                                    player.seek(to: at, precise: true)
                                } label: { Image(systemName: "arrow.right.circle") }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Theme.textFaint)
                            }
                        }
                    }
                }
            }
        }
    }

    private func runPreflight() {
        session.refreshMissingMedia()
        preflight = PreflightService.run(
            edit: edit,
            captionStyle: session.project.captionStyle,
            captionsBurned: session.project.exportSettings.captionMode != .none,
            missingMedia: MediaRelinkService.groupedByFile(session.missingMedia).count,
            hasThumbnail: !session.thumbDoc.layers.isEmpty,
            audioProfile: session.audioProfile)
    }

    /// One bar when anything is offline, with the one-click fix.
    @ViewBuilder
    private var offlineBanner: some View {
        if !session.missingMedia.isEmpty {
            let groups = MediaRelinkService.groupedByFile(session.missingMedia)
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(groups.count) file\(groups.count == 1 ? "" : "s") missing")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(groups.prefix(3).map {
                        URL(fileURLWithPath: $0.path).lastPathComponent
                    }.joined(separator: ", ")
                        + (groups.count > 3 ? " and \(groups.count - 3) more" : ""))
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if session.isRelinking {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Searching…").font(.caption2)
                    }
                } else {
                    Button("Search a folder…") { locateFolder() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.danger)
                        .controlSize(.small)
                }
                InfoTip("Pick the folder your media moved into — every missing file is matched by name in one pass. Files whose extension changed still match on the name.")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.danger.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.danger.opacity(0.4), lineWidth: 1))
        }
    }

    private func locateFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder your media moved into — subfolders are searched too"
        panel.directoryURL = Paths.downloadsRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.relinkAll(searching: url)
    }

    private func locateOne(_ path: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Locate \(URL(fileURLWithPath: path).lastPathComponent)"
        panel.directoryURL = Paths.downloadsRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.relinkOne(path: path, to: url)
    }

    /// Right-click on a clip — the first place anyone looks for Delete.
    @ViewBuilder
    private func clipMenu(_ clip: TimelineClip, locked: Bool) -> some View {
        let start = session.startTime(of: clip)
        let playheadInside = start.map {
            player.currentTime > $0 + 0.25
                && player.currentTime < $0 + clip.effectiveDuration - 0.25
        } ?? false

        Button("Split at Playhead") { session.splitClip(at: player.currentTime) }
            .disabled(locked || !playheadInside)
        Button("Duplicate") { session.duplicateClip(clip) }
            .disabled(locked)
        Divider()
        Button("Cut") { session.cutClip(clip) }
            .disabled(locked)
        Button("Copy") { session.copyClip(clip) }
        Button("Paste After") {
            session.pasteClip(after: clip, playhead: player.currentTime)
        }
        .disabled(locked || session.clipClipboard == nil)
        Divider()
        if !clip.isFreeze {
            Button("Detect Punch-ins") {
                session.detectPunchIns(clipID: clip.id, intensity: punchIntensity)
            }
            Button("Auto-Reframe") { session.detectReframe(clipID: clip.id) }
                .disabled(session.isReframing)
            if clip.hasMotion {
                Button("Clear Motion") {
                    session.clearMotion(clipID: clip.id, zoom: true, pan: true)
                }
            }
            Divider()
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([clip.url])
        }
        .disabled(!FileManager.default.fileExists(atPath: clip.sourcePath))
        if session.isOffline(clip) {
            Button("Locate Missing File…") { locateOne(clip.sourcePath) }
        }
        Divider()
        Button("Delete", role: .destructive) { session.removeTimelineClip(clip) }
            .disabled(locked)
    }

    /// Where the dragged block's centre landed decides its new slot — nearest
    /// centre in the strip's own (non-linear) width scale.
    private func reorderClip(_ clip: TimelineClip, by translation: CGFloat) {
        guard abs(translation) > 8 else { return }
        var e = edit
        guard let from = e.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        let spacing: CGFloat = 1
        var centers: [CGFloat] = []
        var x: CGFloat = 0
        for c in e.clips {
            centers.append(x + blockWidth(c) / 2)
            x += blockWidth(c) + spacing
        }
        let landed = centers[from] + translation
        let to = centers.indices.min { abs(centers[$0] - landed) < abs(centers[$1] - landed) } ?? from
        guard to != from else { return }
        let moved = e.clips.remove(at: from)
        e.clips.insert(moved, at: to)
        session.applyClipEdit(e, action: "Move Clip")
        selectedClipID = clip.id
    }

    // MARK: - Inspector

    private var inspector: some View {
        VStack(spacing: 8) {
            Picker("", selection: $inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Image(systemName: tab.icon).tag(tab)
                        .help(tab.label)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(inspectorTab.label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.textFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch inspectorTab {
                    case .clip:
                        if let clip = selectedClip {
                            clipInspector(clip)
                        } else {
                            Text("Select a clip on the timeline to shape it — framing, motion, speed, audio.")
                                .font(.caption2)
                                .foregroundStyle(Theme.textFaint)
                                .fixedSize(horizontal: false, vertical: true)
                                .panel()
                        }
                    case .design:
                        socialsPanel
                        textPanel
                        overlaysPanel
                    case .audio:
                        voiceoverPanel
                        sfxPanel
                    case .polish:
                        preflightPanel
                        tightenPanel
                        hookPanel
                    case .ship:
                        postPanel
                        exportPanel
                    }
                }
                .padding(2)
            }
        }
        // Fixed width applied OUTSIDE the content, then clipped: whatever a
        // child does, nothing escapes the rail or the window again.
        .frame(width: 302)
        .clipped()
    }

    /// Which drawer of the inspector is open. Tabs replaced a 3000-point
    /// scroll of ten stacked panels.
    enum InspectorTab: String, CaseIterable, Identifiable {
        case clip, design, audio, polish, ship
        var id: String { rawValue }
        var label: String {
            switch self {
            case .clip: return "Clip"
            case .design: return "Design"
            case .audio: return "Audio"
            case .polish: return "Polish"
            case .ship: return "Ship"
            }
        }
        var icon: String {
            switch self {
            case .clip: return "film"
            case .design: return "paintbrush"
            case .audio: return "speaker.wave.2"
            case .polish: return "wand.and.stars"
            case .ship: return "shippingbox"
            }
        }
    }

    private var socialsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Overlay")
                Spacer()
                Menu {
                    ForEach(clientStore.clients) { client in
                        Button(client.name) { session.applyClientProfile(client) }
                    }
                    if !clientStore.clients.isEmpty { Divider() }
                    Button("Capture current look as a client") {
                        let fallback = session.project.clientName.isEmpty
                            ? session.project.name : session.project.clientName
                        let profile = session.captureClientProfile(named: fallback)
                        clientStore.upsert(profile)
                        session.applyClientProfile(profile)
                    }
                } label: {
                    Label(session.project.clientName.isEmpty
                          ? "Client" : session.project.clientName,
                          systemImage: "person.crop.circle")
                        .lineLimit(1)
                        .frame(maxWidth: 150)
                }
                .menuStyle(.borderlessButton)
                .help("Apply a saved client's handles, caption look, framing and vocabulary — or save this project's look as one. Manage the roster in the Dashboard.")
            }
            Text("Burned onto the clip exactly as shown — title at the top, handles beside the logos.")
                .font(.caption2)
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                TextField("Clip title", text: bind(\.title))
                    .textFieldStyle(.roundedBorder)
                Button { copyTitlePrompt() } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Copy a ready-made title prompt — paste it into claude.ai, covered by your plan, no API key")
            }
            if let note = titlePromptNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Image(systemName: "camera.circle.fill")
                    .foregroundStyle(Color(red: 0.87, green: 0.27, blue: 0.55))
                TextField("Instagram name", text: bind(\.instagramHandle))
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 6) {
                Image(systemName: "message.circle.fill")
                    .foregroundStyle(Theme.accent)
                TextField("Twitch name", text: bind(\.twitchHandle))
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                Toggle("Socials", isOn: bind(\.showHandles))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Hide the whole handles block without clearing the names")
                if edit.showHandles {
                    Picker("", selection: bind(\.handlesOnRight)) {
                        Text("Left").tag(false)
                        Text("Right").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                }
                Spacer()
            }
            .font(.caption)
            if edit.showHandles {
                LabeledContent("Handles height") {
                    Slider(value: bind(\.handleY), in: 0.2...0.85)
                }
                .font(.caption)
            }
        }
        .panel()
    }

    private func clipInspector(_ clip: TimelineClip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Selected clip")
            Text(clip.displayName)
                .font(.caption)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            LabeledContent("In") {
                HStack {
                    Slider(value: Binding(
                        get: { clip.start },
                        set: { var c = clip; c.start = min($0, c.end - 0.5); session.updateTimelineClip(c) }
                    ), in: 0...clip.sourceDuration)
                    Text(clip.start.shortTimecode)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 48)
                }
            }
            LabeledContent("Out") {
                HStack {
                    Slider(value: Binding(
                        get: { clip.end },
                        set: { var c = clip; c.end = max($0, c.start + 0.5); session.updateTimelineClip(c) }
                    ), in: 0...clip.sourceDuration)
                    Text(clip.end.shortTimecode)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 48)
                }
            }

            Divider()
            HStack {
                Text("Framing & audio")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                if clip.hasAdjustments {
                    Button("Reset") {
                        var c = clip
                        c.zoom = 1; c.centerX = 0.5; c.centerY = 0.5; c.gainDB = 0
                        session.updateTimelineClip(c)
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }
            LabeledContent("Zoom") {
                HStack {
                    Slider(value: Binding(
                        get: { clip.zoom },
                        set: { var c = clip; c.zoom = $0; session.updateTimelineClip(c) }
                    ), in: 1...3)
                    Text(String(format: "%.2f×", clip.zoom))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 42)
                }
            }
            LabeledContent("Across") {
                Slider(value: Binding(
                    get: { clip.centerX },
                    set: { var c = clip; c.centerX = $0; session.updateTimelineClip(c) }
                ), in: 0...1)
            }
            LabeledContent("Down") {
                Slider(value: Binding(
                    get: { clip.centerY },
                    set: { var c = clip; c.centerY = $0; session.updateTimelineClip(c) }
                ), in: 0...1)
            }
            LabeledContent("Audio") {
                HStack {
                    Slider(value: Binding(
                        get: { clip.gainDB },
                        set: { var c = clip; c.gainDB = $0; session.updateTimelineClip(c) }
                    ), in: -36...12)
                    Text(abs(clip.gainDB) < 0.05 ? "0 dB" : String(format: "%+.0f dB", clip.gainDB))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 42)
                }
            }
            if !clip.isFreeze {
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: Binding(
                            get: { clip.speed },
                            set: { value in
                                var c = clip
                                // Snap near the common stops.
                                let stops: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3]
                                c.speed = stops.first(where: { abs($0 - value) < 0.06 }) ?? value
                                session.updateTimelineClip(c)
                            }
                        ), in: 0.25...3)
                        Text(String(format: "%.2f×", clip.clampedSpeed))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(abs(clip.speed - 1) > 0.001 ? Theme.accent : Theme.textSecondary)
                            .frame(width: 42)
                    }
                }
                if abs(clip.speed - 1) > 0.001 {
                    Text("Preview varispeeds (pitch shifts); the export keeps pitch with atempo.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Held still — trim In/Out to set how long it holds. Audio is silent.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            InfoTip("Zoom rides on top of the vertical fill; Across/Down pick which part stays when the clip is wider or taller than the frame. Audio is this clip only — music has its own slider.")

            if !clip.isFreeze {
                Divider()
                HStack {
                    Text("Motion")
                        .font(.caption2)
                        .foregroundStyle(Theme.textFaint)
                    Spacer()
                    if clip.hasMotion {
                        Text("\(clip.zoomKeys.count / 4) push · \(clip.panKeys.count) pan")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                    }
                }
                LabeledContent("Punch") {
                    HStack(spacing: 5) {
                        Slider(value: $punchIntensity, in: 1.05...1.3)
                        Text(String(format: "%.0f%%", (punchIntensity - 1) * 100))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 32)
                    }
                }
                HStack(spacing: 5) {
                    Button("Detect punch-ins") {
                        session.detectPunchIns(clipID: clip.id, intensity: punchIntensity)
                    }
                    Button("Push here") {
                        session.addPunchIn(atTimeline: player.currentTime,
                                           intensity: punchIntensity)
                    }
                    if !clip.zoomKeys.isEmpty {
                        Button("Clear") {
                            session.clearMotion(clipID: clip.id, zoom: true, pan: false)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                HStack(spacing: 5) {
                    Button {
                        session.detectReframe(clipID: clip.id)
                    } label: {
                        if session.isReframing {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini)
                                Text("Tracking…")
                            }
                        } else {
                            Text("Auto-reframe")
                        }
                    }
                    .disabled(session.isReframing)
                    if !clip.panKeys.isEmpty {
                        Button("Clear pan") {
                            session.clearMotion(clipID: clip.id, zoom: false, pan: true)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                InfoTip("Punch-ins zoom on loud moments; auto-reframe pans the crop after faces or action. Both preview live and export identically.")
            }

            if clip.candidateID != nil {
                Toggle("Captions", isOn: Binding(
                    get: { clip.hasCaptions },
                    set: { session.setTimelineClipCaptions(clip, on: $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(session.isPreparingTimelineClip)
                Text("Captions in a rendered piece are pixels — flipping this re-renders the clip.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button { session.moveTimelineClip(clip, forward: false) } label: {
                    Image(systemName: "arrow.left")
                }
                Button { session.moveTimelineClip(clip, forward: true) } label: {
                    Image(systemName: "arrow.right")
                }
                Spacer()
                Button(role: .destructive) { session.removeTimelineClip(clip) } label: {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .font(.caption)
        .panel()
    }

    // MARK: - Text lane


    private struct LaneDraft {
        enum Mode { case move, trimLeft, trimRight }
        let id: UUID
        let mode: Mode
        let baseStart: Double
        let baseDuration: Double
        var start: Double
        var duration: Double
    }
    @State private var laneDraft: LaneDraft?

    private func textLaneBlock(_ item: TextItem, width: CGFloat, total: Double) -> some View {
        let draft = laneDraft?.id == item.id ? laneDraft : nil
        let start = draft?.start ?? item.startTime
        let duration = draft?.duration ?? item.duration
        let x = CGFloat(start / total) * width
        let w = max(26, CGFloat(duration / total) * width)
        let active = draft != nil
        return Text(item.text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(width: w, height: 24, alignment: .leading)
            .background(active ? Theme.accent.opacity(0.5) : Theme.accent.opacity(0.28))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(active ? Theme.accent : Theme.accent.opacity(0.5), lineWidth: 1))
            .overlay(alignment: .leading) {
                laneHandle.gesture(laneGesture(item, mode: .trimLeft, width: width, total: total))
            }
            .overlay(alignment: .trailing) {
                laneHandle.gesture(laneGesture(item, mode: .trimRight, width: width, total: total))
            }
            .contentShape(Rectangle())
            .gesture(laneGesture(item, mode: .move, width: width, total: total))
            .offset(x: x, y: 3)
    }

    private var laneHandle: some View {
        Rectangle()
            .fill(Theme.accent.opacity(0.001))
            .frame(width: 9, height: 24)
            .overlay(Capsule().fill(Theme.accent.opacity(0.8)).frame(width: 2, height: 12))
            .contentShape(Rectangle())
    }

    private func laneGesture(_ item: TextItem, mode: LaneDraft.Mode,
                             width: CGFloat, total: Double) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                var draft = laneDraft ?? LaneDraft(id: item.id, mode: mode,
                                                   baseStart: item.startTime,
                                                   baseDuration: item.duration,
                                                   start: item.startTime,
                                                   duration: item.duration)
                let dt = Double(value.translation.width / width) * total
                switch draft.mode {
                case .move:
                    draft.start = min(max(0, draft.baseStart + dt),
                                      max(0, total - draft.baseDuration))
                case .trimRight:
                    draft.duration = min(max(0.3, draft.baseDuration + dt),
                                         total - draft.baseStart)
                case .trimLeft:
                    let end = draft.baseStart + draft.baseDuration
                    let start = min(max(0, draft.baseStart + dt), end - 0.3)
                    draft.start = start
                    draft.duration = end - start
                }
                // Snap to the playhead, cut points and markers — ⌥ bypasses.
                if snapEnabled, !NSEvent.modifierFlags.contains(.option) {
                    let threshold = 8.0 / max(0.4, pixelsPerSecond)
                    switch draft.mode {
                    case .move:
                        if let snapped = TimelineSnap.snapped(draft.start, to: snapTargets,
                                                              threshold: threshold) {
                            draft.start = min(max(0, snapped), max(0, total - draft.duration))
                        } else if let snapped = TimelineSnap.snapped(draft.start + draft.duration,
                                                                     to: snapTargets,
                                                                     threshold: threshold) {
                            draft.start = min(max(0, snapped - draft.duration),
                                              max(0, total - draft.duration))
                        }
                    case .trimRight:
                        if let snapped = TimelineSnap.snapped(draft.start + draft.duration,
                                                              to: snapTargets, threshold: threshold),
                           snapped - draft.start >= 0.3 {
                            draft.duration = min(snapped - draft.start, total - draft.start)
                        }
                    case .trimLeft:
                        let end = draft.start + draft.duration
                        if let snapped = TimelineSnap.snapped(draft.start, to: snapTargets,
                                                              threshold: threshold),
                           end - snapped >= 0.3 {
                            draft.start = max(0, snapped)
                            draft.duration = end - draft.start
                        }
                    }
                }
                laneDraft = draft
            }
            .onEnded { _ in
                guard let draft = laneDraft else { return }
                var e = edit
                if let index = e.textItems.firstIndex(where: { $0.id == draft.id }) {
                    e.textItems[index].startTime = draft.start
                    e.textItems[index].duration = draft.duration
                    session.applyClipEdit(e, action: "Text Timing")
                }
                laneDraft = nil
            }
    }

    // MARK: - Library

    private var libraryColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Library")
            Text(libraryDropTargeted
                 ? "Drop to add to the library"
                 : "Drop video files here, then drag anything onto the timeline. Double-click adds it too.")
                .font(.caption2)
                .foregroundStyle(libraryDropTargeted ? Theme.accent : Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(edit.library, id: \.self) { path in
                        libraryFileRow(path)
                    }
                    if edit.library.isEmpty {
                        Text("No files yet")
                            .font(.caption2)
                            .foregroundStyle(Theme.textFaint)
                            .padding(.vertical, 4)
                    }

                    HStack(spacing: 6) {
                        Text("DOWNLOADS")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textFaint)
                        Spacer()
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([Paths.downloadsRoot])
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textFaint)
                        .help("Show the Clips folder in Finder — Desktop → VOD_Editor → Clips")
                        Button {
                            NotificationCenter.default.post(name: .requestMediaBrowser, object: nil)
                        } label: {
                            Image(systemName: "globe")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .help("Browse YouTube and download video or audio straight into this list")
                    }
                    .padding(.top, 8)
                    ForEach(downloader.files, id: \.self) { url in
                        downloadRow(url)
                    }
                    if downloader.files.isEmpty {
                        Text("Nothing downloaded yet — the globe opens a YouTube browser.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textFaint)
                    }

                    let candidates = session.shorts.filter { $0.status != .discarded }
                    if !candidates.isEmpty {
                        Text("THIS VOD'S CLIPS")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textFaint)
                            .padding(.top, 8)
                        ForEach(candidates) { candidate in
                            candidateRow(candidate)
                        }
                    }
                }
            }
        }
        .onAppear { downloader.refresh() }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(libraryDropTargeted ? Theme.accent.opacity(0.10) : Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(libraryDropTargeted ? Theme.accent : Theme.border,
                          lineWidth: libraryDropTargeted ? 2 : 1))
        .onDrop(of: [UTType.fileURL], isTargeted: $libraryDropTargeted) { providers in
            handleFileDrop(providers) { session.addToLibrary($0) }
        }
    }

    private func libraryFileRow(_ path: String) -> some View {
        let url = URL(fileURLWithPath: path)
        return HStack(spacing: 5) {
            Image(systemName: "film")
                .font(.system(size: 9))
                .foregroundStyle(Theme.accent)
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.caption2)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                session.removeFromLibrary(path)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textFaint)
        }
        .padding(5)
        .background(Theme.surfaceRaised.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(object: "vodlib-file:\(path)" as NSString) }
        .onTapGesture(count: 2) { session.addTimelineClip(from: url) }
        .help("Drag onto the timeline, or double-click to add")
    }

    private func downloadRow(_ url: URL) -> some View {
        let isAudio = MediaDownloader.isAudio(url)
        return HStack(spacing: 5) {
            Image(systemName: isAudio ? "music.note" : "film")
                .font(.system(size: 9))
                .foregroundStyle(isAudio ? Theme.warning : Theme.accent)
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.caption2)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                downloader.delete(url)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textFaint)
        }
        .padding(5)
        .background(Theme.surfaceRaised.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(object: "vodlib-file:\(url.path)" as NSString) }
        .onTapGesture(count: 2) {
            isAudio ? session.setTimelineMusic(url) : session.addTimelineClip(from: url)
        }
        .help(isAudio ? "Audio — drag or double-click to set as the music bed"
                      : "Drag onto the timeline, or double-click to add")
    }

    private func candidateRow(_ candidate: ShortCandidate) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 8))
                .foregroundStyle(Theme.warning)
            Text(candidate.start.timecode)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            Text(candidate.title.isEmpty ? "clip" : candidate.title)
                .font(.caption2)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .padding(5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceRaised.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(object: "vodlib-cand:\(candidate.id.uuidString)" as NSString) }
        .onTapGesture(count: 2) { session.addToTimeline(candidate) }
        .help("Drag onto the timeline, or double-click to add — renders as a portrait piece first")
    }

    /// Finder drops carry file URLs; internal drags carry a tagged string.
    /// File URLs are checked first because a URL also loads as a string.
    private func handleTimelineDrop(_ providers: [NSItemProvider]) -> Bool {
        if handleFileDrop(providers, action: { url in
            session.addToLibrary(url)
            session.addTimelineClip(from: url)
        }) { return true }
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
            handled = true
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let string = object as? String else { return }
                DispatchQueue.main.async { self.handleInternalDrop(string) }
            }
        }
        return handled
    }

    private func handleInternalDrop(_ payload: String) {
        if payload.hasPrefix("vodlib-file:") {
            let path = String(payload.dropFirst("vodlib-file:".count))
            let url = URL(fileURLWithPath: path)
            // Audio has no video stream to cut into the reel — it becomes the
            // music bed instead.
            MediaDownloader.isAudio(url)
                ? session.setTimelineMusic(url)
                : session.addTimelineClip(from: url)
        } else if payload.hasPrefix("vodlib-cand:") {
            let raw = String(payload.dropFirst("vodlib-cand:".count))
            if let id = UUID(uuidString: raw),
               let candidate = session.shorts.first(where: { $0.id == id }) {
                session.addToTimeline(candidate)
            }
        }
    }

    @discardableResult
    private func handleFileDrop(_ providers: [NSItemProvider],
                                action: @escaping (URL) -> Void) -> Bool {
        var handled = false
        for provider in providers
        where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { action(url) }
            }
        }
        return handled
    }

    // MARK: - Text panel

    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Text")
                Spacer()
                Button { addTextItem() } label: {
                    Label("Add text", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Text(edit.textItems.isEmpty
                 ? "Extra words anywhere on the frame — add a line, then drag it into place on the preview."
                 : "Drag any line right on the preview, or use the sliders.")
                .font(.caption2)
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(edit.textItems) { item in
                textRow(item)
            }
        }
        .panel()
    }

    private func textRow(_ item: TextItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Text", text: bindText(item.id, \.text))
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive) {
                    var e = edit
                    e.textItems.removeAll { $0.id == item.id }
                    session.applyClipEdit(e, action: "Delete Text")
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            HStack(spacing: 6) {
                ForEach(TextItem.palette, id: \.self) { hex in
                    Circle()
                        .fill(Color(nsColor: SocialOverlayRenderer.color(hex: hex)))
                        .overlay(Circle().strokeBorder(
                            item.colorHex == hex ? Theme.accent : Theme.border,
                            lineWidth: item.colorHex == hex ? 2 : 1))
                        .frame(width: 16, height: 16)
                        .contentShape(Circle())
                        .onTapGesture { bindText(item.id, \.colorHex).wrappedValue = hex }
                }
                Spacer()
                Image(systemName: "textformat.size")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textFaint)
                Slider(value: bindText(item.id, \.size), in: 0.018...0.09)
                    .frame(width: 90)
            }
            LabeledContent("Across") {
                Slider(value: bindText(item.id, \.x), in: 0.02...0.98)
            }
            LabeledContent("Down") {
                Slider(value: bindText(item.id, \.y), in: 0.02...0.98)
            }
            HStack(spacing: 6) {
                if item.isTimed {
                    Button("Whole video") {
                        bindText(item.id, \.duration).wrappedValue = 0
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    Text(String(format: "%@ for %.1fs", item.startTime.shortTimecode, item.duration))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Button("Time it") {
                        var e = edit
                        if let index = e.textItems.firstIndex(where: { $0.id == item.id }) {
                            let total = max(0.4, e.totalDuration)
                            e.textItems[index].startTime = min(max(0, player.currentTime), total - 0.4)
                            e.textItems[index].duration = min(3, total - e.textItems[index].startTime)
                            session.applyClipEdit(e, action: "Text Timing")
                        }
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    Text("shows the whole video — Time it starts a window at the playhead")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            if item.isTimed {
                LabeledContent("At") {
                    Slider(value: bindText(item.id, \.startTime),
                           in: 0...max(0.1, edit.totalDuration))
                }
                LabeledContent("For") {
                    Slider(value: bindText(item.id, \.duration),
                           in: 0.3...max(0.4, edit.totalDuration))
                }
            }
        }
        .font(.caption)
        .padding(6)
        .background(Theme.surfaceRaised.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func addTextItem() {
        var e = edit
        // Stagger new lines down the frame so two adds don't stack invisibly.
        let y = 0.28 + Double(e.textItems.count % 5) * 0.09
        e.textItems.append(TextItem(text: "Your text", y: y))
        session.applyClipEdit(e, action: "Add Text")
    }

    // MARK: - Overlays panel

    private var overlaysPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Overlays")
                Spacer()
                Button { addOverlayFile() } label: {
                    Label("Add video", systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(edit.isEmpty)
            }
            Text("Video on top of the cut — green-screen clips from the media browser drop right in, keyed live in the preview exactly as they'll export. Drag the dashed box to move it.")
                .font(.caption2)
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(edit.overlayClips) { overlay in
                overlayRow(overlay)
            }
        }
        .panel()
    }

    private func overlayRow(_ overlay: OverlayClip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.inset.filled.on.rectangle")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                Text(overlay.url.deletingPathExtension().lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(role: .destructive) {
                    session.removeOverlayClip(overlay)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            LabeledContent("At") {
                HStack {
                    Slider(value: bindOverlay(overlay.id, \.startTime),
                           in: 0...max(0.1, edit.totalDuration))
                    Text(overlay.startTime.shortTimecode)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 40)
                }
            }
            LabeledContent("For") {
                HStack {
                    Slider(value: bindOverlay(overlay.id, \.duration),
                           in: 0.5...max(0.6, edit.totalDuration))
                    Text(String(format: "%.1fs", overlay.duration))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 40)
                }
            }
            LabeledContent("Size") {
                Slider(value: bindOverlay(overlay.id, \.rect.width), in: 0.12...0.9)
            }

            Divider()

            Toggle("Key out a colour", isOn: bindOverlay(overlay.id, \.chromaEnabled))
                .toggleStyle(.switch)
                .controlSize(.small)
            if overlay.chromaEnabled {
                HStack(spacing: 6) {
                    ForEach(["00FF00", "0000FF"], id: \.self) { hex in
                        Circle()
                            .fill(Color(nsColor: SocialOverlayRenderer.color(hex: hex)))
                            .overlay(Circle().strokeBorder(
                                overlay.chromaHex == hex ? Theme.accent : Theme.border,
                                lineWidth: overlay.chromaHex == hex ? 2 : 1))
                            .frame(width: 16, height: 16)
                            .contentShape(Circle())
                            .onTapGesture { bindOverlay(overlay.id, \.chromaHex).wrappedValue = hex }
                    }
                    Text(overlay.chromaHex == "00FF00" ? "green" : "blue")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textFaint)
                    Spacer()
                }
                LabeledContent("Strength") {
                    HStack {
                        Slider(value: bindOverlay(overlay.id, \.chromaSimilarity), in: 0.05...0.6)
                        Text(String(format: "%.2f", overlay.chromaSimilarity))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 34)
                    }
                }
                .help("Raise it if green fringes remain; lower it if the subject starts disappearing")
                LabeledContent("Edge") {
                    HStack {
                        Slider(value: bindOverlay(overlay.id, \.chromaBlend), in: 0...0.3)
                        Text(String(format: "%.2f", overlay.chromaBlend))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 34)
                    }
                }
                .help("Softens the cut-out edge — a little hides compression fringing")
            }

            Divider()

            Toggle("Mute this clip", isOn: bindOverlay(overlay.id, \.muted))
                .toggleStyle(.switch)
                .controlSize(.small)
            if !overlay.muted {
                LabeledContent("Volume") {
                    HStack {
                        Slider(value: bindOverlay(overlay.id, \.gainDB), in: -36...12)
                        Text(abs(overlay.gainDB) < 0.05
                             ? "0 dB" : String(format: "%+.0f dB", overlay.gainDB))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 44)
                    }
                }
            }
        }
        .font(.caption)
        .padding(6)
        .background(Theme.surfaceRaised.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func bindOverlay<T>(_ id: UUID, _ path: WritableKeyPath<OverlayClip, T>,
                                action: String = "Edit Overlay") -> Binding<T> {
        Binding(
            get: {
                (session.clipEdit.overlayClips.first { $0.id == id }
                    ?? OverlayClip(sourcePath: ""))[keyPath: path]
            },
            set: { value in
                var e = session.clipEdit
                guard let index = e.overlayClips.firstIndex(where: { $0.id == id }) else { return }
                e.overlayClips[index][keyPath: path] = value
                session.applyClipEdit(e, action: action)
            }
        )
    }

    private func addOverlayFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .video]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a video to lay on top — green-screen content keys out on export"
        if let last = UserDefaults.standard.string(forKey: "lastTimelineFolder") {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.addOverlayVideo(from: url, at: player.currentTime)
    }

    // MARK: - Voice-over panel

    @StateObject private var voiceRecorder = VoiceoverRecorder()

    /// The first-3-seconds check: loop the open, read the verdicts.
    private var hookPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Hook")
                Spacer()
                Button {
                    hookLooping.toggle()
                    if hookLooping {
                        player.seek(to: 0, precise: true)
                        player.play()
                    } else {
                        player.pause()
                    }
                } label: {
                    Label(hookLooping ? "Stop loop" : "Loop first 3s",
                          systemImage: hookLooping ? "stop.circle" : "repeat.circle")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(edit.isEmpty)
            }
            Button("Check the hook") { hookReport = session.hookReport() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(edit.isEmpty)
            if let report = hookReport {
                ForEach(Array(report.findings.enumerated()), id: \.offset) { _, finding in
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: finding.severity == .good ? "checkmark.circle.fill"
                              : finding.severity == .warn ? "exclamationmark.triangle.fill"
                              : "xmark.octagon.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(finding.severity == .good ? Theme.positive
                                             : finding.severity == .warn ? Theme.warning
                                             : Theme.danger)
                        Text(finding.message)
                            .font(.caption2)
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                InfoTip("Retention is won in the first 3 seconds: when the talk starts, how dense it is, where the payoff lands.")
            }
        }
        .panel()
        .onChange(of: player.currentTime) { _, time in
            if hookLooping, time > 3.05 {
                player.seek(to: 0, precise: true)
                player.play()
            }
        }
    }

    /// Dead-air and filler tightening: preview what would go, then one
    /// undoable pass. Entirely from word timings already on disk.
    private var tightenPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Tighten")
            LabeledContent("Strength") {
                HStack(spacing: 5) {
                    Text("Gentle").font(.system(size: 8)).foregroundStyle(Theme.textFaint)
                    Slider(value: $tightenAggressiveness, in: 0...1)
                        .onChange(of: tightenAggressiveness) { _, _ in
                            if tightenCuts != nil { refreshTighten() }
                        }
                    Text("Tight").font(.system(size: 8)).foregroundStyle(Theme.textFaint)
                }
            }
            Toggle("Cut filler words (um, uh…)", isOn: $tightenFillers)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .onChange(of: tightenFillers) { _, _ in
                    if tightenCuts != nil { refreshTighten() }
                }
            HStack(spacing: 6) {
                Button("Preview cuts") { refreshTighten() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if let cuts = tightenCuts, !cuts.isEmpty {
                    Button("Apply \(cuts.count) cut\(cuts.count == 1 ? "" : "s")") {
                        session.applyTighten(cuts)
                        tightenCuts = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.small)
                }
            }
            if let cuts = tightenCuts {
                if cuts.isEmpty {
                    Text("Nothing to cut at this strength — the take is already tight.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textFaint)
                } else {
                    let saved = cuts.reduce(0) { $0 + $1.duration }
                    Text(String(format: "%d cut(s) · %.1fs removed · %@ → %@",
                                cuts.count, saved,
                                edit.totalDuration.shortTimecode,
                                max(0, edit.totalDuration - saved).shortTimecode))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.positive)
                    ForEach(Array(cuts.prefix(6).enumerated()), id: \.offset) { _, cut in
                        HStack(spacing: 5) {
                            Text(cut.start.shortTimecode)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                            Text(cut.reason == "silence"
                                 ? String(format: "%.1fs silence", cut.duration)
                                 : "\"\(cut.reason)\"")
                                .font(.caption2)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Button {
                                player.seek(to: max(0, cut.start - 1), precise: true)
                            } label: {
                                Image(systemName: "play.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.textFaint)
                        }
                    }
                    if cuts.count > 6 {
                        Text("… and \(cuts.count - 6) more")
                            .font(.caption2)
                            .foregroundStyle(Theme.textFaint)
                    }
                }
            } else {
                InfoTip("Closes gaps in the talk and drops stand-alone \"um\"s. Preview first; applying is one undo step.")
            }
        }
        .panel()
    }

    private func refreshTighten() {
        tightenCuts = session.tightenPlan(aggressiveness: tightenAggressiveness,
                                          removeFillers: tightenFillers)
    }

    /// The sound-effect drawer: the Finder library flat, click to drop at
    /// the playhead, 1–9 from the timeline for the first nine.
    private var sfxPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Sound effects")
                Spacer()
                Button {
                    NSWorkspace.shared.open(Paths.sfxRoot)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textFaint)
                .help("Open the SFX folder — drop packs in, subfolders become tags")
                Button {
                    session.rescanSFX()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textFaint)
            }
            if session.sfxSounds.isEmpty {
                Text("No sounds yet. Drop audio files into the SFX folder, or start with placeholders.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    session.generateSFXStarterPack()
                } label: {
                    if session.isGeneratingSFX {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Generating…")
                        }
                    } else {
                        Text("Generate starter pack")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(session.isGeneratingSFX)
            } else {
                TextField("Filter", text: $sfxFilter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                let shown = session.sfxSounds.filter {
                    sfxFilter.isEmpty
                        || $0.name.localizedCaseInsensitiveContains(sfxFilter)
                        || $0.tag.localizedCaseInsensitiveContains(sfxFilter)
                }
                ForEach(Array(shown.prefix(24).enumerated()), id: \.element.id) { index, sound in
                    HStack(spacing: 5) {
                        if let hotkey = session.sfxSounds.firstIndex(where: { $0.id == sound.id }),
                           hotkey < 9 {
                            Text("\(hotkey + 1)")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 10)
                        } else {
                            Color.clear.frame(width: 10, height: 8)
                        }
                        Text(sound.name)
                            .font(.caption2)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if !sound.tag.isEmpty {
                            Text(sound.tag)
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.textFaint)
                        }
                        Spacer()
                        Button {
                            session.addSFX(path: sound.path, atTimeline: player.currentTime)
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .help("Drop at the playhead")
                    }
                }
                InfoTip("Click + or press 1–9 on the timeline to fire a sound at the playhead.")
            }
        }
        .panel()
        .onAppear { if session.sfxSounds.isEmpty { session.rescanSFX() } }
    }

    private var voiceoverPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Voice-over")
                Spacer()
                if voiceRecorder.isRecording {
                    Button {
                        player.pause()
                        if let take = voiceRecorder.stop() {
                            session.setVoiceover(url: take.url, at: take.start)
                        }
                    } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.danger)
                    .controlSize(.small)
                } else {
                    Button {
                        voiceRecorder.begin(at: player.currentTime,
                                            in: session.project.paths.root)
                        if !player.isPlaying { player.togglePlay() }
                    } label: {
                        Label("Record", systemImage: "record.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(edit.isEmpty)
                }
            }
            Text("Record starts playback from the playhead and the mic rolls over it; Stop drops the take right where it began.")
                .font(.caption2)
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
            if voiceRecorder.permissionDenied {
                Text("Microphone access denied — allow it in System Settings → Privacy & Security → Microphone, then relaunch.")
                    .font(.caption2)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if voiceRecorder.isRecording {
                Label("Recording…", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            }
            if let path = edit.voiceoverPath {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(role: .destructive) {
                        session.setVoiceover(url: nil, at: 0)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                LabeledContent("At") {
                    HStack {
                        Slider(value: bind(\.voiceoverStart), in: 0...max(0.1, edit.totalDuration))
                        Text(edit.voiceoverStart.shortTimecode)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 40)
                    }
                }
                .font(.caption)
                LabeledContent("Gain") {
                    HStack {
                        Slider(value: bind(\.voiceoverGainDB), in: -12...12)
                        Text(String(format: "%+.0f dB", edit.voiceoverGainDB))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 40)
                    }
                }
                .font(.caption)
            }
        }
        .panel()
    }

    // MARK: - Post panel

    private var postPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Post")
                InfoTip("Generate runs on this machine through Ollama — nothing leaves it and there's no copy-paste. Copy prompt is the fallback when you want a better answer than the local model gives; paste it into a claude.ai chat, covered by your plan.")
                Spacer()
                Button {
                    session.runLocalPackaging(vertical: edit.aspect == .portrait)
                } label: {
                    if session.localJobRunning == .packaging {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Writing…")
                        }
                    } else {
                        Label("Generate", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.small)
                .disabled(session.localJobRunning != nil || session.transcript.isEmpty)
                Button { copyPostPrompt() } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Copy the prompt for claude.ai instead")
            }
            if let error = session.localJobError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let packaging = session.localPackaging {
                ForEach(Array(packaging.titles.prefix(4).enumerated()), id: \.offset) { _, title in
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.caption2)
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Use") { session.adoptLocalTitle(title) }
                            .buttonStyle(.plain)
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.accent)
                    }
                }
                if !packaging.description.isEmpty {
                    Text(packaging.description)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !packaging.hashtags.isEmpty {
                    Text(packaging.hashtags.map { "#\($0)" }.joined(separator: " "))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    var lines = packaging.description
                    if !packaging.hashtags.isEmpty {
                        lines += "\n\n" + packaging.hashtags.map { "#\($0)" }.joined(separator: " ")
                    }
                    copyToPasteboard(lines)
                } label: {
                    Label("Copy description + tags", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if let note = postPromptNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panel()
    }

    private func copyTitlePrompt() {
        if let prompt = session.editorTitlePrompt() {
            copyToPasteboard(prompt)
            titlePromptNote = "Title prompt copied — paste it into a claude.ai chat."
        } else {
            titlePromptNote = "No transcript under these clips — add a clip from this VOD's candidates first."
        }
    }

    private func copyPostPrompt() {
        if let prompt = session.editorPostPrompt() {
            copyToPasteboard(prompt)
            postPromptNote = "Prompt copied — paste it into a claude.ai chat."
        } else {
            postPromptNote = "No transcript under these clips — add a clip from this VOD's candidates first."
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var exportPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Bookends")
            HStack(spacing: 6) {
                Button {
                    session.addEndCard()
                } label: {
                    if session.isBakingEndCard {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Baking…")
                        }
                    } else {
                        Label("End card", systemImage: "rectangle.badge.checkmark")
                    }
                }
                .disabled(session.isBakingEndCard)
                .help(session.clientProfile == nil
                      ? "Apply a client first — the card is built from their handles, colour and logo"
                      : "Append \(session.clientProfile!.name)'s end card as a normal 5s clip")
                if let intro = session.clientProfile?.introPath,
                   FileManager.default.fileExists(atPath: intro) {
                    Button {
                        session.addIntro(url: URL(fileURLWithPath: intro))
                    } label: {
                        Label("Intro sting", systemImage: "sparkles.rectangle.stack")
                    }
                    .help("Prepend \(URL(fileURLWithPath: intro).lastPathComponent) at the head of the cut")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            SectionLabel(text: "Export")
            HStack(spacing: 5) {
                Text("\(edit.aspect.width)×\(edit.aspect.height) · \(Int(session.project.exportSettings.videoBitrateMbps)) Mbps")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                InfoTip("Every clip is cover-fit to frame with overlays and music burned in. Clips are staged at \(Int(session.project.exportSettings.intermediateBitrateMbps)) Mbps so the join doesn't cost quality; the Shorts tab has the quality picker.")
            }

            if session.isExporting {
                ProgressView(value: session.exportProgress).tint(Theme.accent)
                Text("Rendering… \(Int(session.exportProgress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Button {
                    presentSavePanel()
                } label: {
                    Label("Export MP4…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(HeroButtonStyle())
                .disabled(edit.isEmpty)
            }

            HStack(spacing: 6) {
                Button {
                    presentQueuePanel(platformSet: false)
                } label: {
                    Label("Queue export", systemImage: "text.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    presentPlatformPanel()
                } label: {
                    Label("All platforms", systemImage: "square.grid.2x2")
                        .frame(maxWidth: .infinity)
                }
                .disabled(edit.aspect == .landscape)
                .help(edit.aspect == .landscape
                      ? "Platform sets derive from a portrait master — switch the timeline to 9:16"
                      : "Portrait master plus Shorts, Reels, TikTok and a 16:9 YouTube version")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(edit.isEmpty)
            Text("Queued renders run back-to-back unattended — watch them in the Dashboard. “All platforms” makes the portrait master plus Shorts (≤3 min), Reels (≤90s), TikTok, and a 16:9 blurred-fill YouTube version.")
                .font(.caption2)
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
            if exportQueue.pendingCount > 0 || exportQueue.isRunning {
                Text(exportQueue.isRunning
                     ? "Queue: rendering now · \(exportQueue.pendingCount) waiting"
                     : "Queue: \(exportQueue.pendingCount) waiting")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
            }

            if let result = session.lastExport {
                HStack(spacing: 6) {
                    Text("\(result.encoderName) · \(ByteCountFormatter.string(fromByteCount: result.sizeBytes, countStyle: .file))")
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

    // MARK: - Plumbing

    private func bind<T>(_ path: WritableKeyPath<ClipEdit, T>,
                         action: String = "Edit Timeline") -> Binding<T> {
        Binding(
            get: { session.clipEdit[keyPath: path] },
            set: { var e = session.clipEdit; e[keyPath: path] = $0
                   session.applyClipEdit(e, action: action) }
        )
    }

    private func bindText<T>(_ id: UUID, _ path: WritableKeyPath<TextItem, T>,
                             action: String = "Edit Text") -> Binding<T> {
        Binding(
            get: { (session.clipEdit.textItems.first { $0.id == id } ?? TextItem())[keyPath: path] },
            set: { value in
                var e = session.clipEdit
                guard let index = e.textItems.firstIndex(where: { $0.id == id }) else { return }
                e.textItems[index][keyPath: path] = value
                session.applyClipEdit(e, action: action)
            }
        )
    }

    private func addClipFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .video]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a video to add to the timeline"
        if let last = UserDefaults.standard.string(forKey: "lastTimelineFolder") {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "lastTimelineFolder")
        session.addTimelineClip(from: url)
    }

    private func addMusicFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio, .wav]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a music track — it loops under the whole cut"
        if let last = UserDefaults.standard.string(forKey: "lastMusicFolder") {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "lastMusicFolder")
        session.setTimelineMusic(url)
    }

    private func presentQueuePanel(platformSet: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.mpeg4Movie]
        panel.nameFieldStringValue = "\(exportStem()).mp4"
        panel.message = "Queue the timeline for an unattended render"
        if let last = UserDefaults.standard.string(forKey: "lastExportFolder") {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "lastExportFolder")
        session.queueTimelineExport(to: url, platformSet: platformSet)
    }

    private func presentPlatformPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Queue"
        panel.message = "Choose a folder — the portrait master plus every platform file lands there"
        if let last = UserDefaults.standard.string(forKey: "lastExportFolder") {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "lastExportFolder")
        session.queueTimelineExport(to: url, platformSet: true)
    }

    private func exportStem() -> String {
        let raw = edit.title.isEmpty ? "clip" : edit.title
        let cleaned = raw
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        return cleaned.isEmpty ? "clip" : String(cleaned.prefix(40))
    }

    private func presentSavePanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.mpeg4Movie]
        let stem = edit.title.isEmpty ? "clip" : edit.title
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        panel.nameFieldStringValue = "\(String(stem.prefix(40))).mp4"
        panel.message = "Export the timeline (1080×1920 H.264/AAC)"
        if let last = UserDefaults.standard.string(forKey: "lastExportFolder") {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "lastExportFolder")
        session.exportClipEdit(to: url)
    }
}

/// Records the mic while the preview plays, so the voice-over lands where you
/// watched it. AVAudioRecorder into an m4a in the project folder.
@MainActor
final class VoiceoverRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var permissionDenied = false
    private var recorder: AVAudioRecorder?
    private(set) var startedAt: Double = 0
    private(set) var fileURL: URL?

    func begin(at playhead: Double, in directory: URL) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                guard granted else {
                    self.permissionDenied = true
                    return
                }
                self.start(at: playhead, in: directory)
            }
        }
    }

    private func start(at playhead: Double, in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("voiceover-\(Int(Date().timeIntervalSince1970)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else { return }
        recorder.record()
        self.recorder = recorder
        startedAt = playhead
        fileURL = url
        isRecording = true
    }

    func stop() -> (url: URL, start: Double)? {
        guard let recorder, let fileURL else { return nil }
        recorder.stop()
        self.recorder = nil
        isRecording = false
        return (fileURL, startedAt)
    }
}

/// A clip's filmstrip: keyframe-tolerant thumbnails from the shared cache,
/// bucketed so zoom reuses tiles instead of regenerating them.
private struct FilmstripView: View {
    let clip: TimelineClip
    let width: CGFloat
    let fine: Bool
    @ObservedObject private var cache = FilmstripCache.shared

    var body: some View {
        let count = max(1, Int(width / 56))
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                let fraction = (Double(index) + 0.5) / Double(count)
                let sourceTime = clip.isFreeze
                    ? clip.start
                    : clip.start + fraction * clip.duration
                if let image = cache.thumbnail(path: clip.sourcePath, at: sourceTime, fine: fine) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(count), height: 68)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Theme.surfaceRaised)
                        .frame(width: width / CGFloat(count), height: 68)
                }
            }
        }
    }
}

/// The audio under a clip, drawn from the project's own peak file.
private struct ClipWaveformView: View {
    let peaks: [UInt8]

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let step = max(1, peaks.count / max(1, Int(size.width / 2)))
            var path = Path()
            var x: CGFloat = 0
            let width = size.width / CGFloat((peaks.count + step - 1) / step)
            for index in stride(from: 0, to: peaks.count, by: step) {
                let value = CGFloat(peaks[index]) / 255
                let height = max(1, value * size.height)
                path.addRect(CGRect(x: x, y: size.height - height, width: max(1, width - 0.5),
                                    height: height))
                x += width
            }
            context.fill(path, with: .color(Theme.accent.opacity(0.7)))
        }
    }
}

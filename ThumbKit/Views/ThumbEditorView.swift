import SwiftUI
import AppKit

/// The editor's chrome: who you are editing, what state it is in, and the
/// verbs that apply to the whole document. The canvas and its panels live in
/// `ThumbnailStudioPane`; everything framing them lives here, so the studio
/// pane stays the same component the VOD editor embeds.
struct ThumbEditorView: View {
    @ObservedObject var store: StandaloneThumbStore
    var onBack: () -> Void
    var onNewDesign: () -> Void

    @StateObject private var editor: ThumbEditorModel<StandaloneThumbStore>
    @Environment(\.undoManager) private var undoManager
    @State private var nameDraft = ""
    @State private var hoveringName = false
    @State private var canUndo = false
    @State private var canRedo = false
    @FocusState private var nameFocused: Bool

    init(store: StandaloneThumbStore, onBack: @escaping () -> Void,
         onNewDesign: @escaping () -> Void) {
        self.store = store
        self.onBack = onBack
        self.onNewDesign = onNewDesign
        _editor = StateObject(wrappedValue: ThumbEditorModel(store: store))
    }

    private var doc: ThumbDocument { store.thumbDoc }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            StudioDivider()
            ThumbnailStudioPane(store: store, editor: editor)
            StudioDivider()
            statusBar
        }
        .studioWindowBackground()
        .onAppear {
            nameDraft = currentName
            refreshUndoState()
        }
        .onChange(of: editor.closeRequested) { _, wanted in
            guard wanted else { return }
            editor.closeRequested = false
            onBack()
        }
        .onChange(of: editor.newDesignRequested) { _, wanted in
            guard wanted else { return }
            editor.newDesignRequested = false
            onNewDesign()
        }
        .onChange(of: store.fileURL) { _, _ in nameDraft = currentName }
        // UndoManager publishes nothing SwiftUI observes, so mirror its state
        // off the notifications it does post — otherwise the buttons freeze in
        // whatever state they had when the view first appeared.
        .onReceive(NotificationCenter.default.publisher(
            for: .NSUndoManagerCheckpoint)) { _ in refreshUndoState() }
        .onReceive(NotificationCenter.default.publisher(
            for: .NSUndoManagerDidUndoChange)) { _ in refreshUndoState() }
        .onReceive(NotificationCenter.default.publisher(
            for: .NSUndoManagerDidRedoChange)) { _ in refreshUndoState() }
    }

    private func refreshUndoState() {
        canUndo = undoManager?.canUndo ?? false
        canRedo = undoManager?.canRedo ?? false
    }

    private var currentName: String {
        store.fileURL.deletingPathExtension().lastPathComponent
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: Studio.Space.s) {
            StudioIconButton("chevron.left", help: "All designs  ⇧⌘W") { onBack() }
            Rectangle()
                .fill(Studio.Palette.separator)
                .frame(width: Studio.Metric.hairline, height: 16)
            nameField
            Text("\(doc.width) × \(doc.height)")
                .font(Studio.Typo.numeric)
                .foregroundStyle(Studio.Palette.textTertiary)
            Spacer()
            zoomCluster
            Spacer()
            StudioIconButton("arrow.uturn.backward", help: "Undo  ⌘Z") { undoManager?.undo() }
                .disabled(!canUndo)
            StudioIconButton("arrow.uturn.forward", help: "Redo  ⇧⌘Z") { undoManager?.redo() }
                .disabled(!canRedo)
        }
        .padding(.horizontal, Studio.Space.s)
        .frame(height: Studio.Metric.topBarHeight)
        .background(Studio.Palette.panel)
    }

    private var zoomCluster: some View {
        HStack(spacing: Studio.Space.xxs) {
            StudioIconButton("minus", help: "Zoom out  ⌘−", size: .small) {
                editor.zoom(.zoomOut)
            }
            Menu {
                Button("Fit  ⌘0") { editor.zoom(.fit) }
                Button("100%  ⌘1") { editor.zoom(.actualSize) }
            } label: {
                Text(zoomLabel)
                    .font(Studio.Typo.numeric)
                    .frame(width: 48)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            StudioIconButton("plus", help: "Zoom in  ⌘+", size: .small) {
                editor.zoom(.zoomIn)
            }
        }
        .padding(Studio.Space.xxs)
        .background(RoundedRectangle(cornerRadius: Studio.Radius.button, style: .continuous)
            .fill(Studio.Palette.control))
    }

    private var zoomLabel: String {
        let scale = editor.isFittingCanvas ? editor.fitScale : editor.zoom
        return "\(Int((scale * 100).rounded()))%"
    }

    // MARK: - Status bar

    private var statusBar: some View {
        StudioStatusBar {
            Text(selectionSummary)
            Text("·")
            Text("\(doc.layers.count) \(doc.layers.count == 1 ? "layer" : "layers")")
            Spacer()
            Text(zoomLabel)
            Text("·")
            Text("\(doc.width) × \(doc.height)")
                .font(Studio.Typo.numeric)
            Text("·")
            Text("Saved")
        }
    }

    private var selectionSummary: String {
        switch editor.selection.count {
        case 0: return "Nothing selected"
        case 1:
            let layer = doc.layers.first { editor.selection.contains($0.id) }
            return layer?.displayName ?? "1 selected"
        case let count: return "\(count) selected"
        }
    }

    // MARK: - Name

    /// The document name, edited in place. Transparent until you touch it — a
    /// text field drawn as a text field in a title bar reads as a form.
    private var nameField: some View {
        TextField("Untitled", text: $nameDraft)
            .textFieldStyle(.plain)
            .font(Studio.Typo.title)
            .foregroundStyle(Studio.Palette.textPrimary)
            .focused($nameFocused)
            .frame(minWidth: 80, idealWidth: 180, maxWidth: 280, alignment: .leading)
            .padding(.horizontal, Studio.Space.xs)
            .frame(height: Studio.Metric.controlS)
            .background(RoundedRectangle(cornerRadius: Studio.Radius.field, style: .continuous)
                .fill(nameFocused || hoveringName ? Studio.Palette.control : .clear))
            .studioFocusRing(nameFocused, radius: Studio.Radius.field)
            .onHover { hoveringName = $0 }
            .onSubmit { commitName() }
            .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
            .animation(Studio.Motion.hover, value: hoveringName)
    }

    private func commitName() {
        guard nameDraft != currentName else { return }
        store.rename(to: nameDraft)
        nameDraft = currentName
    }
}

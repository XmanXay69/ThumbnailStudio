import SwiftUI
import AppKit

/// The editor's chrome: who you are editing, what state it is in, and the
/// verbs that apply to the whole document. The canvas and its panels live in
/// `ThumbnailStudioPane`; everything framing them lives here, so the studio
/// pane can stay the same component the VOD editor embeds.
struct ThumbEditorView: View {
    @ObservedObject var store: StandaloneThumbStore
    var onBack: () -> Void

    @Environment(\.undoManager) private var undoManager
    @State private var nameDraft = ""
    @State private var renaming = false
    @FocusState private var nameFocused: Bool

    private var doc: ThumbDocument { store.thumbDoc }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            StudioDivider()
            ThumbnailStudioPane(store: store)
            StudioDivider()
            StudioStatusBar {
                Text(layerSummary)
                Text("·")
                Text("\(doc.width) × \(doc.height)")
                    .font(Studio.Typo.numeric)
                Spacer()
                if let error = store.thumbStudioError {
                    Text(error)
                        .foregroundStyle(Studio.Palette.warning)
                        .lineLimit(1)
                } else {
                    Text("Saved")
                }
            }
        }
        .studioWindowBackground()
        .onAppear { nameDraft = currentName }
        .onChange(of: store.fileURL) { _, _ in nameDraft = currentName }
    }

    private var currentName: String {
        store.fileURL.deletingPathExtension().lastPathComponent
    }

    private var layerSummary: String {
        let count = doc.layers.count
        return count == 1 ? "1 layer" : "\(count) layers"
    }

    private var topBar: some View {
        HStack(spacing: Studio.Space.s) {
            StudioIconButton("chevron.left", help: "All designs") { onBack() }
            Rectangle()
                .fill(Studio.Palette.separator)
                .frame(width: Studio.Metric.hairline, height: 16)
            nameField
            Text("\(doc.width) × \(doc.height)")
                .font(Studio.Typo.numeric)
                .foregroundStyle(Studio.Palette.textTertiary)
            Spacer()
            StudioIconButton("arrow.uturn.backward", help: "Undo  ⌘Z") {
                undoManager?.undo()
            }
            .disabled(!(undoManager?.canUndo ?? false))
            StudioIconButton("arrow.uturn.forward", help: "Redo  ⇧⌘Z") {
                undoManager?.redo()
            }
            .disabled(!(undoManager?.canRedo ?? false))
        }
        .padding(.horizontal, Studio.Space.s)
        .frame(height: Studio.Metric.topBarHeight)
        .background(Studio.Palette.panel)
    }

    /// The document name, edited in place. Transparent until you touch it —
    /// a text field drawn as a text field in a title bar reads as a form.
    private var nameField: some View {
        TextField("Untitled", text: $nameDraft)
            .textFieldStyle(.plain)
            .font(Studio.Typo.title)
            .foregroundStyle(Studio.Palette.textPrimary)
            .focused($nameFocused)
            .frame(minWidth: 80, idealWidth: 200, maxWidth: 320, alignment: .leading)
            .padding(.horizontal, Studio.Space.xs)
            .frame(height: Studio.Metric.controlS)
            .background(RoundedRectangle(cornerRadius: Studio.Radius.field, style: .continuous)
                .fill(nameFocused || renaming ? Studio.Palette.control : .clear))
            .studioFocusRing(nameFocused, radius: Studio.Radius.field)
            .onHover { renaming = $0 }
            .onSubmit { commitName() }
            .onChange(of: nameFocused) { _, focused in
                if !focused { commitName() }
            }
            .animation(Studio.Motion.hover, value: renaming)
    }

    private func commitName() {
        guard nameDraft != currentName else { return }
        store.rename(to: nameDraft)
        nameDraft = currentName
    }
}

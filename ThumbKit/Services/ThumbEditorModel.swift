import AppKit
import SwiftUI

/// `ThumbEditorActions` is class-bound — a SwiftUI `View` is a struct and
/// cannot adopt it — so selection, zoom and the paste buffer live here, in one
/// `@StateObject` the pane owns. That is also what lets the menu bar reach the
/// editor at all: `Commands` cannot see view state, but it can see this object
/// through the router.
@MainActor
final class ThumbEditorModel<Store: ThumbStore>: ObservableObject, ThumbEditorActions {

    @Published var selection: Set<UUID> = []
    @Published var zoom: Double = 1
    @Published var isFittingCanvas = true
    /// What "fit" currently works out to, published by the canvas so the zoom
    /// readout can show a real percentage instead of "Fit".
    @Published var fitScale: Double = 1
    @Published var isSpacePanning = false
    @Published var showSafeZone = true
    @Published var showCheatSheet = false
    /// Set by Return; the inspector binds its `@FocusState` to it.
    @Published var textEditingRequest: UUID?

    let store: Store
    /// Requests the pane fulfils. Published rather than closures: a closure
    /// assigned from the view captures the view, the view holds this model,
    /// and the model holds the closure — a cycle that pinned the store (and,
    /// in the VOD editor, the whole project session) for the life of the app.
    @Published var exportRequested = false
    @Published var imagePickRequested = false
    @Published var newDesignRequested = false
    @Published var closeRequested = false

    init(store: Store) { self.store = store }

    private var doc: ThumbDocument { store.thumbDoc }

    private func apply(_ document: ThumbDocument, _ action: String) {
        store.applyThumbDoc(document, action: action)
        ThumbKeyRouter.shared.refresh()
    }

    // MARK: State the menus read

    var hasSelection: Bool { !selection.isEmpty }
    var selectedLayers: [ThumbLayer] { doc.layers.filter { selection.contains($0.id) } }
    var selectionIsText: Bool {
        selectedLayers.count == 1 && { if case .text = selectedLayers[0].kind { return true }
                                       return false }()
    }
    var selectionIsImage: Bool {
        selectedLayers.contains { if case .image = $0.kind { return true }; return false }
    }
    var selectionIsLocked: Bool {
        !selectedLayers.isEmpty && selectedLayers.allSatisfy(\.isLocked)
    }
    var selectionIsHidden: Bool {
        !selectedLayers.isEmpty && selectedLayers.allSatisfy { !$0.isVisible }
    }
    var canPasteNow: Bool { ThumbLayerClipboard.canPaste() }
    var canCycleSelection: Bool { doc.layers.count > 1 }

    // MARK: Verbs — each is exactly one applyThumbDoc, i.e. one undo step

    func deleteSelection() {
        var document = doc
        guard document.removeLayers(ids: selection) else { return }
        selection = []
        apply(document, "Delete Layer")
    }

    func nudgeSelection(dx: Double, dy: Double) {
        var document = doc
        guard document.nudge(ids: selection, dx: dx, dy: dy) else { return }
        // One action name for the whole burst: UndoCoalescing collapses
        // repeats inside 0.8 s into a single undo step.
        apply(document, "Nudge Layer")
    }

    func endNudgeRun() { store.endUndoRun() }

    func duplicateSelection() {
        var document = doc
        let created = document.duplicateLayers(ids: selection)
        guard !created.isEmpty else { return }
        apply(document, "Duplicate Layer")
        selection = Set(created)
    }

    func copySelection() {
        ThumbLayerClipboard.copy(selectedLayers)
        ThumbKeyRouter.shared.refresh()
    }

    func cutSelection() {
        guard !selection.isEmpty else { return }
        ThumbLayerClipboard.copy(selectedLayers)
        var document = doc
        guard document.removeLayers(ids: selection) else { return }
        selection = []
        apply(document, "Cut Layer")
    }

    func pasteFromPasteboard() {
        let result = ThumbLayerClipboard.paste(assetDirectory: store.assetDirectory)
        var document = doc
        let created: [UUID]
        switch result {
        case .layers(let layers):
            created = document.appendLayers(layers, offsetBy: 0.03)
        case .image, .text:
            guard let layer = ThumbLayerClipboard.layer(for: result) else { return }
            created = document.appendLayers([layer])
        case .nothing:
            return
        }
        guard !created.isEmpty else { return }
        apply(document, result.undoActionName)
        selection = Set(created)
    }

    func selectAllLayers() {
        selection = Set(doc.layers.map(\.id))
        ThumbKeyRouter.shared.refresh()
    }

    func deselect() {
        textEditingRequest = nil
        selection = []
        ThumbKeyRouter.shared.refresh()
    }

    func cycleSelection(forward: Bool) {
        let current = selection.count == 1 ? selection.first : nil
        guard let next = doc.neighbourLayerID(after: current, forward: forward) else { return }
        selection = doc.expandedSelection([next])
        ThumbKeyRouter.shared.refresh()
    }

    func beginEditingSelectedText() {
        guard selectionIsText, let id = selection.first else { return }
        textEditingRequest = id
    }

    func arrangeSelection(_ move: ThumbDocument.LayerMove) {
        guard selection.count == 1, let id = selection.first else { return }
        var document = doc
        guard document.move(layerID: id, move) else { return }   // no-op → no undo entry
        let name: String
        switch move {
        case .toFront: name = "Bring to Front"
        case .forward: name = "Bring Forward"
        case .backward: name = "Send Backward"
        case .toBack: name = "Send to Back"
        }
        apply(document, name)
    }

    /// Bundles the selection. Named for what you grouped where that is
    /// obvious — three layers called "Character" is more use in the panel than
    /// "Group 3".
    func groupSelection() {
        var document = doc
        guard let id = document.group(selection) else { return }
        apply(document, "Group Layers")
        selection = Set(document.members(of: id))
        ThumbKeyRouter.shared.refresh()
    }

    func ungroupSelection() {
        var document = doc
        guard document.ungroup(selection) else { return }
        apply(document, "Ungroup Layers")
        ThumbKeyRouter.shared.refresh()
    }

    /// Whether the selection is worth offering Group / Ungroup for.
    var canGroup: Bool { selection.count >= 2 }
    var canUngroup: Bool {
        doc.layers.contains { selection.contains($0.id) && $0.groupID != nil }
    }

    func toggleSelectionLock() {
        guard !selection.isEmpty else { return }
        var document = doc
        let locked = document.setFlag(\.isLocked, ids: selection)
        apply(document, locked ? "Lock Layer" : "Unlock Layer")
    }

    func toggleSelectionHidden() {
        guard !selection.isEmpty else { return }
        var document = doc
        // isVisible is the stored flag, so "hide" writes false.
        let visible = document.setFlag(\.isVisible, ids: selection)
        apply(document, visible ? "Show Layer" : "Hide Layer")
    }

    func removeBackgroundOnSelection() {
        // The store owns the async cutout and registers its own single undo
        // entry named "Remove Background" when the work lands.
        for layer in selectedLayers {
            if case .image = layer.kind { store.removeBackground(layerID: layer.id) }
        }
    }

    func zoom(_ command: ThumbZoomCommand) {
        switch command {
        case .zoomIn:
            if isFittingCanvas { zoom = fitScale }
            isFittingCanvas = false
            zoom = min(8, zoom * 1.25)
        case .zoomOut:
            if isFittingCanvas { zoom = fitScale }
            isFittingCanvas = false
            zoom = max(0.05, zoom / 1.25)
        case .fit: isFittingCanvas = true; zoom = 1
        case .actualSize: isFittingCanvas = false; zoom = 1
        }
    }

    func exportImage() { exportRequested = true }
    func saveDesign() { store.applyThumbDoc(doc, action: nil) }   // autosaved; flush + no undo
    func newDesign() { newDesignRequested = true }
    func closeDesign() { closeRequested = true }

    func addText() {
        var document = doc
        let created = document.appendLayers(
            [ThumbLayer(kind: .text(TextSpec(text: "YOUR TEXT")), widthFraction: 0.85)])
        apply(document, "Add Text")
        selection = Set(created)
    }

    func addImageFromFile() { imagePickRequested = true }
    func toggleSafeZone() { showSafeZone.toggle() }
    func toggleCheatSheet() { showCheatSheet.toggle() }
    func setSpacePanning(_ panning: Bool) { isSpacePanning = panning }
}


// =====================================================================

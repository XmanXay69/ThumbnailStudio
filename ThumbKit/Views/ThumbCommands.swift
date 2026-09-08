import SwiftUI
import AppKit

/// Everything here carries a ⌘ so it is safe as a key equivalent: AppKit
/// matches menu equivalents *before* the responder chain, which is exactly why
/// no item below is bound to a bare Delete, arrow, Tab or Return — those would
/// fire while the user was typing in the inspector. The bare keys are the
/// router's, and the menu still advertises them in its titles.
struct ThumbCommands: Commands {
    @ObservedObject private var router = ThumbKeyRouter.shared

    private var actions: (any ThumbEditorActions)? { router.actions }
    private var noEditor: Bool { !router.isEditorActive }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Design…") {
                if let handler = router.newDesignHandler { handler() }
                else { actions?.newDesign() }
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { actions?.saveDesign() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(noEditor)
            Divider()
            Button("Export Image…") { actions?.exportImage() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(noEditor)
            // NOT ⌘W: AppKit's own File ▸ Close already owns that and sits
            // above this group, so ⌘W would close the window (and, with no
            // windows left, quit) instead of returning to the gallery.
            Button("Close Design") { actions?.closeDesign() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(noEditor)
        }

        // MARK: Edit — sits after the system's Undo/Redo pair
        ThumbLayerCommands().body
    }
}

/// The half of the menu bar that is about layers, not about design files.
/// The VOD editor takes this on its own: it has its own File menu, and a
/// "New Design" item there would be a dead command.
struct ThumbLayerCommands: Commands {
    @ObservedObject private var router = ThumbKeyRouter.shared

    private var actions: (any ThumbEditorActions)? { router.actions }
    private var noEditor: Bool { !router.isEditorActive }

    /// While a text field owns the window, a pasteboard command belongs to it.
    /// Sending the equivalent selector down the responder chain is what the
    /// standard Edit items do; this just does it first and falls through to
    /// the layer verb when nobody is typing.
    private func textFirst(_ selector: Selector, _ layerVerb: () -> Void) {
        if ThumbKeyContext.isEditingText {
            NSApp.sendAction(selector, to: nil, from: nil)
        } else {
            layerVerb()
        }
    }

    var body: some Commands {
        CommandGroup(after: .undoRedo) {
            Divider()
            // These sit ABOVE the standard Edit items, and a menu key
            // equivalent is matched before the responder chain — so while a
            // text field has focus each one must hand the key back to it,
            // or ⌘A selects your layers instead of your words and ⌘X cuts the
            // layer out from under the field you are typing in.
            Button("Cut") { textFirst(#selector(NSText.cut(_:))) { actions?.cutSelection() } }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(!router.hasSelection)
            Button("Copy") { textFirst(#selector(NSText.copy(_:))) { actions?.copySelection() } }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!router.hasSelection)
            Button("Paste") { textFirst(#selector(NSText.paste(_:))) { actions?.pasteFromPasteboard() } }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(noEditor || !router.canPaste)
            Button("Duplicate") { actions?.duplicateSelection() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!router.hasSelection)
            // ⌘⌫ so the menu can show a shortcut. Plain ⌫ and ⌦ also work and
            // are handled by the router, which stands down while typing.
            Button("Delete") {
                textFirst(#selector(NSText.delete(_:))) { actions?.deleteSelection() }
            }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!router.hasSelection)
            Divider()
            Button("Select All Layers") {
                textFirst(#selector(NSText.selectAll(_:))) { actions?.selectAllLayers() }
            }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(noEditor)
            Button("Deselect  (esc)") { actions?.deselect() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!router.hasSelection)
            Button("Select Next Layer  (tab)") { actions?.cycleSelection(forward: true) }
                .disabled(noEditor)
            Button("Select Previous Layer  (⇧tab)") { actions?.cycleSelection(forward: false) }
                .disabled(noEditor)
        }

        // MARK: Layer
        CommandMenu("Layer") {
            Button("Add Text") { actions?.addText() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(noEditor)
            Button("Add Image…") { actions?.addImageFromFile() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(noEditor)
            Divider()
            Button("Edit Text  (return)") { actions?.beginEditingSelectedText() }
                .disabled(!router.selectionIsText)
            Button("Remove Background") { actions?.removeBackgroundOnSelection() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!router.selectionIsImage)
            Divider()
            // ⇧⌘L, not ⌘L: the View menu's Library already claims ⌘L, and it
            // is the one the tool rail advertises. Two items on one equivalent
            // is not a tie — AppKit picks one and the other silently never
            // fires, which is how this shipped.
            Button(router.selectionIsLocked ? "Unlock" : "Lock") {
                actions?.toggleSelectionLock()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(!router.hasSelection)
            Button(router.selectionIsHidden ? "Show" : "Hide") {
                actions?.toggleSelectionHidden()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(!router.hasSelection)
            Divider()
            // Nudge is listed for discoverability but deliberately carries no
            // key equivalent: ⌥← in a menu would steal move-word-left from
            // every text field in the app.
            Text("Nudge with the arrow keys · ⇧arrow moves 10×")
        }

        // MARK: Arrange
        CommandMenu("Arrange") {
            Button("Bring to Front") { actions?.arrangeSelection(.toFront) }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(!router.hasSelection)
            Button("Bring Forward") { actions?.arrangeSelection(.forward) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!router.hasSelection)
            Button("Send Backward") { actions?.arrangeSelection(.backward) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!router.hasSelection)
            Button("Send to Back") { actions?.arrangeSelection(.toBack) }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(!router.hasSelection)
            Divider()
            // No key equivalent on purpose. Every mnemonic near this one is
            // taken, and inventing a bad one to fill the column is how ⌘R and
            // ⌘L came to be advertised in tooltips for verbs that were not
            // bound to anything.
            Button("Layouts…") { ThumbKeyRouter.shared.layoutsHandler?() }
                .disabled(noEditor)
        }

        // MARK: View
        CommandGroup(after: .toolbar) {
            Button("Preview at Real Sizes…") { ThumbKeyRouter.shared.previewHandler?() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(noEditor)
            Button("Review Thumbnail…") { ThumbKeyRouter.shared.reviewHandler?() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(noEditor)
            Button("Library…") { ThumbKeyRouter.shared.libraryHandler?() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(noEditor)
            Divider()
            Button("Zoom In") { actions?.zoom(.zoomIn) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(noEditor)
            Button("Zoom Out") { actions?.zoom(.zoomOut) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(noEditor)
            Button("Zoom to Fit") { actions?.zoom(.fit) }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(noEditor)
            Button("Actual Size") { actions?.zoom(.actualSize) }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(noEditor)
            Divider()
            Button("Show Duration Safe Zone") { actions?.toggleSafeZone() }
                .keyboardShortcut("'", modifiers: .command)
                .disabled(noEditor)
        }

        // MARK: Help
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { actions?.toggleCheatSheet() }
                .keyboardShortcut("/", modifiers: .command)
        }
    }
}

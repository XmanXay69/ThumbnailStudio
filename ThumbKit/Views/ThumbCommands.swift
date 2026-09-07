import SwiftUI

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

        // MARK: File
        CommandGroup(replacing: .newItem) {
            Button("New Design…") { actions?.newDesign() }
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
            Button("Close Design") { actions?.closeDesign() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(noEditor)
        }

        // MARK: Edit — sits after the system's Undo/Redo pair
        CommandGroup(after: .undoRedo) {
            Divider()
            Button("Cut") { actions?.cutSelection() }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(!router.hasSelection)
            Button("Copy") { actions?.copySelection() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!router.hasSelection)
            Button("Paste") { actions?.pasteFromPasteboard() }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(noEditor || !router.canPaste)
            Button("Duplicate") { actions?.duplicateSelection() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!router.hasSelection)
            // ⌘⌫ so the menu can show a shortcut. Plain ⌫ and ⌦ also work and
            // are handled by the router, which stands down while typing.
            Button("Delete") { actions?.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!router.hasSelection)
            Divider()
            Button("Select All Layers") { actions?.selectAllLayers() }
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
            Button(router.selectionIsLocked ? "Unlock" : "Lock") {
                actions?.toggleSelectionLock()
            }
            .keyboardShortcut("l", modifiers: .command)
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
        }

        // MARK: View
        CommandGroup(after: .toolbar) {
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


// =====================================================================

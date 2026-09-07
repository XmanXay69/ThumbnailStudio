import AppKit
import SwiftUI

/// Every keyboard- and menu-driven verb, in one place. The editor adopts
/// this; the key router and the menu bar both call through it, so a shortcut
/// and its menu item can never drift apart.
@MainActor
protocol ThumbEditorActions: AnyObject {
    var hasSelection: Bool { get }
    var selectionIsText: Bool { get }
    var selectionIsImage: Bool { get }
    var selectionIsLocked: Bool { get }
    var selectionIsHidden: Bool { get }
    var canPasteNow: Bool { get }

    func deleteSelection()
    func nudgeSelection(dx: Double, dy: Double)
    func endNudgeRun()
    func duplicateSelection()
    func copySelection()
    func cutSelection()
    func pasteFromPasteboard()
    func selectAllLayers()
    func deselect()
    func cycleSelection(forward: Bool)
    func beginEditingSelectedText()
    func arrangeSelection(_ move: ThumbDocument.LayerMove)
    func toggleSelectionLock()
    func toggleSelectionHidden()
    func removeBackgroundOnSelection()
    func zoom(_ command: ThumbZoomCommand)
    func exportImage()
    func saveDesign()
    func newDesign()
    func closeDesign()
    func addText()
    func addImageFromFile()
    func toggleSafeZone()
    func toggleCheatSheet()
    func setSpacePanning(_ panning: Bool)
}

enum ThumbZoomCommand { case zoomIn, zoomOut, fit, actualSize }

/// The single question the whole design turns on. A SwiftUI `TextField` does
/// not become first responder itself: the window lends it the *field editor*,
/// a shared `NSTextView`. On macOS 15 that object is SwiftUI's private
/// `_SystemTextFieldFieldEditor` — an `NSTextView` subclass reporting
/// `isFieldEditor == true` (verified at runtime). `TextEditor` installs its own
/// editable `NSTextView` instead. Testing `as? NSTextView` catches both;
/// testing class names would not, and would break on the next OS.
enum ThumbKeyContext {

    /// Overridable so tests can drive the check without owning the key window.
    /// Production never reassigns it.
    nonisolated(unsafe) static var keyWindowProvider: () -> NSWindow? = { NSApp.keyWindow }

    static var isEditingText: Bool {
        guard let responder = keyWindowProvider()?.firstResponder else { return false }
        if let textView = responder as? NSTextView {
            // A read-only NSTextView (a help blurb) must not block shortcuts.
            return textView.isFieldEditor || textView.isEditable
        }
        // A cell-based control that never handed off to a field editor.
        if let field = responder as? NSTextField { return field.isEditable }
        if responder is NSSearchField { return true }
        return false
    }

    /// Sliders, steppers and pickers answer arrow keys themselves. If one of
    /// ours has focus, leave the arrows alone.
    static var isEditingValue: Bool {
        guard let responder = keyWindowProvider()?.firstResponder else { return false }
        return responder is NSSlider || responder is NSStepper
            || responder is NSSegmentedControl || responder is NSPopUpButton
    }
}

/// One `NSEvent` local monitor for the whole editor. It owns the *unmodified*
/// keys — Delete, arrows, Tab, Escape, Return, Space — that a menu key
/// equivalent must never claim, because a menu equivalent is matched before
/// the responder chain runs and would fire while the user is typing.
///
/// Everything with ⌘ in it is deliberately passed straight through: those live
/// in the menu bar, where macOS shows them, validates them and handles the
/// enable/disable state for free.
@MainActor
final class ThumbKeyRouter: ObservableObject {
    static let shared = ThumbKeyRouter()

    /// Published so menu items can enable and disable themselves.
    @Published private(set) var hasSelection = false
    @Published private(set) var selectionIsText = false
    @Published private(set) var selectionIsImage = false
    @Published private(set) var selectionIsLocked = false
    @Published private(set) var selectionIsHidden = false
    @Published private(set) var canPaste = false
    @Published private(set) var isEditorActive = false
    @Published private(set) var isSpacePanning = false

    private(set) weak var actions: (any ThumbEditorActions)?
    /// The editor's own window. Every key is ignored unless this exact window
    /// is key, which is what makes sheets, panels, `NSOpenPanel` and a second
    /// design window safe for free.
    weak var editorWindow: NSWindow?

    /// The canvas size the nudge step is measured against, so one arrow press
    /// is exactly one exported pixel.
    var canvasWidth = 1280
    var canvasHeight = 720

    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var nudgeRunEnd: DispatchWorkItem?

    // MARK: Lifecycle

    /// Called when the editor appears. Idempotent.
    func attach(_ actions: any ThumbEditorActions) {
        self.actions = actions
        isEditorActive = true
        refresh()
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            // The monitor runs before the event reaches the window, so this is
            // the only place that can beat a text field to the Delete key —
            // and the only place that must be careful not to.
            MainActor.assumeIsolated {
                ThumbKeyRouter.shared.handle(event) ? nil : event
            }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ThumbKeyRouter.shared.clearSpacePanning() }
        }
    }

    /// Called when the editor goes away. Leaving the monitor installed would
    /// keep swallowing Delete on the gallery screen.
    func detach(_ actions: any ThumbEditorActions) {
        guard self.actions === actions else { return }
        self.actions = nil
        isEditorActive = false
        hasSelection = false
        clearSpacePanning()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// The pane calls this whenever selection or document state changes, so the
    /// menu bar's enable/disable is never stale.
    func refresh() {
        guard let actions else {
            hasSelection = false; selectionIsText = false; selectionIsImage = false
            selectionIsLocked = false; selectionIsHidden = false; canPaste = false
            return
        }
        hasSelection = actions.hasSelection
        selectionIsText = actions.selectionIsText
        selectionIsImage = actions.selectionIsImage
        selectionIsLocked = actions.selectionIsLocked
        selectionIsHidden = actions.selectionIsHidden
        canPaste = actions.canPasteNow
    }

    // MARK: The gate

    /// Returns true when the event has been consumed and must not travel on.
    private func handle(_ event: NSEvent) -> Bool {
        guard let actions, let window = editorWindow,
              ThumbKeyContext.keyWindowProvider() === window,
              window.attachedSheet == nil,
              NSApp.modalWindow == nil
        else { return false }

        // Arrow keys carry .function and .numericPad in their modifier flags,
        // so a bare `== []` test never matches. Mask down to the four that
        // matter before comparing.
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])

        // The menu bar owns every ⌘ key. Never intercept one: doing so would
        // silently disable menu items the user can see.
        if flags.contains(.command) { return false }

        if event.type == .keyUp {
            if event.keyCode == KeyCode.space, isSpacePanning {
                clearSpacePanning()
                return true
            }
            return false
        }

        // The user is typing. Every unmodified key belongs to the text field.
        if ThumbKeyContext.isEditingText { return false }

        switch event.keyCode {
        case KeyCode.delete, KeyCode.forwardDelete:
            // Repeats would delete the *next* thing after the selection is
            // gone, which is never what a held key means.
            guard !event.isARepeat else { return true }
            // Consumed even with nothing selected: letting it fall through
            // reaches `NSResponder.noResponder(for:)` and the system beeps at
            // the user for pressing Delete on an empty canvas.
            guard actions.hasSelection else { return true }
            actions.deleteSelection()
            return true

        case KeyCode.left, KeyCode.right, KeyCode.up, KeyCode.down:
            // A focused slider or picker answers arrows itself; let it.
            if ThumbKeyContext.isEditingValue { return false }
            guard actions.hasSelection else { return true }   // silent, no beep
            let step = ThumbNudge.step(coarse: flags.contains(.shift),
                                       canvasWidth: canvasWidth, canvasHeight: canvasHeight)
            switch event.keyCode {
            case KeyCode.left:  actions.nudgeSelection(dx: -step.dx, dy: 0)
            case KeyCode.right: actions.nudgeSelection(dx: step.dx, dy: 0)
            case KeyCode.up:    actions.nudgeSelection(dx: 0, dy: -step.dy)
            default:            actions.nudgeSelection(dx: 0, dy: step.dy)
            }
            scheduleNudgeRunEnd()
            return true

        case KeyCode.escape:
            actions.deselect()
            return true

        case KeyCode.tab:
            actions.cycleSelection(forward: !flags.contains(.shift))
            return true

        case KeyCode.returnKey, KeyCode.keypadEnter:
            guard actions.selectionIsText else { return false }
            actions.beginEditingSelectedText()
            return true

        case KeyCode.space:
            guard flags.isEmpty else { return false }
            if !isSpacePanning {
                isSpacePanning = true
                actions.setSpacePanning(true)
                NSCursor.openHand.push()
            }
            return true

        default:
            return false
        }
    }

    /// A burst of held arrow presses is one undo step; a pause ends the run.
    /// `UndoCoalescing` collapses same-named actions inside 0.8 s, so this just
    /// draws the line where the user stopped pressing.
    private func scheduleNudgeRunEnd() {
        nudgeRunEnd?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated {
            ThumbKeyRouter.shared.actions?.endNudgeRun()
        } }
        nudgeRunEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: work)
    }

    private func clearSpacePanning() {
        guard isSpacePanning else { return }
        isSpacePanning = false
        actions?.setSpacePanning(false)
        NSCursor.pop()
    }

    /// Virtual key codes. Stable across keyboard layouts, unlike characters.
    /// (Key-equivalent matching is character-based, which is one more reason
    /// not to put bare keys in menus: SwiftUI's `.delete` equivalent matched
    /// U+0008 and not U+007F in testing.)
    enum KeyCode {
        static let delete: UInt16 = 51
        static let forwardDelete: UInt16 = 117
        static let tab: UInt16 = 48
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let escape: UInt16 = 53
        static let space: UInt16 = 49
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }
}

/// A zero-size probe that hands the router the `NSWindow` the editor is in.
/// It never becomes first responder and never draws, so it cannot disturb
/// focus or layout — its whole job is `view.window`.
struct ThumbWindowProbe: NSViewRepresentable {
    final class ProbeView: NSView {
        override var acceptsFirstResponder: Bool { false }
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onWindow = { window in
            // Only ever upgrade to a real window: SwiftUI can re-run this
            // while the view is detached, and writing nil there would silently
            // switch the whole keyboard layer off. (Observed, then fixed.)
            if let window { ThumbKeyRouter.shared.editorWindow = window }
        }
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        if let window = view.window { ThumbKeyRouter.shared.editorWindow = window }
    }
}

extension View {
    /// Installs the keyboard layer for as long as this view is on screen.
    func thumbKeyboardLayer(_ actions: any ThumbEditorActions) -> some View {
        background(ThumbWindowProbe().frame(width: 0, height: 0).allowsHitTesting(false))
            .onAppear { ThumbKeyRouter.shared.attach(actions) }
            .onDisappear { ThumbKeyRouter.shared.detach(actions) }
    }
}


// =====================================================================

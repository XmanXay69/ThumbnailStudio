import AppKit
import Foundation

// Drives the studio's real objects — the same ThumbKeyRouter, ThumbEditorModel
// and cutout pipeline the app runs — against a COPY of a real design, and
// reports what actually happened. This is how the keyboard and Remove
// Background get exercised on a machine where the GUI cannot be driven.

var failures = 0
func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    print((condition ? "  PASS  " : "  FAIL  ") + label + (detail.isEmpty ? "" : " — \(detail)"))
    if !condition { failures += 1 }
}
func section(_ name: String) { print("\n\(name)") }

// A window we own, so the router's "is my window key" gate can be satisfied
// without stealing focus from anything the user is doing.
final class FakeText: NSTextView {}

@MainActor
func run() async {
    guard CommandLine.arguments.count > 1 else {
        print("usage: drivestudio <design.json>"); exit(2)
    }
    let source = URL(fileURLWithPath: CommandLine.arguments[1])

    // Never touch the user's own file.
    let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("drivestudio-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    let copy = sandbox.appendingPathComponent(source.lastPathComponent)
    try? FileManager.default.copyItem(at: source, to: copy)

    let store = StandaloneThumbStore(fileURL: copy)
    let model = ThumbEditorModel(store: store)
    let undo = UndoManager()
    store.timelineUndoManager = undo
    let router = ThumbKeyRouter.shared
    router.attach(model)
    router.canvasWidth = store.thumbDoc.width
    router.canvasHeight = store.thumbDoc.height

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: true)
    router.editorWindow = window
    ThumbKeyContext.keyWindowProvider = { window }

    func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [],
             repeating: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                         timestamp: 0, windowNumber: window.windowNumber, context: nil,
                         characters: "", charactersIgnoringModifiers: "",
                         isARepeat: repeating, keyCode: code)!
    }

    print("design: \(source.lastPathComponent)  layers: \(store.thumbDoc.layers.count)")

    // ---------------------------------------------------------------- DELETE
    section("The Delete key")
    let before = store.thumbDoc.layers.count
    let victim = store.thumbDoc.layers.last!
    model.selection = [victim.id]
    check("a layer is selected", router.actions?.hasSelection == true)

    let consumed = router.handle(key(ThumbKeyCodes.delete))
    check("the router consumes Delete", consumed)
    check("the layer is gone",
          store.thumbDoc.layers.count == before - 1
              && !store.thumbDoc.layers.contains { $0.id == victim.id },
          "\(before) -> \(store.thumbDoc.layers.count)")
    check("the selection is cleared", model.selection.isEmpty)
    check("it saved to disk",
          (try? Data(contentsOf: copy)).map {
              (try? JSONDecoder().decode(ThumbDocument.self, from: $0))?.layers.count
          } == before - 1)
    check("it is one undo step", undo.canUndo)
    undo.undo()
    check("undo brings the layer back",
          store.thumbDoc.layers.count == before
              && store.thumbDoc.layers.contains { $0.id == victim.id },
          "\(store.thumbDoc.layers.count) layers")

    // Delete must never fire while the user is typing.
    let field = FakeText(frame: .zero)
    field.isEditable = true
    window.contentView?.addSubview(field)
    window.makeFirstResponder(field)
    model.selection = [store.thumbDoc.layers.last!.id]
    let whileTyping = router.handle(key(ThumbKeyCodes.delete))
    check("Delete is NOT consumed while a text field has focus", !whileTyping)
    check("and nothing was deleted", store.thumbDoc.layers.count == before)
    window.makeFirstResponder(nil)

    // A held Delete must not eat the next layer too.
    let repeated = router.handle(key(ThumbKeyCodes.delete, repeating: true))
    check("a repeated Delete is swallowed, not acted on",
          repeated && store.thumbDoc.layers.count == before)

    // Locked layers survive.
    var locking = store.thumbDoc
    let lockedID = locking.layers[0].id
    locking.layers[0].isLocked = true
    store.applyThumbDoc(locking, action: "Lock Layer")
    model.selection = [lockedID]
    _ = router.handle(key(ThumbKeyCodes.delete))
    check("a locked layer survives Delete",
          store.thumbDoc.layers.contains { $0.id == lockedID })

    // ---------------------------------------------------------------- ARROWS
    section("The arrow keys")
    model.selection = [store.thumbDoc.layers.last!.id]
    let movedID = store.thumbDoc.layers.last!.id
    func x(_ id: UUID) -> Double { store.thumbDoc.layers.first { $0.id == id }!.x }
    let startX = x(movedID)
    _ = router.handle(key(ThumbKeyCodes.right))
    let oneStep = x(movedID) - startX
    check("right arrow moves exactly one canvas pixel",
          abs(oneStep * Double(store.thumbDoc.width) - 1) < 0.001,
          String(format: "%.5f of the canvas = %.2f px", oneStep,
                 oneStep * Double(store.thumbDoc.width)))
    let shiftStart = x(movedID)
    _ = router.handle(key(ThumbKeyCodes.right, .shift))
    check("shift-arrow moves ten",
          abs((x(movedID) - shiftStart) * Double(store.thumbDoc.width) - 10) < 0.001)
    window.makeFirstResponder(field)
    let arrowWhileTyping = router.handle(key(ThumbKeyCodes.left))
    check("arrows are NOT consumed while typing", !arrowWhileTyping)
    window.makeFirstResponder(nil)

    // ------------------------------------------------------ REMOVE BACKGROUND
    section("Remove Background")
    guard let target = store.thumbDoc.layers.first(where: {
        if case .image(let s) = $0.kind, !s.path.isEmpty,
           FileManager.default.fileExists(atPath: s.path) { return true }
        return false
    }), case .image(let originalSpec) = target.kind else {
        check("the design has a usable image layer", false)
        finish(sandbox)
        return
    }
    print("  source: \(URL(fileURLWithPath: originalSpec.path).lastPathComponent)")
    let subjects = CutoutService.subjectCount(in: URL(fileURLWithPath: originalSpec.path))
    print("  Vision sees \(subjects) subject(s)")

    model.selection = [target.id]
    let started = Date()
    model.removeBackgroundOnSelection()
    check("it reports that it is working", store.isCuttingOut)

    var waited = 0.0
    while store.isCuttingOut, waited < 30 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        waited += 0.1
    }
    let elapsed = Date().timeIntervalSince(started)
    check("it finished", !store.isCuttingOut, String(format: "%.2fs", elapsed))
    check("no error was raised", store.thumbStudioError == nil,
          store.thumbStudioError ?? "")

    guard case .image(let after)? = store.thumbDoc.layers
        .first(where: { $0.id == target.id })?.kind else {
        check("the layer survived", false); finish(sandbox); return
    }
    check("a cutout file was produced",
          after.cutoutPath != nil
              && FileManager.default.fileExists(atPath: after.cutoutPath ?? ""))
    check("the layer switched to it", after.useCutout)
    check("the original is untouched", after.path == originalSpec.path)
    check("it went to the app's own folder, not next to the photo",
          (after.cutoutPath ?? "").contains("ThumbAssets"),
          after.cutoutPath ?? "")
    check("a fresh cutout gets the shadow-and-outline treatment",
          after.shadowEnabled && after.strokeWidth >= 6)

    if let path = after.cutoutPath, let rep = NSBitmapImageRep(
        data: (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()) {
        var clear = 0.0, solid = 0.0, soft = 0.0, total = 0.0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 5) {
            for px in stride(from: 0, to: rep.pixelsWide, by: 5) {
                guard let c = rep.colorAt(x: px, y: y) else { continue }
                let a = c.alphaComponent
                if a < 0.02 { clear += 1 } else if a > 0.98 { solid += 1 } else { soft += 1 }
                total += 1
            }
        }
        print(String(format: "  matte: %.0f%% transparent, %.0f%% subject, %.1f%% soft edge",
                     clear / total * 100, solid / total * 100, soft / total * 100))
        check("the cutout has real transparency", clear / total > 0.15)
        check("the cutout kept a subject", solid / total > 0.02)
        check("the edge is feathered, not stamped", soft > 0)
        check("the cutout is the same size as the source",
              rep.pixelsWide == Int(NSImage(contentsOfFile: originalSpec.path)?.size.width ?? 0))
    } else {
        check("the cutout is readable", false)
    }

    check("it is one undo step and reversible", undo.canUndo)
    undo.undo()
    if case .image(let reverted)? = store.thumbDoc.layers
        .first(where: { $0.id == target.id })?.kind {
        check("undo puts the original back", !reverted.useCutout)
    }

    finish(sandbox)
}

func finish(_ sandbox: URL) {
    try? FileManager.default.removeItem(at: sandbox)
    print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
    exit(failures == 0 ? 0 : 1)
}

/// The router's key codes are nested and private to it; mirror the few needed.
enum ThumbKeyCodes {
    static let delete: UInt16 = 51
    static let left: UInt16 = 123
    static let right: UInt16 = 124
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in await run() }
app.run()

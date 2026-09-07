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
    undo.groupsByEvent = false
    store.timelineUndoManager = undo
    let router = ThumbKeyRouter.shared
    router.attach(model)
    router.canvasWidth = store.thumbDoc.width
    router.canvasHeight = store.thumbDoc.height

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: true)
    router.editorWindow = window
    ThumbKeyContext.keyWindowProvider = { window }

    /// One simulated user action, in its own undo group — which is what the
    /// app gets for free from the run loop, and what the harness has to do by
    /// hand or every registration collapses into one giant group.
    func userAction(_ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

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

    var consumed = false
    userAction { consumed = router.handle(key(ThumbKeyCodes.delete)) }
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
    var whileTyping = false
    userAction { whileTyping = router.handle(key(ThumbKeyCodes.delete)) }
    check("Delete is NOT consumed while a text field has focus", !whileTyping)
    check("and nothing was deleted", store.thumbDoc.layers.count == before)
    window.makeFirstResponder(nil)

    // A held Delete must not eat the next layer too.
    var repeated = false
    userAction { repeated = router.handle(key(ThumbKeyCodes.delete, repeating: true)) }
    check("a repeated Delete is swallowed, not acted on",
          repeated && store.thumbDoc.layers.count == before)

    // Locked layers survive.
    var locking = store.thumbDoc
    let lockedID = locking.layers[0].id
    locking.layers[0].isLocked = true
    userAction { store.applyThumbDoc(locking, action: "Lock Layer") }
    model.selection = [lockedID]
    userAction { _ = router.handle(key(ThumbKeyCodes.delete)) }
    check("a locked layer survives Delete",
          store.thumbDoc.layers.contains { $0.id == lockedID })

    // ---------------------------------------------------------------- ARROWS
    section("The arrow keys")
    model.selection = [store.thumbDoc.layers.last!.id]
    let movedID = store.thumbDoc.layers.last!.id
    func x(_ id: UUID) -> Double { store.thumbDoc.layers.first { $0.id == id }!.x }
    let startX = x(movedID)
    userAction { _ = router.handle(key(ThumbKeyCodes.right)) }
    let oneStep = x(movedID) - startX
    check("right arrow moves exactly one canvas pixel",
          abs(oneStep * Double(store.thumbDoc.width) - 1) < 0.001,
          String(format: "%.5f of the canvas = %.2f px", oneStep,
                 oneStep * Double(store.thumbDoc.width)))
    let shiftStart = x(movedID)
    userAction { _ = router.handle(key(ThumbKeyCodes.right, .shift)) }
    check("shift-arrow moves ten",
          abs((x(movedID) - shiftStart) * Double(store.thumbDoc.width) - 10) < 0.001)
    window.makeFirstResponder(field)
    var arrowWhileTyping = false
    userAction { arrowWhileTyping = router.handle(key(ThumbKeyCodes.left)) }
    check("arrows are NOT consumed while typing", !arrowWhileTyping)
    window.makeFirstResponder(nil)

    // ------------------------------------------------------- DRAG AND RESIZE
    section("Dragging a layer")
    let canvas = CGSize(width: Double(store.thumbDoc.width),
                        height: Double(store.thumbDoc.height))
    var doc = store.thumbDoc
    // Put two layers somewhere known, well away from any snap target.
    doc.layers[0].x = 0.20; doc.layers[0].y = 0.20; doc.layers[0].isLocked = false
    doc.layers[1].x = 0.80; doc.layers[1].y = 0.75
    store.applyThumbDoc(doc, action: nil)
    let dragged = store.thumbDoc.layers[0]
    let other = store.thumbDoc.layers[1]

    // A drag of N points moves the layer N canvas pixels.
    let plain = CanvasDrag.translation(
        layer: dragged, translation: CGSize(width: 128, height: 72),
        canvas: canvas, others: [], selectionCount: 1)
    check("dragging 128pt right moves 128 canvas px",
          abs(plain.dx * canvas.width - 128) < 0.001,
          String(format: "%.2f px", plain.dx * canvas.width))
    check("and 72pt down moves 72", abs(plain.dy * canvas.height - 72) < 0.001)
    check("no guides appear in open space",
          plain.guideX == nil && plain.guideY == nil)

    // Released near the canvas centre, it snaps to it and shows a guide.
    let towardCentre = (0.5 - dragged.x) * canvas.width + 3
    let snapped = CanvasDrag.translation(
        layer: dragged, translation: CGSize(width: towardCentre, height: 0),
        canvas: canvas, others: [], selectionCount: 1)
    check("a layer released near the centre snaps to it",
          abs((dragged.x + snapped.dx) - 0.5) < 0.0001,
          String(format: "landed at %.4f", dragged.x + snapped.dx))
    check("and the centre guide is shown", snapped.guideX == 0.5)

    // It also snaps to another layer's centre, so things line up with things.
    let towardOther = (other.y - dragged.y) * canvas.height - 4
    let alignedToOther = CanvasDrag.translation(
        layer: dragged, translation: CGSize(width: 0, height: towardOther),
        canvas: canvas, others: [other], selectionCount: 1)
    check("a layer snaps to another layer's centre",
          abs((dragged.y + alignedToOther.dy) - other.y) < 0.0001)
    check("and the guide names that position", alignedToOther.guideY == other.y)

    // Dragging a group must not snap one member and shear the arrangement.
    let group = CanvasDrag.translation(
        layer: dragged, translation: CGSize(width: towardCentre, height: 0),
        canvas: canvas, others: [other], selectionCount: 2)
    check("a multi-layer drag does not snap",
          abs(group.dx * canvas.width - towardCentre) < 0.001
              && group.guideX == nil)

    // The commit path: it writes, moves only the selection, and undoes as one.
    model.selection = [dragged.id]
    var moved = store.thumbDoc
    moved.nudge(ids: [dragged.id], dx: plain.dx, dy: plain.dy)
    userAction {
        store.applyThumbDoc(moved, action: "Move Layer")
        store.endUndoRun()
    }
    func layer(_ id: UUID) -> ThumbLayer { store.thumbDoc.layers.first { $0.id == id }! }
    check("the drag committed to the document",
          abs(layer(dragged.id).x - (dragged.x + plain.dx)) < 0.0001)
    check("the layer beside it did not move",
          abs(layer(other.id).x - other.x) < 0.0001)
    check("it saved to disk",
          (try? Data(contentsOf: copy)).flatMap {
              try? JSONDecoder().decode(ThumbDocument.self, from: $0)
          }.map { abs($0.layers[0].x - (dragged.x + plain.dx)) < 0.0001 } == true)
    check("a drag is one undo step", undo.canUndo)
    undo.undo()
    check("undo puts it back", abs(layer(dragged.id).x - dragged.x) < 0.0001)

    // A locked layer cannot be dragged, matching Delete and the arrow keys.
    var pinning = store.thumbDoc
    pinning.layers[0].isLocked = true
    store.applyThumbDoc(pinning, action: nil)
    let pinnedX = layer(dragged.id).x
    var attempted = store.thumbDoc
    let didMove = attempted.nudge(ids: [dragged.id], dx: 0.2, dy: 0)
    userAction { store.applyThumbDoc(attempted, action: "Move Layer") }
    check("a locked layer refuses to be dragged",
          !didMove && abs(layer(dragged.id).x - pinnedX) < 0.0001)
    pinning = store.thumbDoc
    pinning.layers[0].isLocked = false
    store.applyThumbDoc(pinning, action: nil)

    section("Resizing a layer")
    var target = store.thumbDoc.layers[0]
    target.widthFraction = 0.40
    target.heightFraction = 0.20
    let grown = CanvasResize.proposedWidth(from: target, translationX: 128,
                                           canvasWidth: canvas.width)
    check("dragging the handle 128pt widens by 128 canvas px",
          abs((grown - target.widthFraction) * canvas.width - 128) < 0.001,
          String(format: "%.3f -> %.3f", target.widthFraction, grown))

    var shaped = target
    CanvasResize.applying(width: grown, to: &shaped)
    check("resizing keeps the layer's proportions",
          abs(shaped.heightFraction / shaped.widthFraction
              - target.heightFraction / target.widthFraction) < 0.0001,
          String(format: "%.4f vs %.4f",
                 shaped.heightFraction / shaped.widthFraction,
                 target.heightFraction / target.widthFraction))

    let shrunk = CanvasResize.proposedWidth(from: target, translationX: -9999,
                                            canvasWidth: canvas.width)
    check("a layer cannot be shrunk until its handle is unreachable",
          shrunk >= CanvasResize.minimumWidthFraction,
          String(format: "floor %.3f", shrunk))

    // The commit path, and that the selection box follows the drawn size.
    model.selection = [target.id]
    let resizedID = target.id
    var resizing = store.thumbDoc
    if let index = resizing.layers.firstIndex(where: { $0.id == resizedID }) {
        resizing.layers[index].widthFraction = target.widthFraction
        resizing.layers[index].heightFraction = target.heightFraction
    }
    store.applyThumbDoc(resizing, action: nil)
    let heightBefore = ThumbnailRenderer.drawnHeightFraction(
        layer(resizedID), in: canvas, provider: ThumbnailRenderer.fileProvider)
    var committed = store.thumbDoc
    if let index = committed.layers.firstIndex(where: { $0.id == resizedID }) {
        CanvasResize.applying(width: grown, to: &committed.layers[index])
    }
    userAction { store.applyThumbDoc(committed, action: "Resize Layer") }
    check("the resize committed", abs(layer(resizedID).widthFraction - grown) < 0.0001)
    let heightAfter = ThumbnailRenderer.drawnHeightFraction(
        layer(resizedID), in: canvas, provider: ThumbnailRenderer.fileProvider)
    check("the selection box grows with the layer",
          heightAfter > heightBefore,
          String(format: "%.3f -> %.3f", heightBefore, heightAfter))
    check("a resize is one undo step", undo.canUndo)
    undo.undo()
    check("undo restores the old size",
          abs(layer(resizedID).widthFraction - target.widthFraction) < 0.0001)

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
    // Not userAction: the work finishes asynchronously, so the group has to
    // stay open until it lands or the completion registers undo with no group
    // open, which with groupsByEvent = false is a hard error.
    undo.beginUndoGrouping()
    model.removeBackgroundOnSelection()
    check("it reports that it is working", store.isCuttingOut)

    var waited = 0.0
    while store.isCuttingOut, waited < 30 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        waited += 0.1
    }
    undo.endUndoGrouping()
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

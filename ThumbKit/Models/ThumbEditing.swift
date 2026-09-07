import AppKit
import Foundation

extension UndoCoalescing {
    /// Discrete verbs never collapse into a neighbouring undo step, even when
    /// they repeat inside the 0.8 s window. Without this list, hammering
    /// Delete four times leaves one undo entry that restores only one layer.
    /// Continuous gestures — drags, sliders, a held arrow key — are absent on
    /// purpose: those *should* collapse into one step.
    static let discrete: Set<String> = [
        "Delete Layer", "Delete Layers", "Duplicate Layer", "Paste Layer",
        "Paste Image", "Paste Text", "Cut Layer", "Add Text", "Add Image",
        "Add Shape", "Add Sticker", "Apply Template", "Remove Background",
        "Lock Layer", "Unlock Layer", "Hide Layer", "Show Layer",
        "Bring to Front", "Bring Forward", "Send Backward", "Send to Back",
    ]
}

extension ThumbDocument {

    /// Removes layers by id. Returns false when nothing matched, so callers
    /// can skip the undo entry entirely.
    @discardableResult
    mutating func removeLayers(ids: Set<UUID>) -> Bool {
        let before = layers.count
        layers.removeAll { ids.contains($0.id) }
        return layers.count != before
    }

    /// Inserts a copy of each id directly above its original, offset a hair so
    /// the copy is visible and grabbable. Returns the new ids in stack order,
    /// which the caller makes the selection.
    @discardableResult
    mutating func duplicateLayers(ids: Set<UUID>) -> [UUID] {
        var created: [UUID] = []
        // Walk from the top down so earlier inserts can't shift later indexes.
        for index in stride(from: layers.count - 1, through: 0, by: -1)
        where ids.contains(layers[index].id) {
            var copy = layers[index]
            copy.id = UUID()
            copy.isLocked = false
            copy.x = min(0.98, copy.x + 0.03)
            copy.y = min(0.98, copy.y + 0.03)
            layers.insert(copy, at: index + 1)
            created.append(copy.id)
        }
        return created.reversed()
    }

    /// Drops layers in at the top of the stack, re-idding so a paste can
    /// repeat, and cascading each paste so stacked copies stay separable.
    @discardableResult
    mutating func appendLayers(_ incoming: [ThumbLayer], offsetBy step: Double = 0) -> [UUID] {
        var created: [UUID] = []
        for var layer in incoming {
            layer.id = UUID()
            layer.x = min(0.98, max(0.02, layer.x + step))
            layer.y = min(0.98, max(0.02, layer.y + step))
            layers.append(layer)
            created.append(layer.id)
        }
        return created
    }

    /// Tab order: front-to-back, wrapping. `nil` selection enters at the front
    /// (forward) or the back (backward).
    func neighbourLayerID(after current: UUID?, forward: Bool) -> UUID? {
        guard !layers.isEmpty else { return nil }
        // The rail shows topmost first, so Tab walks the same way the eye does.
        let order = Array(layers.reversed().map(\.id))
        guard let current, let index = order.firstIndex(of: current) else {
            return forward ? order.first : order.last
        }
        let next = forward ? index + 1 : index - 1
        return order[(next + order.count) % order.count]
    }

    /// Toggles a flag on every id, driving them all to the *opposite of the
    /// majority* so a mixed selection resolves to one state instead of
    /// alternating. Returns the value written, for the undo action name.
    @discardableResult
    mutating func setFlag(_ keyPath: WritableKeyPath<ThumbLayer, Bool>,
                          ids: Set<UUID>, to explicit: Bool? = nil) -> Bool {
        let selected = layers.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return false }
        let value = explicit ?? !selected.allSatisfy { $0[keyPath: keyPath] }
        for index in layers.indices where ids.contains(layers[index].id) {
            layers[index][keyPath: keyPath] = value
        }
        return value
    }

    /// Moves every unlocked selected layer by a fraction of the canvas,
    /// clamped so a layer can never be nudged off the board entirely.
    /// Returns false when every selected layer was locked.
    @discardableResult
    mutating func nudge(ids: Set<UUID>, dx: Double, dy: Double) -> Bool {
        var moved = false
        for index in layers.indices where ids.contains(layers[index].id) {
            guard !layers[index].isLocked else { continue }
            layers[index].x = min(1, max(0, layers[index].x + dx))
            layers[index].y = min(1, max(0, layers[index].y + dy))
            moved = true
        }
        return moved
    }
}

enum ThumbNudge {
    /// One arrow press moves the layer by one canvas pixel at the document's
    /// own size, which is the smallest step that can change the exported image.
    /// (The old hidden buttons used a flat 0.004 — five pixels at 1280 wide.)
    static func step(coarse: Bool, canvasWidth: Int, canvasHeight: Int)
        -> (dx: Double, dy: Double) {
        let multiplier = coarse ? 10.0 : 1.0
        return (multiplier / Double(max(1, canvasWidth)),
                multiplier / Double(max(1, canvasHeight)))
    }
}


// =====================================================================

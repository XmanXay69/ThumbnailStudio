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
        // Locked layers survive. A lock reads as protection everywhere else in
        // the app — drag, resize and nudge all honour it — so Delete honouring
        // it too is the only consistent answer.
        layers.removeAll { ids.contains($0.id) && !$0.isLocked }
        pruneEmptyGroups()
        return layers.count != before
    }

    /// Inserts a copy of each id directly above its original, offset a hair so
    /// the copy is visible and grabbable. Returns the new ids in stack order,
    /// which the caller makes the selection.
    @discardableResult
    mutating func duplicateLayers(ids: Set<UUID>) -> [UUID] {
        var created: [UUID] = []
        // A copy of a group is a NEW group. Letting the copies keep the
        // original's id would silently double its membership, so selecting
        // either one would then drag both.
        var remapped: [UUID: UUID] = [:]
        for layer in layers where ids.contains(layer.id) {
            guard let group = layer.groupID, remapped[group] == nil else { continue }
            let fresh = ThumbGroup(id: UUID(),
                                   name: (groupName(group) ?? "Group") + " copy")
            remapped[group] = fresh.id
            groups.append(fresh)
        }
        // Walk from the top down so earlier inserts can't shift later indexes.
        for index in stride(from: layers.count - 1, through: 0, by: -1)
        where ids.contains(layers[index].id) {
            var copy = layers[index]
            copy.id = UUID()
            copy.isLocked = false
            if let group = copy.groupID { copy.groupID = remapped[group] }
            copy.x = min(0.98, copy.x + 0.03)
            copy.y = min(0.98, copy.y + 0.03)
            layers.insert(copy, at: index + 1)
            created.append(copy.id)
        }
        pruneEmptyGroups()
        return created.reversed()
    }

    /// Drops layers in at the top of the stack, re-idding so a paste can
    /// repeat, and cascading each paste so stacked copies stay separable.
    @discardableResult
    mutating func appendLayers(_ incoming: [ThumbLayer], offsetBy step: Double = 0) -> [UUID] {
        var created: [UUID] = []
        for var layer in incoming {
            layer.id = UUID()
            // A layer copied out of one design carries its old group id. In a
            // document that has never heard of that group it would be an
            // invisible passenger; in the SAME document it would silently join
            // a group the user did not paste into.
            layer.groupID = nil
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

// MARK: - Groups

extension ThumbDocument {

    /// Every layer in the same group as anything in `ids`.
    ///
    /// This is the whole mechanism. Run a selection through here and the rest
    /// of the app — drag, nudge, delete, duplicate, align, arrange, lock,
    /// hide — operates on the group without knowing groups exist.
    func expandedSelection(_ ids: Set<UUID>) -> Set<UUID> {
        let touched = Set(layers.filter { ids.contains($0.id) }.compactMap(\.groupID))
        guard !touched.isEmpty else { return ids }
        return ids.union(layers.compactMap { layer in
            guard let group = layer.groupID, touched.contains(group) else { return nil }
            return layer.id
        })
    }

    func members(of group: UUID) -> [UUID] {
        layers.filter { $0.groupID == group }.map(\.id)
    }

    func groupName(_ id: UUID) -> String? { groups.first { $0.id == id }?.name }

    /// Bundles layers into a new group and makes them CONTIGUOUS in the stack,
    /// gathered at the topmost member's position.
    ///
    /// Contiguity is not cosmetic. "Bring forward" moves a block by one, and a
    /// group whose members had other layers interleaved between them would
    /// shuffle through those layers one at a time and tear itself apart. The
    /// visual cost is that grouping can change what covers what — which is the
    /// same thing grouping does in every editor that has it.
    ///
    /// Returns nil when there is nothing to group: fewer than two layers, or a
    /// selection that is already exactly one group.
    @discardableResult
    mutating func group(_ ids: Set<UUID>, named name: String? = nil) -> UUID? {
        let indexed = layers.enumerated().filter { ids.contains($0.element.id) }
        guard indexed.count >= 2 else { return nil }
        let existing = Set(indexed.compactMap { $0.element.groupID })
        // Already this exact group, with nothing added.
        if existing.count == 1, let only = existing.first,
           members(of: only).count == indexed.count { return nil }

        let created = ThumbGroup(id: UUID(), name: name ?? "Group \(groups.count + 1)")
        let topIndex = indexed.map(\.offset).max() ?? 0
        var moved = indexed.map(\.element)
        for index in moved.indices { moved[index].groupID = created.id }

        let others = layers.enumerated().filter { !ids.contains($0.element.id) }
        let insertAt = others.filter { $0.offset < topIndex }.count
        var rebuilt = others.map(\.element)
        rebuilt.insert(contentsOf: moved, at: insertAt)
        layers = rebuilt
        groups.append(created)
        // Absorbing every member of an old group leaves that group empty.
        pruneEmptyGroups()
        return created.id
    }

    /// Dissolves every group any of `ids` belongs to. The layers stay exactly
    /// where they are; only the binding goes.
    @discardableResult
    mutating func ungroup(_ ids: Set<UUID>) -> Bool {
        let touched = Set(layers.filter { ids.contains($0.id) }.compactMap(\.groupID))
        guard !touched.isEmpty else { return false }
        for index in layers.indices {
            if let group = layers[index].groupID, touched.contains(group) {
                layers[index].groupID = nil
            }
        }
        groups.removeAll { touched.contains($0.id) }
        return true
    }

    /// Drops groups that no longer hold at least two layers.
    ///
    /// Deleting layers is the usual cause. A group of one is not a group, and
    /// leaving it would put a disclosure arrow above a single row forever.
    mutating func pruneEmptyGroups() {
        let counts = layers.reduce(into: [UUID: Int]()) { tally, layer in
            if let group = layer.groupID { tally[group, default: 0] += 1 }
        }
        let doomed = Set(groups.map(\.id).filter { (counts[$0] ?? 0) < 2 })
        guard !doomed.isEmpty else { return }
        for index in layers.indices {
            if let group = layers[index].groupID, doomed.contains(group) {
                layers[index].groupID = nil
            }
        }
        groups.removeAll { doomed.contains($0.id) }
    }

    mutating func renameGroup(_ id: UUID, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = name.isEmpty ? "Group" : name
    }

    /// One thing you can drag in the layers panel. A group counts once.
    enum StackUnit: Equatable, Identifiable {
        case layer(UUID)
        case group(UUID)
        var id: UUID {
            switch self {
            case .layer(let id), .group(let id): return id
            }
        }
    }

    /// The stack as the panel shows it — topmost first, each group once.
    ///
    /// Dragging moves these rather than individual layers, which is what makes
    /// a group travel as a block. Reordering raw layers would walk a group
    /// through its neighbours one member at a time and leave it interleaved.
    func stackUnits() -> [StackUnit] {
        var out: [StackUnit] = []
        var seen = Set<UUID>()
        for layer in layers.reversed() {
            if let group = layer.groupID {
                if seen.insert(group).inserted { out.append(.group(group)) }
            } else {
                out.append(.layer(layer.id))
            }
        }
        return out
    }

    /// The layers a unit stands for, bottom-to-top.
    func layerIDs(in unit: StackUnit) -> [UUID] {
        switch unit {
        case .layer(let id): return [id]
        case .group(let id): return members(of: id)
        }
    }

    /// Applies a drag in the panel. Offsets are into `stackUnits()`.
    @discardableResult
    mutating func moveUnits(fromOffsets offsets: IndexSet, toOffset destination: Int) -> Bool {
        let units = stackUnits()
        guard !units.isEmpty else { return false }
        // Done by hand: `move(fromOffsets:toOffset:)` belongs to SwiftUI, and a
        // model file that imports SwiftUI stops linking into the headless
        // harness. Same semantics — `destination` indexes the ORIGINAL array.
        let moving = offsets.sorted().compactMap {
            units.indices.contains($0) ? units[$0] : nil
        }
        guard !moving.isEmpty else { return false }
        var reordered = units.enumerated()
            .filter { !offsets.contains($0.offset) }
            .map(\.element)
        let insertAt = destination - offsets.filter { $0 < destination }.count
        reordered.insert(contentsOf: moving, at: min(max(0, insertAt), reordered.count))
        let units2 = reordered
        let byID = Dictionary(layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rebuilt: [ThumbLayer] = []
        // Units are top-first; the array is bottom-first.
        for unit in units2.reversed() {
            for id in layerIDs(in: unit) {
                if let layer = byID[id] { rebuilt.append(layer) }
            }
        }
        // Never write back a stack that lost or gained anything.
        guard rebuilt.count == layers.count,
              Set(rebuilt.map(\.id)) == Set(layers.map(\.id)) else { return false }
        let changed = rebuilt.map(\.id) != layers.map(\.id)
        layers = rebuilt
        return changed
    }

    mutating func setGroupCollapsed(_ id: UUID, _ collapsed: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].isCollapsed = collapsed
    }
}

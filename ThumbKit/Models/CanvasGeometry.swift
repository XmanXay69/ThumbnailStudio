import Foundation

/// The arithmetic behind dragging and resizing on the canvas, kept out of the
/// gesture bodies so the feel is testable. The view supplies the translation
/// and the canvas size; everything about where a layer ends up is decided
/// here, the same way `TimelineSnap` and `UndoCoalescing` are pure.
enum CanvasDrag {
    /// How far the dragged selection should move, plus the guides to draw.
    ///
    /// Snapping is only applied when a single layer is dragged: with several,
    /// the group's own shape is what the user is preserving, and snapping one
    /// member of it would shear the arrangement.
    struct Result: Equatable {
        var dx: Double
        var dy: Double
        var guideX: Double?
        var guideY: Double?
    }

    static let snapThreshold = 0.012

    static func translation(layer: ThumbLayer,
                            translation: CGSize,
                            canvas: CGSize,
                            others: [ThumbLayer],
                            selectionCount: Int) -> Result {
        var dx = Double(translation.width) / Double(max(1, canvas.width))
        var dy = Double(translation.height) / Double(max(1, canvas.height))
        guard selectionCount <= 1 else { return Result(dx: dx, dy: dy) }

        var guideX: Double?
        var guideY: Double?
        let targetsX = [0.5] + others.map(\.x)
        let targetsY = [0.5] + others.map(\.y)
        if let snapped = TimelineSnap.snapped(layer.x + dx, to: targetsX,
                                              threshold: snapThreshold) {
            dx = snapped - layer.x
            guideX = snapped
        }
        if let snapped = TimelineSnap.snapped(layer.y + dy, to: targetsY,
                                              threshold: snapThreshold) {
            dy = snapped - layer.y
            guideY = snapped
        }
        return Result(dx: dx, dy: dy, guideX: guideX, guideY: guideY)
    }
}

/// The floor a layer may be dragged to.
enum CanvasResize {
    /// The smallest a layer may be dragged to. Below this the grip sits on
    /// top of the layer and you can never grab it again.
    ///
    /// All that survives of the single-grip resize this replaced: the rest of
    /// it — a width-only proposal and a proportional apply — is what
    /// `CanvasTransform` now does for eight grips instead of one.
    static let minimumWidthFraction = 0.03
}


/// Which grip on the selection box is being dragged.
///
/// Eight, not one. The single bottom-right grip could only ever scale a layer
/// about its own centre, so nudging a headline's width moved both its ends and
/// you had to drag it back afterwards.
enum TransformHandle: String, CaseIterable, Identifiable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var id: String { rawValue }

    /// +1 when this grip is on the right edge, -1 on the left, 0 when it only
    /// moves vertically. Dragging the LEFT edge rightward makes the layer
    /// narrower, which is what the sign carries.
    var widthSign: Double {
        switch self {
        case .topRight, .right, .bottomRight: return 1
        case .topLeft, .left, .bottomLeft: return -1
        case .top, .bottom: return 0
        }
    }

    var heightSign: Double {
        switch self {
        case .bottomLeft, .bottom, .bottomRight: return 1
        case .topLeft, .top, .topRight: return -1
        case .left, .right: return 0
        }
    }

    var isCorner: Bool { widthSign != 0 && heightSign != 0 }

    /// Where the grip sits on the box, in unit coordinates from its top left.
    var unitPosition: CGPoint {
        CGPoint(x: (widthSign + 1) / 2, y: (heightSign + 1) / 2)
    }
}

/// Resizing and rotating from the selection box.
///
/// Pure, like `CanvasDrag` and for the same reason: the feel of a transform is
/// arithmetic, and arithmetic can be checked without a window.
enum CanvasTransform {
    /// What a drag produced. Text carries `sizeScale` as well, because its
    /// height comes from its font rather than from `heightFraction`, so
    /// "bigger" means a bigger point size rather than a taller box.
    struct Result: Equatable {
        var x: Double
        var y: Double
        var widthFraction: Double
        var heightFraction: Double
        var sizeScale: Double = 1
    }

    static let minimumWidth = CanvasResize.minimumWidthFraction
    static let minimumHeight = 0.02

    /// The geometry a drag on one grip produces.
    ///
    /// The opposite edge stays put. That is the whole point of edge grips and
    /// it is what the old single-grip resize could not do: the centre moves by
    /// half the drag, so pulling the right edge right leaves the left edge
    /// exactly where it was.
    ///
    /// `drawnHeight` is the height the layer actually draws at, which for an
    /// image comes from its aspect and for text from its metrics — neither is
    /// `heightFraction`, and resizing from the wrong number makes the box jump
    /// the moment you grab it.
    static func resize(_ layer: ThumbLayer, handle: TransformHandle,
                       translation: CGSize, canvas: CGSize,
                       drawnHeight: Double, proportional: Bool) -> Result {
        let width = max(1, Double(canvas.width))
        let height = max(1, Double(canvas.height))
        var dx = Double(translation.width) / width
        var dy = Double(translation.height) / height

        // A corner keeps the shape unless told otherwise: whichever axis was
        // dragged further decides, and the other follows it. Without this,
        // every corner drag quietly distorts the layer.
        if handle.isCorner && proportional {
            let aspect = drawnHeight / max(0.0001, layer.widthFraction)
            if abs(dx) * height >= abs(dy) * width {
                dy = dx * handle.widthSign * handle.heightSign * aspect
            } else {
                dx = dy * handle.widthSign * handle.heightSign / max(0.0001, aspect)
            }
        }

        var result = Result(x: layer.x, y: layer.y,
                            widthFraction: layer.widthFraction,
                            heightFraction: drawnHeight)

        if handle.widthSign != 0 {
            let proposed = layer.widthFraction + handle.widthSign * dx
            result.widthFraction = max(minimumWidth, proposed)
            // Clamped, so the centre must move by what the edge ACTUALLY
            // moved — otherwise a layer dragged past its minimum keeps
            // sliding sideways while its width stands still.
            let applied = (result.widthFraction - layer.widthFraction) * handle.widthSign
            result.x = layer.x + applied / 2
            result.sizeScale = result.widthFraction / max(0.0001, layer.widthFraction)
        }
        if handle.heightSign != 0 {
            let proposed = drawnHeight + handle.heightSign * dy
            result.heightFraction = max(minimumHeight, proposed)
            let applied = (result.heightFraction - drawnHeight) * handle.heightSign
            result.y = layer.y + applied / 2
            if handle.widthSign == 0 {
                result.sizeScale = result.heightFraction / max(0.0001, drawnHeight)
            }
        }
        return result
    }

    /// Degrees from the layer's centre to the pointer, measured so that
    /// dragging the grip clockwise increases the angle — matching
    /// `rotationDegrees`, which the renderer applies clockwise on screen.
    ///
    /// `snapping` rounds to the nearest 15°, which is how you get an honest
    /// 45 rather than a 44.6 you have to fix in the inspector afterwards.
    static func rotation(centre: CGPoint, pointer: CGPoint, snapping: Bool) -> Double {
        let dx = Double(pointer.x - centre.x)
        let dy = Double(pointer.y - centre.y)
        guard abs(dx) > 0.0001 || abs(dy) > 0.0001 else { return 0 }
        // The grip starts directly above the layer, which is -y on screen, so
        // that direction has to read as zero.
        var degrees = atan2(dx, -dy) * 180 / .pi
        if snapping { degrees = (degrees / 15).rounded() * 15 }
        if degrees < 0 { degrees += 360 }
        return degrees.truncatingRemainder(dividingBy: 360)
    }
}

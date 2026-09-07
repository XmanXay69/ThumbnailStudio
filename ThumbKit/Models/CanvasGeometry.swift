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

enum CanvasResize {
    /// The smallest a layer may be dragged to. Below this the handle sits on
    /// top of the layer and you can never grab it again.
    static let minimumWidthFraction = 0.03

    /// Width the corner handle is proposing, from the drag so far.
    static func proposedWidth(from layer: ThumbLayer,
                              translationX: CGFloat,
                              canvasWidth: CGFloat) -> Double {
        max(minimumWidthFraction,
            layer.widthFraction + Double(translationX) / Double(max(1, canvasWidth)))
    }

    /// Applies a proposed width, carrying the height with it so the layer
    /// keeps its shape. A corner handle that changed only the width would
    /// stretch every face on the canvas.
    static func applying(width: Double, to layer: inout ThumbLayer) {
        let scale = width / max(0.01, layer.widthFraction)
        layer.heightFraction *= scale
        layer.widthFraction = width
    }
}

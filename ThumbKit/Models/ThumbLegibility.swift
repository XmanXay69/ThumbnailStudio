import Foundation

/// Will the text still be readable when the thumbnail is small?
///
/// A thumbnail is designed at 1280×720 and consumed at roughly 360 points wide
/// in a desktop feed, and 168 in the up-next rail. That rail is the honest
/// worst case, so it is what this measures. Everything here is arithmetic on
/// the document — no guessing, and no claims about click-through, which this
/// app has no data for.
enum ThumbLegibility {
    /// The narrowest place a full-size thumbnail is realistically shown, in
    /// points: YouTube's up-next rail.
    static let smallestDisplayPoints: Double = 168
    /// Retina, so the pixel count is double the points.
    static let displayScale: Double = 2

    /// Below roughly this cap height, text on a busy image stops resolving at
    /// a glance. It is a rule of thumb, stated as one.
    static let readablePixels: Double = 11

    struct Report: Equatable {
        /// Height in real pixels of the smallest text layer, as shown in the
        /// up-next rail. nil when the design has no text.
        var smallestTextPixels: Double?
        var textLayerCount: Int
        /// Text layers overlapping YouTube's duration stamp.
        var layersUnderDurationStamp: Int
        var isReadable: Bool
    }

    static func report(for document: ThumbDocument) -> Report {
        let scale = (smallestDisplayPoints * displayScale) / Double(max(1, document.width))
        var smallest: Double?
        var count = 0
        var stamped = 0
        let zone = ThumbDocument.durationSafeZone

        for layer in document.layers where layer.isVisible {
            guard case .text(let spec) = layer.kind,
                  !spec.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            count += 1
            // Cap height is roughly 70% of the font size for the heavy faces a
            // thumbnail uses; the font size is a fraction of canvas height.
            let capHeight = spec.sizeFraction * Double(document.height) * 0.7 * scale
            smallest = min(smallest ?? capHeight, capHeight)

            // The duration stamp sits in the lower right and covers whatever
            // is under it.
            let halfWidth = layer.widthFraction / 2
            let halfHeight = max(spec.sizeFraction * 1.2, 0.08) / 2
            let overlapsX = (layer.x + halfWidth) > zone.x
                && (layer.x - halfWidth) < (zone.x + zone.width)
            let overlapsY = (layer.y + halfHeight) > zone.y
                && (layer.y - halfHeight) < (zone.y + zone.height)
            if overlapsX && overlapsY { stamped += 1 }
        }

        return Report(smallestTextPixels: smallest,
                      textLayerCount: count,
                      layersUnderDurationStamp: stamped,
                      isReadable: (smallest ?? .greatestFiniteMagnitude) >= readablePixels)
    }
}

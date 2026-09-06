import Foundation

/// A rectangle in fractions of its frame, top-based (y grows downward), so the
/// same value describes a crop of any pixel size. Lives in ThumbKit because
/// both the thumbnail canvas and the VOD reframe/overlay code speak it.
struct NormalizedRect: Codable, Equatable {
    var x: Double       // left edge, 0…1
    var y: Double       // top edge, 0…1
    var width: Double   // 0…1
    var height: Double  // 0…1

    /// A cam-sized box in the top-right corner, where overlays usually sit.
    static let defaultCam = NormalizedRect(x: 0.72, y: 0.04, width: 0.26, height: 0.26)

    /// A tall centred slice of the source, for the gameplay box.
    static let defaultGameplay = NormalizedRect(x: 0.28, y: 0, width: 0.44, height: 1)

    /// A full-height, centred 9:16 window of a 16:9 source — the classic single
    /// crop. 607.5 px wide of 1920 is exactly 9:16 at full height. Correct for
    /// 16:9; other aspects are cover-fit to 9:16 on export.
    static let defaultFill = NormalizedRect(x: 0.3418, y: 0, width: 0.31641, height: 1)

    var centerX: Double { x + width / 2 }
    var centerY: Double { y + height / 2 }

    func clamped() -> NormalizedRect {
        let w = min(1, max(0.05, width))
        let h = min(1, max(0.05, height))
        return NormalizedRect(x: min(1 - w, max(0, x)), y: min(1 - h, max(0, y)),
                              width: w, height: h)
    }
}

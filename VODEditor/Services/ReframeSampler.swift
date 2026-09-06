import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// The observation half of auto-reframe: samples a clip's frames and finds
/// where the subject is in each. Faces win (largest, via Vision); when no
/// face shows, the centroid of frame-to-frame change stands in — in
/// gameplay that's the action. `ReframeService` turns these into a track.
enum ReframeSampler {
    /// Samples at ~3 fps in the clip's source range. Returned sample times
    /// are effective (timeline) seconds; positions are the crop-centre
    /// fractions the pan keys want, already through the window maths.
    static func samples(for clip: TimelineClip,
                        renderSize: CGSize) async -> [ReframeService.Sample] {
        let asset = AVURLAsset(url: clip.url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              natural.width > 0, natural.height > 0 else { return [] }
        let preferred = (try? await track.load(.preferredTransform)) ?? .identity
        let oriented = CGRect(origin: .zero, size: natural).applying(preferred)
        let sourceW = abs(oriented.width)
        let sourceH = abs(oriented.height)

        // The window fraction: how much of the (zoomed, cover-fit) frame
        // the output crop shows. Needed to convert a subject position into
        // a crop-centre fraction.
        let zoom = min(4, max(1, clip.zoom))
        let scale = max(renderSize.width / sourceW, renderSize.height / sourceH) * zoom
        let windowFractionX = renderSize.width / (sourceW * scale)
        let windowFractionY = renderSize.height / (sourceH * scale)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)

        // 3 fps is plenty for a webcam and coarse for gameplay, so the rate
        // adapts: sample at 3 fps, and when consecutive frames disagree a
        // lot — fast action — fall to 6 fps until it settles.
        let baseStep = 1.0 / 3.0
        let fastStep = 1.0 / 6.0
        var step = baseStep
        var lastSubject: CGPoint?
        var results: [ReframeService.Sample] = []
        var previous: [UInt8]?
        var sourceTime = clip.start
        while sourceTime < clip.end - 0.1 {
            let cm = CMTime(seconds: sourceTime, preferredTimescale: 600)
            guard let cg = try? generator.copyCGImage(at: cm, actualTime: nil) else {
                sourceTime += step
                continue
            }
            var subject: CGPoint?
            if let face = largestFace(in: cg) {
                // Vision's boundingBox is bottom-left normalized; the crop
                // maths run top-down.
                subject = CGPoint(x: face.midX, y: 1 - face.midY)
            } else {
                let grid = luminanceGrid(cg)
                if let previous, let centroid = motionCentroid(previous, grid) {
                    subject = centroid
                }
                previous = grid
            }
            if let subject {
                let effectiveT = (sourceTime - clip.start) / clip.clampedSpeed
                results.append(ReframeService.Sample(
                    t: effectiveT,
                    x: windowCenter(subject.x, windowFraction: windowFractionX),
                    y: windowCenter(subject.y, windowFraction: windowFractionY)))
                if let previousSubject = lastSubject {
                    let moved = hypot(subject.x - previousSubject.x,
                                      subject.y - previousSubject.y)
                    step = moved > 0.08 ? fastStep : baseStep
                }
                lastSubject = subject
            }
            sourceTime += step
        }
        return results
    }

    /// Converts a subject position (fraction of the source frame) into the
    /// crop-centre fraction that centres the window on it, clamped to what
    /// the spare area allows. A window as wide as the frame has no spare —
    /// the axis pins to 0.5.
    static func windowCenter(_ subject: Double, windowFraction: Double) -> Double {
        let spare = 1 - windowFraction
        guard spare > 0.001 else { return 0.5 }
        return min(1, max(0, (subject - windowFraction / 2) / spare))
    }

    private static func largestFace(in image: CGImage) -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try? handler.perform([request])
        return request.results?
            .max { $0.boundingBox.width * $0.boundingBox.height
                < $1.boundingBox.width * $1.boundingBox.height }?
            .boundingBox
    }

    // MARK: - Motion fallback

    static let gridW = 32
    static let gridH = 18

    /// The frame decimated to a tiny luminance grid — enough to see where
    /// the action moved between samples, cheap enough to run everywhere.
    static func luminanceGrid(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: gridW * gridH)
        let space = CGColorSpaceCreateDeviceGray()
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress,
                                          width: gridW, height: gridH,
                                          bitsPerComponent: 8, bytesPerRow: gridW,
                                          space: space, bitmapInfo: 0) else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: gridW, height: gridH))
        }
        return pixels
    }

    /// Where the change concentrated, as top-down frame fractions. nil when
    /// the frames barely differ — a parked shot shouldn't produce a target.
    static func motionCentroid(_ a: [UInt8], _ b: [UInt8]) -> CGPoint? {
        guard a.count == b.count, a.count == gridW * gridH else { return nil }
        var totalWeight = 0.0
        var sumX = 0.0
        var sumY = 0.0
        for index in a.indices {
            let diff = Double(abs(Int(a[index]) - Int(b[index])))
            guard diff > 12 else { continue }
            let x = Double(index % gridW) + 0.5
            let y = Double(index / gridW) + 0.5
            totalWeight += diff
            sumX += diff * x
            sumY += diff * y
        }
        guard totalWeight > Double(a.count) else { return nil }
        // CGContext drew the image y-flipped relative to top-down reading;
        // row 0 of the buffer is the top of the frame either way here since
        // we only compare buffers to themselves — the centroid's y is in
        // buffer rows, which map top-down after the draw's own flip.
        return CGPoint(x: sumX / totalWeight / Double(gridW),
                       y: sumY / totalWeight / Double(gridH))
    }
}

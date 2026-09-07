import AppKit
import CoreImage
import Foundation
import Vision

/// How good is this frame *as a thumbnail*?
///
/// The app already finds good MOMENTS — the score curve, laughter, chat
/// spikes. That is a different question from whether the single frame sitting
/// at that moment is worth putting in front of someone: the funniest second of
/// a stream is often a motion-blurred shot of the back of your head.
///
/// Everything here is measured on-device with Vision and Core Image. No model
/// downloads, no network, nothing invented — each component is a number you
/// could check by hand, and `overall` is a stated weighting of them, not a
/// prediction of how anything will perform.
struct FrameQuality: Equatable, Codable {
    /// Largest face's area as a fraction of the frame. 0 when there is no face.
    var faceArea: Double = 0
    var faceCount: Int = 0
    /// How well the largest face sits in the frame, 0…1.
    var facePlacement: Double = 0
    /// Are the eyes open? nil when no landmarks were found.
    var eyesOpen: Double?
    /// Root-mean-square edge energy. Motion blur and soft focus drive it down.
    var sharpness: Double = 0
    /// 10th-to-90th percentile luminance spread. Flat frames score low.
    var contrast: Double = 0
    /// Mean luminance, 0…1. Punishes crushed and blown frames.
    var exposure: Double = 0.5

    /// The weighting, in one place so it can be argued with.
    ///
    /// A face is the strongest signal for a creator thumbnail, so it carries
    /// most; sharpness is next, because a blurred frame cannot be rescued in
    /// the editor; contrast and exposure are hygiene — they mostly push bad
    /// frames down rather than lift good ones.
    var overall: Double {
        let faceScore = min(1, faceArea / 0.12) * 0.75 + facePlacement * 0.25
        let eyeFactor = 0.55 + 0.45 * (eyesOpen ?? 0.55)
        let exposureScore = 1 - min(1, abs(exposure - 0.5) / 0.42)
        return 0.34 * faceScore * eyeFactor
            + 0.30 * sharpness
            + 0.20 * contrast
            + 0.16 * exposureScore
    }

    /// One line saying why this frame ranked where it did.
    var explanation: String {
        var parts: [String] = []
        if faceCount == 0 {
            parts.append("no face")
        } else if faceArea < 0.01 {
            parts.append("face is tiny")
        } else {
            parts.append(String(format: "face %.0f%% of frame", faceArea * 100))
        }
        if let eyesOpen, faceCount > 0, eyesOpen < 0.4 { parts.append("eyes closed") }
        if sharpness < 0.35 { parts.append("soft or motion-blurred") }
        if contrast < 0.25 { parts.append("flat contrast") }
        if exposure < 0.2 { parts.append("very dark") }
        if exposure > 0.85 { parts.append("blown out") }
        return parts.isEmpty ? "clean frame" : parts.joined(separator: ", ")
    }
}

enum FrameQualityScorer {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Measures one frame. Safe to call off the main actor.
    static func score(imageAt url: URL) -> FrameQuality? {
        guard let source = CIImage(contentsOf: url) else { return nil }
        return score(source)
    }

    static func score(_ source: CIImage) -> FrameQuality? {
        guard source.extent.width > 0, source.extent.height > 0 else { return nil }
        var quality = FrameQuality()

        let faceRequest = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(ciImage: source, options: [:])
        if (try? handler.perform([faceRequest])) != nil,
           let faces = faceRequest.results, !faces.isEmpty {
            quality.faceCount = faces.count
            if let largest = faces.max(by: { $0.boundingBox.area < $1.boundingBox.area }) {
                quality.faceArea = Double(largest.boundingBox.area)
                quality.facePlacement = placementScore(for: largest.boundingBox)
                quality.eyesOpen = eyeOpenness(largest)
            }
        }

        if let stats = luminanceStats(source) {
            quality.exposure = stats.mean
            quality.contrast = stats.spread
        }
        quality.sharpness = sharpness(of: source)
        return quality
    }

    /// A face reads best off dead-centre and above the middle, and a face
    /// clipped by an edge reads worst.
    private static func placementScore(for box: CGRect) -> Double {
        let horizontal = 1 - min(1, abs(Double(box.midX) - 0.5) / 0.5)
        // Vision's y counts from the bottom; the upper half is where a face
        // is not fighting the title.
        let vertical = 1 - min(1, abs(Double(box.midY) - 0.62) / 0.62)
        let clipped = box.minX < 0.02 || box.maxX > 0.98
            || box.minY < 0.02 || box.maxY > 0.98
        return max(0, (horizontal * 0.45 + vertical * 0.55) * (clipped ? 0.6 : 1))
    }

    /// Eye openness from the landmarks: eye height over eye width. A closed
    /// eye collapses to a line.
    private static func eyeOpenness(_ face: VNFaceObservation) -> Double? {
        guard let landmarks = face.landmarks else { return nil }
        func openness(_ region: VNFaceLandmarkRegion2D?) -> Double? {
            guard let points = region?.normalizedPoints, points.count > 3 else { return nil }
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max(), maxX > minX else { return nil }
            return Double((maxY - minY) / (maxX - minX))
        }
        let values = [openness(landmarks.leftEye), openness(landmarks.rightEye)].compactMap { $0 }
        guard !values.isEmpty else { return nil }
        let ratio = values.reduce(0, +) / Double(values.count)
        // Wide open lands near 0.35-0.5; closed near 0.1.
        return min(1, max(0, (ratio - 0.12) / 0.28))
    }

    private struct Stats { var mean: Double; var spread: Double }

    /// Mean luminance and a percentile-based spread, read from a small
    /// downsample.
    ///
    /// Done by reading pixels rather than with CIAreaHistogram, whose output
    /// scaling turned out to put every frame in one bin — every image came
    /// back "flat contrast, blown out", which is worse than no measurement at
    /// all. A 96x54 downsample is 5,184 samples: plenty for a distribution,
    /// and about a millisecond.
    ///
    /// NOT min/max: over a whole frame there is almost always one near-black
    /// and one near-white pixel, so a min/max spread reads 1.00 for every
    /// image and discriminates nothing. The 10th-to-90th percentile band is
    /// what separates a flat frame from a punchy one.
    private static func luminanceStats(_ image: CIImage) -> Stats? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let width = 96
        let height = max(1, Int((extent.height / extent.width * CGFloat(width)).rounded()))
        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: CGFloat(width) / extent.width,
            y: CGFloat(height) / extent.height))

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(scaled, toBitmap: &pixels, rowBytes: width * 4,
                       bounds: CGRect(x: scaled.extent.origin.x, y: scaled.extent.origin.y,
                                      width: CGFloat(width), height: CGFloat(height)),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())

        var luma: [Double] = []
        luma.reserveCapacity(width * height)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            luma.append((0.299 * Double(pixels[index])
                         + 0.587 * Double(pixels[index + 1])
                         + 0.114 * Double(pixels[index + 2])) / 255)
        }
        guard !luma.isEmpty else { return nil }
        let mean = luma.reduce(0, +) / Double(luma.count)
        let sorted = luma.sorted()
        func percentile(_ fraction: Double) -> Double {
            let index = min(sorted.count - 1,
                            max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
            return sorted[index]
        }
        return Stats(mean: mean, spread: max(0, min(1, percentile(0.9) - percentile(0.1))))
    }

    /// Edge energy via a Laplacian.
    ///
    /// The kernel is zero-sum, so the MEAN of its output is ~0 for any image —
    /// averaging it straight measures nothing, which is exactly what the first
    /// version of this did. Squaring first turns it into energy, which is what
    /// separates a crisp frame from a motion-blurred one.
    private static func sharpness(of image: CIImage) -> Double {
        let target: CGFloat = 480
        let scale = min(1, target / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let mono = small.applyingFilter("CIPhotoEffectMono")
        let weights = CIVector(values: [0, -1, 0, -1, 4, -1, 0, -1, 0], count: 9)
        let edges = mono
            .applyingFilter("CIConvolution3X3",
                            parameters: ["inputWeights": weights, "inputBias": 0])
            .cropped(to: small.extent)
        let energy = edges
            .applyingFilter("CIMultiplyCompositing",
                            parameters: [kCIInputBackgroundImageKey: edges])
            .cropped(to: small.extent)

        guard energy.extent.width > 0,
              let average = CIFilter(name: "CIAreaAverage", parameters: [
                  kCIInputImageKey: energy,
                  kCIInputExtentKey: CIVector(cgRect: energy.extent),
              ])?.outputImage else { return 0 }

        var pixel = [Float](repeating: 0, count: 4)
        context.render(average, toBitmap: &pixel, rowBytes: 16,
                       bounds: CGRect(x: average.extent.origin.x,
                                      y: average.extent.origin.y, width: 1, height: 1),
                       format: .RGBAf, colorSpace: CGColorSpaceCreateDeviceRGB())
        let meanSquared = 0.299 * Double(pixel[0]) + 0.587 * Double(pixel[1])
            + 0.114 * Double(pixel[2])
        // Root-mean-square edge energy on a usable curve. The divisor is
        // calibrated against real VOD frames, not guessed.
        return min(1, sqrt(max(0, meanSquared)) / 0.16)
    }
}

/// Choosing which instants to look at, and ordering what comes back.
///
/// Separate from the extraction itself: pulling frames needs ffmpeg and a VOD,
/// but deciding *which* frames to pull and *which* to keep is arithmetic, and
/// arithmetic should be checkable without either.
enum FrameSampling {
    /// The instants to extract around a set of interesting moments.
    ///
    /// The moment finder says when something happened; it says nothing about
    /// whether the frame sitting on that second is worth looking at. The
    /// funniest second of a stream is regularly a motion-blurred shot of the
    /// back of someone's head — so take a spread around each moment and let
    /// the scorer choose.
    static func times(around moments: [Double],
                      spread: Double = 1.2,
                      samplesPerMoment: Int = 5) -> [Double] {
        guard !moments.isEmpty, samplesPerMoment > 0, spread >= 0 else { return [] }
        var times: [Double] = []
        for moment in moments {
            let step = samplesPerMoment > 1 ? (spread * 2) / Double(samplesPerMoment - 1) : 0
            for sample in 0..<samplesPerMoment {
                let offset = samplesPerMoment > 1 ? -spread + step * Double(sample) : 0
                times.append(max(0, moment + offset))
            }
        }
        // Overlapping moments would otherwise extract the same instant twice,
        // at millisecond resolution because that is what the filenames carry.
        let rounded = times.map { ($0 * 1000).rounded() / 1000 }
        return Array(Set(rounded)).sorted()
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}

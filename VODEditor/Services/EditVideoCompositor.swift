import AVFoundation
import CoreImage
import Foundation

/// Chroma-keyed compositing for the editor preview.
///
/// AVFoundation's built-in compositor cannot do this: it honours transforms
/// and layer opacity, but *not* per-pixel alpha from a source track — a keyed
/// ProRes 4444 overlay composites with its transparent area rendered opaque.
/// So the preview owns its own compositor, keying each overlay in Core Image
/// exactly the way ffmpeg's `chromakey` keys it at export time, which is what
/// keeps preview and output honest.
final class EditVideoCompositor: NSObject, AVVideoCompositing {
    /// One source track drawn into the frame, back to front.
    struct Layer {
        let trackID: CMPersistentTrackID
        /// Source → render space, in video coordinates (origin top-left).
        let transform: CGAffineTransform
        /// When set, the transform ramps linearly to this across the
        /// instruction's range — motion keyframes in the chroma path.
        let endTransform: CGAffineTransform?
        /// nil leaves the footage untouched.
        let chroma: Chroma?
    }

    struct Chroma: Equatable {
        var red: Double
        var green: Double
        var blue: Double
        var similarity: Double
        var blend: Double
    }

    /// Custom instructions carry the layer list; AVFoundation only cares about
    /// the time range and which tracks it must decode.
    final class Instruction: NSObject, AVVideoCompositionInstructionProtocol {
        let timeRange: CMTimeRange
        let enablePostProcessing = false
        let containsTweening: Bool
        let requiredSourceTrackIDs: [NSValue]?
        let passthroughTrackID = kCMPersistentTrackID_Invalid
        let layers: [Layer]

        init(timeRange: CMTimeRange, layers: [Layer]) {
            self.timeRange = timeRange
            self.layers = layers
            self.containsTweening = layers.contains { $0.endTransform != nil }
            self.requiredSourceTrackIDs = layers.map { NSNumber(value: $0.trackID) }
            super.init()
        }
    }

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
    ]

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var renderContext: AVVideoCompositionRenderContext?
    /// Cubes are 1 MB each and depend only on the key settings, so the last
    /// one is kept rather than rebuilt every frame.
    private var cachedCube: (chroma: Chroma, filter: CIFilter)?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderContext = newRenderContext
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? Instruction,
              let destination = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "EditVideoCompositor", code: -1))
            return
        }
        let size = request.renderContext.size
        var output = CIImage(color: .black)
            .cropped(to: CGRect(origin: .zero, size: size))

        // Progress through the instruction, for layers that ramp.
        let range = instruction.timeRange
        let progress = range.duration.seconds > 0.0001
            ? min(1, max(0, (request.compositionTime - range.start).seconds / range.duration.seconds))
            : 0

        for layer in instruction.layers {
            guard let buffer = request.sourceFrame(byTrackID: layer.trackID) else { continue }
            var image = CIImage(cvPixelBuffer: buffer)
            if let chroma = layer.chroma {
                image = keyed(image, chroma: chroma)
            }
            var transform = layer.transform
            if let end = layer.endTransform {
                transform = Self.lerp(layer.transform, end, progress)
            }
            image = image.transformed(by: Self.coreImageTransform(
                transform, sourceHeight: image.extent.height, renderHeight: size.height))
            output = image.composited(over: output)
        }

        ciContext.render(output, to: destination)
        request.finish(withComposedVideoFrame: destination)
    }

    private func keyed(_ image: CIImage, chroma: Chroma) -> CIImage {
        let filter: CIFilter
        if let cached = cachedCube, cached.chroma == chroma {
            filter = cached.filter
        } else {
            guard let built = CIFilter(name: "CIColorCube") else { return image }
            built.setValue(Self.cubeDimension, forKey: "inputCubeDimension")
            built.setValue(Self.cubeData(for: chroma), forKey: "inputCubeData")
            cachedCube = (chroma, built)
            filter = built
        }
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage ?? image
    }

    // MARK: - Geometry

    /// Component-wise linear interpolation — exact for the scale+translate
    /// transforms the framing maths produces (matches AVFoundation's own
    /// transform ramps, which the stock-compositor path uses).
    static func lerp(_ a: CGAffineTransform, _ b: CGAffineTransform,
                     _ f: Double) -> CGAffineTransform {
        let t = CGFloat(min(1, max(0, f)))
        return CGAffineTransform(a: a.a + (b.a - a.a) * t,
                                 b: a.b + (b.b - a.b) * t,
                                 c: a.c + (b.c - a.c) * t,
                                 d: a.d + (b.d - a.d) * t,
                                 tx: a.tx + (b.tx - a.tx) * t,
                                 ty: a.ty + (b.ty - a.ty) * t)
    }

    /// AVFoundation layer transforms are written in video coordinates (origin
    /// top-left, y down); Core Image works bottom-left, y up. The transform is
    /// sandwiched between two flips so the same numbers mean the same framing
    /// in both — the export's crop maths included.
    static func coreImageTransform(_ transform: CGAffineTransform,
                                   sourceHeight: CGFloat,
                                   renderHeight: CGFloat) -> CGAffineTransform {
        let flipSource = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: sourceHeight)
        let flipRender = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: renderHeight)
        return flipSource.concatenating(transform).concatenating(flipRender)
    }

    // MARK: - The key

    static let cubeDimension: Float = 32

    /// Alpha for one colour under a key, matching ffmpeg's `chromakey`:
    /// distance is measured on the U/V (chroma) axes only, so brightness
    /// differences in the green screen don't change the result. Inside
    /// `similarity` the pixel vanishes; across `blend` it feathers.
    static func alpha(red: Double, green: Double, blue: Double, chroma: Chroma) -> Double {
        func u(_ r: Double, _ g: Double, _ b: Double) -> Double {
            -0.1146 * r - 0.3854 * g + 0.5 * b
        }
        func v(_ r: Double, _ g: Double, _ b: Double) -> Double {
            0.5 * r - 0.4542 * g - 0.0458 * b
        }
        let du = u(red, green, blue) - u(chroma.red, chroma.green, chroma.blue)
        let dv = v(red, green, blue) - v(chroma.red, chroma.green, chroma.blue)
        let distance = ((du * du + dv * dv) / 2).squareRoot()
        if distance < chroma.similarity { return 0 }
        if chroma.blend > 0.0001, distance < chroma.similarity + chroma.blend {
            return (distance - chroma.similarity) / chroma.blend
        }
        return 1
    }

    /// The lookup cube CIColorCube wants: premultiplied RGBA floats, red
    /// varying fastest.
    static func cubeData(for chroma: Chroma) -> Data {
        let n = Int(cubeDimension)
        var values = [Float](repeating: 0, count: n * n * n * 4)
        var offset = 0
        for blueIndex in 0..<n {
            let blue = Double(blueIndex) / Double(n - 1)
            for greenIndex in 0..<n {
                let green = Double(greenIndex) / Double(n - 1)
                for redIndex in 0..<n {
                    let red = Double(redIndex) / Double(n - 1)
                    let a = alpha(red: red, green: green, blue: blue, chroma: chroma)
                    values[offset] = Float(red * a)
                    values[offset + 1] = Float(green * a)
                    values[offset + 2] = Float(blue * a)
                    values[offset + 3] = Float(a)
                    offset += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

extension EditVideoCompositor.Chroma {
    /// The overlay clip's own settings, as the compositor wants them.
    init(hex: String, similarity: Double, blend: Double) {
        var value: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255,
                  similarity: similarity, blend: blend)
    }
}

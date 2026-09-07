import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

/// Subject lifting, entirely on this Mac. Vision finds the subject; Core Image
/// cleans up the matte, which is where the difference between "cut out" and
/// "cut out badly" actually lives — a raw segmentation mask has a hard,
/// slightly-too-generous edge that leaves a halo of old background around hair
/// and shoulders.
///
/// Nothing here touches the network, and nothing is written next to the user's
/// source file: cutouts go to the app's own asset folder, keyed by the source
/// and the settings that produced them, so toggling back and forth is free.
enum CutoutService {
    enum CutoutError: LocalizedError {
        case noSubject
        case unreadable

        var errorDescription: String? {
            switch self {
            case .noSubject:
                return "Couldn't find a subject to lift. This works best on a clear person or object against a background it doesn't blend into."
            case .unreadable:
                return "Couldn't read that image."
            }
        }
    }

    /// How the matte is finished after Vision hands it over. All in source
    /// pixels, so the same numbers mean the same thing on any image.
    struct Options: Equatable {
        /// Which subject to lift. nil lifts every subject Vision found.
        var instance: Int?
        /// Pull the edge in, hiding the fringe of background the mask keeps.
        var contract: Double = 1.0
        /// Soften the edge so it sits on a new background instead of being
        /// stamped onto it.
        var feather: Double = 1.0
        /// Push the matte toward fully-on or fully-off. Kills the grey halo
        /// that soft mattes leave over busy backgrounds.
        var contrast: Double = 0.35

        static let standard = Options()
    }

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// How many separate subjects Vision can see. The UI offers a choice only
    /// when this is above one.
    static func subjectCount(in source: URL) -> Int {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(url: source)
        guard (try? handler.perform([request])) != nil,
              let result = request.results?.first else { return 0 }
        return result.allInstances.count
    }

    /// Lifts the subject and writes a PNG with alpha to `destination`.
    static func removeBackground(from source: URL, writingTo destination: URL,
                                 options: Options = .standard) throws {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(url: source)
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw CutoutError.noSubject
        }

        // Instance indexes are 1-based in Vision's IndexSet.
        let instances: IndexSet = {
            guard let wanted = options.instance,
                  wanted >= 0, wanted < result.allInstances.count else {
                return result.allInstances
            }
            let sorted = result.allInstances.sorted()
            return IndexSet(integer: sorted[wanted])
        }()

        // Take the mask, not the pre-masked image: the refinement below has to
        // happen on the alpha channel before it is applied to the colour.
        let maskBuffer = try result.generateScaledMaskForImage(forInstances: instances,
                                                              from: handler)
        // VNImageRequestHandler applies the file's EXIF orientation, so the
        // matte comes back rotated. CIImage does not, unless told — and a
        // portrait photo off a phone would otherwise have a 512x1024 matte
        // stretched across a 1024x512 frame.
        guard let colour = CIImage(contentsOf: source,
                                   options: [.applyOrientationProperty: true])
        else { throw CutoutError.unreadable }
        var matte = CIImage(cvPixelBuffer: maskBuffer)
        // The scaled mask comes back at the model's resolution, not the
        // photo's. Stretch it onto the image before compositing, or the cutout
        // is a small corner of the frame.
        matte = matte.transformed(by: CGAffineTransform(
            scaleX: colour.extent.width / matte.extent.width,
            y: colour.extent.height / matte.extent.height))

        matte = refine(matte, options: options)

        let output = colour.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: matte,
            kCIInputBackgroundImageKey: CIImage.empty(),
        ]).cropped(to: colour.extent)

        guard let cg = context.createCGImage(output, from: colour.extent) else {
            throw CutoutError.unreadable
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CutoutError.unreadable
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: destination, options: .atomic)
    }

    /// Contract, then harden, then soften — in that order. Blurring first and
    /// eroding second would eat the softness you just paid for.
    static func refine(_ matte: CIImage, options: Options) -> CIImage {
        var output = matte
        if options.contract > 0.01 {
            output = output.applyingFilter("CIMorphologyMinimum",
                                           parameters: ["inputRadius": options.contract])
        } else if options.contract < -0.01 {
            output = output.applyingFilter("CIMorphologyMaximum",
                                           parameters: ["inputRadius": -options.contract])
        }
        if options.contrast > 0.01 {
            // Steepen the ramp around 50% grey: partial coverage becomes a
            // decision instead of a halo.
            let slope = 1 + options.contrast * 6
            output = output.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: slope, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: slope, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: slope, w: 0),
                "inputBiasVector": CIVector(x: -(slope - 1) / 2, y: -(slope - 1) / 2,
                                            z: -(slope - 1) / 2, w: 0),
            ])
        }
        if options.feather > 0.01 {
            output = output.applyingFilter("CIGaussianBlur",
                                           parameters: ["inputRadius": options.feather])
        }
        // Every filter above can grow the extent; the mask must line up with
        // the photo exactly or CIBlendWithMask shifts the subject.
        return output.cropped(to: matte.extent)
    }
}

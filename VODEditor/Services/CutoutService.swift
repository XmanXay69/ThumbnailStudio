import AppKit
import CoreImage
import Foundation
import Vision

/// Subject lifting via the Vision framework — fully local, quality on par
/// with the paid tools for the streamer-face case this exists for.
enum CutoutService {
    enum CutoutError: LocalizedError {
        case noSubject
        case unreadable

        var errorDescription: String? {
            switch self {
            case .noSubject:
                return "Vision found no subject to lift in this image — works best with a clear person or object against a background."
            case .unreadable:
                return "Couldn't read that image."
            }
        }
    }

    /// Removes the background from an image file, writing the lifted subject
    /// as a PNG with alpha next to the destination. Runs Vision's foreground
    /// instance mask — macOS 14+, on-device, a second or two per image.
    static func removeBackground(from source: URL, writingTo destination: URL) throws {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(url: source)
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw CutoutError.noSubject
        }
        let buffer = try result.generateMaskedImage(
            ofInstances: result.allInstances, from: handler,
            croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let cg = context.createCGImage(ci, from: ci.extent) else {
            throw CutoutError.unreadable
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CutoutError.unreadable
        }
        try png.write(to: destination, options: .atomic)
    }
}

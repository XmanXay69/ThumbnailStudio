import AppKit
import Foundation

enum LayerRasterizerError: LocalizedError {
    case unreadable(String)
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return "Couldn't read “\(name)” as an image."
        case .encodeFailed:
            return "Couldn't write the overlay image."
        }
    }
}

/// Turns any image the user drops in — including SVG — into a PNG with its
/// transparency intact, because ffmpeg can't read SVG and an overlay without an
/// alpha channel is a rectangle stuck on your thumbnail.
///
/// AppKit does the rendering: `NSImage` loads SVG natively on macOS and draws it
/// at whatever size is asked for, so vector art stays sharp at any scale rather
/// than being upsampled from a fixed raster.
enum LayerRasterizer {
    /// Formats worth offering in the file picker.
    static let supportedExtensions = ["png", "jpg", "jpeg", "svg", "gif", "tiff", "tif", "heic", "webp", "bmp"]

    @discardableResult
    static func rasterize(_ source: URL, to destination: URL, targetWidth: Int) throws -> NSSize {
        guard let image = NSImage(contentsOf: source) else {
            throw LayerRasterizerError.unreadable(source.lastPathComponent)
        }

        let native = image.size
        guard native.width > 0, native.height > 0 else {
            throw LayerRasterizerError.unreadable(source.lastPathComponent)
        }
        let width = max(1, targetWidth)
        let height = max(1, Int((Double(width) * native.height / native.width).rounded()))

        // Drawn into an explicit RGBA bitmap rather than via lockFocus, so the
        // result has a known colour space and a real alpha channel regardless of
        // what the source was.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw LayerRasterizerError.encodeFailed }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw LayerRasterizerError.encodeFailed
        }
        try png.write(to: destination, options: .atomic)
        return NSSize(width: width, height: height)
    }

    /// Pixel size of an image without decoding it at full resolution, for
    /// showing aspect-correct previews.
    static func nativeSize(of source: URL) -> NSSize? {
        guard let image = NSImage(contentsOf: source), image.size.width > 0 else { return nil }
        return image.size
    }
}

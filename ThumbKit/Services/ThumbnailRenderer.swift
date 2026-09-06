import AppKit
import CoreImage
import Foundation

/// Renders a ThumbDocument to pixels. One renderer, two consumers: the studio
/// canvas shows this image scaled to the window, and export writes it to
/// disk — so what you see is what ships, by construction rather than by hope.
enum ThumbnailRenderer {
    /// Loads (and adjusts) layer images. Injectable so tests can render with
    /// synthetic images instead of touching disk.
    typealias ImageProvider = (ImageSpec) -> NSImage?

    /// The app's provider — main-actor because the cache is. The renderer
    /// itself stays nonisolated so the harness can drive it with synthetic
    /// providers.
    @MainActor
    static func renderForStudio(_ document: ThumbDocument) -> NSImage? {
        render(document) { spec in AdjustedImageCache.shared.image(for: spec) }
    }

    static func render(_ document: ThumbDocument,
                       provider: ImageProvider) -> NSImage? {
        let width = document.width
        let height = document.height
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = context
        context?.imageInterpolation = .high
        let cg = context?.cgContext

        // Canvas base: the document's colour, or dark so an empty document
        // previews sensibly.
        if let hex = document.backgroundHex {
            HexColor.color(hex: hex).setFill()
        } else {
            NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        }
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        for layer in document.layers where layer.isVisible {
            cg?.saveGState()
            cg?.setAlpha(CGFloat(layer.opacity))
            cg?.setBlendMode(blendMode(layer.blendMode))
            // Rotation around the layer's centre; AppKit's origin is the
            // bottom, layer y counts from the top.
            let center = CGPoint(x: layer.x * size.width,
                                 y: (1 - layer.y) * size.height)
            cg?.translateBy(x: center.x, y: center.y)
            cg?.rotate(by: -CGFloat(layer.rotationDegrees) * .pi / 180)
            cg?.translateBy(x: -center.x, y: -center.y)
            draw(layer, in: size, center: center, provider: provider)
            cg?.restoreGState()
        }

        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    static func blendMode(_ name: String) -> CGBlendMode {
        switch name {
        case "multiply": return .multiply
        case "screen": return .screen
        case "overlay": return .overlay
        default: return .normal
        }
    }

    private static func draw(_ layer: ThumbLayer, in size: CGSize,
                             center: CGPoint, provider: ImageProvider) {
        switch layer.kind {
        case .image(let spec):
            drawImage(spec, layer: layer, in: size, center: center, provider: provider)
        case .text(let spec):
            drawText(spec, layer: layer, in: size, center: center)
        case .shape(let spec):
            drawShape(spec, layer: layer, in: size, center: center)
        }
    }

    // MARK: - Image

    private static func drawImage(_ spec: ImageSpec, layer: ThumbLayer, in size: CGSize,
                                  center: CGPoint, provider: ImageProvider) {
        guard let image = provider(spec), image.size.width > 0 else {
            // A template's empty face slot: draw the placeholder so the slot
            // is visible and selectable.
            let width = layer.widthFraction * size.width
            let height = layer.heightFraction * size.height
            let rect = NSRect(x: center.x - width / 2, y: center.y - height / 2,
                              width: width, height: height)
            NSColor(calibratedWhite: 0.25, alpha: 0.8).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            NSAttributedString(string: "double-click to set image", attributes: [
                .font: NSFont.systemFont(ofSize: size.height * 0.03, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.7),
                .paragraphStyle: paragraph,
            ]).draw(in: NSRect(x: rect.minX, y: center.y - size.height * 0.02,
                               width: rect.width, height: size.height * 0.05))
            return
        }
        // The crop is a source rect on the draw call — every provider gets
        // the same crop, and the layer's aspect follows the cropped region.
        let sourceRect: NSRect = {
            guard let crop = spec.crop?.clamped(),
                  crop.width > 0.02, crop.height > 0.02 else { return .zero }
            // NormalizedRect's y is top-based; NSImage space is bottom-up.
            return NSRect(x: crop.x * image.size.width,
                          y: (1 - crop.y - crop.height) * image.size.height,
                          width: crop.width * image.size.width,
                          height: crop.height * image.size.height)
        }()
        let sourceW = sourceRect == .zero ? image.size.width : sourceRect.width
        let sourceH = sourceRect == .zero ? image.size.height : sourceRect.height
        let width = layer.widthFraction * size.width
        let height = width * sourceH / max(1, sourceW)
        let rect = NSRect(x: center.x - width / 2, y: center.y - height / 2,
                          width: width, height: height)

        let cg = NSGraphicsContext.current?.cgContext
        if spec.flippedHorizontally {
            cg?.saveGState()
            cg?.translateBy(x: center.x, y: 0)
            cg?.scaleBy(x: -1, y: 1)
            cg?.translateBy(x: -center.x, y: 0)
        }
        // Outline around a cutout subject: the image's silhouette in the
        // stroke colour, drawn slightly larger UNDER the subject. Draw order
        // matters — NSImage.draw's operation parameter overrides any context
        // blend mode, so a destinationOver silhouette drawn second paints
        // over the subject instead of behind it.
        if spec.strokeWidth > 0.5, spec.useCutout,
           let tinted = tintedSilhouette(image, color: HexColor.color(hex: spec.strokeHex)) {
            if spec.shadowEnabled {
                cg?.setShadow(offset: CGSize(width: spec.shadowOffset, height: -spec.shadowOffset),
                              blur: spec.shadowBlur,
                              color: HexColor.color(hex: spec.shadowHex)
                                  .withAlphaComponent(0.75).cgColor)
            }
            let grow = spec.strokeWidth
            tinted.draw(in: rect.insetBy(dx: -grow, dy: -grow), from: sourceRect,
                        operation: .sourceOver, fraction: 1)
            cg?.setShadow(offset: .zero, blur: 0, color: nil)
            image.draw(in: rect, from: sourceRect, operation: .sourceOver, fraction: 1)
        } else {
            // Canva-style frame: clip to a rounded rect or circle, draw,
            // then stroke the mask edge as the border.
            let maskPath: NSBezierPath? = {
                switch spec.maskShape {
                case "rounded":
                    return NSBezierPath(roundedRect: rect,
                                        xRadius: spec.maskCornerRadius,
                                        yRadius: spec.maskCornerRadius)
                case "circle":
                    let side = min(rect.width, rect.height)
                    let square = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2,
                                        width: side, height: side)
                    return NSBezierPath(ovalIn: square)
                default:
                    return nil
                }
            }()
            if spec.shadowEnabled {
                cg?.setShadow(offset: CGSize(width: spec.shadowOffset, height: -spec.shadowOffset),
                              blur: spec.shadowBlur,
                              color: HexColor.color(hex: spec.shadowHex)
                                  .withAlphaComponent(0.75).cgColor)
            }
            let cut = cutPath(edge: spec.cutEdge, amount: spec.cutAmount,
                              flip: spec.cutFlip, in: rect)
            if maskPath != nil || cut != nil {
                // Shadow must come from the silhouette, not the clip.
                if spec.shadowEnabled {
                    HexColor.color(hex: "000000").withAlphaComponent(0.011).setFill()
                    (maskPath ?? cut)?.fill()
                    cg?.setShadow(offset: .zero, blur: 0, color: nil)
                }
                cg?.saveGState()
                maskPath?.addClip()
                cut?.addClip()
                image.draw(in: rect, from: sourceRect, operation: .sourceOver, fraction: 1)
                cg?.restoreGState()
                if spec.borderWidth > 0.1, let edgePath = maskPath ?? cut {
                    HexColor.color(hex: spec.borderHex).setStroke()
                    edgePath.lineWidth = spec.borderWidth
                    edgePath.stroke()
                }
            } else {
                image.draw(in: rect, from: sourceRect, operation: .sourceOver, fraction: 1)
                cg?.setShadow(offset: .zero, blur: 0, color: nil)
                if spec.borderWidth > 0.1 {
                    HexColor.color(hex: spec.borderHex).setStroke()
                    let borderPath = NSBezierPath(rect: rect)
                    borderPath.lineWidth = spec.borderWidth
                    borderPath.stroke()
                }
            }
            cg?.setShadow(offset: .zero, blur: 0, color: nil)
        }
        if spec.flippedHorizontally { cg?.restoreGState() }
    }

    /// The image reduced to a solid-colour silhouette (for cutout outlines).
    static func tintedSilhouette(_ image: NSImage, color: NSColor) -> NSImage? {
        guard let tiff = image.tiffRepresentation,
              let ci = CIImage(data: tiff) else { return nil }
        let rgba = color.usingColorSpace(.deviceRGB) ?? color
        guard let filter = CIFilter(name: "CIColorMatrix") else { return nil }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: rgba.redComponent), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: rgba.greenComponent), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: rgba.blueComponent), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        guard let output = filter.outputImage else { return nil }
        let repCI = NSCIImageRep(ciImage: output)
        let result = NSImage(size: image.size)
        result.addRepresentation(repCI)
        return result
    }

    // MARK: - Text

    static func textAttributes(_ spec: TextSpec, canvasHeight: CGFloat,
                               strokePass: Bool) -> [NSAttributedString.Key: Any] {
        let fontSize = spec.sizeFraction * canvasHeight
        let font = NSFont(name: spec.fontName, size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize, weight: .heavy)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = spec.alignment == "left" ? .left
            : spec.alignment == "right" ? .right : .center
        paragraph.lineHeightMultiple = spec.lineHeightMultiple
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
            .kern: spec.letterSpacing,
        ]
        if strokePass {
            let scaled = spec.strokeWidth * canvasHeight / 720
            attributes[.strokeColor] = HexColor.color(hex: spec.strokeHex)
            attributes[.strokeWidth] = scaled / max(1, fontSize) * 100
            attributes[.foregroundColor] = HexColor.color(hex: spec.strokeHex)
        } else {
            attributes[.foregroundColor] = HexColor.color(hex: spec.fillHex)
        }
        return attributes
    }

    private static func drawText(_ spec: TextSpec, layer: ThumbLayer, in size: CGSize,
                                 center: CGPoint) {
        let text = spec.text
        guard !text.isEmpty else { return }
        let width = layer.widthFraction * size.width
        let measured = NSAttributedString(
            string: text, attributes: textAttributes(spec, canvasHeight: size.height, strokePass: false))
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin])
        let rect = NSRect(x: center.x - width / 2,
                          y: center.y - ceil(measured.height) / 2,
                          width: width, height: ceil(measured.height) + 4)

        let cg = NSGraphicsContext.current?.cgContext
        if spec.boxEnabled {
            let pad = spec.boxPadding * size.height / 720
            let box = NSRect(x: center.x - measured.width / 2 - pad,
                             y: rect.minY - pad,
                             width: measured.width + pad * 2,
                             height: rect.height + pad * 2)
            HexColor.color(hex: spec.boxHex).setFill()
            NSBezierPath(roundedRect: box, xRadius: spec.boxCorner, yRadius: spec.boxCorner).fill()
        }
        if spec.shadowEnabled {
            cg?.setShadow(offset: CGSize(width: spec.shadowOffset, height: -spec.shadowOffset),
                          blur: spec.shadowBlur,
                          color: HexColor.color(hex: spec.shadowHex)
                              .withAlphaComponent(0.8).cgColor)
        }
        // Stroke pass first, then fill — a single stroked pass eats the fill.
        if spec.strokeWidth > 0.1 {
            NSAttributedString(string: text,
                               attributes: textAttributes(spec, canvasHeight: size.height,
                                                          strokePass: true)).draw(in: rect)
        }
        cg?.setShadow(offset: .zero, blur: 0, color: nil)

        if let gradientHex = spec.gradientHex {
            // Gradient fill: the text drawn into its own image becomes a
            // mask; the gradient draws through it.
            let fillImage = NSImage(size: rect.size, flipped: false) { drawRect in
                NSAttributedString(string: text,
                                   attributes: textAttributes(spec, canvasHeight: size.height,
                                                              strokePass: false))
                    .draw(in: drawRect)
                return true
            }
            if let tiff = fillImage.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let mask = bitmap.cgImage {
                cg?.saveGState()
                cg?.clip(to: rect, mask: mask)
                let gradient = NSGradient(
                    starting: HexColor.color(hex: gradientHex),
                    ending: HexColor.color(hex: spec.fillHex))
                gradient?.draw(in: rect, angle: 90)
                cg?.restoreGState()
            }
        } else {
            NSAttributedString(string: text,
                               attributes: textAttributes(spec, canvasHeight: size.height,
                                                          strokePass: false)).draw(in: rect)
        }
    }

    // MARK: - Shapes

    /// The diagonal-cut quadrilateral: the whole rect with one edge turned
    /// into a slant. `amount` moves one corner of that edge inward; `flip`
    /// picks which corner. nil when there's no cut.
    static func cutPath(edge: String, amount: Double, flip: Bool,
                        in rect: NSRect) -> NSBezierPath? {
        let clamped = min(0.9, max(0.02, amount))
        var bl = NSPoint(x: rect.minX, y: rect.minY)
        var br = NSPoint(x: rect.maxX, y: rect.minY)
        var tr = NSPoint(x: rect.maxX, y: rect.maxY)
        var tl = NSPoint(x: rect.minX, y: rect.maxY)
        let dx = clamped * rect.width
        let dy = clamped * rect.height
        switch edge {
        case "right":
            if flip { br.x -= dx } else { tr.x -= dx }
        case "left":
            if flip { bl.x += dx } else { tl.x += dx }
        case "top":
            // Layer space counts y from the top; AppKit's maxY is the top.
            if flip { tl.y -= dy } else { tr.y -= dy }
        case "bottom":
            if flip { bl.y += dy } else { br.y += dy }
        default:
            return nil
        }
        let path = NSBezierPath()
        path.move(to: bl)
        path.line(to: br)
        path.line(to: tr)
        path.line(to: tl)
        path.close()
        return path
    }

    static func shapePath(_ spec: ShapeSpec, in rect: NSRect) -> NSBezierPath {
        switch spec.shape {
        case "ellipse":
            return NSBezierPath(ovalIn: rect)
        case "line":
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: rect.midY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
            path.lineWidth = max(2, rect.height)
            return path
        case "arrow":
            let path = NSBezierPath()
            let headLength = min(rect.width * 0.35, rect.height)
            let shaftHalf = rect.height * 0.18
            path.move(to: NSPoint(x: rect.minX, y: rect.midY - shaftHalf))
            path.line(to: NSPoint(x: rect.maxX - headLength, y: rect.midY - shaftHalf))
            path.line(to: NSPoint(x: rect.maxX - headLength, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
            path.line(to: NSPoint(x: rect.maxX - headLength, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX - headLength, y: rect.midY + shaftHalf))
            path.line(to: NSPoint(x: rect.minX, y: rect.midY + shaftHalf))
            path.close()
            return path
        case "star":
            // Five points by default; `sides` sets the point count.
            let path = NSBezierPath()
            let points = max(4, spec.sides)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let outerX = rect.width / 2
            let outerY = rect.height / 2
            for index in 0..<(points * 2) {
                let angle = Double(index) / Double(points * 2) * 2 * .pi - .pi / 2
                let scale = index % 2 == 0 ? 1.0 : 0.45
                let point = NSPoint(x: center.x + cos(angle) * outerX * scale,
                                    y: center.y + sin(angle) * outerY * scale)
                if index == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.close()
            return path
        case "bubble":
            // Rounded speech bubble, tail at the lower left.
            let tail = rect.height * 0.22
            let body = NSRect(x: rect.minX, y: rect.minY + tail,
                              width: rect.width, height: rect.height - tail)
            let radius = min(body.height * 0.25, body.width * 0.2)
            let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
            let tailPath = NSBezierPath()
            tailPath.move(to: NSPoint(x: body.minX + body.width * 0.18, y: body.minY + 2))
            tailPath.line(to: NSPoint(x: body.minX + body.width * 0.14, y: rect.minY))
            tailPath.line(to: NSPoint(x: body.minX + body.width * 0.34, y: body.minY + 2))
            tailPath.close()
            path.append(tailPath)
            return path
        case "polygon":
            let path = NSBezierPath()
            let sides = max(3, spec.sides)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            for index in 0..<sides {
                let angle = Double(index) / Double(sides) * 2 * .pi - .pi / 2
                let point = NSPoint(x: center.x + cos(angle) * rect.width / 2,
                                    y: center.y + sin(angle) * rect.height / 2)
                index == 0 ? path.move(to: point) : path.line(to: point)
            }
            path.close()
            return path
        default:
            return NSBezierPath(roundedRect: rect, xRadius: spec.cornerRadius,
                                yRadius: spec.cornerRadius)
        }
    }

    private static func drawShape(_ spec: ShapeSpec, layer: ThumbLayer, in size: CGSize,
                                  center: CGPoint) {
        let width = layer.widthFraction * size.width
        let height = layer.heightFraction * size.height
        let rect = NSRect(x: center.x - width / 2, y: center.y - height / 2,
                          width: width, height: height)
        let path = shapePath(spec, in: rect)
        let cut = cutPath(edge: spec.cutEdge, amount: spec.cutAmount,
                          flip: spec.cutFlip, in: rect)
        let cg = NSGraphicsContext.current?.cgContext
        if cut != nil { cg?.saveGState(); cut?.addClip() }
        defer { if cut != nil { cg?.restoreGState() } }
        if spec.shape == "line" {
            HexColor.color(hex: spec.strokeHex).setStroke()
            path.stroke()
            return
        }
        if let fillHex = spec.fillHex {
            if let gradientHex = spec.fillGradientHex,
               let gradient = NSGradient(
                   starting: HexColor.color(hex: fillHex),
                   ending: HexColor.color(hex: gradientHex)) {
                gradient.draw(in: path, angle: CGFloat(spec.gradientAngleDegrees))
            } else {
                HexColor.color(hex: fillHex).setFill()
                path.fill()
            }
        }
        if spec.strokeWidth > 0.1 {
            HexColor.color(hex: spec.strokeHex).setStroke()
            path.lineWidth = spec.strokeWidth
            path.stroke()
        }
    }

    // MARK: - Export encoding

    /// Encoded bytes for the document at a JPEG quality (1 = PNG).
    static func encoded(_ image: NSImage, asPNG: Bool, jpegQuality: Double) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return asPNG
            ? rep.representation(using: .png, properties: [:])
            : rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
    }

    /// Walks JPEG quality down until the file fits the cap. Returns the data
    /// and the quality that achieved it; nil when even the floor won't fit.
    static func compressToFit(_ image: NSImage, capBytes: Int,
                              startQuality: Double = 0.9) -> (data: Data, quality: Double)? {
        var quality = startQuality
        while quality >= 0.3 {
            if let data = encoded(image, asPNG: false, jpegQuality: quality),
               data.count <= capBytes {
                return (data, quality)
            }
            quality -= 0.05
        }
        return nil
    }
}

/// Adjusted layer images, cached by spec — sliders re-render the canvas per
/// tick, and Core Image work shouldn't happen per tick per layer.
@MainActor
final class AdjustedImageCache {
    static let shared = AdjustedImageCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(for spec: ImageSpec) -> NSImage? {
        let key = cacheKey(spec) as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard var image = NSImage(contentsOfFile: spec.effectivePath) else { return nil }
        // Cropping happens in drawImage's source rect, so every provider —
        // gallery previews, template cards, the harness — crops identically.
        if spec.hasAdjustments, let adjusted = Self.adjusted(image, spec: spec) {
            image = adjusted
        }
        cache.setObject(image, forKey: key)
        return image
    }

    func invalidate() { cache.removeAllObjects() }

    private func cacheKey(_ spec: ImageSpec) -> String {
        "\(spec.effectivePath)|\(spec.brightness)|\(spec.contrast)|\(spec.saturation)"
            + "|\(spec.exposure)|\(spec.vibrance)|\(spec.filterPreset)"
            + "|\(spec.crop.map { "\($0.x),\($0.y),\($0.width),\($0.height)" } ?? "-")"
    }

    nonisolated static func adjusted(_ image: NSImage, spec: ImageSpec) -> NSImage? {
        guard let tiff = image.tiffRepresentation, var ci = CIImage(data: tiff) else { return nil }
        if abs(spec.brightness) > 0.001 || abs(spec.contrast) > 0.001 || abs(spec.saturation) > 0.001 {
            ci = ci.applyingFilter("CIColorControls", parameters: [
                "inputBrightness": spec.brightness * 0.5,
                "inputContrast": 1 + spec.contrast * 0.6,
                "inputSaturation": 1 + spec.saturation,
            ])
        }
        if abs(spec.exposure) > 0.001 {
            ci = ci.applyingFilter("CIExposureAdjust", parameters: ["inputEV": spec.exposure * 2])
        }
        if abs(spec.vibrance) > 0.001 {
            ci = ci.applyingFilter("CIVibrance", parameters: ["inputAmount": spec.vibrance])
        }
        let presets = ["mono": "CIPhotoEffectMono", "chrome": "CIPhotoEffectChrome",
                       "fade": "CIPhotoEffectFade", "instant": "CIPhotoEffectInstant",
                       "noir": "CIPhotoEffectNoir"]
        if let filterName = presets[spec.filterPreset] {
            ci = ci.applyingFilter(filterName)
        }
        let rep = NSCIImageRep(ciImage: ci)
        let output = NSImage(size: rep.size)
        output.addRepresentation(rep)
        return output
    }
}

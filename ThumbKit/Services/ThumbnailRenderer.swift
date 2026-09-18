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

    /// The app's provider. Nonisolated, like the renderer it feeds, so a
    /// canvas render can happen off the main thread — decoding a 4K JPEG is
    /// tens of milliseconds on a good day and unbounded on a bad one, and
    /// neither belongs on the thread that draws the window.
    static func renderForStudio(_ document: ThumbDocument) -> NSImage? {
        render(document, showingPlaceholders: true) { spec in
            AdjustedImageCache.shared.image(for: spec)
        }
    }

    /// `showingPlaceholders` draws the "double-click to set image" slot for an
    /// empty image layer. That is editor chrome: true on the canvas, false
    /// everywhere the pixels are the deliverable, so an unfilled template slot
    /// can never be baked into an exported thumbnail.
    static func render(_ document: ThumbDocument,
                       showingPlaceholders: Bool = false,
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
        // previews sensibly. A transparent document paints nothing at all, so
        // the bitmap's alpha survives into a PNG.
        if !document.transparentBackground {
            HexColor.color(hex: document.backgroundHex ?? ThumbDocument.defaultBackgroundHex)
                .setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
        }

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
            if layer.effects.isActive {
                drawWithEffects(layer, in: size, center: center, provider: provider,
                                showingPlaceholders: showingPlaceholders)
            } else {
                draw(layer, in: size, center: center, provider: provider,
                     showingPlaceholders: showingPlaceholders)
            }
            cg?.restoreGState()
        }

        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// The height a layer actually draws at, as a fraction of the canvas.
    /// Text measures its wrapped bounds; an image follows its *cropped*
    /// aspect. The canvas draws its selection box from this, so a five-line
    /// headline is selectable over all five lines and a cropped photo's
    /// handle sits on the photo rather than below it.
    static func drawnHeightFraction(_ layer: ThumbLayer, in size: CGSize,
                                    provider: ImageProvider) -> Double {
        switch layer.kind {
        case .shape:
            return layer.heightFraction
        case .text(let spec):
            guard !spec.renderedText.isEmpty, size.height > 0 else { return layer.heightFraction }
            let width = layer.widthFraction * size.width
            let measured = NSAttributedString(
                string: spec.renderedText,
                attributes: textAttributes(spec, canvasHeight: size.height, strokePass: false))
                .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                              options: [.usesLineFragmentOrigin])
            return Double((ceil(measured.height) + 4) / size.height)
        case .image(let spec):
            guard let image = provider(spec), image.size.width > 0 else {
                return layer.heightFraction
            }
            let crop = spec.crop?.clamped()
            let sourceW = image.size.width * CGFloat(crop.map(\.width) ?? 1)
            let sourceH = image.size.height * CGFloat(crop.map(\.height) ?? 1)
            guard sourceW > 0 else { return layer.heightFraction }
            let drawn = layer.widthFraction * size.width * Double(sourceH / sourceW)
            return drawn / Double(size.height)
        }
    }

    /// The rectangle a layer actually occupies on the canvas, in fractions —
    /// centre-relative, matching how layers are positioned.
    ///
    /// For text this is the MEASURED glyph box, not the wrap width. A centred
    /// headline with a 0.85 wrap width may only paint 0.4 of the canvas, and
    /// anything reasoning about overlap (does this collide with YouTube's
    /// duration stamp?) has to use the ink, not the text box, or it cries wolf.
    static func drawnBounds(_ layer: ThumbLayer, in size: CGSize,
                            provider: ImageProvider) -> CGRect {
        let height = drawnHeightFraction(layer, in: size, provider: provider)
        var width = layer.widthFraction

        if case .text(let spec) = layer.kind,
           !spec.renderedText.isEmpty, size.width > 0 {
            let wrap = layer.widthFraction * size.width
            let measured = NSAttributedString(
                string: spec.renderedText,
                attributes: textAttributes(spec, canvasHeight: size.height, strokePass: false))
                .boundingRect(with: NSSize(width: wrap, height: .greatestFiniteMagnitude),
                              options: [.usesLineFragmentOrigin])
            // Centred text paints around the layer centre; left/right-aligned
            // text can sit anywhere inside the wrap box, so stay conservative
            // and keep the full width for those.
            if spec.alignment == "center" {
                width = min(layer.widthFraction, Double(measured.width) / Double(size.width))
            }
        }
        return CGRect(x: layer.x - width / 2, y: layer.y - height / 2,
                      width: width, height: height)
    }

    static func blendMode(_ name: String) -> CGBlendMode {
        switch name {
        case "multiply": return .multiply
        case "screen": return .screen
        case "overlay": return .overlay
        default: return .normal
        }
    }

    static func draw(_ layer: ThumbLayer, in size: CGSize,
                             center: CGPoint, provider: ImageProvider,
                             showingPlaceholders: Bool) {
        switch layer.kind {
        case .image(let spec):
            drawImage(spec, layer: layer, in: size, center: center, provider: provider,
                      showingPlaceholders: showingPlaceholders)
        case .text(let spec):
            drawText(spec, layer: layer, in: size, center: center)
        case .shape(let spec):
            drawShape(spec, layer: layer, in: size, center: center)
        }
    }

    // MARK: - Image

    private static func drawImage(_ spec: ImageSpec, layer: ThumbLayer, in size: CGSize,
                                  center: CGPoint, provider: ImageProvider,
                                  showingPlaceholders: Bool) {
        guard let image = provider(spec), image.size.width > 0 else {
            // A template's empty face slot: visible and selectable while you
            // work, absent from anything anyone else will see.
            guard showingPlaceholders else { return }
            let width = layer.widthFraction * size.width
            let height = layer.heightFraction * size.height
            let rect = NSRect(x: center.x - width / 2, y: center.y - height / 2,
                              width: width, height: height)
            // An empty slot and a file that would not open are different
            // problems, and "double-click to set image" is a lie about the
            // second one: the image IS set, it just could not be read.
            let unset = spec.effectivePath.isEmpty
            let message = unset
                ? "double-click to set image"
                : "can't read \(URL(fileURLWithPath: spec.effectivePath).lastPathComponent)"
            if unset {
                NSColor(calibratedWhite: 0.25, alpha: 0.8).setFill()
            } else {
                NSColor(calibratedRed: 0.42, green: 0.26, blue: 0.10, alpha: 0.85).setFill()
            }
            let slot = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            slot.fill()
            if !unset {
                NSColor(calibratedRed: 0.82, green: 0.60, blue: 0.13, alpha: 0.9).setStroke()
                slot.lineWidth = max(1, size.height * 0.004)
                slot.stroke()
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingMiddle
            NSAttributedString(string: message, attributes: [
                .font: NSFont.systemFont(ofSize: size.height * 0.03, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
                .paragraphStyle: paragraph,
            ]).draw(in: NSRect(x: rect.minX + rect.width * 0.04,
                               y: center.y - size.height * 0.02,
                               width: rect.width * 0.92, height: size.height * 0.05))
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
            // An outlined cutout can still be framed and cut — the inspector
            // offers both, and the crop sheet previews the slant.
            let outlineCut = cutPath(edge: spec.cutEdge, amount: spec.cutAmount,
                                     flip: spec.cutFlip, in: rect)
            let outlineMask: NSBezierPath? = {
                switch spec.maskShape {
                case "rounded":
                    return NSBezierPath(roundedRect: rect, xRadius: spec.maskCornerRadius,
                                        yRadius: spec.maskCornerRadius)
                case "circle":
                    let side = min(rect.width, rect.height)
                    return NSBezierPath(ovalIn: NSRect(x: rect.midX - side / 2,
                                                       y: rect.midY - side / 2,
                                                       width: side, height: side))
                default:
                    return nil
                }
            }()
            if outlineCut != nil || outlineMask != nil {
                cg?.saveGState()
                outlineMask?.addClip()
                outlineCut?.addClip()
            }
            defer {
                if outlineCut != nil || outlineMask != nil {
                    cg?.restoreGState()
                    if spec.borderWidth > 0.1, let edge = outlineMask ?? outlineCut {
                        HexColor.color(hex: spec.borderHex).setStroke()
                        edge.lineWidth = spec.borderWidth
                        edge.stroke()
                    }
                }
            }
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
                // The shadow has to come from the masked silhouette, but a
                // clip would also clip the shadow away. A transparency layer
                // composites the clipped draw as one unit, so the shadow is
                // cast from the result rather than from each primitive.
                cg?.beginTransparencyLayer(auxiliaryInfo: nil)
                cg?.saveGState()
                maskPath?.addClip()
                cut?.addClip()
                image.draw(in: rect, from: sourceRect, operation: .sourceOver, fraction: 1)
                cg?.restoreGState()
                cg?.endTransparencyLayer()
                cg?.setShadow(offset: .zero, blur: 0, color: nil)
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
        let font = ThumbFonts.font(for: spec, size: fontSize)
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
        let text = spec.renderedText
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
        // The shadow belongs to the outermost thing drawn: the stroke when
        // there is one, otherwise the fill. Clearing it before the fill pass
        // regardless is why stroke-free text never had a shadow.
        if spec.strokeWidth > 0.1 {
            NSAttributedString(string: text,
                               attributes: textAttributes(spec, canvasHeight: size.height,
                                                          strokePass: true)).draw(in: rect)
            cg?.setShadow(offset: .zero, blur: 0, color: nil)
        }

        // An image through the letters, using the same trick as the gradient:
        // the text becomes a mask and the picture draws through it. Takes
        // precedence over a gradient, because a fill cannot be both.
        if let fillPath = spec.imageFillPath, !fillPath.isEmpty,
           let art = NSImage(contentsOfFile: fillPath) {
            let maskImage = NSImage(size: rect.size, flipped: false) { drawRect in
                NSAttributedString(string: text,
                                   attributes: textAttributes(spec, canvasHeight: size.height,
                                                              strokePass: false))
                    .draw(in: drawRect)
                return true
            }
            if let tiff = maskImage.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let mask = bitmap.cgImage {
                cg?.saveGState()
                cg?.clip(to: rect, mask: mask)
                // Cover-fit, so the letters are never filled with letterbox.
                let scale = max(rect.width / max(1, art.size.width),
                                rect.height / max(1, art.size.height))
                let drawn = NSSize(width: art.size.width * scale,
                                   height: art.size.height * scale)
                art.draw(in: NSRect(x: rect.midX - drawn.width / 2,
                                    y: rect.midY - drawn.height / 2,
                                    width: drawn.width, height: drawn.height))
                cg?.restoreGState()
            }
        } else if let gradientHex = spec.gradientHex {
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
        // The shadow is per-context, not per-draw: leave it set and the next
        // layer inherits it.
        cg?.setShadow(offset: .zero, blur: 0, color: nil)
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
        if asPNG { return rep.representation(using: .png, properties: [:]) }
        // JPEG has no alpha channel. Encoding a transparent bitmap straight to
        // JPEG gives you whatever was in the unwritten pixels — usually black.
        // Flatten onto white first so the file is at least predictable.
        guard rep.hasAlpha else {
            return rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
        }
        let flattened = NSImage(size: image.size)
        flattened.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        flattened.unlockFocus()
        guard let flatTiff = flattened.tiffRepresentation,
              let flatRep = NSBitmapImageRep(data: flatTiff) else { return nil }
        return flatRep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
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

extension ThumbnailRenderer {
    /// The off-main-actor provider every preview uses. Reads the file and
    /// applies the layer's adjustments, exactly as the canvas and the export
    /// do — a preview that skips them is a preview of a different image.
    nonisolated static let fileProvider: ImageProvider = { spec in
        guard !spec.effectivePath.isEmpty,
              let image = NSImage(contentsOfFile: spec.effectivePath) else { return nil }
        guard spec.hasAdjustments else { return image }
        return AdjustedImageCache.adjusted(image, spec: spec) ?? image
    }
}

/// Adjusted layer images, cached by spec — sliders re-render the canvas per
/// tick, and Core Image work shouldn't happen per tick per layer.
///
/// Not main-actor-confined: both caches are `NSCache`, which is documented
/// thread-safe, and confining them to the main actor was what forced the whole
/// canvas render onto the main thread with them.
final class AdjustedImageCache: @unchecked Sendable {
    static let shared = AdjustedImageCache()
    private let cache = NSCache<NSString, NSImage>()
    private let originals = NSCache<NSString, NSImage>()
    /// Paths with a read in flight, so a slow file is waited on once.
    private let lock = NSLock()
    private var reading: Set<String> = []

    func image(for spec: ImageSpec) -> NSImage? {
        let key = cacheKey(spec) as NSString
        if let hit = cache.object(forKey: key) { return hit }
        // Two caches, because they miss at different rates: the adjusted
        // result changes on every slider tick, the decoded source does not.
        // Without this, dragging Brightness re-read and re-decoded the file
        // from disk sixty times a second.
        guard var image = decoded(spec.effectivePath) else { return nil }
        // Cropping happens in drawImage's source rect, so every provider —
        // gallery previews, template cards, the harness — crops identically.
        if spec.hasAdjustments, let adjusted = Self.adjusted(image, spec: spec) {
            image = adjusted
        }
        cache.setObject(image, forKey: key)
        return image
    }

    /// How long a render will wait for one file before drawing without it.
    ///
    /// There has to be a limit. `NSImage(contentsOfFile:)` opens the file, and
    /// an open() on an iCloud-evicted path does not fail — it waits for the
    /// download. One such file on this Mac took 2h41m to answer, and because
    /// the whole canvas render sat inside that one call, the artboard stayed
    /// black the entire time with nothing on it and no explanation.
    ///
    /// Generous for a local disk (a 4K JPEG decodes in tens of milliseconds)
    /// and short enough that a stubborn file costs you one pause, not a
    /// session.
    static let readDeadline: TimeInterval = 1.5

    /// Posted when a file that missed its deadline finally arrives, so
    /// whoever drew without it can draw again.
    static let imageDidArrive = Notification.Name("ThumbAdjustedImageDidArrive")

    /// How a file becomes an image. Overridable so a check can make a read
    /// take as long as it likes — the same trick `ThumbKeyContext` uses for
    /// the key window. Production never reassigns it.
    ///
    /// It has to be injectable because the condition being defended against
    /// cannot be staged: a named pipe looked like the obvious stand-in for a
    /// file that will not open, and `NSImage(contentsOfFile:)` rejects one
    /// without blocking, so the test passed against the bug it was written for.
    nonisolated(unsafe) static var reader: (String) -> NSImage? = {
        NSImage(contentsOfFile: $0)
    }

    private func decoded(_ path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        let key = path as NSString
        if let hit = originals.object(forKey: key) { return hit }

        // Only one reader per path. Without this, every layer using a slow
        // file — and every re-render while it is still slow — would start its
        // own read and wait its own deadline.
        lock.lock()
        let alreadyReading = reading.contains(path)
        if !alreadyReading { reading.insert(path) }
        lock.unlock()
        if alreadyReading { return nil }

        let arrived = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = AdjustedImageCache.reader(path)
            guard let self else { return }
            if let image { self.originals.setObject(image, forKey: key) }
            self.lock.lock()
            self.reading.remove(path)
            self.lock.unlock()
            // `signal()` reports whether it woke anyone. Nobody waiting means
            // the render gave up and drew a placeholder, so it needs telling.
            let wokeTheWaiter = arrived.signal() != 0
            if !wokeTheWaiter, image != nil {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: AdjustedImageCache.imageDidArrive, object: nil)
                }
            }
        }

        guard arrived.wait(timeout: .now() + Self.readDeadline) == .success else {
            return nil
        }
        return originals.object(forKey: key)
    }

    func invalidate() {
        cache.removeAllObjects()
        originals.removeAllObjects()
        // Reads in flight are deliberately left alone: they are already
        // running, and forgetting them would let the next render start a
        // second read of the same file.
    }

    /// Derived from the values, not hand-listed by name. The previous key
    /// enumerated each adjustment, so adding one here meant remembering to
    /// add it there too — and forgetting meant the cache cheerfully served the
    /// pre-adjustment image forever.
    private func cacheKey(_ spec: ImageSpec) -> String {
        let values = spec.adjustmentValues
            .map { String(format: "%.4f", $0) }
            .joined(separator: ",")
        let crop = spec.crop.map { "\($0.x),\($0.y),\($0.width),\($0.height)" } ?? "-"
        return "\(spec.effectivePath)|\(values)|\(spec.filterPreset)|\(crop)"
    }

    nonisolated static func adjusted(_ image: NSImage, spec: ImageSpec) -> NSImage? {
        guard let tiff = image.tiffRepresentation, var ci = CIImage(data: tiff) else { return nil }
        let extent = ci.extent

        // Order matters, and it is the order a photo editor uses: get the
        // exposure and white balance right, recover the ends of the range,
        // then grade, then sharpen, then vignette, then apply a look.
        if abs(spec.exposure) > 0.001 {
            ci = ci.applyingFilter("CIExposureAdjust", parameters: ["inputEV": spec.exposure * 2])
        }
        if abs(spec.temperature) > 0.001 || abs(spec.tint) > 0.001 {
            // Neutral is 6500K; the slider moves +/- 3000K and +/- 100 tint.
            ci = ci.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 + spec.temperature * 3000,
                                         y: spec.tint * 100),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        if abs(spec.highlights) > 0.001 || abs(spec.shadows) > 0.001 {
            // Apple's filter takes highlights 0…1 where 1 is untouched, and
            // shadows -1…1 where 0 is untouched. The sliders are both
            // zero-centred, so map them.
            ci = ci.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 - max(0, spec.highlights),
                "inputShadowAmount": spec.shadows,
            ])
        }
        if abs(spec.brightness) > 0.001 || abs(spec.contrast) > 0.001
            || abs(spec.saturation) > 0.001 {
            ci = ci.applyingFilter("CIColorControls", parameters: [
                "inputBrightness": spec.brightness * 0.5,
                "inputContrast": 1 + spec.contrast * 0.6,
                "inputSaturation": 1 + spec.saturation,
            ])
        }
        if abs(spec.vibrance) > 0.001 {
            ci = ci.applyingFilter("CIVibrance", parameters: ["inputAmount": spec.vibrance])
        }
        if abs(spec.hue) > 0.001 {
            ci = ci.applyingFilter("CIHueAdjust",
                                   parameters: ["inputAngle": spec.hue * .pi / 180])
        }
        if spec.noiseReduction > 0.001 {
            ci = ci.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": spec.noiseReduction * 0.05,
                "inputSharpness": 0.4,
            ])
        }
        if spec.sharpness > 0.001 {
            ci = ci.applyingFilter("CIUnsharpMask", parameters: [
                "inputRadius": 2.0,
                "inputIntensity": spec.sharpness,
            ])
        }
        if spec.vignette > 0.001 {
            ci = ci.applyingFilter("CIVignette", parameters: [
                "inputIntensity": spec.vignette * 2,
                "inputRadius": 1.5,
            ])
        }
        let presets = ["mono": "CIPhotoEffectMono", "chrome": "CIPhotoEffectChrome",
                       "fade": "CIPhotoEffectFade", "instant": "CIPhotoEffectInstant",
                       "noir": "CIPhotoEffectNoir"]
        if let filterName = presets[spec.filterPreset] {
            ci = ci.applyingFilter(filterName)
        }
        // Blur-family filters grow the extent and shift the origin; crop back
        // so the layer still lines up with where the canvas thinks it is.
        ci = ci.cropped(to: extent)

        // Flattened, not wrapped. An NSImage backed by NSCIImageRep is lazy:
        // the whole Core Image chain re-runs at full resolution on every
        // single draw, so the cache above was caching a promise to redo the
        // work rather than the work. Rasterising once here costs one pass and
        // makes every subsequent render of that layer a plain blit.
        // Measured on a 3840x2160 source: 58.2 ms/render before, 15.6 after.
        guard extent.width > 0, extent.height > 0, extent.width.isFinite,
              extent.height.isFinite,
              let cg = sharedContext.createCGImage(ci, from: extent) else {
            // A filter that produced an infinite or empty extent is not worth
            // failing the whole render over; draw the source unadjusted.
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        // Keep the SOURCE's point size, not the pixel extent. A 2x-backed
        // NSImage has twice as many pixels as points, so sizing from the
        // extent would silently draw every adjusted layer at half scale
        // against its unadjusted neighbours.
        rep.size = image.size
        let output = NSImage(size: image.size)
        output.addRepresentation(rep)
        return output
    }

    /// One context for every adjustment pass. Building a CIContext per call
    /// is its own measurable cost, and this one is stateless and thread-safe.
    nonisolated static let sharedContext =
        CIContext(options: [.useSoftwareRenderer: false])
}

// MARK: - Layer effects

extension ThumbnailRenderer {
    /// Draws a layer with its effects around it.
    ///
    /// The layer is rendered once, alone, into its own transparent bitmap, and
    /// everything after that is derived from that bitmap's ALPHA. That is what
    /// makes one implementation serve all three layer kinds: a glow does not
    /// need to know whether it is haloing a glyph, a cutout or a polygon, only
    /// where the layer put paint.
    ///
    /// Rendered unrotated on purpose. The canvas context already carries the
    /// layer's rotation when this is called, so compositing the finished image
    /// through it rotates the effects with the layer — which is what you want,
    /// and what building the glow in canvas space would have got wrong.
    static func drawWithEffects(_ layer: ThumbLayer, in size: CGSize, center: CGPoint,
                                provider: ImageProvider, showingPlaceholders: Bool) {
        guard let rep = isolatedRender(layer, in: size, center: center, provider: provider,
                                       showingPlaceholders: showingPlaceholders),
              let cg = rep.cgImage
        else {
            // No bitmap to work in; the layer itself still matters more than
            // its decoration, so draw it plainly rather than not at all.
            draw(layer, in: size, center: center, provider: provider,
                 showingPlaceholders: showingPlaceholders)
            return
        }
        let base = CIImage(cgImage: cg)

        // An overlay repaints the layer's colour, and the layer's alpha
        // includes its stroke — so a gradient over a stroked headline painted
        // straight over the black outline that keeps the letters apart, and
        // "DOOMSDAY HEIST" came out as one orange blob. The overlay is masked
        // to a second render of the same layer with its stroke removed, so it
        // recolours the letters and leaves the outline alone.
        var fillMask: CIImage?
        if layer.effects.hasOverlay, isStroked(layer),
           let maskRep = isolatedRender(strokeless(layer), in: size, center: center,
                                        provider: provider, showingPlaceholders: false),
           let maskCG = maskRep.cgImage {
            fillMask = CIImage(cgImage: maskCG)
        }

        let composed = composited(layer.effects, over: base, fillMask: fillMask,
                                  inked: paintedExtent(of: rep) ?? base.extent,
                                  canvasHeight: size.height)
        // The cache's context, deliberately: it is stateless and thread-safe,
        // and a second CIContext is a second GPU pipeline for no reason.
        guard let out = AdjustedImageCache.sharedContext.createCGImage(
            composed, from: base.extent) else { return }
        NSGraphicsContext.current?.cgContext.draw(
            out, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
    }



    /// Draws one layer, alone, into its own transparent bitmap of canvas size.
    static func isolatedRender(_ layer: ThumbLayer, in size: CGSize, center: CGPoint,
                               provider: ImageProvider,
                               showingPlaceholders: Bool) -> NSBitmapImageRep? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let isolated = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = isolated
        isolated.imageInterpolation = .high
        draw(layer, in: size, center: center, provider: provider,
             showingPlaceholders: showingPlaceholders)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Whether this layer draws an outline that an overlay must not cover.
    static func isStroked(_ layer: ThumbLayer) -> Bool {
        switch layer.kind {
        case .text(let spec): return spec.strokeWidth > 0.1
        case .image(let spec): return spec.strokeWidth > 0.1 || spec.borderWidth > 0.1
        case .shape(let spec): return spec.strokeWidth > 0.1
        }
    }

    /// The same layer with its outline taken off, for use as an overlay mask.
    static func strokeless(_ layer: ThumbLayer) -> ThumbLayer {
        var bare = layer
        switch layer.kind {
        case .text(var spec):
            spec.strokeWidth = 0
            spec.shadowEnabled = false
            bare.kind = .text(spec)
        case .image(var spec):
            spec.strokeWidth = 0
            spec.borderWidth = 0
            spec.shadowEnabled = false
            bare.kind = .image(spec)
        case .shape(var spec):
            spec.strokeWidth = 0
            bare.kind = .shape(spec)
        }
        return bare
    }

    /// The box the layer actually put pixels in, in Core Image's bottom-left
    /// space. nil when it painted nothing.
    ///
    /// Measured from the bitmap rather than from `drawnBounds`, because a
    /// gradient has to run across the LETTERS. A text layer's measured box
    /// includes the line's leading and descender space, so a single line of
    /// digits occupies only the middle of it — and a yellow-to-pink ramp
    /// scaled to the box came out yellow-to-orange, never reaching its own
    /// second colour.
    static func paintedExtent(of rep: NSBitmapImageRep) -> CGRect? {
        guard let data = rep.bitmapData, rep.samplesPerPixel == 4 else { return nil }
        let width = rep.pixelsWide, height = rep.pixelsHigh
        let rowBytes = rep.bytesPerRow, pixelBytes = rep.bitsPerPixel / 8
        guard width > 0, height > 0, pixelBytes >= 4 else { return nil }
        // Every fourth pixel. This is sizing a gradient, not clipping a mask —
        // a few pixels of slop at the edge is invisible, and a full scan of a
        // 4K canvas is not.
        let step = max(1, min(width, height) / 400)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for row in stride(from: 0, to: height, by: step) {
            let rowStart = row * rowBytes
            for column in stride(from: 0, to: width, by: step) {
                guard data[rowStart + column * pixelBytes + 3] > 8 else { continue }
                if column < minX { minX = column }
                if column > maxX { maxX = column }
                if row < minY { minY = row }
                if row > maxY { maxY = row }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // Row 0 of a bitmap rep is the TOP; Core Image counts from the bottom.
        return CGRect(x: CGFloat(minX),
                      y: CGFloat(height - maxY - 1),
                      width: CGFloat(max(1, maxX - minX + 1)),
                      height: CGFloat(max(1, maxY - minY + 1)))
    }

    /// The effect stack, bottom to top, in the order a design tool applies it:
    /// glow behind the layer, then the layer, then the overlays that replace
    /// its colour, then the inner shadow that sits inside its edge.
    static func composited(_ effects: LayerEffects, over base: CIImage,
                           fillMask: CIImage? = nil,
                           inked: CGRect, canvasHeight: CGFloat) -> CIImage {
        // What the overlays are allowed to repaint: the layer minus its
        // outline when it has one, the whole layer otherwise.
        let paintable = fillMask ?? base
        // Authored at 720p and scaled, like every other pixel measure here.
        let scale = Double(canvasHeight) / 720
        var result = base

        if effects.colorOverlayEnabled, effects.colorOverlayOpacity > 0.001 {
            let fill = tinted(paintable, hex: effects.colorOverlayHex,
                              opacity: effects.colorOverlayOpacity)
            result = fill.applyingFilter("CISourceAtopCompositing",
                                         parameters: [kCIInputBackgroundImageKey: result])
        }
        if effects.gradientOverlayEnabled, effects.gradientOpacity > 0.001 {
            let ramp = gradient(over: inked, from: effects.gradientFromHex,
                                to: effects.gradientToHex,
                                angle: effects.gradientAngleDegrees,
                                opacity: effects.gradientOpacity)
            // Masked to the layer's own alpha first, so a gradient on text
            // fills the letters and not the box around them.
            let masked = ramp.applyingFilter("CISourceInCompositing",
                                             parameters: [kCIInputBackgroundImageKey: paintable])
                .cropped(to: base.extent)
            result = masked.applyingFilter("CISourceAtopCompositing",
                                           parameters: [kCIInputBackgroundImageKey: result])
        }
        if effects.innerShadowEnabled, effects.innerShadowOpacity > 0.001 {
            result = withInnerShadow(effects, base: base, over: result, scale: scale)
        }
        if effects.glowEnabled, effects.glowRadius > 0.01, effects.glowOpacity > 0.001 {
            let halo = glow(effects, from: base, scale: scale)
            result = result.applyingFilter("CISourceOverCompositing",
                                           parameters: [kCIInputBackgroundImageKey: halo])
        }
        return result.cropped(to: base.extent)
    }

    /// The layer's silhouette in one colour, at one opacity.
    private static func tinted(_ image: CIImage, hex: String, opacity: Double) -> CIImage {
        let colour = HexColor.color(hex: hex).usingColorSpace(.deviceRGB) ?? .white
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: colour.redComponent),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: colour.greenComponent),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: colour.blueComponent),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity)),
        ])
    }

    private static func gradient(over extent: CGRect, from: String, to: String,
                                 angle: Double, opacity: Double) -> CIImage {
        let radians: Double = angle * .pi / 180
        let cosine = CGFloat(cos(radians)), sine = CGFloat(sin(radians))
        // The box's half-extent measured ALONG the gradient's own direction,
        // not its longest side. Using the longest side meant a vertical ramp
        // over wide, short text spanned the text's WIDTH, so the letters only
        // ever sampled the middle of it and the second colour never arrived.
        let reach = abs(cosine) * extent.width / 2 + abs(sine) * extent.height / 2
        let mid = CGPoint(x: extent.midX, y: extent.midY)
        // 90 degrees runs the FROM colour at the top down to the TO colour at
        // the bottom, matching `TextSpec.gradientHex`, which is documented as
        // "fill at the top, this at the bottom". Core Image's y grows upward,
        // so the from-point is the one that gets +sine.
        let start = CGPoint(x: mid.x + cosine * reach, y: mid.y + sine * reach)
        let end = CGPoint(x: mid.x - cosine * reach, y: mid.y - sine * reach)
        func colour(_ hex: String) -> CIColor {
            let rgba = HexColor.color(hex: hex).usingColorSpace(.deviceRGB) ?? .white
            return CIColor(red: rgba.redComponent, green: rgba.greenComponent,
                           blue: rgba.blueComponent, alpha: CGFloat(opacity))
        }
        let ramp = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(cgPoint: start),
            "inputPoint1": CIVector(cgPoint: end),
            "inputColor0": colour(from),
            "inputColor1": colour(to),
        ])?.outputImage ?? CIImage(color: colour(from))
        // Aimed across the ink, but not clipped to it: the mask decides where
        // it shows, and cropping here would cut a glyph that leans outside the
        // measured box.
        return ramp
    }

    /// A blurred, fattened halo of the layer's silhouette.
    private static func glow(_ effects: LayerEffects, from base: CIImage,
                             scale: Double) -> CIImage {
        var halo = tinted(base, hex: effects.glowHex, opacity: 1)
        let spread = effects.glowSpread * effects.glowRadius * scale
        if spread > 0.5 {
            // Fatten before blurring. Blurring thin glyphs on their own
            // spreads their alpha to almost nothing, so a large radius gave a
            // faint mist rather than a glow — which is what Photoshop's Spread
            // exists to fix, and it does it the same way.
            halo = halo.applyingFilter("CIMorphologyMaximum",
                                       parameters: ["inputRadius": spread])
        }
        // Clamp first: a Gaussian on an image with hard edges at the canvas
        // bounds darkens them, because everything outside reads as transparent.
        halo = halo.clampedToExtent()
            .applyingFilter("CIGaussianBlur",
                            parameters: ["inputRadius": effects.glowRadius * scale])
            .cropped(to: base.extent)
        return halo.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(effects.glowOpacity)),
        ])
    }

    /// Shadow cast INSIDE the layer's edge: the inverse of its own alpha,
    /// offset and blurred, then clipped back to the layer.
    private static func withInnerShadow(_ effects: LayerEffects, base: CIImage,
                                        over result: CIImage, scale: Double) -> CIImage {
        // alpha' = 1 - alpha, which turns the hole into the caster.
        let inverted = base.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: -1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let colour = HexColor.color(hex: effects.innerShadowHex).usingColorSpace(.deviceRGB)
            ?? .black
        let radians: Double = effects.innerShadowAngle * .pi / 180
        let cosine = cos(radians), sine = sin(radians)
        let distance = effects.innerShadowDistance * scale
        let caster = inverted
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: colour.redComponent),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: colour.greenComponent),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: colour.blueComponent),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(effects.innerShadowOpacity)),
            ])
            .transformed(by: CGAffineTransform(translationX: -cosine * distance,
                                               y: -sine * distance))
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur",
                            parameters: ["inputRadius": effects.innerShadowRadius * scale])
            .cropped(to: base.extent)
        return caster.applyingFilter("CISourceAtopCompositing",
                                     parameters: [kCIInputBackgroundImageKey: result])
    }
}

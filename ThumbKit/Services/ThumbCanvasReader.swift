import AppKit
import Foundation

/// Looks at what is actually on the canvas, so the composer can place text
/// against measurements instead of assumptions.
///
/// The whole job is done by rendering the design without its text and reading
/// the pixels. That sounds blunt, and it is the point: `drawnBounds` ignores
/// `rotationDegrees`, and real designs here rotate a divider by -45.8° and a
/// cutout by 31.7°. Any occupancy map built from layer rectangles would be
/// wrong about precisely the layers that dominate the picture. A render cannot
/// be wrong about where the paint landed.
enum ThumbCanvasReader {

    /// Grid resolution. 16×9 keeps a cell at 80×80 px on a 1280×720 canvas —
    /// fine enough to find a gap beside a subject, coarse enough that reading
    /// it costs a couple of milliseconds.
    static let cols = 16
    static let rows = 9

    /// A pixel this opaque counts as the subject being there. Cutout mattes are
    /// feathered, so anything stricter treats the soft edge as background and
    /// anything looser treats the halo as subject.
    static let opaqueThreshold = 0.15

    /// Long edge the two probe renders are done at.
    ///
    /// Not the document's own size. `clampedDimension` permits 8192, so reading
    /// a large canvas at full size means allocating a 256 MB bitmap and then
    /// walking it a pixel at a time through `colorAt` — to fill a 16×9 grid.
    /// Every position in a document is a fraction and type scales off canvas
    /// height, so a 640-wide render is the same composition as the export and
    /// the grid comes out the same.
    static let probeLongEdge = 640.0

    /// The same design at probe size. Cheap because nothing here is absolute.
    static func probeSized(_ document: ThumbDocument) -> ThumbDocument {
        var small = document
        let longest = Double(max(document.width, document.height))
        guard longest > probeLongEdge else { return small }
        let scale = probeLongEdge / longest
        small.width = ThumbDocument.clampedDimension(Double(document.width) * scale)
        small.height = ThumbDocument.clampedDimension(Double(document.height) * scale)
        return small
    }

    /// Reads a document. Call this off the main actor: it renders the design
    /// once and walks the bitmap.
    static func read(_ document: ThumbDocument,
                     provider: @escaping ThumbnailRenderer.ImageProvider) -> ThumbComposer.CanvasReading {
        var backdrop = probeSized(document)
        // Text is what we are placing, so it must not be part of what we are
        // placing it against. Leaving it in would make every layout look like a
        // bad idea: the calmest region would be wherever the text already is,
        // because text is flat.
        backdrop.layers = document.layers.filter {
            if case .text = $0.kind { return false }
            return $0.isVisible
        }
        // Never sample a placeholder. A missing image draws as a grey hatch,
        // which reads as texture that is not in the export.
        guard let image = ThumbnailRenderer.render(backdrop, showingPlaceholders: false,
                                                   provider: provider),
              let rep = bitmap(from: image) else {
            return .empty
        }

        let width = rep.pixelsWide, height = rep.pixelsHigh
        guard width > 0, height > 0 else { return .empty }
        var luminance = [Double](repeating: 0, count: cols * rows)
        var busyness = [Double](repeating: 0, count: cols * rows)
        // The render is already probe-sized, so every pixel is affordable.
        let step = max(1, width / 320)

        for r in 0..<rows {
            let y0 = height * r / rows, y1 = height * (r + 1) / rows
            for c in 0..<cols {
                let x0 = width * c / cols, x1 = width * (c + 1) / cols
                var sum = 0.0, sumSquares = 0.0, n = 0.0
                var y = y0
                while y < y1 {
                    var x = x0
                    while x < x1 {
                        if let colour = rep.colorAt(x: x, y: y) {
                            let l = 0.299 * colour.redComponent
                                + 0.587 * colour.greenComponent
                                + 0.114 * colour.blueComponent
                            sum += l
                            sumSquares += l * l
                            n += 1
                        }
                        x += step
                    }
                    y += step
                }
                guard n > 0 else { continue }
                let mean = sum / n
                luminance[r * cols + c] = mean
                // Standard deviation within the cell. A cell of flat colour
                // reads 0 however bright it is; a cell of foliage reads high.
                busyness[r * cols + c] = max(0, sumSquares / n - mean * mean).squareRoot()
            }
        }

        return ThumbComposer.CanvasReading(
            cols: cols, rows: rows,
            luminance: luminance, busyness: busyness,
            subjectCoverage: subjectCoverage(in: document, provider: provider))
    }

    /// How much of each grid cell the subject layers actually paint.
    ///
    /// Rendered, not reasoned about. Every rectangle-based answer to this
    /// question is wrong in a way that matters here: a cutout's box carries its
    /// PNG's transparent margin (32% too big in the owner's own design), a
    /// rotated layer's axis-aligned box is far larger than the layer, and no
    /// rectangle can describe the gap between an arm and a body. Drawing the
    /// subjects on nothing and counting alpha is exact about all three.
    static func subjectCoverage(in document: ThumbDocument,
                                provider: @escaping ThumbnailRenderer.ImageProvider) -> [Double] {
        let roles = ThumbComposer.roles(for: document, provider: provider)
        var subjectsOnly = probeSized(document)
        subjectsOnly.transparentBackground = true
        subjectsOnly.backgroundHex = nil
        subjectsOnly.layers = document.layers.filter {
            $0.isVisible && roles[$0.id] == .subject
        }
        guard !subjectsOnly.layers.isEmpty else {
            return [Double](repeating: 0, count: cols * rows)
        }
        guard let image = ThumbnailRenderer.render(subjectsOnly, showingPlaceholders: false,
                                                   provider: provider),
              let rep = bitmap(from: image), rep.hasAlpha else {
            return [Double](repeating: 0, count: cols * rows)
        }

        let width = rep.pixelsWide, height = rep.pixelsHigh
        var coverage = [Double](repeating: 0, count: cols * rows)
        let step = max(1, width / 320)
        for r in 0..<rows {
            let y0 = height * r / rows, y1 = height * (r + 1) / rows
            for c in 0..<cols {
                let x0 = width * c / cols, x1 = width * (c + 1) / cols
                var opaque = 0.0, n = 0.0
                var y = y0
                while y < y1 {
                    var x = x0
                    while x < x1 {
                        if let colour = rep.colorAt(x: x, y: y),
                           colour.alphaComponent > opaqueThreshold {
                            opaque += 1
                        }
                        n += 1
                        x += step
                    }
                    y += step
                }
                if n > 0 { coverage[r * cols + c] = opaque / n }
            }
        }
        return coverage
    }

    /// `NSImage.representations.first` is only a bitmap when the image came
    /// from one. A rendered NSImage can hand back a cached rep of another kind,
    /// and reading pixels off it silently returns nothing.
    private static func bitmap(from image: NSImage) -> NSBitmapImageRep? {
        if let rep = image.representations.first as? NSBitmapImageRep, rep.pixelsWide > 0 {
            return rep
        }
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }
}

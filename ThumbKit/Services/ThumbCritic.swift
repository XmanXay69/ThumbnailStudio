import AppKit
import CoreImage
import Foundation
import Vision

/// A review of a thumbnail, built only from things that can be measured.
///
/// What this is NOT: a prediction. This app has no click-through data, no
/// channel history and no model of your audience, so it says nothing about how
/// a design will perform. Every line below is an observation about the pixels
/// and the document — "your smallest text is 6px tall in the up-next rail" —
/// and the score is a stated weighting of those observations, not a forecast.
///
/// The rules it applies are the ones that hold regardless of audience: text
/// too small to read at feed size is wasted, text the duration stamp covers is
/// wasted, and a subject that does not separate from its background is hard to
/// parse at a glance.
struct ThumbCritic {
    struct Finding: Identifiable, Equatable {
        enum Severity: String { case good, warning, problem }

        var id: String { title }
        var title: String
        var detail: String
        var severity: Severity
        /// 0…1, how well this aspect scored.
        var score: Double
        /// Share of the overall score.
        var weight: Double
    }

    struct Review: Equatable {
        var findings: [Finding]
        /// False for a document with nothing on it. A blank canvas used to
        /// score 71 — full marks for having no text too small and no words too
        /// many — which is the app flattering itself.
        var isScoreable: Bool = true

        /// 0…100. A weighted mean of the findings, nothing more.
        var score: Int {
            let total = findings.reduce(0.0) { $0 + $1.weight }
            guard total > 0 else { return 0 }
            let earned = findings.reduce(0.0) { $0 + $1.score * $1.weight }
            return Int((earned / total * 100).rounded())
        }

        var problems: [Finding] { findings.filter { $0.severity == .problem } }
        var warnings: [Finding] { findings.filter { $0.severity == .warning } }

        /// One honest sentence about the number.
        var summary: String {
            guard isScoreable else {
                return "Nothing on the canvas yet — add an image or some text and run this again."
            }
            switch score {
            case 80...: return "Reads well at every size this was measured at."
            case 60..<80: return "Readable, with a few things working against it."
            case 40..<60: return "Several things are costing this at small sizes."
            default: return "This will be hard to read where it is actually seen."
            }
        }
    }

    /// Reviews a document and the image it renders to.
    static func review(document: ThumbDocument, image: NSImage?) -> Review {
        guard document.layers.contains(where: \.isVisible) else {
            return Review(findings: [], isScoreable: false)
        }
        var findings: [Finding] = []
        findings.append(textSize(document))
        findings.append(stampCollision(document))
        findings.append(wordCount(document))
        findings.append(edgeSafety(document))
        if let image, let ci = ciImage(from: image) {
            findings.append(contrast(ci))
            findings.append(busyness(ci))
            findings.append(subject(ci))
        }
        return Review(findings: findings)
    }

    private static func ciImage(from image: NSImage) -> CIImage? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return CIImage(data: tiff)
    }

    // MARK: - Document measurements

    private static func textSize(_ document: ThumbDocument) -> Finding {
        let facts = ThumbLegibility.report(for: document)
        guard let pixels = facts.smallestTextPixels else {
            return Finding(title: "Text size",
                           detail: "No text on this design, so there is nothing to read at small sizes.",
                           severity: .good, score: 1, weight: 0.24)
        }
        let threshold = ThumbLegibility.readablePixels
        let score = min(1, pixels / (threshold * 1.6))
        return Finding(
            title: "Text size",
            detail: String(format: "Smallest text is %.0f px tall in the up-next rail. Below about %.0f px it stops resolving at a glance.",
                           pixels, threshold),
            severity: pixels >= threshold * 1.4 ? .good : (pixels >= threshold ? .warning : .problem),
            score: score, weight: 0.24)
    }

    private static func stampCollision(_ document: ThumbDocument) -> Finding {
        let facts = ThumbLegibility.report(for: document)
        let hit = facts.layersUnderDurationStamp
        return Finding(
            title: "Duration stamp",
            detail: hit == 0
                ? "Nothing is sitting under YouTube's duration badge."
                : "\(hit) text layer\(hit == 1 ? "" : "s") run under the duration badge, which covers whatever is there.",
            severity: hit == 0 ? .good : .warning,
            score: hit == 0 ? 1 : 0.35, weight: 0.12)
    }

    private static func wordCount(_ document: ThumbDocument) -> Finding {
        let words = document.layers
            .filter(\.isVisible)
            .compactMap { layer -> Int? in
                guard case .text(let spec) = layer.kind else { return nil }
                return spec.renderedText.split(whereSeparator: \.isWhitespace).count
            }
            .reduce(0, +)
        guard words > 0 else {
            return Finding(title: "Word count",
                           detail: "No text. That is a choice, not a problem — the image has to carry it alone.",
                           severity: .good, score: 1, weight: 0.08)
        }
        // A reader gives a feed thumbnail a fraction of a second. Fewer words
        // survive that; this is a legibility observation, not a claim about
        // your audience.
        let score = words <= 4 ? 1.0 : max(0.2, 1.0 - Double(words - 4) * 0.12)
        return Finding(
            title: "Word count",
            detail: "\(words) word\(words == 1 ? "" : "s") across all text. Four or fewer is what survives a glance at feed size.",
            severity: words <= 5 ? .good : (words <= 8 ? .warning : .problem),
            score: score, weight: 0.10)
    }

    private static func edgeSafety(_ document: ThumbDocument) -> Finding {
        let canvas = CGSize(width: Double(document.width), height: Double(document.height))
        var clipped: [String] = []
        for layer in document.layers where layer.isVisible {
            let bounds = ThumbnailRenderer.drawnBounds(layer, in: canvas, provider: { _ in nil })
            let full = CGRect(x: 0, y: 0, width: 1, height: 1)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let inside = bounds.intersection(full)
            // A null intersection means the layer is entirely off the canvas —
            // the worst case, and the one an isNull guard would skip.
            let visible = inside.isNull
                ? 0
                : (inside.width * inside.height) / (bounds.width * bounds.height)

            switch layer.kind {
            case .text:
                // Text losing any of itself is always a mistake — you cannot
                // read half a word.
                if visible < 0.99 { clipped.append(layer.displayName) }
            case .image, .shape:
                // A background that bleeds off the edge is a technique, not an
                // error. Only flag one that is mostly outside the canvas,
                // which usually means it was dragged off by accident.
                if visible < 0.5 { clipped.append(layer.displayName) }
            }
        }
        let names = clipped.prefix(2).joined(separator: ", ")
        return Finding(
            title: "Inside the frame",
            detail: clipped.isEmpty
                ? "Nothing important is falling off the edge. Backgrounds that bleed are left alone — that is a technique, not a mistake."
                : "\(clipped.count) layer\(clipped.count == 1 ? "" : "s") mostly outside the canvas (\(names)\(clipped.count > 2 ? ", …" : "")).",
            severity: clipped.isEmpty ? .good : .warning,
            score: clipped.isEmpty ? 1 : max(0.3, 1 - Double(clipped.count) * 0.25),
            weight: 0.10)
    }

    // MARK: - Pixel measurements

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    private static func luminance(_ image: CIImage, samples: Int = 96) -> [Double] {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return [] }
        let height = max(1, Int((extent.height / extent.width * CGFloat(samples)).rounded()))
        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: CGFloat(samples) / extent.width, y: CGFloat(height) / extent.height))
        var pixels = [UInt8](repeating: 0, count: samples * height * 4)
        context.render(scaled, toBitmap: &pixels, rowBytes: samples * 4,
                       bounds: CGRect(x: scaled.extent.origin.x, y: scaled.extent.origin.y,
                                      width: CGFloat(samples), height: CGFloat(height)),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        var out: [Double] = []
        out.reserveCapacity(samples * height)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[index])
            let green = Double(pixels[index + 1])
            let blue = Double(pixels[index + 2])
            out.append((0.299 * red + 0.587 * green + 0.114 * blue) / 255)
        }
        return out
    }

    private static func contrast(_ image: CIImage) -> Finding {
        let luma = luminance(image).sorted()
        guard !luma.isEmpty else {
            return Finding(title: "Contrast", detail: "Couldn't measure.",
                           severity: .good, score: 1, weight: 0)
        }
        func percentile(_ f: Double) -> Double {
            luma[min(luma.count - 1, max(0, Int(Double(luma.count - 1) * f)))]
        }
        let spread = percentile(0.9) - percentile(0.1)
        return Finding(
            title: "Contrast",
            detail: String(format: "The bright and dark ends of this image are %.0f%% apart. A flat image has less to grab the eye in a feed.",
                           spread * 100),
            severity: spread > 0.5 ? .good : (spread > 0.3 ? .warning : .problem),
            score: min(1, spread / 0.6), weight: 0.16)
    }

    private static func busyness(_ image: CIImage) -> Finding {
        let target: CGFloat = 400
        let scale = min(1, target / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let weights = CIVector(values: [0, -1, 0, -1, 4, -1, 0, -1, 0], count: 9)
        let edges = small.applyingFilter("CIPhotoEffectMono")
            .applyingFilter("CIConvolution3X3",
                            parameters: ["inputWeights": weights, "inputBias": 0])
            .cropped(to: small.extent)
        let energy = edges.applyingFilter("CIMultiplyCompositing",
                                          parameters: [kCIInputBackgroundImageKey: edges])
            .cropped(to: small.extent)
        let samples: [Double] = luminance(energy)
        let total: Double = samples.reduce(0, +)
        let mean: Double = samples.isEmpty ? 0 : total / Double(samples.count)
        let busy: Double = min(1, sqrt(max(0, mean)) / 0.22)
        // Detail is not itself bad; competing with the text is. This is the
        // softest signal here and is weighted accordingly.
        return Finding(
            title: "Background detail",
            detail: busy > 0.75
                ? "A lot of fine detail. Text needs a strong stroke or a panel behind it to survive this."
                : "Detail is calm enough for text to sit on.",
            severity: busy > 0.85 ? .warning : .good,
            score: busy > 0.75 ? max(0.4, 1 - (busy - 0.75) * 2) : 1, weight: 0.10)
    }

    private static func subject(_ image: CIImage) -> Finding {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        let ok = (try? handler.perform([request])) != nil
        let faces = ok ? (request.results ?? []) : []
        guard let largest = faces.max(by: { $0.boundingBox.area < $1.boundingBox.area }) else {
            return Finding(
                title: "Face",
                detail: "No face found. Plenty of thumbnails work without one — but if there is meant to be a face here, it is not reading as one.",
                severity: .warning, score: 0.55, weight: 0.18)
        }
        let area = Double(largest.boundingBox.area)
        return Finding(
            title: "Face",
            detail: String(format: "A face fills %.0f%% of the frame. Under about 4%% it is hard to read an expression at feed size.",
                           area * 100),
            severity: area >= 0.04 ? .good : .warning,
            score: min(1, area / 0.08), weight: 0.18)
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}

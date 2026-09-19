import AppKit
import Foundation

/// Auto-layout: arrangements of the content that is already on the canvas.
///
/// What this moves: TEXT. Nothing else. That is not timidity, it is the honest
/// scope — the background you positioned, the subject you cut out and the
/// divider you rotated are decisions, and an "auto-layout" that slid them
/// around would be undoing your work rather than finishing it. Text is the part
/// that has to dodge things, so text is the part this places.
///
/// Everything it decides comes from a measurement, never from a guess about
/// what performs: where the picture is busy, where it is light or dark, where
/// the subject's actual pixels are, and where YouTube's duration badge sits.
/// The ranking is a stated weighting of those measurements. It says nothing
/// about how a thumbnail will do, because this app has no way to know that.
enum ThumbComposer {

    // MARK: - Roles

    /// What a layer is for, decided from the document rather than from a name
    /// the user never set. Only `.text` layers are ever moved.
    enum Role: String {
        /// Covers most of the canvas from the bottom of the stack. Left alone.
        case background
        /// A person or object placed on top — usually a cutout. Left alone, but
        /// text is kept off it.
        case subject
        /// Dividers, stickers, small marks. Left alone and not treated as an
        /// obstacle: text crossing a hairline divider is a normal thumbnail.
        case decoration
        case text
    }

    /// A layer under this share of the canvas is a sticker, not a subject.
    static let decorationCoverage = 0.02
    /// A layer over this share of the canvas is backdrop, wherever it sits in
    /// the stack. Set from the owner's real designs: the two near-full-bleed
    /// plates in "Doomsday" cover 0.80 and 0.83, while the character render in
    /// "Versus 2" covers 0.57 and has to stay a subject. Anything that fills
    /// four fifths of the frame is scenery — keeping text off it would leave
    /// nowhere to put text at all.
    static let backgroundCoverage = 0.62

    static func roles(for document: ThumbDocument,
                      provider: ThumbnailRenderer.ImageProvider) -> [UUID: Role] {
        let canvas = CGSize(width: Double(document.width), height: Double(document.height))
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        var result: [UUID: Role] = [:]
        for layer in document.layers {
            if case .text = layer.kind { result[layer.id] = .text; continue }
            if case .shape = layer.kind { result[layer.id] = .decoration; continue }
            // Deliberately the unrotated box. The question here is how much of
            // the canvas a layer spans, and the axis-aligned box around a
            // rotated layer is far larger than the layer: the 31.7°-rotated
            // cutout in the owner's "Doomsday" design measures 0.42 of the
            // canvas unrotated and 0.68 rotated, which would promote a
            // character standing in the frame to "background" and stop the
            // composer keeping text off it.
            let bounds = ThumbnailRenderer.drawnBounds(layer, in: canvas, provider: provider)
            let clipped = bounds.intersection(full)
            // A null intersection means the layer is entirely off-canvas.
            let coverage = clipped.isNull ? 0 : clipped.width * clipped.height
            if coverage < decorationCoverage {
                result[layer.id] = .decoration
            } else if coverage >= backgroundCoverage {
                result[layer.id] = .background
            } else {
                result[layer.id] = .subject
            }
        }
        return result
    }

    // MARK: - What the canvas looks like under the text

    /// A coarse read of the backdrop — everything except the text — plus where
    /// the subjects' real pixels are.
    ///
    /// The grid is sampled from an actual render, which is the only reason this
    /// copes with rotation at all: `drawnBounds` ignores `rotationDegrees`, and
    /// the owner's real designs rotate a divider by -45.8° and a cutout by
    /// 31.7°. Reasoning about those from their rectangles would be wrong about
    /// exactly the layers you notice most. Rendering them and looking at the
    /// pixels cannot be wrong about it.
    struct CanvasReading: Equatable {
        var cols: Int
        var rows: Int
        /// Mean luminance per cell, 0…1, row-major from the top.
        var luminance: [Double]
        /// Standard deviation of luminance per cell — how much detail there is
        /// for text to fight. 0 is flat colour.
        var busyness: [Double]
        /// Share of each cell the subject layers actually cover, 0…1.
        ///
        /// Measured from a render of the subjects alone rather than from their
        /// rectangles, which is the only way it can be right about any of the
        /// three ways a rectangle lies here: a rotated cutout, whose
        /// axis-aligned box is more than twice its real area; a cutout PNG
        /// carrying a transparent margin, which overstates by a third in the
        /// owner's own designs; and the empty air between an outstretched arm
        /// and a torso, which no rectangle can express at all.
        var subjectCoverage: [Double]

        static let empty = CanvasReading(cols: 0, rows: 0, luminance: [],
                                         busyness: [], subjectCoverage: [])

        var isEmpty: Bool { cols == 0 || rows == 0 }

        private func indices(in rect: CGRect) -> [Int] {
            guard !isEmpty else { return [] }
            let c0 = max(0, min(cols - 1, Int(rect.minX * Double(cols))))
            let c1 = max(c0, min(cols - 1, Int((rect.maxX * Double(cols)).rounded(.up)) - 1))
            let r0 = max(0, min(rows - 1, Int(rect.minY * Double(rows))))
            let r1 = max(r0, min(rows - 1, Int((rect.maxY * Double(rows)).rounded(.up)) - 1))
            var out: [Int] = []
            for r in r0...r1 { for c in c0...c1 { out.append(r * cols + c) } }
            return out
        }

        /// Mean luminance under a rectangle. 0.5 when there is nothing to read,
        /// which scores as neutral rather than as good or bad.
        func meanLuminance(in rect: CGRect) -> Double {
            let cells = indices(in: rect)
            guard !cells.isEmpty else { return 0.5 }
            return cells.reduce(0.0) { $0 + luminance[$1] } / Double(cells.count)
        }

        /// How much detail the text has to fight, read from the noisiest
        /// quarter of what is under it rather than the average.
        ///
        /// The average hides the problem: a headline lying mostly on flat sky
        /// with one corner in foliage reads as calm, and that corner is exactly
        /// where it becomes unreadable. The single worst cell was the first
        /// thing tried and it is too harsh in the other direction — over a
        /// headline-sized box on a real photograph it finds a noisy cell every
        /// time, so every layout scored zero and the measurement said nothing.
        func busynessUnder(_ rect: CGRect) -> Double {
            let cells = indices(in: rect)
            guard !cells.isEmpty else { return 0 }
            let sorted = cells.map { busyness[$0] }.sorted(by: >)
            let worst = max(1, sorted.count / 4)
            return sorted.prefix(worst).reduce(0, +) / Double(worst)
        }

        /// Share of `rect` that lands on a subject's real pixels.
        func subjectOverlap(in rect: CGRect) -> Double {
            let cells = indices(in: rect)
            guard !cells.isEmpty else { return 0 }
            return min(1, cells.reduce(0.0) { $0 + subjectCoverage[$1] } / Double(cells.count))
        }
    }

    // MARK: - Placement rules

    /// Text is kept this far from every canvas edge. Tighter than a print
    /// margin on purpose: thumbnails are cropped by nothing, and creators do
    /// run text close to the edge.
    static let edgeMargin = 0.035
    /// A little air around the duration badge, so text stops short of it rather
    /// than kissing it.
    static let badgeClearance = 0.012
    /// Gap between stacked text layers, as a fraction of canvas height.
    static let stackGap = 0.02
    /// Below this, a move is not visible on a thumbnail and is not worth
    /// offering as a choice — 1.5% of the canvas is under 20px at 1280 wide.
    static let noticeableShift = 0.015

    /// The smallest `sizeFraction` that still clears the legibility floor in
    /// the up-next rail. Derived from `ThumbLegibility` rather than restated,
    /// so the two can never drift apart.
    static func minimumSizeFraction(for document: ThumbDocument) -> Double {
        let scale = (ThumbLegibility.smallestDisplayPoints * ThumbLegibility.displayScale)
            / Double(max(1, document.width))
        let perFraction = Double(document.height) * 0.7 * scale
        guard perFraction > 0 else { return 0.08 }
        return ThumbLegibility.readablePixels / perFraction
    }

    /// Where a layer's glyphs or pixels actually land — like `drawnBounds`, but
    /// right about where left- and right-aligned text sits.
    ///
    /// `drawnBounds` narrows to the measured glyph width only for centred text;
    /// for `left` and `right` it returns the whole wrap box, centred on the
    /// layer. The glyphs are not centred in that box — they are flush to one
    /// edge of it. So a right-aligned headline given a wrap width of 0.42 and
    /// dropped into the left column paints at the column's RIGHT edge, in the
    /// middle of the canvas, which is not the column the user picked. Being
    /// conservative is fine for a collision test and useless for placing
    /// something.
    static func inkBounds(_ layer: ThumbLayer, in document: ThumbDocument,
                          provider: ThumbnailRenderer.ImageProvider) -> CGRect {
        let canvas = CGSize(width: Double(document.width), height: Double(document.height))
        let box = ThumbnailRenderer.drawnBounds(layer, in: canvas, provider: provider)
        guard case .text(let spec) = layer.kind, spec.alignment != "center",
              !spec.renderedText.isEmpty, canvas.width > 0 else { return box }
        let measured = NSAttributedString(
            string: spec.renderedText,
            attributes: ThumbnailRenderer.textAttributes(spec, canvasHeight: canvas.height,
                                                         strokePass: false))
            .boundingRect(with: NSSize(width: layer.widthFraction * canvas.width,
                                       height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin])
        let width = min(box.width, Double(measured.width) / Double(canvas.width))
        let x = spec.alignment == "left" ? box.minX : box.maxX - width
        return CGRect(x: x, y: box.minY, width: width, height: box.height)
    }

    /// Where a text layer actually puts paint, which is wider than the box
    /// `drawnBounds` reports.
    ///
    /// `drawnBounds` measures glyphs. A thumbnail headline is not just glyphs:
    /// the default stroke is 10px at 720p and is drawn outside the letterforms,
    /// and a layer with `boxEnabled` paints a panel `boxPadding` beyond them
    /// again. Testing the glyph box against the duration badge therefore passes
    /// a headline whose stroke is already under the badge. Rotation is folded
    /// in here too, since `drawnBounds` ignores it outright.
    static func paintedBounds(_ layer: ThumbLayer, in document: ThumbDocument,
                              provider: ThumbnailRenderer.ImageProvider) -> CGRect {
        let canvas = CGSize(width: Double(document.width), height: Double(document.height))
        var rect = inkBounds(layer, in: document, provider: provider)
        var pixels = 0.0
        if case .text(let spec) = layer.kind {
            // Both are authored in pixels at 720 high and scale with the canvas,
            // exactly as the renderer scales them.
            // The WIDEST outline, not the innermost: a headline with a second
            // stroke outside the first reaches further than `strokeWidth` says.
            pixels += spec.widestStroke * canvas.height / 720
                + (spec.boxEnabled ? spec.boxPadding * canvas.height / 720 : 0)
        }
        // A glow paints well outside the glyphs, and it is authored at 720p
        // like everything else here. Leaving it out would let auto-layout park
        // a haloed headline whose halo runs under the duration badge and call
        // it clear.
        pixels += layer.effects.outerReach * canvas.height / 720
        if pixels > 0 {
            rect = rect.insetBy(dx: -pixels / canvas.width, dy: -pixels / canvas.height)
        }
        guard abs(layer.rotationDegrees) > 0.01 else { return rect }
        return rotatedBounds(rect, degrees: layer.rotationDegrees,
                             about: CGPoint(x: layer.x, y: layer.y), canvas: canvas)
    }

    /// The axis-aligned box containing `rect` once it is rotated about `centre`.
    ///
    /// Done in pixels and converted back, because a canvas is not square and
    /// rotating a fraction is not rotating a shape. Note this OVERSTATES:
    /// the box around a rotated rectangle is larger than the rectangle. That is
    /// the right way to be wrong when the question is "could this be under the
    /// badge", and the wrong way when the question is "how much of the canvas
    /// does this cover" — which is why `roles` does not use it.
    static func rotatedBounds(_ rect: CGRect, degrees: Double,
                              about centre: CGPoint, canvas: CGSize) -> CGRect {
        let radians: Double = degrees * .pi / 180
        let cosine: Double = cos(radians)
        let sine: Double = sin(radians)
        let halfX = Double(rect.width) / 2 * Double(canvas.width)
        let halfY = Double(rect.height) / 2 * Double(canvas.height)
        let grownX = halfX * abs(cosine) + halfY * abs(sine)
        let grownY = halfX * abs(sine) + halfY * abs(cosine)
        // The rectangle is not necessarily centred on the rotation centre —
        // a mapped ink box sits off to one side — so carry its offset round too.
        let offsetX = Double(rect.midX - centre.x) * Double(canvas.width)
        let offsetY = Double(rect.midY - centre.y) * Double(canvas.height)
        let spunX = offsetX * cosine - offsetY * sine
        let spunY = offsetX * sine + offsetY * cosine
        let midX = Double(centre.x) + spunX / Double(canvas.width)
        let midY = Double(centre.y) + spunY / Double(canvas.height)
        return CGRect(x: midX - grownX / Double(canvas.width),
                      y: midY - grownY / Double(canvas.height),
                      width: 2 * grownX / Double(canvas.width),
                      height: 2 * grownY / Double(canvas.height))
    }

    static var badgeRect: CGRect {
        let zone = ThumbDocument.durationSafeZone
        return CGRect(x: zone.x - badgeClearance, y: zone.y - badgeClearance,
                      width: zone.width + badgeClearance, height: zone.height + badgeClearance)
    }

    /// The region a layout drops its text into, in canvas fractions.
    struct Region: Equatable {
        var name: String
        var rect: CGRect
    }

    /// The fixed regions offered, before the measured one is added. Each is
    /// clear of the duration badge by construction — the bottom band stops at
    /// the badge's left edge rather than running under it.
    static func regions(for reading: CanvasReading) -> [Region] {
        let m = edgeMargin
        let badgeLeft = badgeRect.minX
        var out: [Region] = [
            Region(name: "Left column",
                   rect: CGRect(x: m, y: m, width: 0.46 - m, height: 1 - 2 * m)),
            Region(name: "Right column",
                   rect: CGRect(x: 0.54, y: m, width: 1 - m - 0.54, height: 1 - 2 * m)),
            Region(name: "Top band",
                   rect: CGRect(x: m, y: m, width: 1 - 2 * m, height: 0.42 - m)),
            Region(name: "Bottom band",
                   rect: CGRect(x: m, y: 0.56, width: badgeLeft - m, height: 1 - m - 0.56)),
        ]
        if let calm = calmestRegion(in: reading) {
            out.append(calm)
        }
        return out
    }

    /// The quietest block of the grid wide enough to hold a headline. This is
    /// the one region that is not a guess about where text usually goes — it is
    /// wherever this particular picture happens to be calm.
    static func calmestRegion(in reading: CanvasReading) -> Region? {
        guard !reading.isEmpty, reading.cols >= 4, reading.rows >= 3 else { return nil }
        let blockCols = max(3, reading.cols / 3)
        let blockRows = max(2, reading.rows / 3)
        var best: (score: Double, r: Int, c: Int)?
        for r in 0...(reading.rows - blockRows) {
            for c in 0...(reading.cols - blockCols) {
                var worst = 0.0
                for dr in 0..<blockRows {
                    for dc in 0..<blockCols {
                        worst = max(worst, reading.busyness[(r + dr) * reading.cols + (c + dc)])
                    }
                }
                if best == nil || worst < best!.score { best = (worst, r, c) }
            }
        }
        guard let found = best else { return nil }
        // Grow the block to the canvas edges it already touches, so a calm strip
        // at the top does not become a floating box with arbitrary margins.
        var x0 = Double(found.c) / Double(reading.cols)
        var x1 = Double(found.c + blockCols) / Double(reading.cols)
        var y0 = Double(found.r) / Double(reading.rows)
        var y1 = Double(found.r + blockRows) / Double(reading.rows)
        if x0 < 0.1 { x0 = edgeMargin }
        if x1 > 0.9 { x1 = 1 - edgeMargin }
        if y0 < 0.1 { y0 = edgeMargin }
        if y1 > 0.9 { y1 = 1 - edgeMargin }
        guard x1 - x0 > 0.15, y1 - y0 > 0.1 else { return nil }
        return Region(name: "Where it's calmest",
                      rect: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
    }

    // MARK: - Fitting one text layer

    /// The largest `sizeFraction` at which this layer's drawn text still fits
    /// inside `maxHeight`, never going below the legibility floor.
    ///
    /// Binary search rather than a formula because the height is not linear in
    /// the size: the text rewraps, so growing the font by 10% can add a whole
    /// line and cost 40% of the height.
    static func fittedSize(for layer: ThumbLayer, wrapWidth: Double, maxHeight: Double,
                           in document: ThumbDocument, ceiling: Double) -> Double {
        guard case .text = layer.kind else { return 0 }
        let canvas = CGSize(width: Double(document.width), height: Double(document.height))
        let floor = minimumSizeFraction(for: document)
        func height(_ size: Double) -> Double {
            var probe = layer
            probe.widthFraction = wrapWidth
            if case .text(var spec) = probe.kind {
                spec.sizeFraction = size
                probe.kind = .text(spec)
            }
            return ThumbnailRenderer.drawnHeightFraction(probe, in: canvas, provider: { _ in nil })
        }
        // Nothing fits: hand back the floor and let the caller decide whether to
        // offer this layout at all. Silently returning something smaller than
        // readable would be the app quietly breaking its own rule.
        if height(floor) > maxHeight { return floor }
        var low = floor
        var high = max(floor, ceiling)
        if height(high) <= maxHeight { return high }
        for _ in 0..<18 {
            let mid = (low + high) / 2
            if height(mid) <= maxHeight { low = mid } else { high = mid }
        }
        return low
    }

    /// Moves a text layer so its drawn ink sits inside the canvas margins and
    /// off the duration badge, changing as little as possible.
    ///
    /// Returns nil when no horizontal shift clears the badge — which happens
    /// when the text is simply too wide to avoid it, and is a real answer.
    static func nudgedClear(_ layer: ThumbLayer, in document: ThumbDocument,
                            provider: ThumbnailRenderer.ImageProvider) -> ThumbLayer? {
        var moved = layer
        // Painted, not drawn: the stroke is what reaches the badge first.
        var ink = paintedBounds(moved, in: document, provider: provider)

        // Inside the margins first.
        if ink.minX < edgeMargin { moved.x += edgeMargin - ink.minX }
        if ink.maxX > 1 - edgeMargin { moved.x -= ink.maxX - (1 - edgeMargin) }
        if ink.minY < edgeMargin { moved.y += edgeMargin - ink.minY }
        if ink.maxY > 1 - edgeMargin { moved.y -= ink.maxY - (1 - edgeMargin) }

        ink = paintedBounds(moved, in: document, provider: provider)
        guard ink.intersects(badgeRect) else { return moved }

        // Off the badge. Sliding left is preferred to lifting: a headline near
        // the bottom is a deliberate look, and raising it off the floor changes
        // the design more than shortening its reach does.
        var slid = moved
        slid.x -= ink.maxX - badgeRect.minX
        let slidInk = paintedBounds(slid, in: document, provider: provider)
        if slidInk.minX >= edgeMargin, !slidInk.intersects(badgeRect) { return slid }

        // Too wide to slide clear, so lift it above the badge instead.
        var lifted = moved
        lifted.y -= ink.maxY - badgeRect.minY
        let liftedInk = paintedBounds(lifted, in: document, provider: provider)
        if liftedInk.minY >= edgeMargin, !liftedInk.intersects(badgeRect) { return lifted }
        return nil
    }

    // MARK: - Layouts

    struct Score: Equatable {
        /// How far the text's own colour sits from what is behind it.
        var contrast: Double
        /// How little detail the text has to compete with.
        var calm: Double
        /// How much of the size you chose survived. An arrangement that finds a
        /// lovely quiet corner by halving your headline has not solved your
        /// problem, and this is what says so.
        var size: Double
        /// How much of the text stays off the subjects.
        var clear: Double
        /// How much of the text stays out from under YouTube's duration badge.
        ///
        /// Every generated arrangement satisfies this by construction, so this
        /// number exists to mark down the one candidate that might not: the
        /// design as it stands. Without it, "as it is now" ranked second on a
        /// design whose headline was being covered by the badge — the app
        /// quietly declining to count the very fault it was opened to find.
        var badge: Double

        var overall: Double {
            contrast * 0.25 + calm * 0.18 + clear * 0.19 + size * 0.24 + badge * 0.14
        }
    }

    /// A layout that shrinks the headline below this share of the size you set
    /// is not offered at all. Scoring it down was not enough: a tiny headline
    /// in a calm corner beat every real arrangement because it was measurably
    /// clear of everything, which is true and useless.
    static let minimumSizeRatio = 0.72

    /// The busyness reading at which a region counts as fully noisy.
    ///
    /// Calibrated against the owner's real designs rather than picked: the
    /// noisiest quarter under a headline measures about 0.28–0.36 on a game
    /// screenshot and near 0.02 on flat colour. The first attempt used 0.22,
    /// which every real arrangement exceeded, so the whole measurement clamped
    /// to zero and ranked nothing against anything.
    static let busynessCeiling = 0.34

    struct Layout: Identifiable, Equatable {
        var id: String { name }
        var name: String
        /// What this arrangement did, in measured terms. Shown to the user, so
        /// it must not claim anything the numbers do not say.
        var rationale: String
        var document: ThumbDocument
        var score: Score
        /// True for the design exactly as it already is, which is always
        /// offered so the ranking can be argued with rather than obeyed.
        var isCurrent: Bool = false
    }

    /// Every arrangement worth offering, best first.
    static func layouts(for document: ThumbDocument,
                        reading: CanvasReading,
                        provider: @escaping ThumbnailRenderer.ImageProvider) -> [Layout] {
        let roleMap = roles(for: document, provider: provider)
        let movable = document.layers.filter {
            roleMap[$0.id] == .text && $0.isVisible && !$0.isLocked
                && !textIsEmpty($0)
        }
        // Nothing to arrange. Better to say so than to offer four identical
        // pictures of the design that is already on screen.
        guard !movable.isEmpty else { return [] }

        var out: [Layout] = [current(document, reading: reading, provider: provider)]

        if let repaired = repair(document, movable: movable, reading: reading, provider: provider) {
            out.append(repaired)
        }
        for region in regions(for: reading) {
            if let layout = arrange(document, movable: movable, into: region,
                                    reading: reading, provider: provider) {
                out.append(layout)
            }
        }

        // The design you already have is ranked on the same terms as the rest,
        // so if it wins, it wins.
        return deduplicated(out).sorted { $0.score.overall > $1.score.overall }
    }

    private static func textIsEmpty(_ layer: ThumbLayer) -> Bool {
        guard case .text(let spec) = layer.kind else { return true }
        return spec.renderedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Two layouts that put the headline in the same place are one layout. The
    /// alternative is a picker showing five thumbnails you cannot tell apart.
    /// "As it is now" is never merged away — it is the reference the others are
    /// being compared against, so it has to stay on screen even when a
    /// generated layout lands on top of it.
    private static func deduplicated(_ layouts: [Layout]) -> [Layout] {
        var kept: [Layout] = []
        for layout in layouts {
            if layout.isCurrent { kept.append(layout); continue }
            guard let mine = headlineSignature(layout.document) else { continue }
            let duplicate = kept.contains { existing in
                guard !existing.isCurrent, let theirs = headlineSignature(existing.document)
                else { return false }
                return abs(mine.x - theirs.x) < 0.05 && abs(mine.y - theirs.y) < 0.05
                    && abs(mine.size - theirs.size) < 0.012
            }
            if !duplicate { kept.append(layout) }
        }
        return kept
    }

    private static func headlineSignature(_ document: ThumbDocument) -> (x: Double, y: Double, size: Double)? {
        var best: (x: Double, y: Double, size: Double)?
        for layer in document.layers {
            guard case .text(let spec) = layer.kind else { continue }
            if best == nil || spec.sizeFraction > best!.size {
                best = (layer.x, layer.y, spec.sizeFraction)
            }
        }
        return best
    }

    // MARK: - The individual arrangements

    private static func current(_ document: ThumbDocument, reading: CanvasReading,
                                provider: @escaping ThumbnailRenderer.ImageProvider) -> Layout {
        Layout(name: "As it is now",
               rationale: "Your design, unchanged, measured the same way as the others so the ranking can be argued with.",
               document: document,
               score: score(document, original: document, reading: reading, provider: provider),
               isCurrent: true)
    }

    /// The smallest change that fixes what is measurably wrong: text off the
    /// canvas, text under the badge, text below the readable floor. Everything
    /// else is left exactly where the user put it.
    private static func repair(_ document: ThumbDocument, movable: [ThumbLayer],
                               reading: CanvasReading,
                               provider: @escaping ThumbnailRenderer.ImageProvider) -> Layout? {
        var result = document
        var fixes: [String] = []
        // Whether any of this is worth offering as a choice. A layer whose ink
        // pokes 0.6% past the margin is corrected by a nudge nobody can see,
        // and a card showing an apparently identical picture next to an
        // identical score is worse than not offering one.
        var material = false
        let floor = minimumSizeFraction(for: document)

        for layer in movable {
            guard let index = result.layers.firstIndex(where: { $0.id == layer.id }) else { continue }
            var working = result.layers[index]

            if case .text(var spec) = working.kind, spec.sizeFraction < floor {
                spec.sizeFraction = floor
                working.kind = .text(spec)
                fixes.append("grew \(shortName(working)) to the readable size")
                material = true
            }
            let before = paintedBounds(working, in: document, provider: provider)
            let hitBadge = before.intersects(badgeRect)
            let offCanvas = before.minX < edgeMargin || before.maxX > 1 - edgeMargin
                || before.minY < edgeMargin || before.maxY > 1 - edgeMargin
            if hitBadge || offCanvas, let moved = nudgedClear(working, in: document, provider: provider) {
                let shift = max(abs(moved.x - working.x), abs(moved.y - working.y))
                working = moved
                if hitBadge {
                    fixes.append("moved \(shortName(working)) off the duration badge")
                    material = true
                } else {
                    fixes.append("pulled \(shortName(working)) back inside the frame")
                    if shift > noticeableShift { material = true }
                }
            }
            result.layers[index] = working
        }

        guard material, !fixes.isEmpty, result != document else { return nil }
        return Layout(name: "Fix what's wrong",
                      rationale: "Keeps your arrangement and " + sentence(fixes) + ".",
                      document: result,
                      score: score(result, original: document, reading: reading, provider: provider))
    }

    /// Stacks every text layer inside one region, preserving the order they are
    /// already in from top to bottom — the user decided that the number goes
    /// above the headline, and an arrangement that flips them is not a layout
    /// of their design any more.
    private static func arrange(_ document: ThumbDocument, movable: [ThumbLayer],
                                into region: Region, reading: CanvasReading,
                                provider: @escaping ThumbnailRenderer.ImageProvider) -> Layout? {
        let canvas = canvasSize(document)
        let ordered = movable.sorted { $0.y < $1.y }
        var result = document

        // Each layer gets a share of the region's height in proportion to the
        // size it already has, so a headline stays dominant over a kicker.
        let weights = ordered.map { layer -> Double in
            guard case .text(let spec) = layer.kind else { return 1 }
            return max(0.01, spec.sizeFraction)
        }
        let weightTotal = weights.reduce(0, +)
        let gaps = stackGap * Double(max(0, ordered.count - 1))
        let usable = region.rect.height - gaps
        guard usable > 0.04 else { return nil }

        var placed: [(id: UUID, layer: ThumbLayer, height: Double)] = []
        for (index, layer) in ordered.enumerated() {
            var working = layer
            working.widthFraction = region.rect.width
            let share = usable * (weights[index] / weightTotal)
            let ceiling: Double = {
                guard case .text(let spec) = layer.kind else { return 0.2 }
                // Never enlarge past what the user chose. Auto-layout that
                // silently doubles your type is not arranging your design.
                return spec.sizeFraction
            }()
            let size = fittedSize(for: working, wrapWidth: region.rect.width,
                                  maxHeight: share, in: document, ceiling: ceiling)
            // This region cannot hold the text at anything like the size the
            // user set, so it is not an arrangement of their design.
            guard ceiling <= 0 || size / ceiling >= minimumSizeRatio else { return nil }
            if case .text(var spec) = working.kind {
                spec.sizeFraction = size
                working.kind = .text(spec)
            }
            let height = ThumbnailRenderer.drawnHeightFraction(working, in: canvas, provider: provider)
            placed.append((layer.id, working, height))
        }

        let stackHeight = placed.reduce(0.0) { $0 + $1.height } + gaps
        // The stack is too tall for the region even at the readable floor.
        // Offering it anyway would mean offering text that runs off the region
        // it is named after.
        guard stackHeight <= region.rect.height + 0.001 else { return nil }

        var cursor = region.rect.midY - stackHeight / 2
        for entry in placed {
            guard let index = result.layers.firstIndex(where: { $0.id == entry.id }) else { continue }
            var working = entry.layer
            working.x = region.rect.midX
            working.y = cursor + entry.height / 2
            cursor += entry.height + stackGap
            // The region is already clear of the badge, but a left-aligned
            // layer's ink can still reach past its wrap box, so check rather
            // than assume.
            if let cleared = nudgedClear(working, in: document, provider: provider) {
                working = cleared
            } else {
                return nil
            }
            result.layers[index] = working
        }

        guard result != document else { return nil }
        let measured = score(result, original: document, reading: reading, provider: provider)
        return Layout(name: region.name,
                      rationale: rationale(for: region, score: measured),
                      document: result,
                      score: measured)
    }

    private static func rationale(for region: Region, score: Score) -> String {
        let contrast = Int((score.contrast * 100).rounded())
        let clear = Int((score.clear * 100).rounded())
        return "Text sits in \(region.name.lowercased()), \(contrast)% apart in brightness from what is behind it, \(clear)% of it clear of the subjects."
    }

    // MARK: - Scoring

    /// A weighted mean of four measurements of this arrangement, against the
    /// design it came from. Not a prediction — nothing here knows what gets
    /// clicked.
    ///
    /// `original` is what the user had before, and it is what `size` is judged
    /// against. Without it the only available yardstick is the readability
    /// floor, and every layout that shrank the type to just-legible scored full
    /// marks for it.
    static func score(_ document: ThumbDocument, original: ThumbDocument,
                      reading: CanvasReading,
                      provider: @escaping ThumbnailRenderer.ImageProvider) -> Score {
        var contrastTotal = 0.0, calmTotal = 0.0, sizeTotal = 0.0
        var clearTotal = 0.0, badgeTotal = 0.0
        var weight = 0.0
        var originalSizes: [UUID: Double] = [:]
        for layer in original.layers {
            if case .text(let spec) = layer.kind { originalSizes[layer.id] = spec.sizeFraction }
        }

        for layer in document.layers where layer.isVisible {
            guard case .text(let spec) = layer.kind, !textIsEmpty(layer) else { continue }
            // Soft measurements read the glyph box: contrast and detail are
            // about what sits behind the letters. The badge test below reads the
            // painted box, because a stroke under the badge is covered ink.
            let ink = inkBounds(layer, in: document, provider: provider)
            guard ink.width > 0, ink.height > 0 else { continue }
            let painted = paintedBounds(layer, in: document, provider: provider)
            // Bigger text counts for more: the headline being unreadable
            // matters more than the kicker being unreadable.
            let w = spec.sizeFraction
            weight += w

            let behind = reading.meanLuminance(in: ink)
            let own = HexColor.color(hex: spec.fillHex).usingColorSpace(.deviceRGB).map {
                0.299 * $0.redComponent + 0.587 * $0.greenComponent + 0.114 * $0.blueComponent
            } ?? 1
            contrastTotal += min(1, abs(Double(own) - behind) / 0.55) * w
            calmTotal += max(0, 1 - reading.busynessUnder(ink) / busynessCeiling) * w
            clearTotal += (1 - reading.subjectOverlap(in: ink)) * w
            let was = originalSizes[layer.id] ?? spec.sizeFraction
            sizeTotal += (was > 0 ? min(1, spec.sizeFraction / was) : 1) * w

            // Two parts, because the fault has two parts. Touching the badge at
            // all costs a fixed amount — a clipped letter is a clipped letter —
            // and then the score falls further with how much is covered. Pure
            // proportion was tried first and rated a headline whose corner the
            // badge clips at 0.98, which is arithmetically true and reads as
            // "nothing wrong here".
            let hit = painted.intersection(badgeRect)
            let covered = hit.isNull ? 0 : (hit.width * hit.height) / (painted.width * painted.height)
            badgeTotal += (covered > 0 ? max(0, 0.85 - covered * 4) : 1) * w
        }
        guard weight > 0 else { return Score(contrast: 0, calm: 0, size: 0, clear: 0, badge: 1) }
        return Score(contrast: contrastTotal / weight, calm: calmTotal / weight,
                     size: sizeTotal / weight, clear: clearTotal / weight,
                     badge: badgeTotal / weight)
    }

    // MARK: - Helpers

    private static func canvasSize(_ document: ThumbDocument) -> CGSize {
        CGSize(width: Double(document.width), height: Double(document.height))
    }

    private static func shortName(_ layer: ThumbLayer) -> String {
        guard case .text(let spec) = layer.kind else { return "the layer" }
        let trimmed = spec.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "the text" : "\u{201C}\(trimmed.prefix(18))\u{201D}"
    }

    private static func sentence(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }
}

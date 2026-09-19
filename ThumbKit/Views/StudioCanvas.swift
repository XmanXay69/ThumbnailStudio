import SwiftUI
import AppKit
import ImageIO

extension ThumbnailStudioPane {
    /// The artboard on a workbench: a neutral ground one step darker than the
    /// panels, the render sitting on it with a shadow so it reads as a physical
    /// board, and selection chrome that never touches the pixels themselves.
    var workbench: some View {
        GeometryReader { geo in
            let aspect = Double(doc.width) / Double(doc.height)
            let inset: CGFloat = 32
            let available = CGSize(width: max(40, geo.size.width - inset * 2),
                                   height: max(40, geo.size.height - inset * 2))
            let fitScale = min(available.width / CGFloat(doc.width),
                               available.height / CGFloat(doc.height))
            let scale = editor.isFittingCanvas ? fitScale : CGFloat(editor.zoom)
            let boardWidth = CGFloat(doc.width) * scale
            let boardHeight = CGFloat(doc.height) * scale

            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    artboard(width: boardWidth, height: boardHeight)
                }
                .frame(width: max(geo.size.width, boardWidth + inset * 2),
                       height: max(geo.size.height, boardHeight + inset * 2))
            }
            .scrollDisabled(editor.isFittingCanvas)
            .background(Studio.Palette.workbench)
            .onAppear { editor.fitScale = Double(fitScale) }
            .onChange(of: fitScale) { _, value in editor.fitScale = Double(value) }
        }
    }

    private func artboard(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.black)
                .frame(width: width, height: height)
                .shadow(color: Studio.Palette.artboardShadow, radius: 18, y: 8)
            // While a drag is running the canvas is drawn in two pieces: the
            // design WITHOUT the layers being moved, and those layers as their
            // own images, offset. Both are rendered once when the drag starts,
            // so following the pointer costs nothing per frame.
            //
            // Before this, dragging moved the selection outline and left the
            // picture behind until you let go — which is the single most
            // broken-feeling thing an editor can do. Re-rendering the whole
            // canvas per frame was the other option and it is 17 ms a frame on
            // a nine-layer design, so it would have traded one stutter for
            // another.
            if let preview = dragPreview {
                Image(nsImage: preview.backdrop)
                    .resizable()
                    .interpolation(width >= CGFloat(doc.width) ? .none : .high)
                    .frame(width: width, height: height)
                Image(nsImage: preview.moving)
                    .resizable()
                    .interpolation(width >= CGFloat(doc.width) ? .none : .high)
                    .frame(width: width, height: height)
                    .offset(x: (dragDraft?.dx ?? 0) * width,
                            y: (dragDraft?.dy ?? 0) * height)
            } else if let image = canvasImage {
                Image(nsImage: image)
                    .resizable()
                    // At 100% and above, show real pixels rather than a
                    // smoothed lie — this tool's promise is preview == export.
                    .interpolation(width >= CGFloat(doc.width) ? .none : .high)
                    .frame(width: width, height: height)
            }
            if editor.showSafeZone {
                let zone = ThumbDocument.durationSafeZone
                Rectangle()
                    .strokeBorder(Studio.Palette.warning.opacity(0.65),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: zone.width * width, height: zone.height * height)
                    .offset(x: zone.x * width, y: zone.y * height)
                    .allowsHitTesting(false)
                    .help("YouTube stamps the duration here — keep text out")
            }
            if let guideX {
                Rectangle().fill(Studio.Palette.guideStroke)
                    .frame(width: 1, height: height)
                    .offset(x: guideX * width)
                    .allowsHitTesting(false)
            }
            if let guideY {
                Rectangle().fill(Studio.Palette.guideStroke)
                    .frame(width: width, height: 1)
                    .offset(y: guideY * height)
                    .allowsHitTesting(false)
            }
            layerHandles(width: width, height: height)
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .onTapGesture { location in
            placeOrDeselect(at: location, width: width, height: height)
        }
        // Dropping a file on the artboard is the fastest way to get a face
        // onto a thumbnail, and it is the first thing anyone tries.
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers, location in
            handleDrop(providers, at: CGPoint(x: location.x / max(1, width),
                                              y: location.y / max(1, height)))
        }
        .overlay {
            if isDropTargeted {
                Rectangle()
                    .strokeBorder(Studio.Palette.accent, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Files first, then raw bitmaps. A dropped file keeps its own path so the
    /// layer points at the original; a dropped bitmap has no file of its own,
    /// so it is written into the app's asset folder before becoming a layer.
    private func handleDrop(_ providers: [NSItemProvider], at point: CGPoint) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, NSImage(contentsOf: url) != nil else { return }
                // Copied in, for the same reason a picked file is.
                let path = ThumbLibrary.adopt(url) ?? url.path
                Task { @MainActor in
                    addLayer(.image(ImageSpec(path: path)), at: point, action: "Add Image")
                }
            }
            return true
        }
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                guard let image = image as? NSImage,
                      let stored = ThumbAssets.store(image: image) else { return }
                Task { @MainActor in
                    addLayer(.image(ImageSpec(path: stored.path)), at: point, action: "Add Image")
                }
            }
            return true
        }
        return false
    }

    /// A click with a creation tool active places that layer where you clicked;
    /// with the move tool it clears the selection, which is what clicking empty
    /// canvas means in every tool of this kind.
    private func placeOrDeselect(at location: CGPoint, width: CGFloat, height: CGFloat) {
        let point = CGPoint(x: location.x / max(1, width), y: location.y / max(1, height))
        switch tool {
        case .move: editor.selection = []
        case .text: addText(at: point)
        case .shape: addShape("rectangle", at: point)
        case .image: addImageFile(at: point)
        }
    }

    private func layerHandles(width: CGFloat, height: CGFloat) -> some View {
        ForEach(doc.layers) { layer in
            let dragging = dragDraft?.ids.contains(layer.id) == true
            let draft = transformDraft?.id == layer.id ? transformDraft?.result : nil
            let x = (draft?.x ?? layer.x) + (dragging ? dragDraft!.dx : 0)
            let y = (draft?.y ?? layer.y) + (dragging ? dragDraft!.dy : 0)
            let widthFraction = draft?.widthFraction ?? layer.widthFraction
            let heightFraction = draft?.heightFraction
                ?? layerHeightFraction(layer, width: nil)
            let spin = rotationDraft?.id == layer.id
                ? rotationDraft!.degrees : layer.rotationDegrees
            let boxWidth = max(18, widthFraction * width)
            let boxHeight = max(14, heightFraction * height)
            let isSelected = selection.contains(layer.id)

            ZStack {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                if isSelected {
                    Rectangle()
                        .strokeBorder(Studio.Palette.accent, lineWidth: 1)
                    if !layer.isLocked {
                        ForEach(grips(for: layer)) { grip in
                            handle(grip, layer: layer,
                                   boxWidth: boxWidth, boxHeight: boxHeight,
                                   canvas: CGSize(width: width, height: height))
                        }
                        rotationHandle(layer, boxWidth: boxWidth, boxHeight: boxHeight,
                                       canvas: CGSize(width: width, height: height))
                    }
                }
            }
            .frame(width: boxWidth, height: boxHeight)
            // Chrome turns with the layer. It did not before, so a rotated
            // cutout had a selection box lying flat across it.
            .rotationEffect(.degrees(spin))
            .position(x: x * width, y: y * height)
            // ONE tap gesture, asking AppKit how many clicks it was.
            //
            // Stacking `.onTapGesture(count: 2)` above `.onTapGesture` makes
            // every single click wait out the double-click window before it
            // fires, because SwiftUI cannot know yet which one you meant. On a
            // layer that is a third of a second of dead air between clicking
            // and being selected, and it reads as the app being slow. The
            // click count is already on the event; reading it costs nothing
            // and selection becomes instant.
            .onTapGesture {
                let clicks = NSApp.currentEvent?.clickCount ?? 1
                guard clicks >= 2 else {
                    select(layer.id, extending: NSEvent.modifierFlags.contains(.command))
                    return
                }
                if case .image(let spec) = layer.kind, spec.path.isEmpty {
                    setImageFile(for: layer.id)
                } else if case .text = layer.kind {
                    select(layer.id)
                    editor.textEditingRequest = layer.id
                }
            }
            .gesture(layer.isLocked ? nil : moveGesture(layer, width: width, height: height))
        }
    }

    /// Which grips this layer offers.
    ///
    /// Text gets corners and side grips only. Its height comes from its font
    /// and its line breaks, so a top or bottom grip would have nothing to
    /// change — offering one that does nothing is worse than not offering it.
    private func grips(for layer: ThumbLayer) -> [TransformHandle] {
        if case .text = layer.kind {
            return TransformHandle.allCases.filter { $0.heightSign == 0 || $0.isCorner }
        }
        return TransformHandle.allCases
    }

    private func handle(_ grip: TransformHandle, layer: ThumbLayer,
                        boxWidth: CGFloat, boxHeight: CGFloat,
                        canvas: CGSize) -> some View {
        let unit = grip.unitPosition
        return Rectangle()
            .fill(Studio.Palette.handleFill)
            .overlay(Rectangle().strokeBorder(Studio.Palette.handleStroke, lineWidth: 1))
            .frame(width: grip.isCorner ? 8 : 7, height: grip.isCorner ? 8 : 7)
            .position(x: unit.x * boxWidth, y: unit.y * boxHeight)
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    // A corner keeps the shape; holding Shift lets go of it.
                    // That is the opposite of most editors and deliberate:
                    // distorting a face is the rarer intent, so it is the one
                    // that costs a modifier.
                    let proportional = !NSEvent.modifierFlags.contains(.shift)
                    let result = CanvasTransform.resize(
                        layer, handle: grip, translation: value.translation,
                        canvas: canvas,
                        drawnHeight: layerHeightFraction(layer, width: nil),
                        proportional: proportional)
                    transformDraft = (layer.id, grip, result)
                    lastDragWasProportional = proportional
                    // Only the layer being resized is redrawn; the rest of the
                    // design was rendered once when the drag started. A grip
                    // that moved an outline while the picture stood still is
                    // the same glitch dragging had.
                    previewResize(of: layer, grip: grip, result: result,
                                  proportional: proportional)
                }
                .onEnded { _ in
                    defer { transformDraft = nil; dragPreview = nil }
                    guard let draft = transformDraft else { return }
                    commit(draft.result, handle: draft.handle,
                           proportional: lastDragWasProportional, to: layer)
                })
    }

    /// Writes a finished transform onto the layer.
    ///
    /// Each kind takes it differently, because "taller" means something
    /// different to each: a shape stores a height, an image has to be told to
    /// stop following its own aspect, and text has no height of its own at all
    /// — it has a point size.
    private func commit(_ result: CanvasTransform.Result,
                        handle: TransformHandle, proportional: Bool,
                        to layer: ThumbLayer) {
        mutateLayer(layer.id, "Resize Layer") { target in
            target.x = min(1, max(0, result.x))
            target.y = min(1, max(0, result.y))
            target.widthFraction = result.widthFraction
            target.heightFraction = result.heightFraction
            switch target.kind {
            case .text(var spec):
                // Corners scale the type; side grips only change the width the
                // words wrap at, which is a real and separate thing to want.
                if handle.isCorner {
                    spec.sizeFraction = max(0.01, min(1, spec.sizeFraction * result.sizeScale))
                    target.kind = .text(spec)
                }
            case .image(var spec):
                // "Stop following the source's shape" is meant by a top or
                // bottom grip, and by a corner dragged with Shift. A
                // proportional corner drag keeps the aspect and must not set
                // it — but a Shift-corner drag that did not would compute a
                // new height and then have it ignored, so the drag would look
                // broken in one axis.
                if handle.heightSign != 0, handle.widthSign == 0 || !proportional {
                    spec.stretched = true
                }
                target.kind = .image(spec)
            case .shape:
                break
            }
        }
        // A resize changes neither the file nor its shape, so only the
        // adjusted result is stale — and the aspect cache must be left alone
        // or every grip drag re-reads every image header.
        AdjustedImageCache.shared.invalidate()
    }

    /// The grip above the box that spins the layer.
    ///
    /// Rotation was inspector-only, which meant angling a cutout was a trip to
    /// a slider and back for every nudge.
    private func rotationHandle(_ layer: ThumbLayer, boxWidth: CGFloat, boxHeight: CGFloat,
                                canvas: CGSize) -> some View {
        let centre = CGPoint(x: boxWidth / 2, y: boxHeight / 2)
        let reach: CGFloat = 22
        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: centre.x, y: 0))
                path.addLine(to: CGPoint(x: centre.x, y: -reach))
            }
            .stroke(Studio.Palette.handleStroke, lineWidth: 1)
            Circle()
                .fill(Studio.Palette.handleFill)
                .overlay(Circle().strokeBorder(Studio.Palette.handleStroke, lineWidth: 1))
                .frame(width: 9, height: 9)
                .position(x: centre.x, y: -reach)
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let degrees = CanvasTransform.rotation(
                            from: layer.rotationDegrees,
                            centre: centre, pointer: value.location,
                            snapping: NSEvent.modifierFlags.contains(.shift))
                        rotationDraft = (layer.id, degrees)
                    }
                    .onEnded { _ in
                        defer { rotationDraft = nil }
                        guard let draft = rotationDraft else { return }
                        mutateLayer(layer.id, "Rotate Layer") {
                            $0.rotationDegrees = draft.degrees
                        }
                    })
        }
        .frame(width: boxWidth, height: boxHeight)
        .allowsHitTesting(true)
    }

    /// Dragging moves the whole selection, and snaps to the canvas centre and
    /// to every other layer's centre.
    private func moveGesture(_ layer: ThumbLayer, width: CGFloat, height: CGFloat) -> some Gesture {
        // Global, not local. This gesture hangs off a box that is rotated with
        // its layer, and a local translation would be measured along the
        // layer's own axes — so dragging a 32° cutout sideways would send it
        // diagonally. Moving is a screen-space verb; only the resize grips
        // want the layer's own frame.
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                if !selection.contains(layer.id) { select(layer.id) }
                if dragPreview == nil { beginDragPreview(for: selection) }
                let result = CanvasDrag.translation(
                    layer: layer,
                    translation: value.translation,
                    canvas: CGSize(width: width, height: height),
                    others: doc.layers.filter { $0.id != layer.id },
                    selectionCount: selection.count)
                guideX = result.guideX
                guideY = result.guideY
                dragDraft = (ids: selection, dx: result.dx, dy: result.dy)
            }
            .onEnded { _ in
                defer { dragDraft = nil; guideX = nil; guideY = nil; dragPreview = nil }
                guard let draft = dragDraft else { return }
                var document = doc
                document.nudge(ids: draft.ids, dx: draft.dx, dy: draft.dy)
                apply(document, "Move Layer")
                store.endUndoRun()
            }
    }

    /// Redraws just the layer being resized, over the backdrop taken when the
    /// drag began.
    ///
    /// One layer is a fraction of a full canvas render, which is what makes
    /// this affordable per frame where re-rendering the design would not be.
    private func previewResize(of layer: ThumbLayer, grip: TransformHandle,
                               result: CanvasTransform.Result, proportional: Bool) {
        if dragPreview == nil { beginDragPreview(for: [layer.id]) }
        guard let existing = dragPreview else { return }
        var drafted = layer
        drafted.x = result.x
        drafted.y = result.y
        drafted.widthFraction = result.widthFraction
        drafted.heightFraction = result.heightFraction
        applyPreviewScale(result, handle: grip, proportional: proportional, to: &drafted)
        var moving = doc
        moving.transparentBackground = true
        moving.backgroundHex = nil
        moving.layers = [drafted]
        guard let lifted = ThumbnailRenderer.renderForStudio(moving) else { return }
        dragPreview = (backdrop: existing.backdrop, moving: lifted)
    }

    /// The same rules `commit` applies, so what you see while dragging is what
    /// you get when you let go.
    private func applyPreviewScale(_ result: CanvasTransform.Result,
                                   handle: TransformHandle, proportional: Bool,
                                   to target: inout ThumbLayer) {
        switch target.kind {
        case .text(var spec):
            if handle.isCorner {
                spec.sizeFraction = max(0.01, min(1, spec.sizeFraction * result.sizeScale))
                target.kind = .text(spec)
            }
        case .image(var spec):
            if handle.heightSign != 0, handle.widthSign == 0 || !proportional {
                spec.stretched = true
                target.kind = .image(spec)
            }
        case .shape:
            break
        }
    }

    /// Splits the design into "everything staying put" and "everything being
    /// dragged", each rendered once.
    ///
    /// Both go through the same renderer the export uses, so the preview is
    /// the design — not an approximation of it that snaps into place when you
    /// let go.
    private func beginDragPreview(for ids: Set<UUID>) {
        let document = doc
        guard !ids.isEmpty else { return }
        var staying = document
        staying.layers = document.layers.filter { !ids.contains($0.id) }
        var moving = document
        moving.transparentBackground = true
        moving.backgroundHex = nil
        moving.layers = document.layers.filter { ids.contains($0.id) }
        guard let backdrop = ThumbnailRenderer.renderForStudio(staying),
              let lifted = ThumbnailRenderer.renderForStudio(moving) else { return }
        dragPreview = (backdrop: backdrop, moving: lifted)
    }

    /// A layer's drawn height, straight from the renderer — the selection box
    /// and the thing on screen are then the same rectangle by construction.
    func layerHeightFraction(_ layer: ThumbLayer, width: Double?) -> Double {
        var measured = layer
        if let width {
            measured.heightFraction = layer.heightFraction * width
                / max(0.01, layer.widthFraction)
            measured.widthFraction = width
        }
        return ThumbnailRenderer.drawnHeightFraction(
            measured,
            in: CGSize(width: Double(doc.width), height: Double(doc.height)),
            provider: { spec in
                // Only the size matters here, so a stand-in of the right
                // aspect is enough. The cache answers from memory or not at
                // all — a nil here means "not read yet", and the renderer
                // falls back to the layer's stored height for a frame.
                guard let aspect = ImageAspectCache.shared.aspect(of: spec.effectivePath)
                else { return nil }
                return NSImage(size: NSSize(width: 1000, height: 1000 * aspect))
            })
    }
}


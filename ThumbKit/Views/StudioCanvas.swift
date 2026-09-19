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
            if let image = canvasImage {
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
            .onTapGesture(count: 2) {
                if case .image(let spec) = layer.kind, spec.path.isEmpty {
                    setImageFile(for: layer.id)
                } else if case .text = layer.kind {
                    select(layer.id)
                    editor.textEditingRequest = layer.id
                } else {
                    select(layer.id)
                }
            }
            .onTapGesture {
                select(layer.id, extending: NSEvent.modifierFlags.contains(.command))
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
                }
                .onEnded { _ in
                    defer { transformDraft = nil }
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
        AdjustedImageCache.shared.invalidate()
        ImageAspectCache.shared.invalidate()
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
                defer { dragDraft = nil; guideX = nil; guideY = nil }
                guard let draft = dragDraft else { return }
                var document = doc
                document.nudge(ids: draft.ids, dx: draft.dx, dy: draft.dy)
                apply(document, "Move Layer")
                store.endUndoRun()
            }
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


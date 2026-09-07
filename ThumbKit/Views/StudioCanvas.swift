import SwiftUI
import AppKit

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
            let x = layer.x + (dragging ? dragDraft!.dx : 0)
            let y = layer.y + (dragging ? dragDraft!.dy : 0)
            let widthFraction = resizeDraft?.id == layer.id
                ? resizeDraft!.width : layer.widthFraction
            let heightFraction = layerHeightFraction(layer, width: resizeDraft?.id == layer.id
                                                     ? resizeDraft!.width : nil)
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
                        handle(at: CGPoint(x: boxWidth, y: boxHeight),
                               layer: layer, canvasWidth: width)
                    }
                }
            }
            .frame(width: boxWidth, height: boxHeight)
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

    private func handle(at point: CGPoint, layer: ThumbLayer, canvasWidth: CGFloat) -> some View {
        Circle()
            .fill(Studio.Palette.handleFill)
            .overlay(Circle().strokeBorder(Studio.Palette.handleStroke, lineWidth: 1))
            .frame(width: 9, height: 9)
            .position(point)
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let proposed = max(0.03,
                        layer.widthFraction + Double(value.translation.width) / canvasWidth)
                    resizeDraft = (layer.id, proposed)
                }
                .onEnded { _ in
                    guard let draft = resizeDraft else { return }
                    mutateLayer(layer.id, "Resize Layer") {
                        $0.heightFraction = $0.heightFraction * draft.width
                            / max(0.01, $0.widthFraction)
                        $0.widthFraction = draft.width
                    }
                    resizeDraft = nil
                })
    }

    /// Dragging moves the whole selection, and snaps to the canvas centre and
    /// to every other layer's centre.
    private func moveGesture(_ layer: ThumbLayer, width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if !selection.contains(layer.id) { select(layer.id) }
                var dx = Double(value.translation.width) / Double(width)
                var dy = Double(value.translation.height) / Double(height)
                guideX = nil
                guideY = nil
                // Snapping only makes sense against a single dragged layer;
                // with several, the group's own shape is what matters.
                if selection.count <= 1 {
                    var targetsX: [Double] = [0.5]
                    var targetsY: [Double] = [0.5]
                    for other in doc.layers where other.id != layer.id {
                        targetsX.append(other.x)
                        targetsY.append(other.y)
                    }
                    if let snapped = TimelineSnap.snapped(layer.x + dx, to: targetsX,
                                                          threshold: 0.012) {
                        dx = snapped - layer.x
                        guideX = snapped
                    }
                    if let snapped = TimelineSnap.snapped(layer.y + dy, to: targetsY,
                                                          threshold: 0.012) {
                        dy = snapped - layer.y
                        guideY = snapped
                    }
                }
                dragDraft = (ids: selection, dx: dx, dy: dy)
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

    /// A layer's drawn height fraction — text and images derive it.
    func layerHeightFraction(_ layer: ThumbLayer, width: Double?) -> Double {
        let widthFraction = width ?? layer.widthFraction
        switch layer.kind {
        case .shape:
            return layer.heightFraction * (width.map { $0 / max(0.01, layer.widthFraction) } ?? 1)
        case .text(let spec):
            return max(spec.sizeFraction * 1.2, 0.08)
        case .image(let spec):
            guard let image = NSImage(contentsOfFile: spec.effectivePath),
                  image.size.width > 0 else { return layer.heightFraction }
            let aspect = image.size.height / image.size.width
            return widthFraction * Double(aspect) * Double(doc.width) / Double(doc.height)
        }
    }
}

import SwiftUI
import AppKit

extension ThumbnailStudioPane {
    /// Topmost first, like every layers panel ever. Rows carry a live
    /// thumbnail of the layer itself, because "Text" and "Text" and "Text"
    /// is not a list you can navigate.
    var layersPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: Studio.Space.xs) {
                Text("Layers")
                    .font(Studio.Typo.section)
                    .foregroundStyle(Studio.Palette.textTertiary)
                Spacer()
                templatesMenu
                addMenu
            }
            .padding(.horizontal, Studio.Space.s)
            .frame(height: Studio.Metric.sectionHeaderHeight)

            if doc.layers.isEmpty {
                StudioEmptyState(symbol: "square.stack.3d.up.slash",
                                 title: "No layers",
                                 message: "Pick a tool on the left, then click the canvas.",
                                 actionTitle: "Add text") { addText() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(doc.layers.reversed()) { layer in
                        layerRow(layer)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 1, leading: Studio.Space.xs,
                                                      bottom: 1, trailing: Studio.Space.xs))
                            .listRowBackground(Color.clear)
                    }
                    .onMove { from, to in
                        var reversed = Array(doc.layers.reversed())
                        reversed.move(fromOffsets: from, toOffset: to)
                        var document = doc
                        document.layers = reversed.reversed()
                        apply(document, "Reorder Layers")
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // Focus lands in the List the moment you click a row, so the
                // canvas's key handling can't be the only home for Delete.
                .onDeleteCommand { editor.deleteSelection() }
            }
        }
        .background(Studio.Palette.panel)
    }

    private var addMenu: some View {
        Menu {
            Button("Text") { addText() }
            Button("Image file…") { addImageFile() }
            Button("From library…") { showLibrary = true }
            if let frameSource {
                Button("Frame at playhead") {
                    frameSource.grabFrameToCanvas(at: frameSource.playheadTime)
                }
                if frameSource.frameSourceDuration > 0 {
                    Button("Frame picker…") { showFramePicker = true }
                }
            }
            Menu("Shape") {
                ForEach(ShapeSpec.shapes, id: \.self) { shape in
                    Button(shape.capitalized) { addShape(shape) }
                }
            }
            Menu("Sticker") {
                ForEach(ThumbStickers.all, id: \.self) { emoji in
                    Button(emoji) { addSticker(emoji) }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(Studio.Typo.iconSmall)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: Studio.Metric.controlXS)
        .help("Add a layer")
    }

    private var templatesMenu: some View {
        Menu {
            ForEach(ThumbTemplates.starters(), id: \.name) { template in
                Button(template.name) { applyTemplate(template.document) }
            }
            let saved = savedTemplates()
            if !saved.isEmpty {
                Divider()
                ForEach(saved, id: \.0) { name, document in
                    Button(name) { applyTemplate(document) }
                }
            }
            Divider()
            Button("Save current as template…") { saveTemplate() }
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(Studio.Typo.iconSmall)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: Studio.Metric.controlXS)
        .help("Templates")
    }

    private func layerRow(_ layer: ThumbLayer) -> some View {
        LayerRow(layer: layer,
                 document: doc,
                 isSelected: selection.contains(layer.id),
                 onSelect: { extending in select(layer.id, extending: extending) },
                 onToggleVisible: {
                     mutateLayer(layer.id, "Layer Visibility") { $0.isVisible.toggle() }
                 },
                 onToggleLock: {
                     mutateLayer(layer.id, "Layer Lock") { $0.isLocked.toggle() }
                 })
            .contextMenu {
                Button("Bring to Front") { moveLayer(layer.id, .toFront, "Bring to Front") }
                Button("Bring Forward") { moveLayer(layer.id, .forward, "Bring Forward") }
                Button("Send Backward") { moveLayer(layer.id, .backward, "Send Backward") }
                Button("Send to Back") { moveLayer(layer.id, .toBack, "Send to Back") }
                Divider()
                Button("Duplicate  ⌘D") {
                    select(layer.id)
                    editor.duplicateSelection()
                }
                Button("Delete  ⌫", role: .destructive) {
                    select(layer.id)
                    editor.deleteSelection()
                }
            }
    }
}

/// One row: a real thumbnail of the layer, its name, and the two toggles that
/// only appear when they matter — on hover, or when they are already off.
private struct LayerRow: View {
    let layer: ThumbLayer
    let document: ThumbDocument
    let isSelected: Bool
    let onSelect: (Bool) -> Void
    let onToggleVisible: () -> Void
    let onToggleLock: () -> Void

    @State private var hovering = false

    /// An image layer whose file has gone renders as nothing at all, with no
    /// error anywhere — you notice when the export comes out wrong.
    private var isMissingFile: Bool {
        guard case .image(let spec) = layer.kind, !spec.effectivePath.isEmpty else { return false }
        return !FileManager.default.fileExists(atPath: spec.effectivePath)
    }

    var body: some View {
        HStack(spacing: Studio.Space.s) {
            LayerThumbnail(layer: layer, document: document)
                .frame(width: 40, height: 24)
            Text(layer.displayName)
                .font(Studio.Typo.label)
                .foregroundStyle(layer.isVisible
                                 ? Studio.Palette.textPrimary : Studio.Palette.textTertiary)
                .lineLimit(1)
            if isMissingFile {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Studio.Typo.iconSmall)
                    .foregroundStyle(Studio.Palette.warning)
                    .help("This image file is missing — the layer draws nothing")
            }
            Spacer(minLength: 0)
            if hovering || !layer.isVisible {
                StudioIconButton(layer.isVisible ? "eye" : "eye.slash",
                                 help: "Show or hide", size: .small, action: onToggleVisible)
            }
            if hovering || layer.isLocked {
                StudioIconButton(layer.isLocked ? "lock.fill" : "lock.open",
                                 help: "Lock  ⌘L", size: .small, action: onToggleLock)
            }
        }
        .padding(.horizontal, Studio.Space.xs)
        .frame(height: Studio.Metric.layerRowHeight)
        .studioSelectable(isSelected: isSelected, radius: Studio.Radius.row)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(NSEvent.modifierFlags.contains(.command)) }
    }
}

/// A single layer, rendered on its own through the real renderer. Cheap
/// because the canvas is scaled down to row size first, and cached by the
/// layer's own contents so scrolling the list doesn't re-render anything.
private struct LayerThumbnail: View {
    let layer: ThumbLayer
    let document: ThumbDocument
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Studio.Radius.field, style: .continuous)
                .fill(Studio.Palette.windowBackground)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(1)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Studio.Radius.field, style: .continuous)
            .strokeBorder(Studio.Palette.hairline, lineWidth: Studio.Metric.hairline))
        .task(id: LayerThumbnailCache.key(layer, in: document)) {
            image = await LayerThumbnailCache.shared.image(for: layer, in: document)
        }
    }
}

@MainActor
final class LayerThumbnailCache {
    static let shared = LayerThumbnailCache()
    private var cache: [String: NSImage] = [:]

    /// Identity is everything that changes the pixels — not the layer's
    /// position on the canvas, which the thumbnail ignores.
    static func key(_ layer: ThumbLayer, in document: ThumbDocument) -> String {
        var stripped = layer
        stripped.x = 0.5
        stripped.y = 0.5
        stripped.rotationDegrees = 0
        let data = (try? JSONEncoder().encode(stripped)) ?? Data()
        return ThumbAssets.digest(data) + "|\(document.width)x\(document.height)"
    }

    func image(for layer: ThumbLayer, in document: ThumbDocument) async -> NSImage? {
        let key = Self.key(layer, in: document)
        if let hit = cache[key] { return hit }
        // Rendered at the document's real size, then downsampled. Half the
        // spec is in absolute pixels — stroke widths, shadow blur, corner
        // radius — so a layer rendered straight into a 40pt tile would be all
        // stroke and no glyph.
        var solo = document
        solo.backgroundHex = nil
        var only = layer
        only.x = 0.5
        only.y = 0.5
        only.opacity = 1
        only.isVisible = true
        only.rotationDegrees = 0
        solo.layers = [only]
        let rendered = await Task.detached(priority: .utility) { [solo] in
            guard let full = ThumbnailRenderer.render(
                solo, showingPlaceholders: true,
                provider: ThumbnailRenderer.fileProvider) else { return nil as NSImage? }
            return Self.downsampled(full, maxWidth: 96)
        }.value
        if let rendered { cache[key] = rendered }
        if cache.count > 300 { cache.removeAll() }
        return rendered
    }

    /// A small copy, so the row holds 96px of bitmap rather than 1280.
    nonisolated static func downsampled(_ image: NSImage, maxWidth: CGFloat) -> NSImage? {
        let scale = min(1, maxWidth / max(1, image.size.width))
        let size = NSSize(width: max(1, (image.size.width * scale).rounded()),
                          height: max(1, (image.size.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let output = NSImage(size: size)
        output.addRepresentation(rep)
        return output
    }
}

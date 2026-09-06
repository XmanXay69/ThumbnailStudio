import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Thumbnail Studio: layer panel on the left, canvas in the middle,
/// inspector and export on the right. The canvas displays the actual export
/// render scaled to fit — the same `ThumbnailRenderer` output that gets
/// written to disk, so preview and file cannot disagree.
struct ThumbnailStudioPane<Store: ThumbStore>: View {
    @ObservedObject var store: Store
    /// Present only when a host app can supply video frames (the VOD
    /// editor); nil in the standalone studio, which then hides the
    /// frame-grab affordances entirely.
    var frameSource: (any ThumbFrameSource)?
    @Environment(\.undoManager) private var undoManager

    @State private var selectedLayerID: UUID?
    @State private var canvasImage: NSImage?
    @State private var showSafeZone = true
    @State private var exportAsPNG = false
    @State private var jpegQuality = 0.85
    @State private var exportBytes: Int?
    @State private var showFramePicker = false
    @State private var croppingLayerID: UUID?
    @State private var dragDraft: (id: UUID, x: Double, y: Double)?
    @State private var resizeDraft: (id: UUID, width: Double, height: Double)?
    @State private var guideX: Double?
    @State private var guideY: Double?

    private var doc: ThumbDocument { store.thumbDoc }
    private var selectedLayer: ThumbLayer? { doc.layers.first { $0.id == selectedLayerID } }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            layerPanel.frame(width: 210).clipped()
            canvas
            VStack(spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let layer = selectedLayer { inspector(layer) }
                        canvasPanel
                        exportPanel
                    }
                    .padding(2)
                }
            }
            // Fixed and clipped: no control row can paint past the rail or
            // the window, whatever it holds.
            .frame(width: 300)
            .clipped()
        }
        .clipped()
        // Hidden buttons carry the stacking shortcuts (⌘]/⌘[ step,
        // ⌥⌘]/⌥⌘[ to the edge) and ⌥-arrow nudges for the selected layer.
        .background {
            if let id = selectedLayerID {
                Group {
                    Button("") { nudgeSelected(dx: -0.004, dy: 0) }
                        .keyboardShortcut(.leftArrow, modifiers: .option)
                    Button("") { nudgeSelected(dx: 0.004, dy: 0) }
                        .keyboardShortcut(.rightArrow, modifiers: .option)
                    Button("") { nudgeSelected(dx: 0, dy: -0.004) }
                        .keyboardShortcut(.upArrow, modifiers: .option)
                    Button("") { nudgeSelected(dx: 0, dy: 0.004) }
                        .keyboardShortcut(.downArrow, modifiers: .option)
                    Button("") { nudgeSelected(dx: -0.02, dy: 0) }
                        .keyboardShortcut(.leftArrow, modifiers: [.option, .shift])
                    Button("") { nudgeSelected(dx: 0.02, dy: 0) }
                        .keyboardShortcut(.rightArrow, modifiers: [.option, .shift])
                    Button("") { nudgeSelected(dx: 0, dy: -0.02) }
                        .keyboardShortcut(.upArrow, modifiers: [.option, .shift])
                    Button("") { nudgeSelected(dx: 0, dy: 0.02) }
                        .keyboardShortcut(.downArrow, modifiers: [.option, .shift])
                    Button("") { moveLayer(id, .forward, "Bring Forward") }
                        .keyboardShortcut("]", modifiers: .command)
                    Button("") { moveLayer(id, .backward, "Send Backward") }
                        .keyboardShortcut("[", modifiers: .command)
                    Button("") { moveLayer(id, .toFront, "Bring to Front") }
                        .keyboardShortcut("]", modifiers: [.command, .option])
                    Button("") { moveLayer(id, .toBack, "Send to Back") }
                        .keyboardShortcut("[", modifiers: [.command, .option])
                }
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
        }
        .onAppear {
            store.timelineUndoManager = undoManager
            rerender()
        }
        .onChange(of: undoManager) { _, manager in store.timelineUndoManager = manager }
        .onChange(of: store.thumbDoc) { _, _ in rerender() }
        .sheet(isPresented: Binding(
            get: { croppingLayerID != nil },
            set: { if !$0 { croppingLayerID = nil } }
        )) {
            if let id = croppingLayerID,
               case .image(let spec)? = doc.layers.first(where: { $0.id == id })?.kind,
               let image = NSImage(contentsOfFile: spec.path) {
                CropSheet(image: image, initial: spec.crop,
                          initialCut: (spec.cutEdge, spec.cutAmount, spec.cutFlip)) { result in
                    mutateImage(id, "Crop & Cut") {
                        $0.crop = result.crop
                        $0.cutEdge = result.cutEdge
                        $0.cutAmount = result.cutAmount
                        $0.cutFlip = result.cutFlip
                    }
                }
            }
        }
        .sheet(isPresented: $showFramePicker) {
            if let frameSource {
                FramePickerSheet(source: frameSource)
                    .frame(width: 640, height: 480)
            }
        }
    }

    private func rerender() {
        canvasImage = ThumbnailRenderer.renderForStudio(doc)
        updateExportSize()
    }

    private func updateExportSize() {
        guard let image = canvasImage else { exportBytes = nil; return }
        exportBytes = ThumbnailRenderer.encoded(image, asPNG: exportAsPNG,
                                                jpegQuality: jpegQuality)?.count
    }

    private func apply(_ document: ThumbDocument, _ action: String) {
        store.applyThumbDoc(document, action: action)
    }

    private func moveLayer(_ id: UUID, _ direction: ThumbDocument.LayerMove, _ action: String) {
        var document = doc
        guard document.move(layerID: id, direction) else { return }
        apply(document, action)
    }

    /// The four stacking verbs, shared by the layer-row context menu and the
    /// hidden keyboard-shortcut buttons.
    @ViewBuilder
    private func arrangeMenuItems(for id: UUID) -> some View {
        Button("Bring to Front") { moveLayer(id, .toFront, "Bring to Front") }
        Button("Bring Forward") { moveLayer(id, .forward, "Bring Forward") }
        Button("Send Backward") { moveLayer(id, .backward, "Send Backward") }
        Button("Send to Back") { moveLayer(id, .toBack, "Send to Back") }
    }


    private func addSticker(_ emoji: String) {
        var document = doc
        var spec = TextSpec(text: emoji)
        spec.sizeFraction = 0.22
        spec.strokeWidth = 0
        spec.shadowEnabled = true
        document.layers.append(ThumbLayer(kind: .text(spec),
                                          x: 0.5, y: 0.42, widthFraction: 0.3))
        apply(document, "Add Sticker")
        selectedLayerID = document.layers.last?.id
    }

    private func alignButton(_ layer: ThumbLayer,
                             _ horizontal: ThumbDocument.HorizontalAlign?,
                             _ vertical: ThumbDocument.VerticalAlign?,
                             _ icon: String) -> some View {
        Button {
            var document = doc
            document.align(layerID: layer.id, horizontal: horizontal, vertical: vertical,
                           drawnHeightFraction: layerHeightFraction(layer, width: nil))
            apply(document, "Align Layer")
        } label: {
            Image(systemName: icon).font(.system(size: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textSecondary)
    }

    private func nudgeSelected(dx: Double, dy: Double) {
        guard let id = selectedLayerID else { return }
        mutateLayer(id, "Nudge Layer") {
            guard !$0.isLocked else { return }
            $0.x = min(1, max(0, $0.x + dx))
            $0.y = min(1, max(0, $0.y + dy))
        }
    }

    private func arrangeButton(_ id: UUID, _ direction: ThumbDocument.LayerMove,
                               _ icon: String, _ help: String) -> some View {
        Button {
            moveLayer(id, direction, help.components(separatedBy: "  ").first ?? "Arrange")
        } label: {
            Image(systemName: icon).font(.system(size: 11))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
    }

    private func mutateLayer(_ id: UUID, _ action: String,
                             _ change: (inout ThumbLayer) -> Void) {
        var document = doc
        guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
        change(&document.layers[index])
        apply(document, action)
    }

    // MARK: - Layer panel

    private var layerPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Layers")
                Spacer()
                Menu {
                    Button("Text") { addText() }
                    Button("Image file…") { addImageFile() }
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
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
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
                Label("Templates", systemImage: "square.grid.2x2")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if store.isCuttingOut {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Lifting subject…")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if let error = store.thumbStudioError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Topmost first, like every layers panel ever.
            List {
                ForEach(doc.layers.reversed()) { layer in
                    layerRow(layer)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2))
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
        }
        .panel()
    }

    private func layerRow(_ layer: ThumbLayer) -> some View {
        HStack(spacing: 5) {
            Image(systemName: {
                switch layer.kind {
                case .image: return "photo"
                case .text: return "textformat"
                case .shape: return "square.on.circle"
                }
            }())
            .font(.system(size: 9))
            .foregroundStyle(Theme.accent)
            Text(layer.displayName)
                .font(.caption2)
                .foregroundStyle(layer.isVisible ? Theme.textPrimary : Theme.textFaint)
                .lineLimit(1)
            Spacer()
            Button {
                mutateLayer(layer.id, "Layer Visibility") { $0.isVisible.toggle() }
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textFaint)
            Button {
                mutateLayer(layer.id, "Layer Lock") { $0.isLocked.toggle() }
            } label: {
                Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(layer.isLocked ? Theme.warning : Theme.textFaint)
        }
        .padding(4)
        .background(selectedLayerID == layer.id ? Theme.accent.opacity(0.18) : Theme.surfaceRaised.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { selectedLayerID = layer.id }
        .contextMenu {
            arrangeMenuItems(for: layer.id)
            Divider()
            Button("Duplicate") {
                var document = doc
                guard let index = document.layers.firstIndex(where: { $0.id == layer.id }) else { return }
                var copy = document.layers[index]
                copy.id = UUID()
                copy.x = min(0.95, copy.x + 0.03)
                copy.y = min(0.95, copy.y + 0.03)
                document.layers.insert(copy, at: index + 1)
                apply(document, "Duplicate Layer")
            }
            Button("Delete", role: .destructive) {
                var document = doc
                document.layers.removeAll { $0.id == layer.id }
                apply(document, "Delete Layer")
            }
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let aspect = Double(doc.width) / Double(doc.height)
            let fitWidth = min(geo.size.width, geo.size.height * aspect)
            let fitHeight = fitWidth / aspect
            ZStack {
                Color.black.opacity(0.25)
                ZStack(alignment: .topLeading) {
                    if let image = canvasImage {
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: fitWidth, height: fitHeight)
                    }
                    if showSafeZone {
                        let zone = ThumbDocument.durationSafeZone
                        Rectangle()
                            .strokeBorder(Theme.warning.opacity(0.7),
                                          style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .frame(width: zone.width * fitWidth, height: zone.height * fitHeight)
                            .offset(x: zone.x * fitWidth, y: zone.y * fitHeight)
                            .allowsHitTesting(false)
                            .help("YouTube stamps the duration here — keep text out")
                    }
                    if let guideX {
                        Rectangle().fill(Theme.accent).frame(width: 1)
                            .offset(x: guideX * fitWidth)
                            .allowsHitTesting(false)
                    }
                    if let guideY {
                        Rectangle().fill(Theme.accent).frame(height: 1)
                            .frame(width: fitWidth)
                            .offset(y: guideY * fitHeight)
                            .allowsHitTesting(false)
                    }
                    canvasHandles(fitWidth: fitWidth, fitHeight: fitHeight)
                }
                .frame(width: fitWidth, height: fitHeight)
                .clipped()
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// Hit targets, selection chrome and drag/resize for every layer.
    private func canvasHandles(fitWidth: CGFloat, fitHeight: CGFloat) -> some View {
        ForEach(doc.layers) { layer in
            let dragging = dragDraft?.id == layer.id
            let x = dragging ? dragDraft!.x : layer.x
            let y = dragging ? dragDraft!.y : layer.y
            let widthFraction = resizeDraft?.id == layer.id ? resizeDraft!.width : layer.widthFraction
            let heightFraction = layerHeightFraction(layer,
                                                     width: resizeDraft?.id == layer.id
                                                         ? resizeDraft!.width : nil)
            let width = max(30, widthFraction * fitWidth)
            let height = max(24, heightFraction * fitHeight)
            let selected = selectedLayerID == layer.id

            ZStack {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(selected ? Theme.accent : .clear,
                                  style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                if selected, !layer.isLocked {
                    // Corner resize handle, bottom-right.
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 9, height: 9)
                        .position(x: width, y: height)
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let base = resizeDraft?.id == layer.id
                                    ? layer.widthFraction : layer.widthFraction
                                _ = base
                                let proposed = max(0.05,
                                    layer.widthFraction + Double(value.translation.width) / fitWidth)
                                resizeDraft = (layer.id, proposed,
                                               layer.heightFraction * proposed / max(0.01, layer.widthFraction))
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
            }
            .frame(width: width, height: height)
            .position(x: x * fitWidth, y: y * fitHeight)
            .contextMenu {
                arrangeMenuItems(for: layer.id)
                Divider()
                Button("Delete", role: .destructive) {
                    var document = doc
                    document.layers.removeAll { $0.id == layer.id }
                    apply(document, "Delete Layer")
                }
            }
            .onTapGesture(count: 2) {
                if case .image(let spec) = layer.kind, spec.path.isEmpty {
                    setImageFile(for: layer.id)
                } else {
                    selectedLayerID = layer.id
                }
            }
            .onTapGesture { selectedLayerID = layer.id }
            .gesture(layer.isLocked ? nil : DragGesture(minimumDistance: 2)
                .onChanged { value in
                    selectedLayerID = layer.id
                    var draft = dragDraft ?? (layer.id, layer.x, layer.y)
                    draft.x = min(1, max(0, layer.x + Double(value.translation.width) / fitWidth))
                    draft.y = min(1, max(0, layer.y + Double(value.translation.height) / fitHeight))
                    // Alignment guides: centre lines and other layers' centres.
                    guideX = nil
                    guideY = nil
                    var targetsX: [Double] = [0.5]
                    var targetsY: [Double] = [0.5]
                    for other in doc.layers where other.id != layer.id {
                        targetsX.append(other.x)
                        targetsY.append(other.y)
                    }
                    if let snapped = TimelineSnap.snapped(draft.x, to: targetsX, threshold: 0.012) {
                        draft.x = snapped
                        guideX = snapped
                    }
                    if let snapped = TimelineSnap.snapped(draft.y, to: targetsY, threshold: 0.012) {
                        draft.y = snapped
                        guideY = snapped
                    }
                    dragDraft = draft
                }
                .onEnded { _ in
                    guard let draft = dragDraft else { return }
                    mutateLayer(layer.id, "Move Layer") {
                        $0.x = draft.x
                        $0.y = draft.y
                    }
                    dragDraft = nil
                    guideX = nil
                    guideY = nil
                })
        }
    }

    /// A layer's drawn height fraction — text and images derive it.
    private func layerHeightFraction(_ layer: ThumbLayer, width: Double?) -> Double {
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

    // MARK: - Adding layers

    private func addText() {
        var document = doc
        document.layers.append(ThumbLayer(kind: .text(TextSpec(text: "YOUR TEXT")),
                                          y: 0.5, widthFraction: 0.85))
        apply(document, "Add Text")
        selectedLayerID = document.layers.last?.id
    }

    private func addShape(_ shape: String) {
        var document = doc
        document.layers.append(ThumbLayer(kind: .shape(ShapeSpec(shape: shape)),
                                          widthFraction: 0.3, heightFraction: 0.3))
        apply(document, "Add Shape")
        selectedLayerID = document.layers.last?.id
    }

    private func addImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var document = doc
        document.layers.append(ThumbLayer(kind: .image(ImageSpec(path: url.path)),
                                          widthFraction: 0.5))
        apply(document, "Add Image")
        selectedLayerID = document.layers.last?.id
    }

    private func setImageFile(for layerID: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        mutateLayer(layerID, "Set Image") { layer in
            if case .image(var spec) = layer.kind {
                spec.path = url.path
                spec.cutoutPath = nil
                spec.useCutout = false
                layer.kind = .image(spec)
            }
        }
        AdjustedImageCache.shared.invalidate()
    }

    // MARK: - Templates

    private func applyTemplate(_ template: ThumbDocument) {
        var document = template
        document.width = doc.width
        document.height = doc.height
        apply(document, "Apply Template")
        selectedLayerID = nil
    }

    private func savedTemplates() -> [(String, ThumbDocument)] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Paths.thumbTemplatesRoot, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let document = try? JSONDecoder().decode(ThumbDocument.self, from: data)
            else { return nil }
            return (url.deletingPathExtension().lastPathComponent, document)
        }
    }

    private func saveTemplate() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = Paths.thumbTemplatesRoot
        panel.nameFieldStringValue = "My template.json"
        panel.message = "Templates saved here appear in the Templates menu in every project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? JSONEncoder().encode(doc).write(to: url, options: .atomic)
    }

    // MARK: - Inspector

    @ViewBuilder
    private func inspector(_ layer: ThumbLayer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Layer")
            LabeledContent("Align") {
                HStack(spacing: 3) {
                    alignButton(layer, .left, nil, "align.horizontal.left")
                    alignButton(layer, .center, nil, "align.horizontal.center")
                    alignButton(layer, .right, nil, "align.horizontal.right")
                    Divider().frame(height: 12)
                    alignButton(layer, nil, .top, "align.vertical.top")
                    alignButton(layer, nil, .middle, "align.vertical.center")
                    alignButton(layer, nil, .bottom, "align.vertical.bottom")
                }
            }
            LabeledContent("Arrange") {
                HStack(spacing: 4) {
                    arrangeButton(layer.id, .toBack, "square.3.layers.3d.bottom.filled",
                                  "Send to Back  ⌥⌘[")
                    arrangeButton(layer.id, .backward, "square.2.layers.3d.bottom.filled",
                                  "Send Backward  ⌘[")
                    arrangeButton(layer.id, .forward, "square.2.layers.3d.top.filled",
                                  "Bring Forward  ⌘]")
                    arrangeButton(layer.id, .toFront, "square.3.layers.3d.top.filled",
                                  "Bring to Front  ⌥⌘]")
                }
            }
            LabeledContent("Opacity") {
                Slider(value: layerBinding(layer.id, \.opacity, "Layer Opacity"), in: 0.05...1)
            }
            LabeledContent("Rotation") {
                HStack {
                    Slider(value: layerBinding(layer.id, \.rotationDegrees, "Rotate Layer"),
                           in: -180...180)
                    Text("\(Int(layer.rotationDegrees))°")
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 34)
                }
            }
            LabeledContent("Blend") {
                Picker("", selection: layerBinding(layer.id, \.blendMode, "Blend Mode")) {
                    ForEach(["normal", "multiply", "screen", "overlay"], id: \.self) {
                        Text($0.capitalized).tag($0)
                    }
                }
                .pickerStyle(.menu)
            }
            LabeledContent("Size") {
                Slider(value: layerBinding(layer.id, \.widthFraction, "Resize Layer"), in: 0.05...1.4)
            }
            switch layer.kind {
            case .text(let spec): textInspector(layer.id, spec)
            case .image(let spec): imageInspector(layer.id, spec)
            case .shape(let spec): shapeInspector(layer.id, spec)
            }
        }
        .font(.caption)
        .panel()
    }

    private func textInspector(_ id: UUID, _ spec: TextSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 6) {
                Button {
                    ThumbStyleClipboard.spec = spec
                } label: {
                    Label("Copy style", systemImage: "paintbrush.pointed")
                }
                Button {
                    guard let copied = ThumbStyleClipboard.spec else { return }
                    mutateText(id, "Paste Style") { target in
                        var restyled = copied
                        restyled.text = target.text
                        target = restyled
                    }
                } label: {
                    Label("Paste style", systemImage: "paintbrush.pointed.fill")
                }
                .disabled(ThumbStyleClipboard.spec == nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            TextField("Text", text: textBinding(id, spec, \.text, "Edit Text"), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            LabeledContent("Font") {
                Picker("", selection: textBinding(id, spec, \.fontName, "Font")) {
                    Section("Thumbnail picks") {
                        ForEach(["Anton", "Impact", "Bangers", "Montserrat",
                                 "Arial Black", "Avenir Next Heavy"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    Section("All installed") {
                        ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                }
                .pickerStyle(.menu)
            }
            LabeledContent("Size") {
                Slider(value: textBinding(id, spec, \.sizeFraction, "Text Size"), in: 0.04...0.4)
            }
            LabeledContent("Spacing") {
                Slider(value: textBinding(id, spec, \.letterSpacing, "Letter Spacing"), in: -4...20)
            }
            HStack(spacing: 8) {
                colorSwatch("Fill", textBinding(id, spec, \.fillHex, "Text Fill"))
                colorSwatch("Stroke", textBinding(id, spec, \.strokeHex, "Text Stroke"))
                Toggle("Gradient", isOn: Binding(
                    get: { spec.gradientHex != nil },
                    set: { on in
                        mutateText(id, "Text Gradient") { $0.gradientHex = on ? "FFD60A" : nil }
                    }
                ))
                .toggleStyle(.checkbox)
            }
            LabeledContent("Stroke W") {
                Slider(value: textBinding(id, spec, \.strokeWidth, "Stroke Width"), in: 0...30)
            }
            HStack(spacing: 8) {
                Toggle("Shadow", isOn: textBinding(id, spec, \.shadowEnabled, "Text Shadow"))
                    .toggleStyle(.checkbox)
                Toggle("Box", isOn: textBinding(id, spec, \.boxEnabled, "Text Box"))
                    .toggleStyle(.checkbox)
                if spec.boxEnabled {
                    colorSwatch("", textBinding(id, spec, \.boxHex, "Box Colour"))
                }
            }
        }
    }

    private func imageInspector(_ id: UUID, _ spec: ImageSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            LabeledContent("Frame") {
                Picker("", selection: imageBinding(id, spec, \.maskShape, "Image Frame")) {
                    Text("None").tag("none")
                    Text("Rounded").tag("rounded")
                    Text("Circle").tag("circle")
                }
                .pickerStyle(.segmented)
            }
            if spec.maskShape == "rounded" {
                LabeledContent("Corner") {
                    Slider(value: imageBinding(id, spec, \.maskCornerRadius, "Corner Radius"),
                           in: 4...120)
                }
            }
            if spec.maskShape != "none" || spec.borderWidth > 0 {
                LabeledContent("Border") {
                    HStack(spacing: 5) {
                        Slider(value: imageBinding(id, spec, \.borderWidth, "Border Width"),
                               in: 0...30)
                        colorSwatch("", imageBinding(id, spec, \.borderHex, "Border Colour"))
                    }
                }
            }
            cutControls(edge: imageBinding(id, spec, \.cutEdge, "Diagonal Cut"),
                        amount: imageBinding(id, spec, \.cutAmount, "Cut Depth"),
                        flip: imageBinding(id, spec, \.cutFlip, "Cut Direction"),
                        currentEdge: spec.cutEdge)
            HStack(spacing: 6) {
                Button {
                    croppingLayerID = id
                } label: {
                    Label("Crop…", systemImage: "crop")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(spec.path.isEmpty)
                if spec.crop != nil {
                    Button("Clear crop") {
                        mutateImage(id, "Clear Crop") { $0.crop = nil }
                    }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                }
            }

            HStack(spacing: 6) {
                Button("Replace…") { setImageFile(for: id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button {
                    mutateImage(id, "Flip") { $0.flippedHorizontally.toggle() }
                } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if spec.cutoutPath == nil {
                Button {
                    store.removeBackground(layerID: id)
                } label: {
                    Label("Remove Background", systemImage: "person.and.background.dotted")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.small)
                .disabled(store.isCuttingOut || spec.path.isEmpty)
                .help("Vision lifts the subject locally — a second or two, nothing leaves the Mac")
            } else {
                Toggle("Use cutout", isOn: Binding(
                    get: { spec.useCutout },
                    set: { on in
                        mutateImage(id, "Toggle Cutout") { $0.useCutout = on }
                        AdjustedImageCache.shared.invalidate()
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            if spec.useCutout {
                LabeledContent("Outline") {
                    HStack {
                        Slider(value: imageBinding(id, spec, \.strokeWidth, "Cutout Outline"), in: 0...24)
                        colorSwatch("", imageBinding(id, spec, \.strokeHex, "Outline Colour"))
                    }
                }
            }
            Toggle("Drop shadow", isOn: imageBinding(id, spec, \.shadowEnabled, "Image Shadow"))
                .toggleStyle(.checkbox)
            Divider()
            ForEach([("Brightness", \ImageSpec.brightness),
                     ("Contrast", \ImageSpec.contrast),
                     ("Saturation", \ImageSpec.saturation),
                     ("Exposure", \ImageSpec.exposure),
                     ("Vibrance", \ImageSpec.vibrance)], id: \.0) { name, path in
                LabeledContent(name) {
                    Slider(value: Binding(
                        get: { spec[keyPath: path] },
                        set: { value in
                            mutateImage(id, name) { $0[keyPath: path] = value }
                        }
                    ), in: -1...1)
                }
            }
            LabeledContent("Filter") {
                Picker("", selection: imageBinding(id, spec, \.filterPreset, "Filter Preset")) {
                    ForEach(["none", "mono", "chrome", "fade", "instant", "noir"], id: \.self) {
                        Text($0.capitalized).tag($0)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private func shapeInspector(_ id: UUID, _ spec: ShapeSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 8) {
            LabeledContent("Gradient") {
                HStack(spacing: 5) {
                    Toggle("", isOn: Binding(
                        get: { spec.fillGradientHex != nil },
                        set: { on in
                            mutateShape(id, "Shape Gradient") {
                                $0.fillGradientHex = on ? ($0.fillHex ?? "FF0000") : nil
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    if let gradientHex = spec.fillGradientHex {
            cutControls(edge: shapeBinding(id, spec, \.cutEdge, "Diagonal Cut"),
                        amount: shapeBinding(id, spec, \.cutAmount, "Cut Depth"),
                        flip: shapeBinding(id, spec, \.cutFlip, "Cut Direction"),
                        currentEdge: spec.cutEdge)
                        colorSwatch("", Binding(
                            get: { gradientHex },
                            set: { value in mutateShape(id, "Gradient Colour") { $0.fillGradientHex = value } }
                        ))
                        Slider(value: shapeBinding(id, spec, \.gradientAngleDegrees, "Gradient Angle"),
                               in: 0...360)
                    }
                }
            }
                colorSwatch("Fill", Binding(
                    get: { spec.fillHex ?? "FF0000" },
                    set: { value in
                        mutateShape(id, "Shape Fill") { $0.fillHex = value }
                    }
                ))
                colorSwatch("Stroke", shapeBinding(id, spec, \.strokeHex, "Shape Stroke"))
            }
            LabeledContent("Stroke W") {
                Slider(value: shapeBinding(id, spec, \.strokeWidth, "Shape Stroke"), in: 0...20)
            }
            if spec.shape == "rectangle" {
                LabeledContent("Corner") {
                    Slider(value: shapeBinding(id, spec, \.cornerRadius, "Corner Radius"), in: 0...80)
                }
            }
            if spec.shape == "polygon" {
                LabeledContent("Sides") {
                    Stepper("\(spec.sides)", value: Binding(
                        get: { spec.sides },
                        set: { value in
                            mutateShape(id, "Polygon Sides") { $0.sides = value }
                        }
                    ), in: 3...16)
                }
            }
            LabeledContent("Height") {
                Slider(value: layerBinding(id, \.heightFraction, "Resize Layer"), in: 0.02...1.4)
            }
        }
    }

    /// The diagonal-cut row both inspectors share: pick an edge, set the
    /// slant depth, flip which corner it leans from.
    @ViewBuilder
    private func cutControls(edge: Binding<String>, amount: Binding<Double>,
                             flip: Binding<Bool>, currentEdge: String) -> some View {
        LabeledContent("Cut") {
            Picker("", selection: edge) {
                Text("None").tag("none")
                Image(systemName: "arrowtriangle.left").tag("left")
                Image(systemName: "arrowtriangle.right").tag("right")
                Image(systemName: "arrowtriangle.up").tag("top")
                Image(systemName: "arrowtriangle.down").tag("bottom")
            }
            .pickerStyle(.segmented)
        }
        .help("Slant one edge — the split-thumbnail look. Pair a cut image with a cut colour panel.")
        if currentEdge != "none" {
            LabeledContent("Slant") {
                HStack(spacing: 5) {
                    Slider(value: amount, in: 0.05...0.6)
                    Toggle(isOn: flip) {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .toggleStyle(.button)
                    .controlSize(.mini)
                    .help("Lean the slant the other way")
                }
            }
        }
    }

    private func colorSwatch(_ label: String, _ binding: Binding<String>) -> some View {
        HStack(spacing: 4) {
            if !label.isEmpty {
                Text(label).font(.caption2).foregroundStyle(Theme.textFaint)
            }
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: HexColor.color(hex: binding.wrappedValue)) },
                set: { color in
                    let rgba = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
                    binding.wrappedValue = String(format: "%02X%02X%02X",
                                                  Int(rgba.redComponent * 255),
                                                  Int(rgba.greenComponent * 255),
                                                  Int(rgba.blueComponent * 255))
                }
            ), supportsOpacity: false)
            .labelsHidden()
        }
    }

    // MARK: - Canvas + export panels

    private var canvasPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Canvas")
            LabeledContent("Background") {
                HStack(spacing: 5) {
                    ForEach(["0F0F14", "FFFFFF", "111C2E", "1B4332", "3C096C", "7B2D26"], id: \.self) { hex in
                        Button {
                            var document = doc
                            document.backgroundHex = hex
                            apply(document, "Canvas Colour")
                        } label: {
                            Circle()
                                .fill(Color(nsColor: HexColor.color(hex: hex)))
                                .frame(width: 14, height: 14)
                                .overlay(Circle().strokeBorder(
                                    doc.backgroundHex == hex ? Theme.accent : Theme.border,
                                    lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    Button("None") {
                        var document = doc
                        document.backgroundHex = nil
                        apply(document, "Canvas Colour")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textFaint)
                }
            }
            .font(.caption)
            Picker("", selection: Binding(
                get: { "\(doc.width)×\(doc.height)" },
                set: { value in
                    guard let preset = ThumbDocument.canvasPresets.first(where: {
                        "\($0.width)×\($0.height)" == value
                    }) else { return }
                    var document = doc
                    document.width = preset.width
                    document.height = preset.height
                    apply(document, "Canvas Size")
                }
            )) {
                ForEach(ThumbDocument.canvasPresets, id: \.name) { preset in
                    Text(preset.name).tag("\(preset.width)×\(preset.height)")
                }
            }
            .pickerStyle(.menu)
            Toggle("Duration-stamp safe zone", isOn: $showSafeZone)
                .toggleStyle(.checkbox)
                .font(.caption)
        }
        .panel()
    }

    private var exportPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Export")
            Picker("", selection: $exportAsPNG) {
                Text("JPG").tag(false)
                Text("PNG").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: exportAsPNG) { _, _ in updateExportSize() }
            if !exportAsPNG {
                LabeledContent("Quality") {
                    Slider(value: $jpegQuality, in: 0.3...1)
                        .onChange(of: jpegQuality) { _, _ in updateExportSize() }
                }
                .font(.caption)
            }
            if let bytes = exportBytes {
                let over = bytes > 2_000_000
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
                     + (over ? " — over YouTube's 2 MB cap" : " · fits YouTube's 2 MB cap"))
                    .font(.caption2)
                    .foregroundStyle(over ? Theme.danger : Theme.positive)
                if over, !exportAsPNG {
                    Button("Compress to fit") {
                        if let image = canvasImage,
                           let fitted = ThumbnailRenderer.compressToFit(image, capBytes: 2_000_000) {
                            jpegQuality = fitted.quality
                            updateExportSize()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if over, exportAsPNG {
                    Text("PNG can't hit the cap on a busy design — switch to JPG.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textFaint)
                }
            }
            HStack(spacing: 6) {
                Button {
                    exportToFile()
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                Button {
                    if let image = canvasImage {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .help("Copy the rendered thumbnail to the clipboard")
            }
        }
        .panel()
    }

    private func exportToFile() {
        guard let image = canvasImage,
              let data = ThumbnailRenderer.encoded(image, asPNG: exportAsPNG,
                                                   jpegQuality: jpegQuality) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [exportAsPNG ? .png : .jpeg]
        panel.nameFieldStringValue = "thumbnail.\(exportAsPNG ? "png" : "jpg")"
        if let last = UserDefaults.standard.string(forKey: "lastExportFolder") {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "lastExportFolder")
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Bindings

    private func layerBinding<T>(_ id: UUID, _ path: WritableKeyPath<ThumbLayer, T>,
                                 _ action: String) -> Binding<T> {
        Binding(
            get: {
                (doc.layers.first { $0.id == id } ?? ThumbLayer(kind: .text(TextSpec())))[keyPath: path]
            },
            set: { value in mutateLayer(id, action) { $0[keyPath: path] = value } }
        )
    }

    private func mutateText(_ id: UUID, _ action: String, _ change: (inout TextSpec) -> Void) {
        mutateLayer(id, action) { layer in
            guard case .text(var spec) = layer.kind else { return }
            change(&spec)
            layer.kind = .text(spec)
        }
    }

    private func mutateImage(_ id: UUID, _ action: String, _ change: (inout ImageSpec) -> Void) {
        mutateLayer(id, action) { layer in
            guard case .image(var spec) = layer.kind else { return }
            change(&spec)
            layer.kind = .image(spec)
        }
        AdjustedImageCache.shared.invalidate()
    }

    private func mutateShape(_ id: UUID, _ action: String, _ change: (inout ShapeSpec) -> Void) {
        mutateLayer(id, action) { layer in
            guard case .shape(var spec) = layer.kind else { return }
            change(&spec)
            layer.kind = .shape(spec)
        }
    }

    private func textBinding<T>(_ id: UUID, _ current: TextSpec,
                                _ path: WritableKeyPath<TextSpec, T>,
                                _ action: String) -> Binding<T> {
        Binding(
            get: {
                if case .text(let spec)? = doc.layers.first(where: { $0.id == id })?.kind {
                    return spec[keyPath: path]
                }
                return current[keyPath: path]
            },
            set: { value in mutateText(id, action) { $0[keyPath: path] = value } }
        )
    }

    private func imageBinding<T>(_ id: UUID, _ current: ImageSpec,
                                 _ path: WritableKeyPath<ImageSpec, T>,
                                 _ action: String) -> Binding<T> {
        Binding(
            get: {
                if case .image(let spec)? = doc.layers.first(where: { $0.id == id })?.kind {
                    return spec[keyPath: path]
                }
                return current[keyPath: path]
            },
            set: { value in mutateImage(id, action) { $0[keyPath: path] = value } }
        )
    }

    private func shapeBinding<T>(_ id: UUID, _ current: ShapeSpec,
                                 _ path: WritableKeyPath<ShapeSpec, T>,
                                 _ action: String) -> Binding<T> {
        Binding(
            get: {
                if case .shape(let spec)? = doc.layers.first(where: { $0.id == id })?.kind {
                    return spec[keyPath: path]
                }
                return current[keyPath: path]
            },
            set: { value in mutateShape(id, action) { $0[keyPath: path] = value } }
        )
    }
}

/// Scrub the source and grab the exact frame — the reason this studio is
/// in-house instead of Canva. It talks to a `ThumbFrameSource`, so it knows
/// nothing about projects, sessions or players.
private struct FramePickerSheet: View {
    let source: any ThumbFrameSource
    @Environment(\.dismiss) private var dismiss

    @State private var time: Double = 0
    @State private var preview: NSImage?
    @State private var loading = false

    var body: some View {
        VStack(spacing: 10) {
            Text("Pick a frame")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            ZStack {
                Color.black
                if let preview {
                    Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit)
                } else if loading {
                    ProgressView()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Slider(value: $time, in: 0...max(1, source.frameSourceDuration)) { editing in
                    if !editing { loadPreview() }
                }
                Text(time.timecode)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Add to canvas") {
                    Task {
                        let destination = source.frameGrabDestination(at: time)
                        try? await source.writeSourceFrame(at: time, to: destination)
                        source.addFrameToCanvas(path: destination.path, time: time)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
        }
        .padding(14)
        .background(Theme.background)
        .onAppear {
            time = source.frameSourceDuration / 2
            loadPreview()
        }
    }

    private func loadPreview() {
        loading = true
        Task {
            let destination = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("framepick-preview.png")
            try? await source.writeSourceFrame(at: time, to: destination)
            preview = NSImage(contentsOf: destination)
            loading = false
        }
    }
}


/// Canva's paint roller: lift one text layer's whole look, stamp it on
/// another. A tiny global so it survives switching designs and works
/// across the generic pane's specialisations.
@MainActor
enum ThumbStyleClipboard {
    static var spec: TextSpec?
}

/// The sticker drawer — big emoji as instant text layers.
enum ThumbStickers {
    static let all = ["🔥", "😂", "💀", "😱", "❗", "💯", "⚡", "👀",
                      "🏆", "🚨", "😤", "🤯", "❤️", "🎮", "💰", "🥶"]
}

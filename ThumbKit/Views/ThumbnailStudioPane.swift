import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Thumbnail Studio: tool rail, layers, the artboard on a workbench, and a
/// contextual inspector. The artboard shows the actual export render scaled to
/// fit — the same `ThumbnailRenderer` output that gets written to disk, so the
/// preview and the file cannot disagree.
///
/// Generic over its store so the same editor serves a project's thumbnail and
/// a standalone design; `frameSource` is the only thing a video host adds.
struct ThumbnailStudioPane<Store: ThumbStore>: View {
    @ObservedObject var store: Store
    /// Present only when a host app can supply video frames (the VOD editor);
    /// nil in the standalone studio, which then hides the frame-grab
    /// affordances entirely.
    var frameSource: (any ThumbFrameSource)?

    /// Owned by whoever hosts the pane, because the chrome around it (zoom,
    /// undo, the menu bar) reads the same state. Observed here so a change
    /// made from a menu item repaints the canvas.
    @ObservedObject var editor: ThumbEditorModel<Store>
    /// Observed so that a layer's selection box, drawn at its stored height
    /// while the real aspect was still being read, redraws when it arrives.
    @ObservedObject private var aspects = ImageAspectCache.shared
    @Environment(\.undoManager) private var undoManager
    @FocusState var editingTextLayer: UUID?

    @State var canvasImage: NSImage?
    @State var tool: Tool = .move
    @State var croppingLayerID: UUID?
    @State var showFramePicker = false
    @State var showExport = false
    /// Remembered across launches: a panel you opened is a panel you want,
    /// and re-opening it every session is the kind of small friction that
    /// makes a tool feel like it is not listening.
    @AppStorage("thumbStudio.libraryOpen") var showLibrary = false
    @State var showReview = false
    @State var showLayouts = false
    @State var showPreview = false
    @State var dragDraft: (ids: Set<UUID>, dx: Double, dy: Double)?
    @State var resizeDraft: (id: UUID, width: Double)?
    @State var isDropTargeted = false
    /// Which render is current. A canvas render now happens off the main
    /// thread, so a slow one of an OLD document can finish after a fast one of
    /// a new document — and would paint stale pixels over fresh ones. Each
    /// request takes the next token and throws its result away if it is no
    /// longer the newest.
    @State var renderToken = 0
    /// The group whose name is being edited, if any.
    @State var renamingGroup: UUID?
    @State var guideX: Double?
    @State var guideY: Double?



    /// What a click on the artboard does.
    enum Tool: String, CaseIterable {
        case move, text, image, shape

        var symbol: String {
            switch self {
            case .move: return "cursorarrow"
            case .text: return "textformat"
            case .image: return "photo"
            case .shape: return "square.on.circle"
            }
        }

        var help: String {
            switch self {
            case .move: return "Move  V"
            case .text: return "Text  T — click the canvas to place"
            case .image: return "Image  I — click the canvas to place"
            case .shape: return "Shape  R — click the canvas to place"
            }
        }
    }

    var doc: ThumbDocument { store.thumbDoc }
    var selection: Set<UUID> { editor.selection }
    var selectedLayer: ThumbLayer? {
        guard editor.selection.count == 1 else { return nil }
        return doc.layers.first { editor.selection.contains($0.id) }
    }

    var body: some View {
        HStack(spacing: 0) {
            toolRail
            StudioVRule()
            if showLibrary {
                LibraryPanel(onInsert: { path in
                    addLayer(.image(ImageSpec(path: path)), action: "Add Image")
                }, onClose: { showLibrary = false })
                StudioVRule()
            }
            layersPanel
                .frame(width: Studio.Metric.layersWidth)
            StudioVRule()
            workbench
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            StudioVRule()
            inspector
                .frame(width: Studio.Metric.inspectorWidth)
        }
        .background(Studio.Palette.workbench)
        .thumbKeyboardLayer(editor)
        .onAppear {
            store.timelineUndoManager = undoManager
            ThumbKeyRouter.shared.previewHandler = { showPreview = true }
            ThumbKeyRouter.shared.reviewHandler = { showReview = true }
            ThumbKeyRouter.shared.libraryHandler = { showLibrary.toggle() }
            ThumbKeyRouter.shared.layoutsHandler = { showLayouts = true }
            ThumbKeyRouter.shared.canvasWidth = doc.width
            ThumbKeyRouter.shared.canvasHeight = doc.height
            rerender()
            openLaunchSheet()
        }
        // A file that missed its read deadline draws as a placeholder. When it
        // finally arrives, draw again — otherwise the canvas keeps the
        // placeholder until something else happens to change the document.
        .onReceive(NotificationCenter.default.publisher(
            for: AdjustedImageCache.imageDidArrive)) { _ in rerender() }
        .onChange(of: undoManager) { _, manager in store.timelineUndoManager = manager }
        .onChange(of: editor.selection) { _, _ in ThumbKeyRouter.shared.refresh() }
        .onChange(of: editor.textEditingRequest) { _, id in editingTextLayer = id }
        .onChange(of: editor.imagePickRequested) { _, wanted in
            guard wanted else { return }
            editor.imagePickRequested = false
            addImageFile()
        }
        .onChange(of: store.thumbDoc) { _, document in
            ThumbKeyRouter.shared.canvasWidth = document.width
            ThumbKeyRouter.shared.canvasHeight = document.height
            // Undo, an external reload and a cutout landing all change the
            // document without going through the model, so a selection can
            // outlive its layers and leave the menus enabled over nothing.
            let live = Set(document.layers.map(\.id))
            let pruned = editor.selection.intersection(live)
            if pruned != editor.selection { editor.selection = pruned }
            ThumbKeyRouter.shared.refresh()
            rerender()
        }
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
        .sheet(isPresented: Binding(get: { showExport || editor.exportRequested },
                                   set: { showExport = $0; editor.exportRequested = $0 })) {
            ExportSheet(document: doc, image: canvasImage)
        }
        .sheet(isPresented: $showReview) {
            ReviewSheet(document: doc, image: canvasImage)
        }
        .sheet(isPresented: Binding(get: { renamingGroup != nil },
                                    set: { if !$0 { renamingGroup = nil } })) {
            if let id = renamingGroup {
                GroupRenameSheet(name: doc.groupName(id) ?? "Group") { newName in
                    var document = doc
                    document.renameGroup(id, to: newName)
                    apply(document, "Rename Group")
                }
            }
        }
        .sheet(isPresented: $showLayouts) {
            ComposeSheet(document: doc) { document, action in
                apply(document, action)
            }
        }
        .sheet(isPresented: $showPreview) {
            PlatformPreviewSheet(document: doc, image: canvasImage, title: previewTitle)
        }
        .sheet(isPresented: Binding(get: { editor.showCheatSheet },
                                     set: { editor.showCheatSheet = $0 })) {
            ThumbShortcutCheatSheet()
        }
    }

    // MARK: - Tool rail

    private var toolRail: some View {
        VStack(spacing: Studio.Space.xs) {
            ForEach(Tool.allCases, id: \.self) { item in
                StudioIconButton(item.symbol, help: item.help, isActive: tool == item) {
                    tool = item
                }
            }
            StudioDivider().padding(.horizontal, Studio.Space.s)
            StudioIconButton("crop", help: "Crop & cut") { beginCrop() }
                .disabled(!selectedIsImage)
            StudioIconButton("photo.stack", help: "Library  ⌘L",
                             isActive: showLibrary) { showLibrary.toggle() }
            StudioIconButton("checklist", help: "Review this thumbnail  ⌘R") {
                showReview = true
            }
            StudioIconButton("rectangle.3.group",
                             help: "Layouts — arrangements of your text") {
                showLayouts = true
            }
            StudioIconButton("rectangle.on.rectangle.angled",
                             help: "Preview where it will be seen  ⌘P") {
                showPreview = true
            }
            Spacer()
            cutoutButton
            StudioIconButton("questionmark", help: "Keyboard shortcuts  ⌘/") {
                editor.showCheatSheet = true
            }
        }
        .padding(.vertical, Studio.Space.s)
        .frame(width: Studio.Metric.toolRailWidth)
        .background(Studio.Palette.panel)
    }

    /// What the mock feed shows beside the thumbnail. The biggest text layer
    /// is almost always the headline, which is what a real title would echo.
    var previewTitle: String {
        let headline = doc.layers
            .compactMap { layer -> (Double, String)? in
                guard case .text(let spec) = layer.kind,
                      !spec.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return (spec.sizeFraction, spec.text)
            }
            .max { $0.0 < $1.0 }?.1
        return headline?.replacingOccurrences(of: "\n", with: " ") ?? "Your video title goes here"
    }

    var selectedIsImage: Bool {
        if case .image? = selectedLayer?.kind { return true }
        return false
    }

    @ViewBuilder
    private var cutoutButton: some View {
        if store.isCuttingOut {
            ProgressView()
                .controlSize(.small)
                .frame(width: Studio.Metric.controlM, height: Studio.Metric.controlM)
                .help("Lifting the subject…")
        } else {
            StudioIconButton("person.and.background.dotted",
                             help: "Remove background  ⇧⌘K") {
                editor.removeBackgroundOnSelection()
            }
            .disabled(!selectedIsImage)
        }
    }

    /// `ThumbStudio --open "doomsday" --sheet layouts` opens that design with
    /// that sheet already up.
    ///
    /// The companion to `--open`, and there for the same reason: this Mac
    /// withholds accessibility permission, so nothing can click a button, and
    /// a sheet nobody can open is a sheet nobody can check. Only ever reads
    /// arguments the developer passed on the command line.
    private func openLaunchSheet() {
        let arguments = CommandLine.arguments
        if let pick = arguments.firstIndex(of: "--select"), pick + 1 < arguments.count,
           let which = Int(arguments[pick + 1]), doc.layers.indices.contains(which) {
            let id = doc.layers[which].id
            DispatchQueue.main.async { editor.selection = [id] }
        }
        guard let index = arguments.firstIndex(of: "--sheet"),
              index + 1 < arguments.count else { return }
        let wanted = arguments[index + 1].lowercased()
        // One runloop turn later, not now. Presenting a sheet from inside
        // `onAppear` mutates the state that drives this view while the view is
        // still being installed, and the window comes up with no content at
        // all — the same fault that writing `@FocusState` in `onAppear` caused
        // in the gallery.
        DispatchQueue.main.async {
            switch wanted {
            case "layouts": showLayouts = true
            case "review": showReview = true
            case "library": showLibrary = true
            case "preview": showPreview = true
            default: break
            }
        }
    }

    // MARK: - Rendering

    func rerender() {
        let snapshot = doc
        renderToken &+= 1
        let token = renderToken
        Task { @MainActor in
            let image = await Task.detached(priority: .userInitiated) {
                ThumbnailRenderer.renderForStudio(snapshot)
            }.value
            guard token == renderToken else { return }
            canvasImage = image
        }
    }

    func apply(_ document: ThumbDocument, _ action: String) {
        store.applyThumbDoc(document, action: action)
    }

    // MARK: - Layer mutation

    func mutateLayer(_ id: UUID, _ action: String, _ change: (inout ThumbLayer) -> Void) {
        var document = doc
        guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
        change(&document.layers[index])
        apply(document, action)
    }

    func mutateText(_ id: UUID, _ action: String, _ change: (inout TextSpec) -> Void) {
        mutateLayer(id, action) { layer in
            guard case .text(var spec) = layer.kind else { return }
            change(&spec)
            layer.kind = .text(spec)
        }
    }

    func mutateImage(_ id: UUID, _ action: String, _ change: (inout ImageSpec) -> Void) {
        mutateLayer(id, action) { layer in
            guard case .image(var spec) = layer.kind else { return }
            change(&spec)
            layer.kind = .image(spec)
        }
        AdjustedImageCache.shared.invalidate()
        ImageAspectCache.shared.invalidate()
    }

    func mutateShape(_ id: UUID, _ action: String, _ change: (inout ShapeSpec) -> Void) {
        mutateLayer(id, action) { layer in
            guard case .shape(var spec) = layer.kind else { return }
            change(&spec)
            layer.kind = .shape(spec)
        }
    }

    func moveLayer(_ id: UUID, _ direction: ThumbDocument.LayerMove, _ action: String) {
        var document = doc
        guard document.move(layerID: id, direction) else { return }
        apply(document, action)
    }

    /// Picking a layer picks its group, unless you deliberately reached past
    /// the group to get at the member — which is what `withinGroup` means, and
    /// what clicking a row inside an expanded group in the layers panel does.
    func select(_ id: UUID, extending: Bool = false, withinGroup: Bool = false) {
        let wanted = withinGroup ? [id] : doc.expandedSelection([id])
        if extending {
            if editor.selection.isSuperset(of: wanted) {
                editor.selection.subtract(wanted)
            } else {
                editor.selection.formUnion(wanted)
            }
        } else {
            editor.selection = wanted
        }
    }

    func beginCrop() {
        guard selectedIsImage, let id = selectedLayer?.id else { return }
        croppingLayerID = id
    }

    // MARK: - Adding layers

    /// Every creation verb funnels through here so a new layer is always
    /// selected and always lands where the tool was used.
    @discardableResult
    func addLayer(_ kind: ThumbLayer.Kind, at point: CGPoint? = nil,
                  width: Double = 0.5, height: Double = 0.3, action: String) -> UUID {
        var document = doc
        var layer = ThumbLayer(kind: kind,
                               x: point.map { Double($0.x) } ?? 0.5,
                               y: point.map { Double($0.y) } ?? 0.5,
                               widthFraction: width, heightFraction: height)
        if case .text = kind { layer.widthFraction = 0.85 }
        document.layers.append(layer)
        apply(document, action)
        editor.selection = [layer.id]
        tool = .move
        return layer.id
    }

    func addText(at point: CGPoint? = nil) {
        let id = addLayer(.text(TextSpec(text: "YOUR TEXT")), at: point, action: "Add Text")
        // A new text layer with placeholder copy should land you in the field,
        // not make you hunt for it.
        editor.textEditingRequest = id
    }

    func addShape(_ shape: String, at point: CGPoint? = nil) {
        addLayer(.shape(ShapeSpec(shape: shape)), at: point,
                 width: 0.3, height: 0.3, action: "Add Shape")
    }

    func addSticker(_ emoji: String) {
        var spec = TextSpec(text: emoji)
        spec.sizeFraction = 0.22
        spec.strokeWidth = 0
        spec.shadowEnabled = true
        addLayer(.text(spec), width: 0.3, action: "Add Sticker")
    }

    func addImageFile(at point: CGPoint? = nil) {
        guard let url = pickImage() else { return }
        // Adopted, not referenced: a design that points at wherever you dragged
        // a file from breaks the day you tidy your Downloads folder. Storage is
        // content-addressed, so importing the same file twice costs one copy.
        let path = ThumbLibrary.adopt(url) ?? url.path
        addLayer(.image(ImageSpec(path: path)), at: point, action: "Add Image")
    }

    func setImageFile(for layerID: UUID) {
        guard let url = pickImage() else { return }
        let adopted = ThumbLibrary.adopt(url) ?? url.path
        mutateLayer(layerID, "Set Image") { layer in
            if case .image(var spec) = layer.kind {
                spec.path = adopted
                spec.cutoutPath = nil
                spec.useCutout = false
                layer.kind = .image(spec)
            }
        }
        AdjustedImageCache.shared.invalidate()
        ImageAspectCache.shared.invalidate()
    }

    private func pickImage() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    // MARK: - Templates

    func applyTemplate(_ template: ThumbDocument) {
        var document = template
        document.width = doc.width
        document.height = doc.height
        apply(document, "Apply Template")
        editor.selection = []
    }

    func savedTemplates() -> [(String, ThumbDocument)] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Paths.thumbTemplatesRoot, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let document = try? JSONDecoder().decode(ThumbDocument.self, from: data)
            else { return nil }
            return (url.deletingPathExtension().lastPathComponent, document)
        }
    }

    func saveTemplate() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = Paths.thumbTemplatesRoot
        panel.nameFieldStringValue = "My template.json"
        panel.message = "Templates saved here appear in the Templates menu in every project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? JSONEncoder().encode(doc).write(to: url, options: .atomic)
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

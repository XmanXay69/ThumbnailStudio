import SwiftUI
import AppKit

/// The Thumbnail Studio home: a gallery of designs, the sizes you can start
/// from, and the templates. Selecting a design opens the editor in place.
///
/// Deliberately not a "hero" screen. A tool you open twenty times a day should
/// get out of the way — the top bar states where you are, the body is your
/// work, and the status line carries the numbers.
struct ThumbLabView: View {
    /// nil in the standalone app, where there is nothing to go back to.
    var onClose: (() -> Void)?

    @State private var designs: [StandaloneThumbStore.Design] = []
    @State private var store: StandaloneThumbStore?
    @State private var selectedID: String?
    @State private var search = ""
    @State private var sort = Sort.recent
    @State private var pendingDelete: StandaloneThumbStore.Design?
    @FocusState private var searchFocused: Bool
    @FocusState private var gridFocused: Bool

    private enum Sort: String, CaseIterable {
        case recent = "Recently edited"
        case name = "Name"
        case size = "Canvas size"
    }

    var body: some View {
        Group {
            if let store {
                ThumbEditorView(store: store, onBack: closeEditor,
                                onNewDesign: { create(preset: ThumbDocument.canvasPresets[0]) })
                    // Identity is the file: switching designs without this
                    // reuses the view, keeps its editor model bound to the
                    // old store, and silently edits the design you left.
                    .id(store.fileURL)
            } else {
                gallery
            }
        }
        .studioWindowBackground()
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            store?.reloadIfChangedExternally()
            reload()
        }
        .alert("Delete this design?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { design in
            Button("Delete", role: .destructive) { delete(design) }
            Button("Cancel", role: .cancel) {}
        } message: { design in
            Text("“\(design.name)” will be moved to the Trash. This cannot be undone from inside the app.")
        }
    }

    // MARK: - Gallery

    private var gallery: some View {
        VStack(spacing: 0) {
            topBar
            StudioDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: Studio.Space.xl) {
                    if search.isEmpty {
                        startStrip
                        templateStrip
                        StudioDivider()
                    }
                    designGrid
                }
                .padding(Studio.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .focusable()
            .focused($gridFocused)
            .onKeyPress(.delete) { deleteSelected() }
            .onKeyPress(.deleteForward) { deleteSelected() }
            .onKeyPress(.return) { openSelected() }
            .onKeyPress(.escape) { selectedID = nil; return .handled }
            .onKeyPress(.leftArrow) { moveSelection(-1) }
            .onKeyPress(.rightArrow) { moveSelection(1) }
            StudioStatusBar {
                Text(countLabel)
                Text("·")
                Text(Paths.thumbLabRoot.path)
                    .truncationMode(.middle)
                    .lineLimit(1)
                Spacer()
                StudioIconButton("folder", help: "Reveal the designs folder", size: .small) {
                    NSWorkspace.shared.open(Paths.thumbLabRoot)
                }
            }
        }
    }

    private var countLabel: String {
        designs.count == 1 ? "1 design" : "\(designs.count) designs"
    }

    private var topBar: some View {
        HStack(spacing: Studio.Space.s) {
            if let onClose {
                StudioIconButton("chevron.left", help: "Back to projects") { onClose() }
            }
            Text("Designs")
                .font(Studio.Typo.display)
                .foregroundStyle(Studio.Palette.textPrimary)
            Spacer()
            searchField
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(Studio.Typo.iconMedium)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: Studio.Metric.controlM)
            .help("Sort designs")
            Button("New design") { create(preset: ThumbDocument.canvasPresets[0]) }
                .buttonStyle(.studioPrimary)
                .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, Studio.Space.l)
        .frame(height: Studio.Metric.topBarHeight)
        .background(Studio.Palette.panel)
    }

    private var searchField: some View {
        HStack(spacing: Studio.Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(Studio.Typo.iconSmall)
                .foregroundStyle(Studio.Palette.textTertiary)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .font(Studio.Typo.body)
                .focused($searchFocused)
            if !search.isEmpty {
                StudioIconButton("xmark.circle.fill", help: "Clear", size: .small) { search = "" }
            }
        }
        .padding(.horizontal, Studio.Space.s)
        .frame(width: 200, height: Studio.Metric.controlS)
        .background(RoundedRectangle(cornerRadius: Studio.Radius.field, style: .continuous)
            .fill(Studio.Palette.control))
        .studioFocusRing(searchFocused, radius: Studio.Radius.field)
    }

    // MARK: - Start from a size, or a template

    private var startStrip: some View {
        VStack(alignment: .leading, spacing: Studio.Space.s) {
            Text("Start a new design")
                .font(Studio.Typo.section)
                .foregroundStyle(Studio.Palette.textTertiary)
            HStack(spacing: Studio.Space.m) {
                ForEach(ThumbDocument.canvasPresets, id: \.name) { preset in
                    Button { create(preset: preset) } label: {
                        VStack(spacing: Studio.Space.s) {
                            RoundedRectangle(cornerRadius: Studio.Radius.field, style: .continuous)
                                .fill(Studio.Palette.windowBackground)
                                .aspectRatio(CGFloat(preset.width) / CGFloat(preset.height),
                                             contentMode: .fit)
                                .frame(height: 72)
                                .overlay(
                                    RoundedRectangle(cornerRadius: Studio.Radius.field,
                                                     style: .continuous)
                                        .strokeBorder(Studio.Palette.hairline,
                                                      lineWidth: Studio.Metric.hairline))
                                .overlay(Image(systemName: "plus")
                                    .font(Studio.Typo.iconSmall)
                                    .foregroundStyle(Studio.Palette.textTertiary))
                            Text(shortName(preset.name))
                                .font(Studio.Typo.label)
                                .foregroundStyle(Studio.Palette.textSecondary)
                            Text("\(preset.width) × \(preset.height)")
                                .font(Studio.Typo.numeric)
                                .foregroundStyle(Studio.Palette.textTertiary)
                        }
                        .padding(Studio.Space.s)
                        .frame(width: 132)
                        .studioSelectable(isSelected: false)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// "YouTube 1280×720" → "YouTube": the dimensions get their own line, so
    /// repeating them in the name is noise.
    private func shortName(_ name: String) -> String {
        name.split(separator: " ").dropLast().joined(separator: " ")
    }

    private var templateStrip: some View {
        VStack(alignment: .leading, spacing: Studio.Space.s) {
            Text("Start from a template")
                .font(Studio.Typo.section)
                .foregroundStyle(Studio.Palette.textTertiary)
            HStack(spacing: Studio.Space.m) {
                ForEach(ThumbTemplates.starters(), id: \.name) { template in
                    Button { createFromTemplate(template.name, template.document) } label: {
                        VStack(alignment: .leading, spacing: Studio.Space.s) {
                            DocPreview(document: template.document)
                                .frame(height: 72)
                            Text(template.name)
                                .font(Studio.Typo.label)
                                .foregroundStyle(Studio.Palette.textSecondary)
                        }
                        .padding(Studio.Space.s)
                        .frame(width: 132)
                        .studioSelectable(isSelected: false)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - The designs

    private var visible: [StandaloneThumbStore.Design] {
        let filtered = search.isEmpty ? designs : designs.filter {
            $0.name.localizedCaseInsensitiveContains(search)
        }
        switch sort {
        case .recent: return filtered.sorted { $0.modifiedAt > $1.modifiedAt }
        case .name: return filtered.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size: return filtered.sorted { $0.width * $0.height > $1.width * $1.height }
        }
    }

    private var designGrid: some View {
        VStack(alignment: .leading, spacing: Studio.Space.m) {
            HStack {
                Text(search.isEmpty ? "Your designs" : "Results")
                    .font(Studio.Typo.section)
                    .foregroundStyle(Studio.Palette.textTertiary)
                Spacer()
            }
            if visible.isEmpty {
                StudioEmptyState(
                    symbol: search.isEmpty ? "rectangle.on.rectangle.angled" : "magnifyingglass",
                    title: search.isEmpty ? "No designs yet" : "Nothing matches “\(search)”",
                    message: search.isEmpty
                        ? "Start from a size above, or open a template."
                        : "Try a different word, or clear the search.",
                    actionTitle: search.isEmpty ? "New design" : "Clear search") {
                        if search.isEmpty { create(preset: ThumbDocument.canvasPresets[0]) }
                        else { search = "" }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Studio.Space.xxl)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 232, maximum: 300),
                                             spacing: Studio.Space.l)],
                          spacing: Studio.Space.l) {
                    ForEach(visible) { design in
                        designCard(design)
                    }
                }
            }
        }
    }

    private func designCard(_ design: StandaloneThumbStore.Design) -> some View {
        VStack(spacing: 0) {
            LabPreview(url: design.url)
                .aspectRatio(CGFloat(design.width) / CGFloat(design.height), contentMode: .fit)
                .frame(maxWidth: .infinity)
            HStack(spacing: Studio.Space.s) {
                VStack(alignment: .leading, spacing: Studio.Space.xxs) {
                    Text(design.name)
                        .font(Studio.Typo.bodyStrong)
                        .foregroundStyle(Studio.Palette.textPrimary)
                        .lineLimit(1)
                    Text("\(design.width) × \(design.height) · \(design.modifiedAt.formatted(.relative(presentation: .named)))")
                        .font(Studio.Typo.caption)
                        .foregroundStyle(Studio.Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(Studio.Space.s)
        }
        .studioSelectable(isSelected: selectedID == design.id)
        .onTapGesture(count: 2) { open(design) }
        .onTapGesture { selectedID = design.id; gridFocused = true }
        .contextMenu {
            Button("Open") { open(design) }
            Button("Duplicate") { duplicate(design) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([design.url])
            }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = design }
        }
    }

    // MARK: - Keyboard

    private func deleteSelected() -> KeyPress.Result {
        guard let design = visible.first(where: { $0.id == selectedID }) else { return .ignored }
        pendingDelete = design
        return .handled
    }

    private func openSelected() -> KeyPress.Result {
        guard let design = visible.first(where: { $0.id == selectedID }) else { return .ignored }
        open(design)
        return .handled
    }

    private func moveSelection(_ offset: Int) -> KeyPress.Result {
        let list = visible
        guard !list.isEmpty else { return .ignored }
        guard let current = list.firstIndex(where: { $0.id == selectedID }) else {
            selectedID = list.first?.id
            return .handled
        }
        selectedID = list[min(list.count - 1, max(0, current + offset))].id
        return .handled
    }

    // MARK: - Actions

    private func reload() { designs = StandaloneThumbStore.designs() }

    private func closeEditor() {
        store?.detachUndo()
        store = nil
        reload()
    }

    private func open(_ design: StandaloneThumbStore.Design) {
        store?.detachUndo()
        store = StandaloneThumbStore(fileURL: design.url)
    }

    /// No naming dialog. Every tool in this class creates the document first
    /// and lets you rename it in the editor, because a modal asking for a name
    /// before you have drawn anything is friction with no payoff.
    private func create(preset: (name: String, width: Int, height: Int)) {
        store?.detachUndo()
        store = StandaloneThumbStore.create(named: "Untitled",
                                            width: preset.width, height: preset.height)
        reload()
    }

    private func createFromTemplate(_ name: String, _ document: ThumbDocument) {
        store?.detachUndo()
        let created = StandaloneThumbStore.create(
            named: name, width: document.width, height: document.height)
        created.applyThumbDoc(document, action: nil)
        store = created
        reload()
    }

    private func duplicate(_ design: StandaloneThumbStore.Design) {
        guard let copy = StandaloneThumbStore.duplicate(design) else { return }
        reload()
        selectedID = copy.path
    }

    private func delete(_ design: StandaloneThumbStore.Design) {
        // Trash, not unlink: a design is the user's work, and an undo stack
        // that ends at the app's own launch is not a safety net.
        try? FileManager.default.trashItem(at: design.url, resultingItemURL: nil)
        if store?.fileURL == design.url { store = nil }
        if selectedID == design.id { selectedID = nil }
        pendingDelete = nil
        reload()
    }
}

/// A live render of a design file at gallery size.
private struct LabPreview: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Studio.Palette.windowBackground
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .task(id: url) {
            let fileURL = url
            image = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let data = try? Data(contentsOf: fileURL),
                      let doc = try? JSONDecoder().decode(ThumbDocument.self, from: data)
                else { return nil }
                // Full size, then downsampled: shrinking the *document*
                // instead would shrink the canvas but not the stroke widths
                // and shadow radii, which are absolute pixels.
                guard let full = ThumbnailRenderer.render(
                    doc, provider: ThumbnailRenderer.fileProvider) else { return nil }
                return LayerThumbnailCache.downsampled(full, maxWidth: 600)
            }.value
        }
    }
}

/// A live render of an in-memory document — template cards.
private struct DocPreview: View {
    let document: ThumbDocument
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Studio.Palette.windowBackground
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Studio.Radius.field, style: .continuous))
        .task {
            let doc = document
            image = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let full = ThumbnailRenderer.render(
                    doc, showingPlaceholders: true,
                    provider: ThumbnailRenderer.fileProvider) else { return nil }
                return LayerThumbnailCache.downsampled(full, maxWidth: 400)
            }.value
        }
    }
}

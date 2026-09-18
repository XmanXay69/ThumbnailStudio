import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Everything you can put on a canvas, in a column beside it.
///
/// A panel rather than a sheet, for the reason every design tool settles on a
/// panel: picking an image is not a single decision you make and dismiss, it is
/// something you do repeatedly while looking at the thing you are building. A
/// modal that covers the canvas hides the one piece of information you need to
/// choose — what the design currently looks like — and makes adding four images
/// four round trips.
///
/// Drag a row onto the canvas to place it where you dropped it, or click to
/// drop it in the middle. Drop files onto the panel to bring them in.
struct LibraryPanel: View {
    /// Click-to-insert. Dragging goes through the canvas's own drop handler,
    /// which is what makes the image land where the pointer was.
    let onInsert: (String) -> Void
    let onClose: () -> Void

    @ObservedObject private var favourites = ThumbFavourites.shared
    @State private var assets: [ThumbLibrary.Asset] = []
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var loading = true
    @State private var isDropTargeted = false

    /// Which slice of the library is showing. Sources are kept separable
    /// because "the logo I filed" and "a frame the app grabbed off a video"
    /// are different kinds of thing that happen to live in the same list.
    enum Filter: String, CaseIterable {
        case all, favourites, uploaded, cutouts

        var label: String {
            switch self {
            case .all: return "All"
            case .favourites: return "Starred"
            case .uploaded: return "Uploaded"
            case .cutouts: return "Cutouts"
            }
        }
    }

    private var visible: [ThumbLibrary.Asset] {
        assets.filter { asset in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .favourites: matchesFilter = favourites.hasAsset(asset.path)
            case .uploaded: matchesFilter = asset.source == .imported || asset.source == .folder
                || asset.source == .recent
            case .cutouts: matchesFilter = asset.source == .cutout
            }
            return matchesFilter
                && (search.isEmpty || asset.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            StudioDivider()
            searchRow
            StudioDivider()
            content
            StudioDivider()
            footer
        }
        .frame(width: Studio.Metric.libraryWidth)
        .background(Studio.Palette.panel)
        // Dropping onto the panel files an image without placing it, which is
        // how you stock the library before you know where anything goes.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            adopt(providers)
        }
        .overlay {
            if isDropTargeted {
                Rectangle()
                    .strokeBorder(Studio.Palette.accent, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .task { load() }
    }

    private var header: some View {
        HStack(spacing: Studio.Space.s) {
            Text("Library")
                .font(Studio.Typo.title)
                .foregroundStyle(Studio.Palette.textPrimary)
            Spacer()
            StudioIconButton("plus", help: "Add images…", size: .small) { pickFiles() }
            StudioIconButton("xmark", help: "Close the library  ⌘L", size: .small) { onClose() }
        }
        .padding(.horizontal, Studio.Space.m)
        .frame(height: Studio.Metric.topBarHeight)
    }

    private var searchRow: some View {
        VStack(spacing: Studio.Space.s) {
            HStack(spacing: Studio.Space.xs) {
                Image(systemName: "magnifyingglass")
                    .font(Studio.Typo.iconSmall)
                    .foregroundStyle(Studio.Palette.textTertiary)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .font(Studio.Typo.body)
            }
            .padding(.horizontal, Studio.Space.s)
            .frame(height: Studio.Metric.controlS)
            .background(RoundedRectangle(cornerRadius: Studio.Radius.field, style: .continuous)
                .fill(Studio.Palette.control))

            StudioSegmented(selection: $filter,
                            options: Filter.allCases.map { ($0, $0.label) })
        }
        .padding(Studio.Space.m)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty {
            StudioEmptyState(
                symbol: filter == .favourites ? "star" : "photo.on.rectangle.angled",
                title: emptyTitle,
                message: emptyMessage,
                actionTitle: filter == .favourites ? nil : "Add images…") { pickFiles() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 160),
                                             spacing: Studio.Space.s)],
                          spacing: Studio.Space.s) {
                    ForEach(visible) { asset in
                        card(asset)
                    }
                }
                .padding(Studio.Space.m)
            }
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .favourites: return "Nothing starred yet"
        case .cutouts: return "No cutouts yet"
        case .uploaded: return "Nothing brought in yet"
        case .all: return search.isEmpty ? "Nothing here yet" : "No matches"
        }
    }

    private var emptyMessage: String {
        switch filter {
        case .favourites:
            return "Star an image and it stays at the top of this list."
        case .cutouts:
            return "Run Remove Background on an image and the subject it lifts turns up here."
        default:
            return "Drag images onto this panel, or drop a folder of them into the Assets folder — a subfolder there becomes a tag."
        }
    }

    private func card(_ asset: ThumbLibrary.Asset) -> some View {
        VStack(spacing: 0) {
            ZStack {
                // A checkerboard rather than a flat ground: half of these are
                // cutouts, and a transparent PNG on a dark panel looks like a
                // failed load.
                LibraryCheckerboard()
                if let image = NSImage(contentsOfFile: asset.path) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .font(Studio.Typo.iconMedium)
                        .foregroundStyle(Studio.Palette.warning)
                }
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            favourites.toggleAsset(asset.path)
                        } label: {
                            Image(systemName: favourites.hasAsset(asset.path)
                                  ? "star.fill" : "star")
                                .font(Studio.Typo.iconSmall)
                                .foregroundStyle(favourites.hasAsset(asset.path)
                                                 ? Studio.Palette.accent
                                                 : Studio.Palette.textSecondary)
                                .padding(Studio.Space.xxs)
                                .background(Circle().fill(Studio.Palette.windowBackground.opacity(0.7)))
                        }
                        .buttonStyle(.plain)
                        .help(favourites.hasAsset(asset.path) ? "Unstar" : "Star this image")
                    }
                    Spacer()
                }
                .padding(Studio.Space.xxs)
            }
            .frame(height: 72)
            .clipped()

            VStack(alignment: .leading, spacing: 0) {
                Text(asset.name)
                    .font(Studio.Typo.caption)
                    .foregroundStyle(Studio.Palette.textPrimary)
                    .lineLimit(1)
                Text(asset.tag ?? asset.source.label)
                    .font(Studio.Typo.caption)
                    .foregroundStyle(asset.tag != nil
                                     ? Studio.Palette.accent : Studio.Palette.textTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Studio.Space.xs)
            .padding(.vertical, Studio.Space.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .studioSelectable(isSelected: false)
        .contentShape(Rectangle())
        // The canvas already accepts a dropped file URL and places it where the
        // pointer was, so a drag out of here needs to offer exactly that and
        // nothing else has to change.
        .onDrag { NSItemProvider(contentsOf: asset.url) ?? NSItemProvider() }
        .onTapGesture { onInsert(asset.path) }
        .contextMenu {
            Button(favourites.hasAsset(asset.path) ? "Unstar" : "Star") {
                favourites.toggleAsset(asset.path)
            }
            Button("Add to Canvas") { onInsert(asset.path) }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([asset.url])
            }
        }
        .help("\(asset.name) — drag onto the canvas, or click to add")
    }

    private var footer: some View {
        StudioStatusBar {
            Text(loading ? "Reading…" : "\(visible.count) of \(assets.count)")
            Spacer()
            StudioIconButton("folder", help: "Open the Assets folder", size: .small) {
                try? FileManager.default.createDirectory(at: Paths.assetsRoot,
                                                         withIntermediateDirectories: true)
                NSWorkspace.shared.open(Paths.assetsRoot)
            }
            StudioIconButton("arrow.clockwise", help: "Rescan", size: .small) { load() }
        }
    }

    // MARK: - Work

    private func load() {
        loading = true
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                ThumbLibrary.all()
            }.value
            // Starred first, then whatever order the scan produced, which is
            // newest-first within each source.
            let starred = favourites.set.assets
            assets = found.filter(\.exists).sorted {
                let a = starred.contains($0.path), b = starred.contains($1.path)
                return a == b ? $0.modifiedAt > $1.modifiedAt : a
            }
            loading = false
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = true
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { _ = ThumbLibrary.adopt(url) }
        load()
    }

    /// Files dropped on the panel are copied into the app's storage and appear
    /// in the list. They are not placed on the canvas: dropping onto a library
    /// is filing, and dropping onto the canvas is placing.
    private func adopt(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        let group = DispatchGroup()
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                defer { group.leave() }
                guard let url, NSImage(contentsOf: url) != nil else { return }
                _ = ThumbLibrary.adopt(url)
            }
        }
        guard handled else { return false }
        group.notify(queue: .main) { load() }
        return true
    }
}

/// The transparency checker. Drawn rather than an asset so it scales with the
/// card and needs nothing in a bundle.
struct LibraryCheckerboard: View {
    var square: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Studio.Palette.windowBackground))
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var column = 0
                var x: CGFloat = 0
                while x < size.width {
                    if (row + column) % 2 == 0 {
                        context.fill(Path(CGRect(x: x, y: y, width: square, height: square)),
                                     with: .color(Studio.Palette.control))
                    }
                    x += square
                    column += 1
                }
                y += square
                row += 1
            }
        }
        .allowsHitTesting(false)
    }
}

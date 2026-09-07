import SwiftUI
import AppKit

/// Everything you can drop into a design, in one place.
///
/// Two sources, neither of which needs you to maintain a catalogue: a folder
/// in Finder where a subfolder is a tag, and the images your existing designs
/// already use. Clicking one puts it on the canvas.
struct AssetLibrarySheet: View {
    let onInsert: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var assets: [ThumbLibrary.Asset] = []
    @State private var search = ""
    @State private var tag: String?
    @State private var loading = true

    private var visible: [ThumbLibrary.Asset] {
        assets.filter { asset in
            (tag == nil || asset.tag == tag)
                && (search.isEmpty || asset.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            StudioDivider()
            if !loading, assets.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200),
                                                 spacing: Studio.Space.m)],
                              spacing: Studio.Space.m) {
                        ForEach(visible) { asset in
                            card(asset)
                        }
                    }
                    .padding(Studio.Space.l)
                }
            }
            StudioDivider()
            StudioStatusBar {
                Text(loading ? "Reading…" : "\(visible.count) of \(assets.count)")
                Text("·")
                Text(Paths.assetsRoot.path)
                    .truncationMode(.middle).lineLimit(1)
                Spacer()
                StudioIconButton("folder", help: "Open the assets folder", size: .small) {
                    NSWorkspace.shared.open(Paths.assetsRoot)
                }
                StudioIconButton("arrow.clockwise", help: "Rescan", size: .small) { load() }
            }
        }
        .frame(width: 820, height: 640)
        .studioWindowBackground()
        .task { load() }
    }

    private var header: some View {
        HStack(spacing: Studio.Space.s) {
            Text("Library")
                .font(Studio.Typo.title)
                .foregroundStyle(Studio.Palette.textPrimary)
            if !ThumbLibrary.tags(in: assets).isEmpty {
                Menu {
                    Button("All") { tag = nil }
                    Divider()
                    ForEach(ThumbLibrary.tags(in: assets), id: \.self) { name in
                        Button(name) { tag = name }
                    }
                } label: {
                    Text(tag ?? "All").font(Studio.Typo.body)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 110)
            }
            Spacer()
            HStack(spacing: Studio.Space.xs) {
                Image(systemName: "magnifyingglass")
                    .font(Studio.Typo.iconSmall)
                    .foregroundStyle(Studio.Palette.textTertiary)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .font(Studio.Typo.body)
            }
            .padding(.horizontal, Studio.Space.s)
            .frame(width: 200, height: Studio.Metric.controlS)
            .background(RoundedRectangle(cornerRadius: Studio.Radius.field, style: .continuous)
                .fill(Studio.Palette.control))
            Button("Done") { dismiss() }
                .buttonStyle(.studio(.secondary, .medium))
        }
        .padding(.horizontal, Studio.Space.l)
        .frame(height: Studio.Metric.topBarHeight)
        .background(Studio.Palette.panel)
    }

    private var empty: some View {
        StudioEmptyState(
            symbol: "photo.on.rectangle.angled",
            title: "Nothing in the library yet",
            message: "Drop images into the Assets folder — a subfolder becomes a tag — or they'll appear here once you've used them in a design.",
            actionTitle: "Open the folder") {
                NSWorkspace.shared.open(Paths.assetsRoot)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(_ asset: ThumbLibrary.Asset) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Studio.Palette.windowBackground
                if let image = NSImage(contentsOfFile: asset.path) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .font(Studio.Typo.iconLarge)
                        .foregroundStyle(Studio.Palette.warning)
                }
            }
            .frame(height: 96)
            VStack(alignment: .leading, spacing: Studio.Space.xxs) {
                Text(asset.name)
                    .font(Studio.Typo.label)
                    .foregroundStyle(Studio.Palette.textPrimary)
                    .lineLimit(1)
                HStack(spacing: Studio.Space.xs) {
                    if let tag = asset.tag {
                        Text(tag)
                            .font(Studio.Typo.caption)
                            .foregroundStyle(Studio.Palette.accent)
                            .lineLimit(1)
                    } else if asset.source == .recent {
                        Text("used before")
                            .font(Studio.Typo.caption)
                            .foregroundStyle(Studio.Palette.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(Studio.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .studioSelectable(isSelected: false)
        .contentShape(Rectangle())
        .onTapGesture {
            onInsert(asset.path)
            dismiss()
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([asset.url])
            }
        }
        .help(asset.path)
    }

    private func load() {
        loading = true
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                ThumbLibrary.all()
            }.value
            assets = found.filter(\.exists)
            loading = false
        }
    }
}

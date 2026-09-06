import SwiftUI
import AppKit

/// The Thumb Lab, Canva-shaped: a design home — hero, size presets,
/// template cards, a grid of your recent designs — and a full-bleed editor
/// you step into and back out of. No project, no video, no floating window.
struct ThumbLabView: View {
    var onClose: () -> Void = {}

    @State private var designs: [StandaloneThumbStore.Design] = []
    @State private var store: StandaloneThumbStore?
    @State private var namingPreset: Int?
    @State private var draftName = ""

    var body: some View {
        Group {
            if let store {
                editor(store)
            } else {
                home
            }
        }
        .background(Theme.background)
        .onAppear { designs = StandaloneThumbStore.designs() }
        .alert("Name your design", isPresented: Binding(
            get: { namingPreset != nil },
            set: { if !$0 { namingPreset = nil } }
        )) {
            TextField("Name", text: $draftName)
            Button("Create") { createDesign() }
            Button("Cancel", role: .cancel) { draftName = "" }
        }
    }

    // MARK: - The editor, full bleed with a way back

    private func editor(_ store: StandaloneThumbStore) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    self.store = nil
                    designs = StandaloneThumbStore.designs()
                } label: {
                    Label("Designs", systemImage: "chevron.left")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                Text(store.fileURL.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(store.thumbDoc.width)×\(store.thumbDoc.height)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Theme.surface.opacity(0.6))

            ThumbnailStudioPane<StandaloneThumbStore>(store: store)
                .padding(12)
        }
    }

    // MARK: - Home

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero
                sizeRow
                templateRow
                gallerySection
            }
            .padding(24)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What are we designing?")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Thumbnails, banners, end cards — no video required. Everything here lives outside your projects.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
                .help("Back to projects")
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Theme.accent.opacity(0.22),
                                    Color(red: 0.42, green: 0.36, blue: 1.0).opacity(0.10),
                                    Theme.surface],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// Canva's size chooser: one card per canvas, drawn at its own aspect.
    private var sizeRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Start blank")
            HStack(spacing: 12) {
                ForEach(Array(ThumbDocument.canvasPresets.enumerated()), id: \.offset) { index, preset in
                    Button {
                        namingPreset = index
                    } label: {
                        VStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Theme.accent.opacity(0.7),
                                              style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(Theme.surfaceRaised.opacity(0.6)))
                                .aspectRatio(CGFloat(preset.width) / CGFloat(preset.height),
                                             contentMode: .fit)
                                .frame(height: 64)
                                .overlay {
                                    Image(systemName: "plus")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Theme.accent)
                                }
                            Text(preset.name)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The starter templates, rendered live — click one and it's yours.
    private var templateRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Start from a template")
            HStack(spacing: 12) {
                ForEach(ThumbTemplates.starters(), id: \.name) { template in
                    Button {
                        createFromTemplate(template.name, template.document)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            DocPreview(document: template.document)
                                .frame(height: 92)
                            Text(template.name)
                                .font(.caption)
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var gallerySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Your designs")
                Text("\(designs.count)")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                Button {
                    NSWorkspace.shared.open(Paths.thumbLabRoot)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textFaint)
                .help("Every design is a file in this folder")
            }
            if designs.isEmpty {
                Text("Nothing yet — start blank or grab a template above.")
                    .font(.caption)
                    .foregroundStyle(Theme.textFaint)
                    .padding(.vertical, 18)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 280),
                                             spacing: 14)],
                          spacing: 14) {
                    ForEach(designs) { design in
                        designCard(design)
                    }
                }
            }
        }
    }

    private func designCard(_ design: StandaloneThumbStore.Design) -> some View {
        Button {
            store = StandaloneThumbStore(fileURL: design.url)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                LabPreview(url: design.url)
                    .frame(height: 120)
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(design.name)
                            .font(.caption)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text("\(design.width)×\(design.height) · \(design.modifiedAt.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }
            .padding(8)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Duplicate") { duplicateDesign(design) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([design.url])
            }
            Divider()
            Button("Delete", role: .destructive) { deleteDesign(design) }
        }
    }

    // MARK: - Actions

    private func createDesign() {
        let preset = ThumbDocument.canvasPresets[namingPreset ?? 0]
        store = StandaloneThumbStore.create(
            named: draftName, width: preset.width, height: preset.height)
        draftName = ""
        namingPreset = nil
        designs = StandaloneThumbStore.designs()
    }

    private func createFromTemplate(_ name: String, _ document: ThumbDocument) {
        let created = StandaloneThumbStore.create(
            named: name, width: document.width, height: document.height)
        created.applyThumbDoc(document, action: nil)
        store = created
        designs = StandaloneThumbStore.designs()
    }

    private func duplicateDesign(_ design: StandaloneThumbStore.Design) {
        var copy = design.name + " copy"
        var target = Paths.thumbLabRoot.appendingPathComponent("\(copy).json")
        var suffix = 2
        while FileManager.default.fileExists(atPath: target.path) {
            copy = design.name + " copy \(suffix)"
            target = Paths.thumbLabRoot.appendingPathComponent("\(copy).json")
            suffix += 1
        }
        try? FileManager.default.copyItem(at: design.url, to: target)
        designs = StandaloneThumbStore.designs()
    }

    private func deleteDesign(_ design: StandaloneThumbStore.Design) {
        try? FileManager.default.removeItem(at: design.url)
        if store?.fileURL == design.url { store = nil }
        designs = StandaloneThumbStore.designs()
    }
}

/// A live render of a design file at gallery size.
private struct LabPreview: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.4))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) {
            let fileURL = url
            image = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let data = try? Data(contentsOf: fileURL),
                      var doc = try? JSONDecoder().decode(ThumbDocument.self, from: data)
                else { return nil }
                doc.width = max(64, doc.width / 4)
                doc.height = max(36, doc.height / 4)
                return ThumbnailRenderer.render(doc) { spec in
                    let path = spec.useCutout ? (spec.cutoutPath ?? spec.path) : spec.path
                    return NSImage(contentsOfFile: path)
                }
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
            Rectangle().fill(Color.black.opacity(0.4))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task {
            var doc = document
            image = await Task.detached(priority: .utility) { () -> NSImage? in
                doc.width = max(64, doc.width / 4)
                doc.height = max(36, doc.height / 4)
                return ThumbnailRenderer.render(doc) { spec in
                    let path = spec.useCutout ? (spec.cutoutPath ?? spec.path) : spec.path
                    return path.isEmpty ? nil : NSImage(contentsOfFile: path)
                }
            }.value
        }
    }
}

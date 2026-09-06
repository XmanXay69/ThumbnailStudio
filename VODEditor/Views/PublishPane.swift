import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Packaging surface: pick a still, write the text over it, and get the titles
/// and description that go with it.
struct PublishPane: View {
    @ObservedObject var session: ProjectSession
    @State private var copied: String?
    @State private var selectedLayerID: UUID?
    @State private var overlayPrompt = ""

    private var draft: ThumbnailDraft { session.project.thumbnail }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            frameStrip.frame(width: 210)
            composer
            ideasColumn.frame(width: 300)
        }
        .onAppear {
            if session.frames.isEmpty, !session.shorts.isEmpty { session.extractFrames() }
        }
    }

    // MARK: - Frames

    private var frameStrip: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel(text: "Moments")
                Spacer()
                Button {
                    session.extractFrames()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textFaint)
                .help("Pull fresh stills from the highest-scoring moments")
                .disabled(session.isExtractingFrames)
            }
            .padding(10)

            Divider().overlay(Theme.border)

            if session.isExtractingFrames {
                VStack(spacing: 8) {
                    ProgressView(value: session.frameProgress).tint(Theme.accent)
                    Text("Pulling frames… \(Int(session.frameProgress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(12)
            }

            if session.frames.isEmpty, !session.isExtractingFrames {
                VStack(spacing: 8) {
                    Text("No stills yet")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                    Button("Pull frames") { session.extractFrames() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .disabled(session.shorts.isEmpty)
                    if session.shorts.isEmpty {
                        Text("Run the shorts analysis first — the stills come from the moments it rated highest.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textFaint)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(session.frames) { frame in
                            frameRow(frame)
                                .onTapGesture { session.selectThumbnailFrame(frame.time) }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        
    }

    private func frameRow(_ frame: FrameCandidate) -> some View {
        let isSelected = draft.frameTime.map { abs($0 - frame.time) < 0.3 } ?? false
        return VStack(alignment: .leading, spacing: 3) {
            if let image = NSImage(contentsOf: frame.url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(16.0 / 9.0, contentMode: .fill)
                    .frame(height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Text(frame.time.timecode)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(isSelected ? Theme.accent : Theme.textFaint)
        }
        .padding(5)
        .background(isSelected ? Theme.accent.opacity(0.16) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.7) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Composer

    private var composer: some View {
        ScrollView { composerContent }
    }

    private var composerContent: some View {
        VStack(spacing: 10) {
            ZStack {
                Rectangle().fill(Color.black)
                if let background = session.thumbnailBackgroundURL,
                   let image = NSImage(contentsOf: background) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                    LayerStack(layers: draft.layers,
                               selected: $selectedLayerID,
                               onMove: { layer in session.updateLayer(layer) })
                    ThumbnailTextOverlay(text: draft.text, style: draft.style)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.system(size: 32))
                            .foregroundStyle(Theme.textFaint)
                        Text("Pick a moment on the left")
                            .font(.callout)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxHeight: 540)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            

            HStack(spacing: 8) {
                TextField("Thumbnail text", text: Binding(
                    get: { draft.text },
                    set: { var updated = draft; updated.text = $0; session.updateThumbnail(updated) }
                ))
                .textFieldStyle(.roundedBorder)

                Button {
                    presentSavePanel()
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(session.thumbnailBackgroundURL == nil)
            }

            if let error = session.publishError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let path = session.lastThumbnailPath {
                HStack(spacing: 6) {
                    Text("Saved \(URL(fileURLWithPath: path).lastPathComponent), plus a 1080×1920 cover")
                        .font(.caption2)
                        .foregroundStyle(Theme.positive)
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    Spacer()
                }
            }

            layersPanel

            ThumbnailStyleControls(
                style: Binding(
                    get: { draft.style },
                    set: { var updated = draft; updated.style = $0; session.updateThumbnail(updated) }
                )
            )
            .panel()
        }
    }

    // MARK: - Layers

    private var layersPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Layers")
                Spacer()
                Button {
                    addLayerFile()
                } label: {
                    Label("Add image…", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("Your logo, a facecam grab, a sticker — drop it in and drag it on the preview. PNG keeps its transparency; SVG stays sharp at any size.")
                .font(.caption2)
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(draft.layers.reversed()) { layer in
                layerRow(layer)
            }

            Divider().overlay(Theme.border)

            VStack(alignment: .leading, spacing: 6) {
                Text("Design an overlay with Claude")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                TextField("e.g. a red \"NEW\" burst, top-right", text: $overlayPrompt)
                    .textFieldStyle(.roundedBorder)
                Text("Copy the prompt into a claude.ai chat (covered by your plan); Claude replies with vector art, which is sanitized and rendered on your machine when you paste it back.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                ManualClaudePanel(
                    makePrompt: {
                        let brief = overlayPrompt.trimmingCharacters(in: .whitespaces)
                        return brief.isEmpty ? nil : session.overlayPrompt(brief: brief)
                    },
                    notReadyText: "Describe the overlay first — that's what Claude draws.",
                    apply: { try session.applyOverlayReply($0, name: overlayPrompt) }
                )
            }
        }
        .panel()
    }

    private func layerRow(_ layer: ThumbnailLayer) -> some View {
        let isSelected = selectedLayerID == layer.id
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: layer.origin == .designed ? "sparkles" : "photo")
                    .font(.system(size: 10))
                    .foregroundStyle(layer.origin == .designed ? Theme.accent : Theme.textFaint)
                Text(layer.displayName)
                    .font(.caption)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Button { session.moveLayer(layer, up: true) } label: {
                    Image(systemName: "chevron.up").font(.system(size: 9))
                }.buttonStyle(.plain).foregroundStyle(Theme.textFaint)
                Button { session.moveLayer(layer, up: false) } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }.buttonStyle(.plain).foregroundStyle(Theme.textFaint)
                Button { session.removeLayer(layer) } label: {
                    Image(systemName: "trash").font(.system(size: 9))
                }.buttonStyle(.plain).foregroundStyle(Theme.textFaint)
            }

            if isSelected {
                LabeledContent("Size") {
                    Slider(value: binding(layer, \.width), in: 0.05...1.2)
                }
                LabeledContent("Opacity") {
                    Slider(value: binding(layer, \.opacity), in: 0.1...1)
                }
                Toggle("Flip horizontally", isOn: binding(layer, \.flipped))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        }
        .font(.caption)
        .padding(6)
        .background(isSelected ? Theme.accent.opacity(0.14) : Theme.surfaceRaised.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { selectedLayerID = isSelected ? nil : layer.id }
    }

    private func binding<T>(_ layer: ThumbnailLayer, _ path: WritableKeyPath<ThumbnailLayer, T>) -> Binding<T> {
        Binding(
            get: { layer[keyPath: path] },
            set: { var updated = layer; updated[keyPath: path] = $0; session.updateLayer(updated) }
        )
    }

    private func addLayerFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedFileTypes = LayerRasterizer.supportedExtensions
        panel.message = "Choose an image to lay over the thumbnail"
        if let last = UserDefaults.standard.string(forKey: "lastLayerFolder") {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "lastLayerFolder")
        session.addThumbnailLayer(from: url)
    }


    // MARK: - Ideas

    private var ideasColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Titles and copy")
                    Text("The whole packaging set — titles, hooks, thumbnail text, description, tags — from one prompt. Copy it into a claude.ai chat (covered by your plan) and paste the reply back.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                    ManualClaudePanel(
                        makePrompt: { session.ideasPrompt() },
                        notReadyText: "This project has no transcript yet.",
                        apply: { try session.applyIdeasReply($0) }
                    )
                    if let pack = session.ideas {
                        Text("From the \(pack.scopeLabel)")
                            .font(.caption2)
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                .panel()

                if let pack = session.ideas {
                    titleList(pack)
                    if !pack.thumbnailTexts.isEmpty { thumbnailTextList(pack) }
                    if !pack.hooks.isEmpty { hookList(pack) }
                    descriptionBlock(pack)
                    imageBlock(pack)
                }
            }
            .padding(2)
        }
    }

    private func titleList(_ pack: IdeaPack) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Titles")
            ForEach(pack.titles) { title in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .top, spacing: 6) {
                        Text(title.text)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        copyButton(title.text)
                    }
                    HStack(spacing: 6) {
                        Text("\(title.length) chars")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(title.fitsSearchResults ? Theme.textFaint : Theme.warning)
                        if !title.fitsSearchResults {
                            Text("truncates in search")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.warning)
                        }
                    }
                    Text(title.why)
                        .font(.caption2)
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
                .background(Theme.surfaceRaised.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .panel()
    }

    private func thumbnailTextList(_ pack: IdeaPack) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Thumbnail text")
            ForEach(pack.thumbnailTexts, id: \.self) { text in
                Button {
                    var updated = draft
                    updated.text = text
                    session.updateThumbnail(updated)
                } label: {
                    HStack {
                        Text(text)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(draft.text == text ? Theme.accent : Theme.textPrimary)
                        Spacer()
                    }
                    .padding(6)
                    .background(Theme.surfaceRaised.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
        .panel()
    }

    private func hookList(_ pack: IdeaPack) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Short-form hooks")
            ForEach(pack.hooks, id: \.self) { hook in
                HStack(alignment: .top, spacing: 6) {
                    Text("• \(hook)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    copyButton(hook)
                }
            }
        }
        .panel()
    }

    private func descriptionBlock(_ pack: IdeaPack) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(text: "Description")
                Spacer()
                copyButton(pack.descriptionText)
            }
            Text(pack.descriptionText)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if !pack.tags.isEmpty {
                Divider().overlay(Theme.border)
                HStack {
                    SectionLabel(text: "Tags")
                    Spacer()
                    copyButton(pack.tags.joined(separator: ", "))
                }
                Text(pack.tags.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .panel()
    }

    private func imageBlock(_ pack: IdeaPack) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Generated background")
            Text("A real frame from the stream is free and truthful, and for gameplay it usually beats an illustration of something that didn't happen. This is the fallback.")
                .font(.caption2)
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)

            Text(pack.imagePrompt)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pack.imagePrompt, forType: .string)
            } label: {
                Label("Copy image prompt", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Text("Paste it into any image generator you already pay for, save the picture, and add it with “Add image…” above — nothing is billed from here.")
                .font(.caption2)
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panel()
    }

    private func copyButton(_ value: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = value
        } label: {
            Image(systemName: copied == value ? "checkmark" : "doc.on.doc")
                .font(.system(size: 9))
        }
        .buttonStyle(.plain)
        .foregroundStyle(copied == value ? Theme.positive : Theme.textFaint)
    }

    private func presentSavePanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.jpeg]
        panel.nameFieldStringValue = "thumbnail.jpg"
        panel.message = "Export thumbnail (1280×720, plus a 1080×1920 cover beside it)"
        if let last = UserDefaults.standard.string(forKey: "lastThumbnailFolder") {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "lastThumbnailFolder")
        session.exportThumbnail(to: url)
    }
}

/// The layers drawn over the frame, draggable to reposition.
///
/// Positions are fractions of the frame, so what's dragged here in a small
/// preview lands in the same place in the 1280×720 render.
private struct LayerStack: View {
    let layers: [ThumbnailLayer]
    @Binding var selected: UUID?
    let onMove: (ThumbnailLayer) -> Void

    var body: some View {
        GeometryReader { geometry in
            ForEach(layers) { layer in
                if layer.isVisible, let image = NSImage(contentsOf: layer.url) {
                    let width = geometry.size.width * layer.width
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: width)
                        .scaleEffect(x: layer.flipped ? -1 : 1)
                        .opacity(layer.opacity)
                        .position(x: geometry.size.width * layer.centerX,
                                  y: geometry.size.height * layer.centerY)
                        .overlay {
                            if selected == layer.id {
                                Rectangle().stroke(Theme.accent, lineWidth: 1.5)
                                    .frame(width: width, height: width * aspect(image))
                                    .position(x: geometry.size.width * layer.centerX,
                                              y: geometry.size.height * layer.centerY)
                            }
                        }
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    guard geometry.size.width > 0 else { return }
                                    selected = layer.id
                                    var moved = layer
                                    moved.centerX = min(1, max(0, value.location.x / geometry.size.width))
                                    moved.centerY = min(1, max(0, value.location.y / geometry.size.height))
                                    onMove(moved)
                                }
                        )
                }
            }
        }
    }

    private func aspect(_ image: NSImage) -> CGFloat {
        image.size.width > 0 ? image.size.height / image.size.width : 1
    }
}

/// WYSIWYG thumbnail text, mirroring what `ThumbnailService` writes into ASS.
struct ThumbnailTextOverlay: View {
    let text: String
    let style: ThumbnailTextStyle

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.height / CGFloat(ThumbnailDraft.horizontalSize.height)
            let size = max(8, CGFloat(style.fontSize) * scale)
            let rendered = style.uppercase ? text.uppercased() : text

            if !rendered.trimmingCharacters(in: .whitespaces).isEmpty {
                content(rendered, size: size, scale: scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    .padding(.top, style.position.isTop ? CGFloat(style.marginVertical) * scale : 0)
                    .padding(.bottom, style.position.isBottom ? CGFloat(style.marginVertical) * scale : 0)
                    .padding(.leading, style.position.isLeading ? CGFloat(style.marginHorizontal) * scale : 0)
                    .padding(.trailing, style.position.isTrailing ? CGFloat(style.marginHorizontal) * scale : 0)
            }
        }
        .allowsHitTesting(false)
    }

    private var alignment: Alignment {
        switch style.position {
        case .topLeft: return .topLeading
        case .top: return .top
        case .topRight: return .topTrailing
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        case .bottomLeft: return .bottomLeading
        case .bottom: return .bottom
        case .bottomRight: return .bottomTrailing
        }
    }

    private var textAlignment: TextAlignment {
        if style.position.isLeading { return .leading }
        if style.position.isTrailing { return .trailing }
        return .center
    }

    @ViewBuilder
    private func content(_ rendered: String, size: CGFloat, scale: CGFloat) -> some View {
        let wrapped = ThumbnailService.wrap(rendered, limit: style.maxCharactersPerLine)
            .joined(separator: "\n")
        let body = Text(wrapped)
            .font(.custom(style.fontName, size: size))
            .multilineTextAlignment(textAlignment)
            .lineLimit(nil)

        if style.useBox {
            body
                .foregroundColor(style.fill.swiftUIColor)
                .padding(.horizontal, 14 * scale)
                .padding(.vertical, 8 * scale)
                .background(style.boxColor.swiftUIColor)
        } else {
            body
                .foregroundColor(style.fill.swiftUIColor)
                .background(outline(wrapped, size: size, scale: scale))
        }
    }

    /// libass strokes the glyphs; stamping the text behind itself in eight
    /// directions is the closest a plain SwiftUI `Text` gets.
    private func outline(_ wrapped: String, size: CGFloat, scale: CGFloat) -> some View {
        let width = max(0, style.outlineWidth * scale)
        return ZStack {
            if width > 0 {
                ForEach(0..<8, id: \.self) { index in
                    let angle = Double(index) / 8 * 2 * .pi
                    Text(wrapped)
                        .font(.custom(style.fontName, size: size))
                        .multilineTextAlignment(textAlignment)
                        .foregroundColor(style.outline.swiftUIColor)
                        .offset(x: CGFloat(cos(angle)) * width, y: CGFloat(sin(angle)) * width)
                }
            }
        }
    }
}

private struct ThumbnailStyleControls: View {
    @Binding var style: ThumbnailTextStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Thumbnail text style")

            HStack(spacing: 10) {
                Picker("Font", selection: $style.fontName) {
                    if !FontCatalog.suggested.isEmpty {
                        Section("Suggested") {
                            ForEach(FontCatalog.suggested, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Section("All installed") {
                        ForEach(FontCatalog.installed, id: \.self) { Text($0).tag($0) }
                    }
                }
                .frame(maxWidth: 220)

                Picker("Position", selection: $style.position) {
                    ForEach(ThumbnailTextPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(maxWidth: 180)
            }

            HStack(spacing: 14) {
                LabeledContent("Size") {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(style.fontSize) },
                            set: { style.fontSize = Int($0) }
                        ), in: 40...260, step: 5)
                        Text("\(style.fontSize)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 28)
                    }
                }
                LabeledContent("Outline") {
                    Slider(value: $style.outlineWidth, in: 0...20, step: 0.5)
                }
            }

            HStack(spacing: 14) {
                ColorPicker("Fill", selection: Binding(
                    get: { style.fill.swiftUIColor },
                    set: { style.fill = CaptionColor($0) }
                ), supportsOpacity: false)
                ColorPicker("Outline", selection: Binding(
                    get: { style.outline.swiftUIColor },
                    set: { style.outline = CaptionColor($0) }
                ), supportsOpacity: false)
                Toggle("Box", isOn: $style.useBox)
                    .toggleStyle(.switch)
                Toggle("Uppercase", isOn: $style.uppercase)
                    .toggleStyle(.switch)
            }

            HStack(spacing: 14) {
                LabeledContent("Wrap at") {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(style.maxCharactersPerLine) },
                            set: { style.maxCharactersPerLine = Int($0) }
                        ), in: 6...30, step: 1)
                        Text("\(style.maxCharactersPerLine)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 22)
                    }
                }
                LabeledContent("Margin") {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(style.marginVertical) },
                            set: { style.marginVertical = Int($0); style.marginHorizontal = Int($0) }
                        ), in: 10...220, step: 5)
                        Text("\(style.marginVertical)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 28)
                    }
                }
            }
        }
        .font(.caption)
        .controlSize(.small)
    }
}

import SwiftUI
import AppKit

extension ThumbnailStudioPane {
    /// Contextual by rule: a control that does not apply to what is selected is
    /// not dimmed, it is absent. With nothing selected you get the document;
    /// with a layer you get that layer's own sections and nothing else.
    var inspector: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let layer = selectedLayer {
                        transformSection(layer)
                        StudioDivider()
                        kindSection(layer)
                    } else if selection.count > 1 {
                        multiSelectionSection
                    } else {
                        documentSection
                    }
                }
                .padding(.horizontal, Studio.Space.m)
                .padding(.vertical, Studio.Space.s)
            }
            if let error = store.thumbStudioError {
                StudioDivider()
                Text(error)
                    .font(Studio.Typo.caption)
                    .foregroundStyle(Studio.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Studio.Space.m)
            }
            StudioDivider()
            HStack(spacing: Studio.Space.s) {
                Button("Review") { showReview = true }
                    .buttonStyle(.studio(.secondary, .large))
                    .help("Measure this thumbnail at the size people see it  ⌘R")
                Button("Export…") { showExport = true }
                    .buttonStyle(.studio(.primary, .large, fullWidth: true))
                    .keyboardShortcut("e", modifiers: .command)
            }
            .padding(Studio.Space.m)
        }
        .background(Studio.Palette.panel)
    }

    // MARK: - Document

    private var documentSection: some View {
        VStack(alignment: .leading, spacing: Studio.Space.s) {
            StudioSection("Canvas", symbol: "rectangle", isExpanded: expansion("canvas")) {
                StudioRow("Preset") {
                    StudioSizeMenu(document: doc) { width, height in
                        var document = doc
                        document.width = width
                        document.height = height
                        apply(document, "Canvas Size")
                    }
                }
                // Any size, not just the four presets. A banner, a Discord
                // header, whatever the platform of the month wants.
                StudioRow("Size") {
                    HStack(spacing: Studio.Space.xs) {
                        StudioNumberField(value: Binding(
                            get: { Double(doc.width) },
                            set: { value in
                                var document = doc
                                document.width = ThumbDocument.clampedDimension(value)
                                apply(document, "Canvas Size")
                            }), in: 64...8192, suffix: "W")
                        StudioNumberField(value: Binding(
                            get: { Double(doc.height) },
                            set: { value in
                                var document = doc
                                document.height = ThumbDocument.clampedDimension(value)
                                apply(document, "Canvas Size")
                            }), in: 64...8192, suffix: "H")
                    }
                }
                StudioRow("Background") {
                    HStack(spacing: Studio.Space.xs) {
                        StudioColorWell(hex: Binding(
                            get: { doc.backgroundHex ?? ThumbDocument.defaultBackgroundHex },
                            set: { value in
                                var document = doc
                                document.backgroundHex = value
                                document.transparentBackground = false
                                apply(document, "Canvas Colour")
                            }))
                            .disabled(doc.transparentBackground)
                            .opacity(doc.transparentBackground ? 0.4 : 1)
                    }
                }
                Toggle("Transparent", isOn: Binding(
                    get: { doc.transparentBackground },
                    set: { on in
                        var document = doc
                        document.transparentBackground = on
                        apply(document, "Transparent Background")
                    }))
                    .toggleStyle(.checkbox)
                    .font(Studio.Typo.body)
                    .help("Exports a PNG with real alpha. JPEG has no transparency and flattens onto white.")
            }
            StudioDivider()
            StudioSection("Guides", symbol: "ruler", isExpanded: expansion("guides")) {
                Toggle("Duration-stamp safe zone", isOn: Binding(
                    get: { editor.showSafeZone },
                    set: { editor.showSafeZone = $0 }))
                    .toggleStyle(.checkbox)
                    .font(Studio.Typo.body)
            }
            StudioDivider()
            StudioSection("Templates", symbol: "square.grid.2x2", isExpanded: expansion("templates")) {
                ForEach(ThumbTemplates.starters(), id: \.name) { template in
                    Button(template.name) { applyTemplate(template.document) }
                        .buttonStyle(.studio(.secondary, .small, fullWidth: true))
                }
                Button("Save current as template…") { saveTemplate() }
                    .buttonStyle(.studio(.ghost, .small, fullWidth: true))
            }
            if doc.layers.isEmpty {
                StudioEmptyState(symbol: "cursorarrow.rays",
                                 title: "Nothing selected",
                                 message: "Pick a tool on the left and click the canvas, or select a layer to edit it.")
                    .padding(.vertical, Studio.Space.xl)
            }
        }
    }

    private var multiSelectionSection: some View {
        VStack(alignment: .leading, spacing: Studio.Space.s) {
            StudioSection("\(selection.count) layers", symbol: "square.on.square",
                          isExpanded: .constant(true)) {
                StudioRow("Align") { alignRow(multiple: true) }
                StudioRow("Arrange") { arrangeRow(Array(selection)) }
                HStack(spacing: Studio.Space.s) {
                    Button("Duplicate") { editor.duplicateSelection() }
                        .buttonStyle(.studio(.secondary, .small))
                    Button("Delete") { editor.deleteSelection() }
                        .buttonStyle(.studio(.destructive, .small))
                }
            }
        }
    }

    // MARK: - Transform

    private func transformSection(_ layer: ThumbLayer) -> some View {
        StudioSection("Transform", symbol: "arrow.up.left.and.arrow.down.right",
                      isExpanded: expansion("transform")) {
            StudioRow("Align") { alignRow(multiple: false) }
            StudioRow("Arrange") { arrangeRow([layer.id]) }
            // Typed, in pixels. Dragging gets you close; a number gets you
            // exactly where you meant, and lets you line two designs up.
            StudioRow("Position") {
                HStack(spacing: Studio.Space.xs) {
                    StudioNumberField(value: pixelBinding(layer.id, \.x,
                                                          span: Double(doc.width),
                                                          action: "Move Layer"),
                                      in: 0...Double(doc.width), suffix: "X")
                    StudioNumberField(value: pixelBinding(layer.id, \.y,
                                                          span: Double(doc.height),
                                                          action: "Move Layer"),
                                      in: 0...Double(doc.height), suffix: "Y")
                }
            }
            StudioRow("Size") {
                HStack(spacing: Studio.Space.xs) {
                    StudioNumberField(value: pixelBinding(layer.id, \.widthFraction,
                                                          span: Double(doc.width),
                                                          action: "Resize Layer"),
                                      in: 8...Double(doc.width) * 2, suffix: "W")
                    if case .shape = layer.kind {
                        StudioNumberField(value: pixelBinding(layer.id, \.heightFraction,
                                                              span: Double(doc.height),
                                                              action: "Resize Layer"),
                                          in: 8...Double(doc.height) * 2, suffix: "H")
                    } else {
                        // Text and images derive their height from their
                        // content, so it is shown rather than edited.
                        Text("\(Int(layerHeightFraction(layer, width: nil) * Double(doc.height))) H")
                            .font(Studio.Typo.numeric)
                            .foregroundStyle(Studio.Palette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .help("Height follows the content — change the size or the text")
                    }
                }
            }
            StudioRow("Scale") {
                StudioValueSlider(value: layerBinding(layer.id, \.widthFraction, "Resize Layer"),
                                  in: 0.05...1.4) { "\(Int($0 * 100))%" }
            }
            StudioRow("Rotation") {
                StudioValueSlider(value: layerBinding(layer.id, \.rotationDegrees, "Rotate Layer"),
                                  in: -180...180) { String(format: "%.0f°", $0) }
            }
            StudioRow("Opacity") {
                StudioValueSlider(value: layerBinding(layer.id, \.opacity, "Layer Opacity"),
                                  in: 0.05...1) { "\(Int($0 * 100))%" }
            }
            StudioRow("Blend") {
                StudioSegmented(selection: layerBinding(layer.id, \.blendMode, "Blend Mode"),
                                options: [("normal", "Normal"), ("multiply", "Multiply"),
                                          ("screen", "Screen"), ("overlay", "Overlay")])
            }
        }
    }

    private func alignRow(multiple: Bool) -> some View {
        HStack(spacing: Studio.Space.xxs) {
            alignButton(.left, nil, "align.horizontal.left")
            alignButton(.center, nil, "align.horizontal.center")
            alignButton(.right, nil, "align.horizontal.right")
            Rectangle().fill(Studio.Palette.separator).frame(width: 1, height: 12)
            alignButton(nil, .top, "align.vertical.top")
            alignButton(nil, .middle, "align.vertical.center")
            alignButton(nil, .bottom, "align.vertical.bottom")
        }
    }

    private func alignButton(_ horizontal: ThumbDocument.HorizontalAlign?,
                             _ vertical: ThumbDocument.VerticalAlign?,
                             _ icon: String) -> some View {
        StudioIconButton(icon, help: "Align", size: .small) {
            var document = doc
            for layer in doc.layers where selection.contains(layer.id) {
                document.align(layerID: layer.id, horizontal: horizontal, vertical: vertical,
                               drawnHeightFraction: layerHeightFraction(layer, width: nil))
            }
            apply(document, "Align Layer")
        }
    }

    private func arrangeRow(_ ids: [UUID]) -> some View {
        HStack(spacing: Studio.Space.xxs) {
            arrangeButton(ids, .toBack, "square.3.layers.3d.bottom.filled", "Send to back  ⌥⌘[")
            arrangeButton(ids, .backward, "square.2.layers.3d.bottom.filled", "Send backward  ⌘[")
            arrangeButton(ids, .forward, "square.2.layers.3d.top.filled", "Bring forward  ⌘]")
            arrangeButton(ids, .toFront, "square.3.layers.3d.top.filled", "Bring to front  ⌥⌘]")
        }
    }

    private func arrangeButton(_ ids: [UUID], _ direction: ThumbDocument.LayerMove,
                               _ icon: String, _ help: String) -> some View {
        StudioIconButton(icon, help: help, size: .small) {
            var document = doc
            var changed = false
            for id in ids where document.move(layerID: id, direction) { changed = true }
            guard changed else { return }
            apply(document, help.components(separatedBy: "  ").first ?? "Arrange")
        }
    }

    // MARK: - Per-kind

    @ViewBuilder
    private func kindSection(_ layer: ThumbLayer) -> some View {
        switch layer.kind {
        case .text(let spec): textInspector(layer.id, spec)
        case .image(let spec): imageInspector(layer.id, spec)
        case .shape(let spec): shapeInspector(layer.id, spec)
        }
    }

    private func textInspector(_ id: UUID, _ spec: TextSpec) -> some View {
        VStack(alignment: .leading, spacing: Studio.Space.s) {
            StudioSection("Text", symbol: "textformat", isExpanded: expansion("text")) {
                TextField("Text", text: textBinding(id, spec, \.text, "Edit Text"), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Studio.Typo.body)
                    .lineLimit(1...4)
                    .padding(Studio.Space.xs)
                    .background(RoundedRectangle(cornerRadius: Studio.Radius.field,
                                                 style: .continuous)
                        .fill(Studio.Palette.control))
                    .focused($editingTextLayer, equals: id)
                    .onExitCommand { editingTextLayer = nil }
                StudioRow("Font") {
                    HStack(spacing: Studio.Space.xs) {
                        StudioFontMenu(selection: textBinding(id, spec, \.fontName, "Font"))
                        StudioFontStar(family: spec.fontName)
                    }
                }
                // Only offered when the family actually has faces to choose
                // between, which most system families do and most single-face
                // display fonts do not.
                let faces = ThumbFonts.faces(in: spec.fontName)
                if faces.count > 1 {
                    StudioRow("Weight") {
                        Menu {
                            ForEach(faces, id: \.self) { face in
                                Button(face) {
                                    mutateText(id, "Font Weight") { $0.fontFace = face }
                                }
                            }
                        } label: {
                            Text(spec.fontFace ?? faces.first ?? "Regular")
                                .font(Studio.Typo.body)
                                .lineLimit(1)
                        }
                        .menuStyle(.borderlessButton)
                        .frame(height: Studio.Metric.controlS)
                    }
                }
                if let note = ThumbFonts.substitution(for: spec) {
                    Text(note)
                        .font(Studio.Typo.caption)
                        .foregroundStyle(Studio.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Both of these were honoured by the renderer already and had
                // no control anywhere — dead model surface.
                StudioRow("Align") {
                    StudioSegmented(selection: textBinding(id, spec, \.alignment, "Text Align"),
                                    options: [("left", "Left"), ("center", "Centre"),
                                              ("right", "Right")])
                }
                StudioRow("Line height") {
                    StudioValueSlider(
                        value: textBinding(id, spec, \.lineHeightMultiple, "Line Height"),
                        in: 0.6...2.0) { String(format: "%.2f×", $0) }
                }
                Toggle("All caps", isOn: textBinding(id, spec, \.uppercase, "All Caps"))
                    .toggleStyle(.checkbox)
                    .font(Studio.Typo.body)
                StudioRow("Size") {
                    StudioValueSlider(value: textBinding(id, spec, \.sizeFraction, "Text Size"),
                                      in: 0.04...0.4) { "\(Int($0 * Double(doc.height))) px" }
                }
                StudioRow("Spacing") {
                    StudioValueSlider(value: textBinding(id, spec, \.letterSpacing, "Letter Spacing"),
                                      in: -4...20) { String(format: "%.0f", $0) }
                }
                StudioRow("Fill") {
                    StudioColorWell(hex: textBinding(id, spec, \.fillHex, "Text Fill"))
                }
                StudioRow("Image fill") {
                    HStack(spacing: Studio.Space.xs) {
                        Button(spec.imageFillPath == nil ? "Choose…" : "Replace…") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.png, .jpeg, .image]
                            panel.message = "Show this image through the letters"
                            guard panel.runModal() == .OK, let url = panel.url else { return }
                            let path = ThumbLibrary.adopt(url) ?? url.path
                            mutateText(id, "Text Image Fill") { $0.imageFillPath = path }
                        }
                        .buttonStyle(.studio(.secondary, .small))
                        if spec.imageFillPath != nil {
                            Button("Clear") {
                                mutateText(id, "Clear Image Fill") { $0.imageFillPath = nil }
                            }
                            .buttonStyle(.studio(.ghost, .small))
                        }
                    }
                }
                .help("Fills the letters with a picture. Overrides the gradient.")
                // A fill image that cannot be read falls back to the flat
                // colour, which looks exactly like the feature not working.
                // Say so rather than leaving the user to guess.
                if let path = spec.imageFillPath, !path.isEmpty,
                   !FileManager.default.fileExists(atPath: path) {
                    Text("That fill image is missing — the letters fall back to the flat colour.")
                        .font(Studio.Typo.caption)
                        .foregroundStyle(Studio.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                StudioRow("Gradient") {
                    HStack(spacing: Studio.Space.s) {
                        Toggle("", isOn: Binding(
                            get: { spec.gradientHex != nil },
                            set: { on in
                                mutateText(id, "Text Gradient") {
                                    $0.gradientHex = on ? "FFD60A" : nil
                                }
                            }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        if spec.gradientHex != nil {
                            StudioColorWell(hex: Binding(
                                get: { spec.gradientHex ?? "FFD60A" },
                                set: { value in
                                    mutateText(id, "Gradient Colour") { $0.gradientHex = value }
                                }))
                        }
                    }
                }
            }
            StudioDivider()
            StudioSection("Outline & shadow", symbol: "shadow", isExpanded: expansion("texteffects")) {
                StudioRow("Stroke") {
                    StudioColorWell(hex: textBinding(id, spec, \.strokeHex, "Text Stroke"))
                }
                StudioRow("Width") {
                    StudioValueSlider(value: textBinding(id, spec, \.strokeWidth, "Stroke Width"),
                                      in: 0...30) { String(format: "%.0f", $0) }
                }
                Toggle("Drop shadow", isOn: textBinding(id, spec, \.shadowEnabled, "Text Shadow"))
                    .toggleStyle(.checkbox)
                    .font(Studio.Typo.body)
                Toggle("Highlight box", isOn: textBinding(id, spec, \.boxEnabled, "Text Box"))
                    .toggleStyle(.checkbox)
                    .font(Studio.Typo.body)
                if spec.boxEnabled {
                    StudioRow("Box colour") {
                        StudioColorWell(hex: textBinding(id, spec, \.boxHex, "Box Colour"))
                    }
                }
                HStack(spacing: Studio.Space.s) {
                    Button("Copy style") { ThumbStyleClipboard.spec = spec }
                        .buttonStyle(.studio(.ghost, .small))
                    Button("Paste style") {
                        guard let copied = ThumbStyleClipboard.spec else { return }
                        mutateText(id, "Paste Style") { target in
                            var restyled = copied
                            restyled.text = target.text
                            target = restyled
                        }
                    }
                    .buttonStyle(.studio(.ghost, .small))
                    .disabled(ThumbStyleClipboard.spec == nil)
                }
            }
        }
    }

    private func shapeInspector(_ id: UUID, _ spec: ShapeSpec) -> some View {
        StudioSection("Shape", symbol: "square.on.circle", isExpanded: expansion("shape")) {
            StudioRow("Fill") {
                StudioColorWell(hex: Binding(
                    get: { spec.fillHex ?? "FF0000" },
                    set: { value in mutateShape(id, "Shape Fill") { $0.fillHex = value } }))
            }
            StudioRow("Gradient") {
                HStack(spacing: Studio.Space.s) {
                    Toggle("", isOn: Binding(
                        get: { spec.fillGradientHex != nil },
                        set: { on in
                            mutateShape(id, "Shape Gradient") {
                                $0.fillGradientHex = on ? ($0.fillHex ?? "FF0000") : nil
                            }
                        }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    if spec.fillGradientHex != nil {
                        StudioColorWell(hex: Binding(
                            get: { spec.fillGradientHex ?? "FF0000" },
                            set: { value in
                                mutateShape(id, "Gradient Colour") { $0.fillGradientHex = value }
                            }))
                    }
                }
            }
            if spec.fillGradientHex != nil {
                StudioRow("Angle") {
                    StudioValueSlider(value: shapeBinding(id, spec, \.gradientAngleDegrees,
                                                          "Gradient Angle"),
                                      in: 0...360) { String(format: "%.0f°", $0) }
                }
            }
            StudioRow("Stroke") {
                StudioColorWell(hex: shapeBinding(id, spec, \.strokeHex, "Shape Stroke"))
            }
            StudioRow("Width") {
                StudioValueSlider(value: shapeBinding(id, spec, \.strokeWidth, "Shape Stroke"),
                                  in: 0...20) { String(format: "%.0f", $0) }
            }
            if spec.shape == "rectangle" {
                StudioRow("Corner") {
                    StudioValueSlider(value: shapeBinding(id, spec, \.cornerRadius, "Corner Radius"),
                                      in: 0...80) { String(format: "%.0f", $0) }
                }
            }
            if spec.shape == "polygon" || spec.shape == "star" {
                StudioRow("Points") {
                    Stepper("\(spec.sides)", value: Binding(
                        get: { spec.sides },
                        set: { value in mutateShape(id, "Polygon Sides") { $0.sides = value } }
                    ), in: 3...16)
                    .font(Studio.Typo.numeric)
                }
            }
            cutControls(edge: shapeBinding(id, spec, \.cutEdge, "Diagonal Cut"),
                        amount: shapeBinding(id, spec, \.cutAmount, "Cut Depth"),
                        flip: shapeBinding(id, spec, \.cutFlip, "Cut Direction"),
                        currentEdge: spec.cutEdge)
        }
    }

    /// The diagonal-cut row both inspectors share: pick an edge, set the slant
    /// depth, flip which corner it leans from.
    @ViewBuilder
    func cutControls(edge: Binding<String>, amount: Binding<Double>,
                     flip: Binding<Bool>, currentEdge: String) -> some View {
        StudioRow("Cut", help: "Slant one edge — the split-thumbnail look. Pair a cut image with a cut colour panel.") {
            StudioSegmented(selection: edge,
                            options: [("none", "Off"), ("left", "◀"), ("right", "▶"),
                                      ("top", "▲"), ("bottom", "▼")])
        }
        if currentEdge != "none" {
            StudioRow("Slant") {
                HStack(spacing: Studio.Space.xs) {
                    StudioValueSlider(value: amount, in: 0.05...0.6) {
                        "\(Int($0 * 100))%"
                    }
                    StudioIconButton("arrow.up.arrow.down", help: "Lean the other way",
                                     isActive: flip.wrappedValue, size: .small) {
                        flip.wrappedValue.toggle()
                    }
                }
            }
        }
    }

    // MARK: - Inspector section expansion, remembered between launches

    func expansion(_ key: String) -> Binding<Bool> {
        Binding(
            get: {
                UserDefaults.standard.object(forKey: "inspector.\(key)") as? Bool
                    ?? !Self.collapsedByDefault.contains(key)
            },
            set: { UserDefaults.standard.set($0, forKey: "inspector.\(key)") }
        )
    }

    private static var collapsedByDefault: Set<String> {
        ["adjustments", "texteffects", "templates", "guides"]
    }

    /// A fractional layer property, edited in canvas pixels. The document
    /// stores fractions so a design renders at any size; the inspector talks
    /// pixels because that is what the user is looking at.
    func pixelBinding(_ id: UUID, _ path: WritableKeyPath<ThumbLayer, Double>,
                      span: Double, action: String) -> Binding<Double> {
        Binding(
            get: {
                let layer = doc.layers.first { $0.id == id }
                return (layer?[keyPath: path] ?? 0) * span
            },
            set: { pixels in
                mutateLayer(id, action) { $0[keyPath: path] = pixels / max(1, span) }
            }
        )
    }

    // MARK: - Bindings

    func layerBinding<T>(_ id: UUID, _ path: WritableKeyPath<ThumbLayer, T>,
                         _ action: String) -> Binding<T> {
        Binding(
            get: {
                (doc.layers.first { $0.id == id } ?? ThumbLayer(kind: .text(TextSpec())))[keyPath: path]
            },
            set: { value in mutateLayer(id, action) { $0[keyPath: path] = value } }
        )
    }

    func textBinding<T>(_ id: UUID, _ current: TextSpec,
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

    func imageBinding<T>(_ id: UUID, _ current: ImageSpec,
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

    func shapeBinding<T>(_ id: UUID, _ current: ShapeSpec,
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

/// The canvas-size chooser, kept out of the inspector body because it is the
/// one control that reflows the whole document.
struct StudioSizeMenu: View {
    let document: ThumbDocument
    let onPick: (Int, Int) -> Void

    var body: some View {
        Menu {
            ForEach(ThumbDocument.canvasPresets, id: \.name) { preset in
                Button(preset.name) { onPick(preset.width, preset.height) }
            }
        } label: {
            Text("\(document.width) × \(document.height)")
                .font(Studio.Typo.numeric)
        }
        .menuStyle(.borderlessButton)
        .frame(height: Studio.Metric.controlS)
    }
}

/// Font picking. Only lists what is installed — offering a font the renderer
/// cannot draw is how the inspector ended up claiming "Anton" while the canvas
/// drew system heavy.
struct StudioFontMenu: View {
    @Binding var selection: String

    @ObservedObject private var favourites = ThumbFavourites.shared

    var body: some View {
        Menu {
            // Starred first. Four hundred installed families is a scroll, and
            // a channel uses three of them.
            if !favourites.fonts.isEmpty {
                Section("Starred") {
                    ForEach(favourites.fonts, id: \.self) { name in
                        Button(name) { selection = name }
                    }
                }
            }
            Section("Thumbnail picks") {
                ForEach(ThumbFonts.picks, id: \.self) { name in
                    Button(name) { selection = name }
                }
            }
            Section("All installed") {
                ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { name in
                    Button(name) { selection = name }
                }
            }
        } label: {
            Text(selection)
                .font(Studio.Typo.body)
                .foregroundStyle(ThumbFonts.isInstalled(selection)
                                 ? Studio.Palette.textPrimary : Studio.Palette.warning)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .frame(height: Studio.Metric.controlS)
    }
}

/// Stars the family the selected layer is using. Sits beside the font menu
/// rather than inside it: a menu row that toggles a star has to close the menu
/// to show you it worked, which is the opposite of what you wanted.
struct StudioFontStar: View {
    let family: String

    @ObservedObject private var favourites = ThumbFavourites.shared

    var body: some View {
        Button {
            favourites.toggleFont(family)
        } label: {
            Image(systemName: favourites.hasFont(family) ? "star.fill" : "star")
                .font(Studio.Typo.iconSmall)
                .foregroundStyle(favourites.hasFont(family)
                                 ? Studio.Palette.accent : Studio.Palette.textTertiary)
        }
        .buttonStyle(.plain)
        .frame(width: Studio.Metric.controlXS, height: Studio.Metric.controlS)
        .help(favourites.hasFont(family)
              ? "Unstar \(family)" : "Star \(family) so it stays at the top of the font menu")
    }
}

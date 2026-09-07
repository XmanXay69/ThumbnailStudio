import SwiftUI
import AppKit

extension ThumbnailStudioPane {
    func imageInspector(_ id: UUID, _ spec: ImageSpec) -> some View {
        VStack(alignment: .leading, spacing: Studio.Space.s) {
            StudioSection("Image", symbol: "photo", isExpanded: expansion("image")) {
                HStack(spacing: Studio.Space.s) {
                    Button("Replace…") { setImageFile(for: id) }
                        .buttonStyle(.studio(.secondary, .small))
                    StudioIconButton("arrow.left.and.right.righttriangle.left.righttriangle.right",
                                     help: "Flip horizontally", size: .small) {
                        mutateImage(id, "Flip") { $0.flippedHorizontally.toggle() }
                    }
                    StudioIconButton("crop", help: "Crop & cut", size: .small) {
                        croppingLayerID = id
                    }
                    .disabled(spec.path.isEmpty)
                    if spec.crop != nil {
                        Button("Clear crop") { mutateImage(id, "Clear Crop") { $0.crop = nil } }
                            .buttonStyle(.studio(.ghost, .small))
                    }
                }
                StudioRow("Frame") {
                    StudioSegmented(selection: imageBinding(id, spec, \.maskShape, "Image Frame"),
                                    options: [("none", "None"), ("rounded", "Rounded"),
                                              ("circle", "Circle")])
                }
                if spec.maskShape == "rounded" {
                    StudioRow("Corner") {
                        StudioValueSlider(value: imageBinding(id, spec, \.maskCornerRadius,
                                                             "Corner Radius"),
                                          in: 4...120) { String(format: "%.0f", $0) }
                    }
                }
                if spec.maskShape != "none" || spec.borderWidth > 0 {
                    StudioRow("Border") {
                        StudioValueSlider(value: imageBinding(id, spec, \.borderWidth,
                                                             "Border Width"),
                                          in: 0...30) { String(format: "%.0f", $0) }
                    }
                    StudioRow("Colour") {
                        StudioColorWell(hex: imageBinding(id, spec, \.borderHex, "Border Colour"))
                    }
                }
                cutControls(edge: imageBinding(id, spec, \.cutEdge, "Diagonal Cut"),
                            amount: imageBinding(id, spec, \.cutAmount, "Cut Depth"),
                            flip: imageBinding(id, spec, \.cutFlip, "Cut Direction"),
                            currentEdge: spec.cutEdge)
                Toggle("Drop shadow", isOn: imageBinding(id, spec, \.shadowEnabled, "Image Shadow"))
                    .toggleStyle(.checkbox)
                    .font(Studio.Typo.body)
            }

            StudioDivider()
            cutoutSection(id, spec)

            StudioDivider()
            StudioSection("Adjustments", symbol: "dial.medium",
                          isExpanded: expansion("adjustments")) {
                ForEach([("Brightness", \ImageSpec.brightness),
                         ("Contrast", \ImageSpec.contrast),
                         ("Saturation", \ImageSpec.saturation),
                         ("Exposure", \ImageSpec.exposure),
                         ("Vibrance", \ImageSpec.vibrance)], id: \.0) { name, path in
                    StudioRow(name) {
                        StudioValueSlider(value: Binding(
                            get: { spec[keyPath: path] },
                            set: { value in mutateImage(id, name) { $0[keyPath: path] = value } }
                        ), in: -1...1) { String(format: "%+.2f", $0) }
                    }
                }
                StudioRow("Filter") {
                    StudioSegmented(selection: imageBinding(id, spec, \.filterPreset,
                                                           "Filter Preset"),
                                    options: [("none", "None"), ("mono", "Mono"),
                                              ("chrome", "Chrome"), ("fade", "Fade"),
                                              ("noir", "Noir")])
                }
            }
        }
    }

    /// Background removal, where the user can actually find it — and with the
    /// three controls that decide whether a cutout looks lifted or looks
    /// pasted. Changing any of them re-lifts; results are cached per setting,
    /// so going back to a value you already tried is instant.
    @ViewBuilder
    private func cutoutSection(_ id: UUID, _ spec: ImageSpec) -> some View {
        StudioSection("Background", symbol: "person.and.background.dotted",
                      isExpanded: expansion("cutout")) {
            if spec.cutoutPath == nil {
                Button {
                    store.removeBackground(layerID: id)
                } label: {
                    if store.isCuttingOut {
                        HStack(spacing: Studio.Space.s) {
                            ProgressView().controlSize(.small)
                            Text("Lifting the subject…")
                        }
                    } else {
                        Text("Remove background")
                    }
                }
                .buttonStyle(.studio(.primary, .medium, fullWidth: true))
                .disabled(store.isCuttingOut || spec.path.isEmpty)
                Text("Runs on this Mac — nothing is uploaded. Works best on a clear subject; fine hair, glass and motion blur are where it struggles.")
                    .font(Studio.Typo.caption)
                    .foregroundStyle(Studio.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Toggle("Use cutout", isOn: Binding(
                    get: { spec.useCutout },
                    set: { on in
                        mutateImage(id, "Toggle Cutout") { $0.useCutout = on }
                        AdjustedImageCache.shared.invalidate()
                    }))
                    .toggleStyle(.switch)
                    .font(Studio.Typo.body)
                if spec.useCutout {
                    StudioRow("Edge in") {
                        StudioValueSlider(value: cutoutBinding(id, spec, \.cutoutContract),
                                          in: 0...6) { String(format: "%.1f px", $0) }
                    }
                    StudioRow("Soften") {
                        StudioValueSlider(value: cutoutBinding(id, spec, \.cutoutFeather),
                                          in: 0...6) { String(format: "%.1f px", $0) }
                    }
                    StudioRow("Harden") {
                        StudioValueSlider(value: cutoutBinding(id, spec, \.cutoutContrast),
                                          in: 0...1) { "\(Int($0 * 100))%" }
                    }
                    StudioRow("Outline") {
                        StudioValueSlider(value: imageBinding(id, spec, \.strokeWidth,
                                                             "Cutout Outline"),
                                          in: 0...24) { String(format: "%.0f", $0) }
                    }
                    if spec.strokeWidth > 0.5 {
                        StudioRow("Colour") {
                            StudioColorWell(hex: imageBinding(id, spec, \.strokeHex,
                                                             "Outline Colour"))
                        }
                    }
                    subjectPicker(id, spec)
                    Button("Redo cutout") { store.removeBackground(layerID: id) }
                        .buttonStyle(.studio(.ghost, .small, fullWidth: true))
                        .disabled(store.isCuttingOut)
                }
            }
        }
    }

    /// Only offered when there is genuinely more than one subject — a picker
    /// with one option is a control that teaches the user nothing.
    @ViewBuilder
    private func subjectPicker(_ id: UUID, _ spec: ImageSpec) -> some View {
        let count = CutoutSubjectCount.shared.count(for: spec.path)
        if count > 1 {
            StudioRow("Subject") {
                StudioSegmented(selection: Binding(
                    get: { spec.cutoutInstance ?? -1 },
                    set: { value in
                        mutateImage(id, "Cutout Subject") {
                            $0.cutoutInstance = value < 0 ? nil : value
                        }
                        store.removeBackground(layerID: id)
                    }),
                    options: [(-1, "All")] + (0..<count).map { ($0, "\($0 + 1)") })
            }
        }
    }

    /// Edge settings re-lift on release rather than on every tick — Vision is
    /// fast but not 60-times-a-second fast.
    private func cutoutBinding(_ id: UUID, _ spec: ImageSpec,
                               _ path: WritableKeyPath<ImageSpec, Double>) -> Binding<Double> {
        Binding(
            get: {
                if case .image(let current)? = doc.layers.first(where: { $0.id == id })?.kind {
                    return current[keyPath: path]
                }
                return spec[keyPath: path]
            },
            set: { value in
                mutateImage(id, "Cutout Edge") { $0[keyPath: path] = value }
                CutoutDebounce.shared.schedule(id: id) { store.removeBackground(layerID: id) }
            }
        )
    }
}

/// Vision's subject count, asked once per file. The answer never changes for a
/// given path, and asking costs a full segmentation pass.
@MainActor
final class CutoutSubjectCount {
    static let shared = CutoutSubjectCount()
    private var cache: [String: Int] = [:]
    private var inFlight: Set<String> = []

    func count(for path: String) -> Int {
        guard !path.isEmpty else { return 0 }
        if let hit = cache[path] { return hit }
        guard !inFlight.contains(path) else { return 0 }
        inFlight.insert(path)
        Task.detached(priority: .utility) {
            let found = CutoutService.subjectCount(in: URL(fileURLWithPath: path))
            await MainActor.run {
                self.cache[path] = found
                self.inFlight.remove(path)
            }
        }
        return 0
    }
}

/// Dragging an edge slider should re-lift once, when you stop — not forty
/// times on the way there.
@MainActor
final class CutoutDebounce {
    static let shared = CutoutDebounce()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func schedule(id: UUID, _ work: @escaping () -> Void) {
        tasks[id]?.cancel()
        tasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            work()
            self?.tasks[id] = nil
        }
    }
}

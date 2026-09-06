import SwiftUI
import AppKit

/// The crop tool: the full image with a draggable, resizable window over
/// it, aspect presets for the shapes that matter to a thumbnail, and a
/// rule-of-thirds grid while you work. Returns a NormalizedRect (top-based,
/// like everything else in the app) or nil for "no crop".
struct CropSheet: View {
    struct Result {
        var crop: NormalizedRect?
        var cutEdge: String
        var cutAmount: Double
        var cutFlip: Bool
    }

    let image: NSImage
    let initial: NormalizedRect?
    var initialCut: (edge: String, amount: Double, flip: Bool) = ("none", 0.22, false)
    let onApply: (Result) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var crop = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    @State private var aspect: Double?    // nil = free
    @State private var dragStart: NormalizedRect?
    @State private var cutEdge = "none"
    @State private var cutAmount = 0.22
    @State private var cutFlip = false

    private let presets: [(label: String, ratio: Double?)] = [
        ("Free", nil), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16),
        ("1:1", 1), ("4:5", 0.8),
    ]

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Crop & cut")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Picker("", selection: $aspect) {
                    ForEach(presets, id: \.label) { preset in
                        Text(preset.label).tag(preset.ratio)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                .onChange(of: aspect) { _, ratio in
                    if let ratio { snapToAspect(ratio) }
                }
                Spacer()
                Button("Reset") {
                    crop = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
                    aspect = nil
                    cutEdge = "none"
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // The slant, edited right where the crop is — the bright window
            // previews exactly what will render.
            HStack(spacing: 8) {
                Text("Cut")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Picker("", selection: $cutEdge) {
                    Text("None").tag("none")
                    Image(systemName: "arrowtriangle.left").tag("left")
                    Image(systemName: "arrowtriangle.right").tag("right")
                    Image(systemName: "arrowtriangle.up").tag("top")
                    Image(systemName: "arrowtriangle.down").tag("bottom")
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
                if cutEdge != "none" {
                    Slider(value: $cutAmount, in: 0.05...0.6)
                        .frame(maxWidth: 180)
                    Toggle(isOn: $cutFlip) {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Lean the slant the other way")
                }
                Spacer()
            }

            GeometryReader { geo in
                let fit = fittedFrame(in: geo.size)
                ZStack(alignment: .topLeading) {
                    // The image, dimmed; the crop window shows it at full
                    // brightness through a second, clipped copy.
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: fit.width, height: fit.height)
                        .opacity(0.35)
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: fit.width, height: fit.height)
                        .clipShape(windowShape(in: fit))

                    // Window chrome: border, thirds, handles.
                    let window = cropRect(in: fit)
                    windowShape(in: fit)
                        .stroke(Theme.accent, lineWidth: 1.5)
                    thirdsGrid(in: window)
                    ForEach(Corner.allCases, id: \.self) { corner in
                        handle(corner, window: window, fit: fit)
                    }
                }
                .frame(width: fit.width, height: fit.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .contentShape(Rectangle())
                .gesture(moveGesture(fit: fit))
            }
            .frame(minHeight: 360)

            HStack {
                Text(cropSummary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Apply") {
                    let full = crop.width > 0.99 && crop.height > 0.99
                    onApply(Result(crop: full ? nil : crop.clamped(),
                                   cutEdge: cutEdge, cutAmount: cutAmount,
                                   cutFlip: cutFlip))
                    dismiss()
                }
                .buttonStyle(HeroButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 680, height: 540)
        .background(Theme.background)
        .onAppear {
            if let initial { crop = initial }
            cutEdge = initialCut.edge
            cutAmount = initialCut.amount
            cutFlip = initialCut.flip
        }
    }

    // MARK: - Geometry

    private func fittedFrame(in available: CGSize) -> CGSize {
        let ratio = image.size.width / max(1, image.size.height)
        let width = min(available.width, available.height * ratio)
        return CGSize(width: width, height: width / ratio)
    }

    private func cropRect(in fit: CGSize) -> CGRect {
        CGRect(x: crop.x * fit.width, y: crop.y * fit.height,
               width: crop.width * fit.width, height: crop.height * fit.height)
    }

    private var cropSummary: String {
        let w = Int(crop.width * image.size.width)
        let h = Int(crop.height * image.size.height)
        return "\(w)×\(h) px"
    }

    private func snapToAspect(_ ratio: Double) {
        // Keep the centre, fit the largest window of that aspect inside.
        let imageRatio = image.size.width / max(1, image.size.height)
        var w = crop.width
        var h = w * imageRatio / ratio
        if h > 1 { h = 1; w = h * ratio / imageRatio }
        let cx = crop.x + crop.width / 2
        let cy = crop.y + crop.height / 2
        crop = NormalizedRect(x: min(max(0, cx - w / 2), 1 - w),
                              y: min(max(0, cy - h / 2), 1 - h),
                              width: w, height: h)
    }

    // MARK: - Gestures

    private func moveGesture(fit: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? crop
                dragStart = start
                var next = start
                next.x = min(max(0, start.x + value.translation.width / fit.width),
                             1 - start.width)
                next.y = min(max(0, start.y + value.translation.height / fit.height),
                             1 - start.height)
                crop = next
            }
            .onEnded { _ in dragStart = nil }
    }

    private enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    private func handle(_ corner: Corner, window: CGRect, fit: CGSize) -> some View {
        let point: CGPoint = {
            switch corner {
            case .topLeft: return CGPoint(x: window.minX, y: window.minY)
            case .topRight: return CGPoint(x: window.maxX, y: window.minY)
            case .bottomLeft: return CGPoint(x: window.minX, y: window.maxY)
            case .bottomRight: return CGPoint(x: window.maxX, y: window.maxY)
            }
        }()
        return Circle()
            .fill(Theme.accent)
            .frame(width: 11, height: 11)
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStart ?? crop
                        dragStart = start
                        resize(corner, from: start,
                               dx: value.translation.width / fit.width,
                               dy: value.translation.height / fit.height)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }

    private func resize(_ corner: Corner, from start: NormalizedRect,
                        dx: Double, dy: Double) {
        var next = start
        switch corner {
        case .topLeft:
            next.x = start.x + dx; next.y = start.y + dy
            next.width = start.width - dx; next.height = start.height - dy
        case .topRight:
            next.y = start.y + dy
            next.width = start.width + dx; next.height = start.height - dy
        case .bottomLeft:
            next.x = start.x + dx
            next.width = start.width - dx; next.height = start.height + dy
        case .bottomRight:
            next.width = start.width + dx; next.height = start.height + dy
        }
        // Aspect lock rides the width.
        if let ratio = aspect {
            let imageRatio = image.size.width / max(1, image.size.height)
            next.height = next.width * imageRatio / ratio
            if corner == .topLeft || corner == .topRight {
                next.y = start.y + start.height - next.height
            }
        }
        guard next.width > 0.08, next.height > 0.08 else { return }
        next.x = min(max(0, next.x), 1 - next.width)
        next.y = min(max(0, next.y), 1 - next.height)
        guard next.x + next.width <= 1.001, next.y + next.height <= 1.001 else { return }
        crop = next
    }

    /// The crop window with the cut applied — one Path used for both the
    /// bright-region clip and the border, so the preview IS the render.
    private func windowShape(in fit: CGSize) -> Path {
        let rect = cropRect(in: fit)
        guard cutEdge != "none" else { return Path { $0.addRect(rect) } }
        let clamped = min(0.9, max(0.02, cutAmount))
        // Visual-space corners (y down).
        var tl = CGPoint(x: rect.minX, y: rect.minY)
        var tr = CGPoint(x: rect.maxX, y: rect.minY)
        var br = CGPoint(x: rect.maxX, y: rect.maxY)
        var bl = CGPoint(x: rect.minX, y: rect.maxY)
        let dx = clamped * rect.width
        let dy = clamped * rect.height
        switch cutEdge {
        case "right": if cutFlip { br.x -= dx } else { tr.x -= dx }
        case "left": if cutFlip { bl.x += dx } else { tl.x += dx }
        case "top": if cutFlip { tl.y += dy } else { tr.y += dy }
        case "bottom": if cutFlip { bl.y -= dy } else { br.y -= dy }
        default: break
        }
        return Path { path in
            path.move(to: tl)
            path.addLine(to: tr)
            path.addLine(to: br)
            path.addLine(to: bl)
            path.closeSubpath()
        }
    }

    private func thirdsGrid(in window: CGRect) -> some View {
        Path { path in
            for fraction in [1.0 / 3, 2.0 / 3] {
                path.move(to: CGPoint(x: window.minX + window.width * fraction, y: window.minY))
                path.addLine(to: CGPoint(x: window.minX + window.width * fraction, y: window.maxY))
                path.move(to: CGPoint(x: window.minX, y: window.minY + window.height * fraction))
                path.addLine(to: CGPoint(x: window.maxX, y: window.minY + window.height * fraction))
            }
        }
        .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
    }
}

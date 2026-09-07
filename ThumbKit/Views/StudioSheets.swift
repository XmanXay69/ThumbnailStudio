import SwiftUI
import AppKit

/// Export as its own step, not a permanent panel in the object inspector.
/// Shows the real encoded size, because the only export question that ever
/// bites is YouTube's 2 MB cap.
struct ExportSheet: View {
    let document: ThumbDocument
    let image: NSImage?

    @Environment(\.dismiss) private var dismiss
    @State private var asPNG = false
    @State private var quality = 0.85
    @State private var bytes: Int?

    private var overCap: Bool { (bytes ?? 0) > 2_000_000 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Export")
                    .font(Studio.Typo.title)
                    .foregroundStyle(Studio.Palette.textPrimary)
                Spacer()
                Text("\(document.width) × \(document.height)")
                    .font(Studio.Typo.numeric)
                    .foregroundStyle(Studio.Palette.textTertiary)
            }
            .padding(.horizontal, Studio.Space.l)
            .frame(height: Studio.Metric.topBarHeight)
            .background(Studio.Palette.panel)
            StudioDivider()

            ZStack {
                Studio.Palette.windowBackground
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(Studio.Space.l)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            StudioDivider()
            VStack(alignment: .leading, spacing: Studio.Space.s) {
                StudioRow("Format") {
                    StudioSegmented(selection: $asPNG,
                                    options: [(false, "JPG"), (true, "PNG")])
                }
                if !asPNG {
                    StudioRow("Quality") {
                        StudioValueSlider(value: $quality, in: 0.3...1) { "\(Int($0 * 100))%" }
                    }
                }
                HStack(spacing: Studio.Space.s) {
                    if let bytes {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(bytes),
                                                       countStyle: .file))
                            .font(Studio.Typo.numeric)
                            .foregroundStyle(overCap ? Studio.Palette.danger
                                                     : Studio.Palette.textSecondary)
                        Text(overCap ? "over YouTube's 2 MB cap" : "fits YouTube's 2 MB cap")
                            .font(Studio.Typo.caption)
                            .foregroundStyle(Studio.Palette.textTertiary)
                    }
                    if overCap, !asPNG {
                        Button("Compress to fit") {
                            if let image,
                               let fitted = ThumbnailRenderer.compressToFit(image,
                                                                            capBytes: 2_000_000) {
                                quality = fitted.quality
                                refresh()
                            }
                        }
                        .buttonStyle(.studio(.ghost, .small))
                    }
                    if overCap, asPNG {
                        Text("PNG can't hit the cap on a busy design — switch to JPG.")
                            .font(Studio.Typo.caption)
                            .foregroundStyle(Studio.Palette.textTertiary)
                    }
                    Spacer()
                }
            }
            .padding(Studio.Space.l)

            StudioDivider()
            HStack(spacing: Studio.Space.s) {
                Button("Copy image") { copyToClipboard() }
                    .buttonStyle(.studio(.ghost, .large))
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.studio(.secondary, .large))
                Button("Export…") { save() }
                    .buttonStyle(.studio(.primary, .large))
                    .disabled(image == nil)
            }
            .padding(Studio.Space.l)
            .background(Studio.Palette.panel)
        }
        .frame(width: 720, height: 620)
        .studioWindowBackground()
        .onAppear { refresh() }
        .onChange(of: asPNG) { _, _ in refresh() }
        .onChange(of: quality) { _, _ in refresh() }
    }

    private func refresh() {
        guard let image else { bytes = nil; return }
        bytes = ThumbnailRenderer.encoded(image, asPNG: asPNG, jpegQuality: quality)?.count
    }

    private func copyToClipboard() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        dismiss()
    }

    private func save() {
        guard let image,
              let data = ThumbnailRenderer.encoded(image, asPNG: asPNG,
                                                   jpegQuality: quality) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [asPNG ? .png : .jpeg]
        panel.nameFieldStringValue = "thumbnail.\(asPNG ? "png" : "jpg")"
        if let last = UserDefaults.standard.string(forKey: "lastExportFolder") {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "lastExportFolder")
        try? data.write(to: url, options: .atomic)
        dismiss()
    }
}

/// Scrub the source and grab the exact frame — the reason this studio is
/// in-house instead of Canva. It talks to a `ThumbFrameSource`, so it knows
/// nothing about projects, sessions or players.
struct FramePickerSheet: View {
    let source: any ThumbFrameSource
    @Environment(\.dismiss) private var dismiss

    @State private var time: Double = 0
    @State private var preview: NSImage?
    @State private var loading = false

    var body: some View {
        VStack(spacing: Studio.Space.m) {
            Text("Pick a frame")
                .font(Studio.Typo.title)
                .foregroundStyle(Studio.Palette.textPrimary)
            ZStack {
                Studio.Palette.windowBackground
                if let preview {
                    Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit)
                } else if loading {
                    ProgressView()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Studio.Radius.card, style: .continuous))
            HStack(spacing: Studio.Space.s) {
                Slider(value: $time, in: 0...max(1, source.frameSourceDuration)) { editing in
                    if !editing { loadPreview() }
                }
                .tint(Studio.Palette.accent)
                Text(time.timecode)
                    .font(Studio.Typo.numeric)
                    .foregroundStyle(Studio.Palette.textSecondary)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.studio(.secondary, .large))
                Spacer()
                Button("Add to canvas") {
                    Task {
                        let destination = source.frameGrabDestination(at: time)
                        try? await source.writeSourceFrame(at: time, to: destination)
                        source.addFrameToCanvas(path: destination.path, time: time)
                        dismiss()
                    }
                }
                .buttonStyle(.studio(.primary, .large))
            }
        }
        .padding(Studio.Space.l)
        .studioWindowBackground()
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

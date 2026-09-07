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

/// Pick a frame: the best ones the app can find, or scrub for yourself.
///
/// The strip is the point. The app already knows which moments matter, and
/// `FrameQuality` knows which frame within a moment is worth looking at, so
/// the common case should be picking from six good frames rather than
/// dragging a slider across four hours hoping to land on one.
struct FramePickerSheet: View {
    let source: any ThumbFrameSource
    @Environment(\.dismiss) private var dismiss

    @State private var time: Double = 0
    @State private var preview: NSImage?
    @State private var loading = false
    @State private var ranked: [RankedFramePick] = []
    @State private var findingBest = false
    @State private var searchFailed: String?
    @State private var selected: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pick a frame")
                    .font(Studio.Typo.title)
                    .foregroundStyle(Studio.Palette.textPrimary)
                Spacer()
                Text(source.frameSourceDuration.timecode)
                    .font(Studio.Typo.numeric)
                    .foregroundStyle(Studio.Palette.textTertiary)
            }
            .padding(.horizontal, Studio.Space.l)
            .frame(height: Studio.Metric.topBarHeight)
            .background(Studio.Palette.panel)
            StudioDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: Studio.Space.l) {
                    bestStrip
                    scrubber
                }
                .padding(Studio.Space.l)
            }

            StudioDivider()
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.studio(.secondary, .large))
                Spacer()
                Button("Add to canvas") { addScrubbed() }
                    .buttonStyle(.studio(.primary, .large))
            }
            .padding(Studio.Space.l)
            .background(Studio.Palette.panel)
        }
        .frame(width: 720, height: 660)
        .studioWindowBackground()
        .onAppear {
            time = source.frameSourceDuration / 2
            loadPreview()
        }
    }

    // MARK: - The ranked strip

    @ViewBuilder
    private var bestStrip: some View {
        let moments = source.suggestedMoments
        if !moments.isEmpty {
            VStack(alignment: .leading, spacing: Studio.Space.s) {
                HStack(spacing: Studio.Space.s) {
                    Text("Best frames")
                        .font(Studio.Typo.section)
                        .foregroundStyle(Studio.Palette.textTertiary)
                    Spacer()
                    if findingBest {
                        ProgressView().controlSize(.small)
                        Text("Sampling \(moments.count) moments…")
                            .font(Studio.Typo.caption)
                            .foregroundStyle(Studio.Palette.textTertiary)
                    } else if ranked.isEmpty {
                        Button("Find best frames") { findBest(moments) }
                            .buttonStyle(.studio(.secondary, .small))
                    } else {
                        Button("Search again") { findBest(moments) }
                            .buttonStyle(.studio(.ghost, .small))
                    }
                }

                if let searchFailed {
                    Text(searchFailed)
                        .font(Studio.Typo.caption)
                        .foregroundStyle(Studio.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                } else if ranked.isEmpty, !findingBest {
                    Text("Samples a spread of frames around your strongest clips and ranks them by face size, sharpness and contrast. Takes a few seconds.")
                        .font(Studio.Typo.caption)
                        .foregroundStyle(Studio.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 240),
                                                 spacing: Studio.Space.m)],
                              spacing: Studio.Space.m) {
                        ForEach(ranked) { pick in
                            rankedCard(pick)
                        }
                    }
                }
            }
        }
    }

    private func rankedCard(_ pick: RankedFramePick) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Studio.Palette.windowBackground
                if let image = NSImage(contentsOfFile: pick.path) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            VStack(alignment: .leading, spacing: Studio.Space.xxs) {
                HStack(spacing: Studio.Space.xs) {
                    Text(pick.time.timecode)
                        .font(Studio.Typo.numeric)
                        .foregroundStyle(Studio.Palette.textSecondary)
                    Spacer()
                    Text("\(Int(pick.score * 100))")
                        .font(Studio.Typo.numeric)
                        .foregroundStyle(pick.score > 0.5 ? Studio.Palette.success
                                                          : Studio.Palette.textTertiary)
                }
                Text(pick.explanation)
                    .font(Studio.Typo.caption)
                    .foregroundStyle(Studio.Palette.textTertiary)
                    .lineLimit(1)
            }
            .padding(Studio.Space.s)
        }
        .studioSelectable(isSelected: selected == pick.id)
        .contentShape(Rectangle())
        .onTapGesture {
            selected = pick.id
            source.addFrameToCanvas(path: pick.path, time: pick.time)
            dismiss()
        }
        .help("\(pick.explanation) — click to add")
    }

    private func findBest(_ moments: [Double]) {
        findingBest = true
        searchFailed = nil
        Task {
            do {
                ranked = try await source.rankedFrames(around: moments)
                if ranked.isEmpty {
                    searchFailed = "No frames came back — the source may not be reachable."
                }
            } catch {
                searchFailed = error.localizedDescription
            }
            findingBest = false
        }
    }

    // MARK: - Manual scrubbing, for when you know the moment yourself

    private var scrubber: some View {
        VStack(alignment: .leading, spacing: Studio.Space.s) {
            Text("Or scrub")
                .font(Studio.Typo.section)
                .foregroundStyle(Studio.Palette.textTertiary)
            ZStack {
                Studio.Palette.windowBackground
                if let preview {
                    Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit)
                } else if loading {
                    ProgressView()
                }
            }
            .frame(height: 220)
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
        }
    }

    private func addScrubbed() {
        Task {
            let destination = source.frameGrabDestination(at: time)
            try? await source.writeSourceFrame(at: time, to: destination)
            source.addFrameToCanvas(path: destination.path, time: time)
            dismiss()
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

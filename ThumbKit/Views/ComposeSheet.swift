import SwiftUI
import AppKit

/// Arrangements of your design, to pick from.
///
/// Every card is a real render of a real document — the same renderer that
/// writes the export — so what you click is exactly what you get. Nothing here
/// is generated: the words, the pictures and the colours are yours, and the
/// only thing that changed is where the text sits and, sometimes, how big it is.
struct ComposeSheet: View {
    let document: ThumbDocument
    /// Applied as one undoable step by the pane.
    let onApply: (ThumbDocument, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var layouts: [ThumbComposer.Layout] = []
    @State private var previews: [String: NSImage] = [:]
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            header
            StudioDivider()
            content
            StudioDivider()
            // Pinned, like the review's. A grid of ranked pictures invites you
            // to read the order as a verdict about performance, and it is not
            // one. Putting that at the bottom of a scroll view would mean it is
            // read by nobody.
            Text("Ranked by measurements of this design — brightness against the background, how much detail the text sits on, what it covers, and how much of your type size survives. Not a prediction: this app has no click-through data and does not pretend to.")
                .font(Studio.Typo.caption)
                .foregroundStyle(Studio.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Studio.Space.m)
                .background(Studio.Palette.panel)
        }
        .frame(width: 900, height: 660)
        .studioWindowBackground()
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: Studio.Space.s) {
            Text("Layouts")
                .font(Studio.Typo.title)
                .foregroundStyle(Studio.Palette.textPrimary)
            if !loading && !layouts.isEmpty {
                Text("\(layouts.count) arrangements of your text")
                    .font(Studio.Typo.caption)
                    .foregroundStyle(Studio.Palette.textTertiary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.studio(.secondary, .medium))
        }
        .padding(.horizontal, Studio.Space.l)
        .frame(height: Studio.Metric.topBarHeight)
        .background(Studio.Palette.panel)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if layouts.isEmpty {
            StudioEmptyState(
                symbol: "text.alignleft",
                title: "No text to arrange",
                message: "This places the text on your design around what is already there. Add a text layer — or unlock the one you have — and open this again.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 320),
                                             spacing: Studio.Space.l)],
                          spacing: Studio.Space.l) {
                    ForEach(layouts) { layout in
                        card(layout)
                    }
                }
                .padding(Studio.Space.l)
            }
        }
    }

    private func card(_ layout: ThumbComposer.Layout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Studio.Palette.windowBackground
                if let image = previews[layout.id] {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .aspectRatio(CGFloat(document.width) / CGFloat(max(1, document.height)),
                         contentMode: .fit)
            .clipped()

            VStack(alignment: .leading, spacing: Studio.Space.xs) {
                HStack(spacing: Studio.Space.s) {
                    Text(layout.name)
                        .font(Studio.Typo.bodyStrong)
                        .foregroundStyle(Studio.Palette.textPrimary)
                        .lineLimit(1)
                    if layout.isCurrent {
                        Text("current")
                            .font(Studio.Typo.caption)
                            .foregroundStyle(Studio.Palette.accent)
                    }
                    Spacer(minLength: 0)
                    // Labelled, not bare. A naked number stamped on a picture of
                    // an alternative reads as "this one will do better", which
                    // is a claim this app cannot make about anything.
                    Text("measured \(Int((layout.score.overall * 100).rounded()))")
                        .font(Studio.Typo.caption)
                        .monospacedDigit()
                        .foregroundStyle(Studio.Palette.textTertiary)
                }
                Text(layout.rationale)
                    .font(Studio.Typo.caption)
                    .foregroundStyle(Studio.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Studio.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .studioSelectable(isSelected: false)
        .contentShape(Rectangle())
        // Single click, deliberately. A card that needed a double click was
        // shipped once here and read as a dead control.
        .onTapGesture {
            guard !layout.isCurrent else { dismiss(); return }
            onApply(layout.document, "Apply Layout")
            dismiss()
        }
        .help(layout.isCurrent ? "This is the design you already have" : "Use this arrangement")
    }

    // MARK: - Work

    /// Reads the canvas, builds the arrangements, then renders a card for each.
    ///
    /// The renders are the expensive part and they are done at card size, not
    /// canvas size. That is free accuracy rather than a shortcut: every position
    /// in a document is a fraction, and the type scales off canvas height, so a
    /// 480-wide render is the same composition as the 1280-wide export.
    private func load() async {
        let source = document
        let provider: ThumbnailRenderer.ImageProvider = { AdjustedImageCache.shared.image(for: $0) }

        // Off the main thread now that the renderer is nonisolated: reading a
        // canvas renders it twice and walks both bitmaps.
        let found = await Task.detached(priority: .userInitiated) { () -> [ThumbComposer.Layout] in
            let reading = ThumbCanvasReader.read(source, provider: provider)
            return ThumbComposer.layouts(for: source, reading: reading, provider: provider)
        }.value
        layouts = found
        loading = false
        // Let the grid paint before the renders start, so the sheet appears
        // immediately instead of after every card is drawn.
        await Task.yield()

        for layout in found {
            var small = layout.document
            let scale = 480.0 / Double(max(1, source.width))
            small.width = ThumbDocument.clampedDimension(Double(source.width) * scale)
            small.height = ThumbDocument.clampedDimension(Double(source.height) * scale)
            if let image = await Task.detached(priority: .userInitiated, operation: {
                ThumbnailRenderer.render(small, showingPlaceholders: false, provider: provider)
            }).value {
                previews[layout.id] = image
            }
            await Task.yield()
        }
    }
}

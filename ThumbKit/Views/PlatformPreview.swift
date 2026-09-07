import SwiftUI
import AppKit

/// Your thumbnail where it will actually be seen: small, surrounded by other
/// thumbnails, next to a title, on a phone. A thumbnail is designed at
/// 1280×720 and consumed at about 360 points wide on a desktop feed and
/// smaller than that in a sidebar — which is why text that looked obvious in
/// the editor disappears in the wild.
///
/// Nothing here is fetched. The surrounding chrome is grey scaffolding whose
/// only job is to give the thumbnail a realistic size and some neighbours.
struct PlatformPreviewSheet: View {
    let document: ThumbDocument
    let image: NSImage?
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var surface = Surface.desktopFeed

    enum Surface: String, CaseIterable, Identifiable {
        case desktopFeed = "Home feed"
        case searchResult = "Search"
        case sidebar = "Up next"
        case mobileFeed = "Mobile"
        case sizes = "Size test"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            StudioDivider()
            ScrollView {
                Group {
                    switch surface {
                    case .desktopFeed: desktopFeed
                    case .searchResult: searchResults
                    case .sidebar: sidebar
                    case .mobileFeed: mobileFeed
                    case .sizes: sizeTest
                    }
                }
                .padding(Studio.Space.xl)
                .frame(maxWidth: .infinity)
            }
            StudioDivider()
            legibility
        }
        .frame(width: 900, height: 700)
        .studioWindowBackground()
    }

    private var header: some View {
        HStack(spacing: Studio.Space.m) {
            Text("Preview")
                .font(Studio.Typo.title)
                .foregroundStyle(Studio.Palette.textPrimary)
            StudioSegmented(selection: $surface,
                            options: Surface.allCases.map { ($0, $0.rawValue) })
                .frame(width: 420)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.studio(.secondary, .medium))
        }
        .padding(.horizontal, Studio.Space.l)
        .frame(height: Studio.Metric.topBarHeight)
        .background(Studio.Palette.panel)
    }

    // MARK: - The thumbnail itself, at a given width

    private func thumb(width: CGFloat) -> some View {
        let aspect = CGFloat(document.width) / CGFloat(max(1, document.height))
        return ZStack {
            Rectangle().fill(Studio.Palette.windowBackground)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: width, height: (width / aspect).rounded())
        .clipShape(RoundedRectangle(cornerRadius: min(8, width / 45), style: .continuous))
    }

    /// A neighbour in the feed. Deliberately featureless — the point is to see
    /// whether YOUR thumbnail stands out from things that are not it.
    private func neighbour(width: CGFloat, tone: Double) -> some View {
        let aspect = 16.0 / 9.0
        return VStack(alignment: .leading, spacing: Studio.Space.s) {
            RoundedRectangle(cornerRadius: min(8, width / 45), style: .continuous)
                .fill(Color(.sRGB, white: tone, opacity: 1))
                .frame(width: width, height: (width / aspect).rounded())
            metaBlock(width: width, faded: true)
        }
    }

    private func metaBlock(width: CGFloat, faded: Bool) -> some View {
        VStack(alignment: .leading, spacing: Studio.Space.xs) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Studio.Palette.textDisabled.opacity(faded ? 0.5 : 0))
                .frame(width: width * 0.85, height: 9)
            RoundedRectangle(cornerRadius: 2)
                .fill(Studio.Palette.textDisabled.opacity(faded ? 0.32 : 0))
                .frame(width: width * 0.5, height: 8)
        }
    }

    private func titleBlock(width: CGFloat, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Studio.Space.xxs) {
            Text(title)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Studio.Palette.textPrimary)
                .lineLimit(2)
                .frame(width: width, alignment: .leading)
            Text("Your channel · 12K views · 2 hours ago")
                .font(.system(size: size - 2))
                .foregroundStyle(Studio.Palette.textTertiary)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
    }

    // MARK: - Surfaces

    /// YouTube's desktop grid: roughly 360pt wide per card.
    private var desktopFeed: some View {
        let w: CGFloat = 320
        return LazyVGrid(columns: [GridItem(.fixed(w), spacing: Studio.Space.l),
                                   GridItem(.fixed(w), spacing: Studio.Space.l)],
                         spacing: Studio.Space.xl) {
            neighbour(width: w, tone: 0.20)
            VStack(alignment: .leading, spacing: Studio.Space.s) {
                thumb(width: w)
                titleBlock(width: w, size: 13)
            }
            neighbour(width: w, tone: 0.16)
            neighbour(width: w, tone: 0.23)
        }
    }

    /// A search result: a wide thumbnail with the title beside it.
    private var searchResults: some View {
        VStack(alignment: .leading, spacing: Studio.Space.l) {
            ForEach(0..<3, id: \.self) { row in
                HStack(alignment: .top, spacing: Studio.Space.m) {
                    if row == 1 {
                        thumb(width: 300)
                        titleBlock(width: 360, size: 15)
                    } else {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color(.sRGB, white: row == 0 ? 0.19 : 0.23, opacity: 1))
                            .frame(width: 300, height: 169)
                        metaBlock(width: 360, faded: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// The up-next rail, which is where thumbnails get genuinely small.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Studio.Space.m) {
            ForEach(0..<5, id: \.self) { row in
                HStack(alignment: .top, spacing: Studio.Space.s) {
                    if row == 2 {
                        thumb(width: 168)
                        titleBlock(width: 200, size: 12)
                    } else {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(.sRGB, white: 0.18 + Double(row) * 0.02, opacity: 1))
                            .frame(width: 168, height: 94)
                        metaBlock(width: 200, faded: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// A phone feed — full-bleed, and where most watch time comes from.
    private var mobileFeed: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Studio.Space.s) {
                thumb(width: 380)
                HStack(alignment: .top, spacing: Studio.Space.s) {
                    Circle().fill(Studio.Palette.control).frame(width: 32, height: 32)
                    titleBlock(width: 330, size: 14)
                }
            }
            .padding(Studio.Space.m)
            .frame(width: 412)
            .background(Studio.Palette.windowBackground)
            .clipShape(RoundedRectangle(cornerRadius: Studio.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Studio.Radius.card, style: .continuous)
                .strokeBorder(Studio.Palette.hairline, lineWidth: Studio.Metric.hairline))
        }
        .frame(maxWidth: .infinity)
    }

    /// The one that matters most: can you still read it when it is tiny.
    private var sizeTest: some View {
        VStack(alignment: .leading, spacing: Studio.Space.xl) {
            ForEach([1.0, 0.5, 0.25, 0.1], id: \.self) { scale in
                let width = CGFloat(document.width) * scale / 4
                VStack(alignment: .leading, spacing: Studio.Space.s) {
                    HStack(spacing: Studio.Space.s) {
                        Text("\(Int(scale * 100))%")
                            .font(Studio.Typo.section)
                            .foregroundStyle(Studio.Palette.textSecondary)
                        Text("\(Int(CGFloat(document.width) * scale)) px wide")
                            .font(Studio.Typo.numeric)
                            .foregroundStyle(Studio.Palette.textTertiary)
                    }
                    thumb(width: max(48, width))
                }
            }
        }
    }

    // MARK: - A measurement, not just a vibe

    private var legibility: some View {
        HStack(spacing: Studio.Space.m) {
            let report = ThumbLegibility.verdict(for: document)
            Image(systemName: report.symbol)
                .font(Studio.Typo.iconSmall)
                .foregroundStyle(report.tint)
            Text(report.message)
                .font(Studio.Typo.caption)
                .foregroundStyle(Studio.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Studio.Space.l)
        .padding(.vertical, Studio.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Studio.Palette.panel)
    }
}

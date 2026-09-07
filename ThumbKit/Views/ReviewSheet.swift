import SwiftUI
import AppKit

/// What can be measured about this thumbnail, and what it adds up to.
///
/// The number is deliberately plain and the wording is deliberately careful:
/// this is a set of observations, not a prediction. Nothing here knows how a
/// design will perform, and the sheet says so rather than implying otherwise
/// with a confident-looking gauge.
struct ReviewSheet: View {
    let document: ThumbDocument
    let image: NSImage?

    @Environment(\.dismiss) private var dismiss
    @State private var review: ThumbCritic.Review?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Review")
                    .font(Studio.Typo.title)
                    .foregroundStyle(Studio.Palette.textPrimary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.studio(.secondary, .medium))
            }
            .padding(.horizontal, Studio.Space.l)
            .frame(height: Studio.Metric.topBarHeight)
            .background(Studio.Palette.panel)
            StudioDivider()

            if let review, !review.isScoreable {
                StudioEmptyState(symbol: "checklist",
                                 title: "Nothing to review",
                                 message: review.summary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let review {
                ScrollView {
                    VStack(alignment: .leading, spacing: Studio.Space.l) {
                        headline(review)
                        ForEach(review.findings) { finding in
                            row(finding)
                        }
                    }
                    .padding(Studio.Space.l)
                }
                StudioDivider()
                // Pinned, not appended. This is the one line that stops a
                // confident-looking number being read as a forecast, and it
                // does not get to depend on whether anyone scrolls.
                Text("Measurements of this image and this document — text height at feed size, contrast, what the duration badge covers. Not a prediction: this app has no click-through data and does not pretend to.")
                    .font(Studio.Typo.caption)
                    .foregroundStyle(Studio.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Studio.Space.m)
                    .background(Studio.Palette.panel)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 620, height: 700)
        .studioWindowBackground()
        .task {
            let doc = document
            let art = image
            review = await Task.detached(priority: .userInitiated) {
                ThumbCritic.review(document: doc, image: art)
            }.value
        }
    }

    private func headline(_ review: ThumbCritic.Review) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Studio.Space.m) {
            Text("\(review.score)")
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint(for: review.score))
            VStack(alignment: .leading, spacing: Studio.Space.xxs) {
                Text("out of 100")
                    .font(Studio.Typo.caption)
                    .foregroundStyle(Studio.Palette.textTertiary)
                Text(review.summary)
                    .font(Studio.Typo.body)
                    .foregroundStyle(Studio.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func tint(for score: Int) -> Color {
        switch score {
        case 75...: return Studio.Palette.success
        case 50..<75: return Studio.Palette.warning
        default: return Studio.Palette.danger
        }
    }

    private func row(_ finding: ThumbCritic.Finding) -> some View {
        HStack(alignment: .top, spacing: Studio.Space.m) {
            Image(systemName: symbol(finding.severity))
                .font(Studio.Typo.iconSmall)
                .foregroundStyle(colour(finding.severity))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: Studio.Space.xxs) {
                HStack(spacing: Studio.Space.s) {
                    Text(finding.title)
                        .font(Studio.Typo.bodyStrong)
                        .foregroundStyle(Studio.Palette.textPrimary)
                    Spacer()
                    Text("\(Int(finding.weight * 100))% of the score")
                        .font(Studio.Typo.caption)
                        .foregroundStyle(Studio.Palette.textTertiary)
                }
                Text(finding.detail)
                    .font(Studio.Typo.caption)
                    .foregroundStyle(Studio.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Studio.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Studio.Radius.card, style: .continuous)
            .fill(Studio.Palette.panel))
    }

    private func symbol(_ severity: ThumbCritic.Finding.Severity) -> String {
        switch severity {
        case .good: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .problem: return "xmark.octagon"
        }
    }

    private func colour(_ severity: ThumbCritic.Finding.Severity) -> Color {
        switch severity {
        case .good: return Studio.Palette.success
        case .warning: return Studio.Palette.warning
        case .problem: return Studio.Palette.danger
        }
    }
}

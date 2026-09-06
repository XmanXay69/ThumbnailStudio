import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Point at an edit you like; the app measures its rhythm and maps it onto this
/// project's settings.
struct StyleMatchPanel: View {
    @ObservedObject var session: ProjectSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Match a style")
                Spacer()
                if session.styleProfile != nil, !session.isAnalyzingStyle {
                    Button("Clear") { session.clearStyleProfile() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }

            if let profile = session.styleProfile {
                summary(profile)
            } else if !session.isAnalyzingStyle {
                Text("Choose a video whose editing you want to copy — one of your own cuts, or a creator's short you like.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if session.isAnalyzingStyle {
                ProgressView(value: session.styleProgress).tint(Theme.accent)
                Text("\(session.styleStage)… \(Int(session.styleProgress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                HStack {
                    Button(session.styleProfile == nil ? "Choose video…" : "Replace…") {
                        chooseReference()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if session.styleProfile != nil {
                        Button("Apply") { session.applyStyleProfile() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                            .controlSize(.small)
                    }
                }
            }

            if !session.appliedStyleChanges.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Applied")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.positive)
                    ForEach(session.appliedStyleChanges, id: \.self) { change in
                        Text("• \(change)")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if session.styleProfile != nil {
                Text(StyleAnalyzer.limitations)
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panel()
    }

    private func summary(_ profile: StyleProfile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(profile.sourceName)
                .font(.caption)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            row("Runtime", profile.duration.shortTimecode)
            row("Frame", profile.isVertical ? "vertical \(profile.width)×\(profile.height)"
                                            : "horizontal \(profile.width)×\(profile.height)")
            row("Pacing", String(format: "%@ · %.1fs median shot", profile.pacingLabel, profile.medianShotSeconds))
            row("Cuts", String(format: "%d · %.1f/min", profile.cutCount, profile.cutsPerMinute))
            row("Shot range", String(format: "%.1f–%.1fs", profile.shortShotSeconds, profile.longShotSeconds))
            row("Silence kept", String(format: "%.0f%%", profile.silenceRatio * 100))
            row("Music bed", profile.hasMusicBed
                ? String(format: "yes, ~%.0f dB under", profile.musicLevelDB ?? 0)
                : "none")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textFaint)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
    }

    private func chooseReference() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .video]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a video whose editing style you want to copy"
        if let last = UserDefaults.standard.string(forKey: "lastStyleFolder") {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "lastStyleFolder")
        session.analyzeStyle(reference: url)
    }
}

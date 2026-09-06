import SwiftUI

/// Caption controls, reachable from every mode.
///
/// These used to live only inside the Shorts inspector behind a selected
/// candidate, which made captions effectively invisible — you could see the
/// transcript and never find a way to turn it into captions.
struct CaptionSettingsPanel: View {
    @ObservedObject var session: ProjectSession
    @Binding var styleDraft: CaptionStyle
    @Binding var showPreview: Bool
    /// Shorts and long-form each own their export button, so the delivery
    /// options only need to appear once per surface.
    var showsDeliveryOptions: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Captions")
                InfoTip("One switch for everything: off means no captions in the preview and none in the export. Captions come from the transcript — edit any line to fix a mistranscription.")
                Spacer()
                // One switch for the whole feature. Off means no captions in
                // the preview AND none in the export — a preview-only toggle
                // that silently still exported captions was a trap.
                Toggle("", isOn: Binding(
                    get: { session.project.exportSettings.captionMode != .none },
                    set: { on in
                        var settings = session.project.exportSettings
                        settings.captionMode = on ? .burned : .none
                        session.updateExportSettings(settings)
                        showPreview = on
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }

            if showsDeliveryOptions {
                Divider().overlay(Theme.border)
                deliverySection
            }

            Divider().overlay(Theme.border)

            CaptionStyleControls(style: $styleDraft) {
                session.updateCaptionStyle(styleDraft)
            }
        }
        .panel()
    }

    private var deliverySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("In exports", selection: Binding(
                get: { session.project.exportSettings.captionMode },
                set: { mode in
                    var settings = session.project.exportSettings
                    settings.captionMode = mode
                    session.updateExportSettings(settings)
                    if mode != .none { showPreview = true }
                }
            )) {
                ForEach(CaptionMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)

            HStack(spacing: 5) {
                InfoTip(captionModeHelp)
                Text(session.project.exportSettings.captionMode.label)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textFaint)
            }


            HStack(spacing: 12) {
                Toggle("SRT file", isOn: Binding(
                    get: { session.project.exportSettings.writeSRTSidecar },
                    set: { value in
                        var settings = session.project.exportSettings
                        settings.writeSRTSidecar = value
                        session.updateExportSettings(settings)
                    }
                ))
                Toggle("VTT file", isOn: Binding(
                    get: { session.project.exportSettings.writeVTTSidecar },
                    set: { value in
                        var settings = session.project.exportSettings
                        settings.writeVTTSidecar = value
                        session.updateExportSettings(settings)
                    }
                ))
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            InfoTip("Sidecar files are written next to the video with the same name.")

        }
        .font(.caption)
    }

    private var captionModeHelp: String {
        switch session.project.exportSettings.captionMode {
        case .none:
            return "No captions in the video file."
        case .burned:
            return "Drawn into the pixels — always visible. What TikTok, Reels and Shorts expect, since their players don't offer a subtitle toggle."
        case .soft:
            return "A separate track the viewer can switch off. YouTube reads and indexes it; shorts platforms generally ignore it."
        case .both:
            return "Burned in for shorts platforms, plus a toggleable track for YouTube."
        }
    }
}

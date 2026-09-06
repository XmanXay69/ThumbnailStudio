import SwiftUI

/// Measures how far your voice sits above the game, and lets you move it.
///
/// The measurement is what makes this more than three sliders: the numbers come
/// from the transcript's own word timings, so "background" means the level when
/// whisper heard nobody talking — not a guess from a level detector.
struct AudioTuningPanel: View {
    @ObservedObject var session: ProjectSession

    private var tuning: AudioTuning { session.project.audioTuning }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Audio tuning")
                Spacer()
                if session.audioProfile != nil, !session.isMeasuringAudio {
                    Button("Clear") { session.clearAudioProfile() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }

            if let profile = session.audioProfile {
                measurement(profile)
            } else if !session.isMeasuringAudio {
                Text("Measures your voice against the game using the transcript's word timings, then balances them at export.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if session.isMeasuringAudio {
                ProgressView(value: session.audioProgress).tint(Theme.accent)
                Text("\(session.audioStage)… \(Int(session.audioProgress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                HStack {
                    Button(session.audioProfile == nil ? "Measure" : "Re-measure") {
                        session.measureAudio()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!session.canTuneAudio)

                    if session.audioProfile != nil {
                        Button("Apply suggested") { session.applyRecommendedTuning() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                            .controlSize(.small)
                    }
                }
            }

            if let error = session.audioError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(Theme.border)

            controls

            if tuning.enabled {
                Divider().overlay(Theme.border)
                verification
            }

            if session.audioProfile != nil {
                Text(AudioTuner.limitations)
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panel()
    }

    // MARK: - Measurement

    private func measurement(_ profile: AudioProfile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(String(format: "%.1f dB", profile.voiceToBackgroundDB))
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(colour(for: profile))
                Text("voice above game, in band")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            Text(profile.verdict)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            row("You talking", String(format: "%.1f dB", profile.voiceBandSpeechDB))
            row("Game, in band", String(format: "%.1f dB in gaps", profile.voiceBandBackgroundDB))
            row("Under your voice", String(format: "%.1f dB out of band", profile.outOfBandSpeechDB))
            row("Clarity", String(format: "%.1f dB — what tuning moves", profile.clarityDB))
            row("Measured over", String(format: "%.0f min talking · %.0f min gaps",
                                        profile.speechSeconds / 60, profile.backgroundSeconds / 60))
        }
    }

    private func colour(for profile: AudioProfile) -> Color {
        guard profile.isReliable else { return Theme.textSecondary }
        switch profile.voiceToBackgroundDB {
        case ..<4: return Theme.danger
        case 4..<AudioProfile.comfortableMarginDB: return Theme.warning
        default: return Theme.positive
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Tune audio on export", isOn: binding(\.enabled))
                .toggleStyle(.switch)
                .controlSize(.small)

            if tuning.enabled {
                LabeledContent("Duck background") {
                    HStack {
                        Slider(value: binding(\.duckDB), in: 0...15, step: 1)
                        Text(String(format: "%.0f dB", tuning.duckDB))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 40)
                    }
                }
                Text("Applied to everything outside 200–3600 Hz while you're talking: engine noise, explosions, music low end.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("Voice presence") {
                    HStack {
                        Slider(value: binding(\.presenceDB), in: -3...8, step: 1)
                        Text(String(format: "%+.0f dB", tuning.presenceDB))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 40)
                    }
                }

                Toggle("Normalize loudness", isOn: binding(\.normalize))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                if tuning.normalize {
                    Picker("Target", selection: binding(\.targetLUFS)) {
                        Text("−14 LUFS · YouTube, TikTok").tag(-14.0)
                        Text("−16 LUFS · podcast").tag(-16.0)
                        Text("−23 LUFS · broadcast").tag(-23.0)
                    }
                    .pickerStyle(.menu)
                }
            }
        }
        .font(.caption)
    }

    // MARK: - Verification

    private var verification: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let preview = session.audioPreview {
                HStack(spacing: 6) {
                    Text(String(format: "clarity %.1f → %.1f dB", preview.before.clarityDB,
                                preview.after.clarityDB))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                    Text(String(format: "%+.1f", preview.improvementDB))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(preview.improvementDB > 0.5 ? Theme.positive : Theme.warning)
                    Spacer()
                }
                Text(String(format: "In-band ratio moved %+.1f dB — it isn't supposed to move, and a large number here means something is squashing the dynamics.",
                            preview.inBandChangeDB))
                    .font(.caption2)
                    .foregroundStyle(abs(preview.inBandChangeDB) > 1 ? Theme.warning : Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Measured on a rendered \(Int(preview.sampleDuration))s sample from \(preview.sampleStart.timecode) — the stretch with the most of both talking and not talking.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Check on a sample") { session.previewTuning() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(session.isMeasuringAudio || !session.canTuneAudio)
        }
    }

    // MARK: - Plumbing

    private func binding<T>(_ path: WritableKeyPath<AudioTuning, T>) -> Binding<T> {
        Binding(
            get: { session.project.audioTuning[keyPath: path] },
            set: { value in
                var updated = session.project.audioTuning
                updated[keyPath: path] = value
                session.updateAudioTuning(updated)
            }
        )
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textFaint)
                .frame(width: 104, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
    }
}

import SwiftUI
import AppKit

struct DependencyReport {
    var ffmpeg: URL?
    var ffprobe: URL?
    var whisper: URL?
    var model: WhisperModel?
    /// Only needed to download from a pasted link; opening a local file doesn't
    /// touch it, so it never blocks startup.
    var ytdlp: URL?
    var fullDiskAccess: Bool

    /// Full Disk Access is a warning, not a hard requirement — plenty of folders
    /// are readable without it.
    var allSatisfied: Bool { ffmpeg != nil && ffprobe != nil && whisper != nil && model != nil }

    static func current() -> DependencyReport {
        DependencyReport(
            ffmpeg: ToolLocator.locate("ffmpeg"),
            ffprobe: ToolLocator.locate("ffprobe"),
            whisper: ToolLocator.locate("whisper-cli"),
            model: ToolLocator.preferredModel(),
            ytdlp: ToolLocator.locate("yt-dlp"),
            fullDiskAccess: ToolLocator.hasFullDiskAccess
        )
    }
}

struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var report = DependencyReport.current()

    private var modelsFolder: String { Paths.modelsRoot.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DependencyRow(
                        title: "ffmpeg",
                        detail: report.ffmpeg?.path ?? "Not found",
                        satisfied: report.ffmpeg != nil,
                        fix: "brew install ffmpeg"
                    )
                    DependencyRow(
                        title: "ffprobe",
                        detail: report.ffprobe?.path ?? "Not found",
                        satisfied: report.ffprobe != nil,
                        fix: "brew install ffmpeg"
                    )
                    DependencyRow(
                        title: "whisper-cli",
                        detail: report.whisper?.path ?? "Not found",
                        satisfied: report.whisper != nil,
                        fix: "brew install whisper-cpp"
                    )
                    DependencyRow(
                        title: "yt-dlp",
                        detail: report.ytdlp?.path ?? "Not found — only needed for pasted links",
                        satisfied: report.ytdlp != nil,
                        fix: "brew install yt-dlp"
                    )
                    DependencyRow(
                        title: "Whisper model",
                        detail: report.model.map { "\($0.displayName) · \(ByteCountFormatter.string(fromByteCount: $0.sizeBytes, countStyle: .file))" }
                            ?? "No ggml-*.bin in models folder",
                        satisfied: report.model != nil,
                        fix: "curl -L -o \"\(modelsFolder)/ggml-large-v3-turbo.bin\" https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
                    )
                    DependencyRow(
                        title: "Max-accuracy model (optional)",
                        detail: ToolLocator.hasAccurateModel
                            ? "Full large-v3 installed — Max accuracy re-transcribe is available"
                            : "Full large-v3 not installed — Max accuracy re-transcribe is greyed out. ~3 GB, roughly 3–4× slower than turbo, measurably fewer mishearings on fast stream speech.",
                        satisfied: ToolLocator.hasAccurateModel,
                        fix: "curl -L -o \"\(modelsFolder)/ggml-large-v3.bin\" https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin"
                    )

                    Divider().overlay(Theme.border)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: report.fullDiskAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(report.fullDiskAccess ? Theme.positive : Theme.warning)
                            Text("Full Disk Access")
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            if !report.fullDiskAccess {
                                Button("Open Settings…") {
                                    NSWorkspace.shared.open(ToolLocator.fullDiskAccessSettingsURL)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        Text(report.fullDiskAccess
                             ? "Granted. Every folder on disk is readable."
                             : "Not granted. This app is not sandboxed, so most folders already work — but macOS separately gates Desktop, Documents and Downloads. If a VOD in one of those folders won't open, grant access here and relaunch.")
                            .font(.callout)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .panel()

                    DependencyRow(
                        title: "Local clip finder (optional)",
                        detail: OllamaClient.binary() != nil
                            ? "Ollama installed — the clip finder runs full on-device analysis (pull a model with the command below if it reports heuristics-only)"
                            : "Ollama not installed — the clip finder falls back to chat/audio heuristics",
                        satisfied: OllamaClient.binary() != nil,
                        fix: "brew install ollama && ollama pull llama3.1:8b"
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: "AI features")
                        Text("Nothing in this app calls a paid API anymore. The clip finder's local model runs on this Mac via Ollama — no key, no cloud, no per-run cost. Every Claude feature — throughlines, transcript polish, titles, post copy, overlay art — works by copying a ready-made prompt into a claude.ai chat (covered by your subscription) and pasting the reply back. No keys needed.")
                            .font(.callout)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .panel()

                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: "Models folder")
                        HStack {
                            Text(modelsFolder)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([Paths.modelsRoot])
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .panel()
                }
                .padding(16)
            }

            Divider().overlay(Theme.border)

            HStack {
                Button("Re-check") { report = .current() }
                    .buttonStyle(.bordered)
                Spacer()
                Button(report.allSatisfied ? "Done" : "Continue anyway") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
            .padding(16)
        }
        .background(Theme.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Setup")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("This app shells out to ffmpeg and whisper.cpp. Apps launched from Finder don't inherit your shell's PATH, so tools are located by absolute path in /opt/homebrew/bin and /usr/local/bin.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }
}

private struct DependencyRow: View {
    let title: String
    let detail: String
    let satisfied: Bool
    let fix: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: satisfied ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(satisfied ? Theme.positive : Theme.danger)
                Text(title)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if !satisfied {
                HStack {
                    Text(fix)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(fix, forType: .string)
                        copied = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(8)
                .background(Theme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .panel()
    }
}

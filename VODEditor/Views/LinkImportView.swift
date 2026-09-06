import SwiftUI
import AppKit

/// Paste a VOD link, and it downloads and ingests without another click.
struct LinkImportView: View {
    @ObservedObject var queue: DownloadQueue
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var folder = DownloadService.downloadsFolder
    @State private var freeSpace: Int64 = 0
    @FocusState private var fieldFocused: Bool

    private var toolInstalled: Bool { ToolLocator.locate("yt-dlp") != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if !toolInstalled {
                missingTool
            } else {
                input
                Divider().overlay(Theme.border)
                list
            }

            Divider().overlay(Theme.border)
            footer
        }
        .background(Theme.background)
        .onAppear {
            fieldFocused = true
            refreshSpace()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Add from a link")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Paste a Twitch or YouTube link — or several, one per line. Each one is transcribed straight away, and lands in the sidebar as soon as it's readable.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private var missingTool: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("yt-dlp isn't installed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
            Text("Downloading needs yt-dlp. It's one Homebrew formula, and it's what handles Twitch's HLS streams.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("brew install yt-dlp")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install yt-dlp", forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(8)
            .background(Theme.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("twitch.tv/videos/… or youtube.com/watch?v=…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($fieldFocused)
                    .onSubmit(submit)

                Button("Paste") {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        draft = draft.isEmpty ? text : draft + "\n" + text
                        submit()
                    }
                }
                .buttonStyle(.bordered)

                Button("Add") { submit() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let error = queue.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("", selection: $queue.mode) {
                ForEach(DownloadQueue.Mode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(queue.mode == .stream
                 ? "Only the audio comes down, for the transcript. The video stays where it is and the export pulls just the parts you keep. Twitch only — YouTube and other sites fall back to a normal download automatically."
                 : "The whole video lands on disk first. Slower to start, but playback scrubs instantly afterwards and works with no connection.")
                .font(.caption2)
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)

            if queue.mode == .download {
            HStack(spacing: 6) {
                Text("Saving to")
                    .font(.caption)
                    .foregroundStyle(Theme.textFaint)
                Text(folder.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Change…") { chooseFolder() }
                    .buttonStyle(.link)
                    .controlSize(.small)
                Spacer()
                Text("\(ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file)) free")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(freeSpace < 20_000_000_000 ? Theme.warning : Theme.textFaint)
            }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var list: some View {
        Group {
            if queue.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.textFaint)
                    Text("Nothing queued")
                        .foregroundStyle(Theme.textSecondary)
                    Text(queue.mode == .stream
                         ? "A four-hour VOD reaches a finished transcript in about 35 minutes, having pulled 407 MB instead of 10 GB."
                         : "A four-hour 1080p60 VOD is around 10 GB, then about 20 minutes to transcribe once it lands.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textFaint)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(queue.items) { item in
                            LinkRow(item: item,
                                    ingestDetail: queue.ingestDetail,
                                    onRemove: { queue.remove(item) })
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            if queue.isRunning {
                ProgressView().controlSize(.small)
                Text("\(queue.pendingCount) to go")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Button("Stop") { queue.cancel() }
                    .buttonStyle(.bordered)
            } else if queue.items.contains(where: { !$0.status.isFinished }) {
                Button("Resume") { queue.start() }
                    .buttonStyle(.bordered)
            }
            if queue.items.contains(where: { $0.status.isFinished }) {
                Button("Clear finished") { queue.clearFinished() }
                    .buttonStyle(.bordered)
            }
            Spacer()
            Text("Downloads resume where they stopped.")
                .font(.caption2)
                .foregroundStyle(Theme.textFaint)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
        .padding(16)
    }

    private func submit() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if queue.add(text) > 0 { draft = "" }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Where downloaded VODs are saved"
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        DownloadService.downloadsFolder = url
        folder = url
        refreshSpace()
    }

    private func refreshSpace() {
        let probe = FileManager.default.fileExists(atPath: folder.path)
            ? folder : folder.deletingLastPathComponent()
        freeSpace = (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage).flatMap { Int64($0) } ?? 0
    }
}

private struct LinkRow: View {
    let item: DownloadQueue.Item
    let ingestDetail: String?
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(item.status.isFailure ? Theme.danger : Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)

                if let progress = item.progress {
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction).tint(Theme.accent)
                    } else {
                        ProgressView().progressViewStyle(.linear).tint(Theme.accent)
                    }
                    Text(progressLabel(progress))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer(minLength: 4)

            if item.status.isFinished || item.status == .queued || item.status == .probing {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textFaint)
            }
        }
        .padding(8)
        .background(Theme.surfaceRaised.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func progressLabel(_ progress: DownloadProgress) -> String {
        var parts = [ByteCountFormatter.string(fromByteCount: progress.downloadedBytes, countStyle: .file)]
        if let estimated = progress.estimatedBytes {
            parts[0] += " of about " + ByteCountFormatter.string(fromByteCount: estimated, countStyle: .file)
        }
        if let speed = progress.speedLabel { parts.append(speed) }
        if let eta = progress.etaLabel { parts.append(eta + " left") }
        return parts.joined(separator: " · ")
    }

    private var subtitle: String {
        switch item.status {
        case .probing: return "Reading the link…"
        case .queued: return item.detail.isEmpty ? "Waiting" : item.detail
        case .preparing: return "Opening the stream…"
        case .downloading: return item.detail.isEmpty ? "Downloading" : item.detail
        case .ingesting: return ingestDetail ?? "Transcribing"
        case .done: return item.detail.isEmpty ? "Ready" : item.detail
        case .failed(let message): return message
        }
    }

    private var icon: String {
        switch item.status {
        case .probing: return "magnifyingglass"
        case .queued: return "clock"
        case .preparing: return "antenna.radiowaves.left.and.right"
        case .downloading: return "arrow.down.circle"
        case .ingesting: return "waveform"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch item.status {
        case .done: return Theme.positive
        case .failed: return Theme.danger
        case .downloading, .ingesting, .preparing: return Theme.accent
        default: return Theme.textFaint
        }
    }
}

private extension DownloadQueue.Item.Status {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Queue several VODs and leave them to ingest. Each one lands as a normal
/// project with candidates and a long-form cut already generated.
struct BatchView: View {
    @ObservedObject var runner: BatchRunner
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.border)

            if runner.items.isEmpty {
                emptyState
            } else {
                queue
            }

            if let session = runner.activeSession {
                Divider().overlay(Theme.border)
                ActiveItemProgress(session: session)
                    .padding(12)
            }

            Divider().overlay(Theme.border)
            footer
        }
        .background(Theme.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Batch ingest")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Runs one VOD at a time — whisper already saturates the GPU, so parallel runs would be slower. Files already ingested are skipped.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.down.right")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textFaint)
            Text("No VODs queued")
                .foregroundStyle(Theme.textSecondary)
            Button("Add VODs…") { addFiles() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var queue: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(Array(runner.items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 10) {
                        statusIcon(item.status)
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(statusText(item))
                                .font(.caption2)
                                .foregroundStyle(statusColor(item.status))
                                .lineLimit(1)
                        }

                        Spacer()

                        if !runner.isRunning {
                            Button {
                                runner.remove(item)
                            } label: {
                                Image(systemName: "xmark.circle.fill").font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.textFaint)
                        }
                    }
                    .padding(8)
                    .background(index == runner.activeIndex
                                ? Theme.accent.opacity(0.12)
                                : Theme.surfaceRaised.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(12)
        }
        .frame(minHeight: 200)
    }

    private var footer: some View {
        HStack {
            Button("Add VODs…") { addFiles() }
                .disabled(runner.isRunning)
            Button("Clear finished") { runner.clearFinished() }
                .disabled(runner.isRunning)

            Spacer()

            Text("\(runner.completedCount)/\(runner.items.count)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)

            if runner.isRunning {
                Button("Stop") { runner.cancel() }
                    .buttonStyle(.bordered)
            } else {
                Button("Start") { runner.start() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(runner.items.isEmpty)
            }
            Button("Close") { dismiss() }
        }
        .padding(14)
    }

    @ViewBuilder
    private func statusIcon(_ status: BatchRunner.Item.Status) -> some View {
        switch status {
        case .queued:
            Image(systemName: "circle").font(.caption).foregroundStyle(Theme.textFaint)
        case .running:
            ProgressView().controlSize(.small).scaleEffect(0.55)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.positive)
        case .skipped:
            Image(systemName: "forward.circle.fill").font(.caption).foregroundStyle(Theme.textSecondary)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(Theme.danger)
        }
    }

    private func statusText(_ item: BatchRunner.Item) -> String {
        switch item.status {
        case .queued: return "Queued"
        case .running: return "Processing…"
        case .done: return item.detail.isEmpty ? "Done" : item.detail
        case .skipped(let reason): return reason
        case .failed(let reason): return reason
        }
    }

    private func statusColor(_ status: BatchRunner.Item.Status) -> Color {
        switch status {
        case .failed: return Theme.danger
        case .done: return Theme.positive
        default: return Theme.textFaint
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .video]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose VODs to ingest"
        if let last = UserDefaults.standard.string(forKey: "lastImportFolder") {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        guard panel.runModal() == .OK else { return }
        if let first = panel.urls.first {
            UserDefaults.standard.set(first.deletingLastPathComponent().path, forKey: "lastImportFolder")
        }
        runner.enqueue(panel.urls)
    }
}

/// Live stage/progress for the item currently being processed.
private struct ActiveItemProgress: View {
    @ObservedObject var session: ProjectSession

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(session.stage.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if session.stageProgress > 0 {
                    Text("\(Int(session.stageProgress * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            ProgressView(value: max(0.001, session.stageProgress))
                .tint(Theme.accent)
            if !session.statusDetail.isEmpty {
                Text(session.statusDetail)
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }
        }
    }
}

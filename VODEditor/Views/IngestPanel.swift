import SwiftUI

/// Stage-by-stage view of the ingest pipeline, with resume semantics made
/// visible: finished stages stay finished across relaunches.
struct IngestPanel: View {
    @ObservedObject var session: ProjectSession
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            VStack(spacing: 6) {
                ForEach(IngestStage.pipeline, id: \.self) { stage in
                    StageRow(
                        stage: stage,
                        state: state(for: stage),
                        progress: session.stage == stage ? session.stageProgress : 0,
                        detail: session.stage == stage ? session.statusDetail : chunkSummary(for: stage)
                    )
                }
            }

            if let error = session.project.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let note = session.backendNote {
                Label(note, systemImage: note.hasPrefix("Metal") ? "bolt.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(note.hasPrefix("Metal") ? Theme.positive : Theme.warning)
            }

            if !session.log.isEmpty {
                DisclosureGroup(isExpanded: $showLog) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(session.log.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                } label: {
                    SectionLabel(text: "Log")
                }
            }
        }
        .panel()
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.isRunning ? session.stage.label : (session.isReady ? "Ingest complete" : "Ingest"))
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                if session.isReady, let speed = session.project.transcriptionSpeedLabel {
                    Text("Transcribed at \(speed)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                } else if !session.statusDetail.isEmpty {
                    Text(session.statusDetail)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if session.isRunning {
                Button("Cancel") { session.cancelIngest() }
                    .buttonStyle(.bordered)
            } else {
                Button(session.isReady ? "Re-run" : (session.stage == .created ? "Start Ingest" : "Resume")) {
                    session.startIngest()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
        }
    }

    private func chunkSummary(for stage: IngestStage) -> String {
        guard stage == .transcribing, !session.project.chunkPlan.isEmpty else { return "" }
        return "\(session.project.completedChunkIndices.count)/\(session.project.chunkPlan.count) chunks"
    }

    private func state(for stage: IngestStage) -> StageRow.State {
        let pipeline = IngestStage.pipeline
        guard let current = pipeline.firstIndex(of: session.stage),
              let target = pipeline.firstIndex(of: stage) else {
            return session.isReady ? .done : .pending
        }
        if session.isReady { return .done }
        if target < current { return .done }
        if target == current { return session.project.stage == .failed ? .failed : .active }
        return .pending
    }
}

private struct StageRow: View {
    enum State { case pending, active, done, failed }

    let stage: IngestStage
    let state: State
    let progress: Double
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 16)
            Text(stage.label)
                .font(.callout)
                .foregroundStyle(state == .pending ? Theme.textFaint : Theme.textPrimary)
            Spacer()
            if state == .active, progress > 0 {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            } else if !detail.isEmpty, state != .pending {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .overlay(alignment: .bottom) {
            if state == .active {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: geometry.size.width * progress, height: 2)
                }
                .frame(height: 2)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .pending:
            Image(systemName: "circle").foregroundStyle(Theme.textFaint).font(.caption)
        case .active:
            ProgressView().controlSize(.small).scaleEffect(0.6)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.positive).font(.caption)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger).font(.caption)
        }
    }
}

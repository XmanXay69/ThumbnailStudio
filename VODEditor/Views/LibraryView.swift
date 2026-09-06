import SwiftUI
import AppKit

/// The back catalogue as one surface: build a best-of from clips you already
/// accepted, and see the bits you keep coming back to.
struct LibraryView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case compilation, bits
        var id: String { rawValue }
        var label: String { self == .compilation ? "Compilation" : "Running bits" }
    }

    @State private var tab: Tab = .compilation
    @State private var entries: [CompilationService.Entry] = []
    @State private var bits: [RecurringBitService.Bit] = []
    @State private var query = CompilationService.Query()
    @State private var loading = true
    @State private var note: String?

    private var picks: [CompilationService.Entry] {
        CompilationService.select(entries, query: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Library")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
            }

            if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading every project…")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tab == .compilation {
                compilationTab
            } else {
                bitsTab
            }

            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Theme.positive)
            }
        }
        .padding(14)
        .frame(width: 820, height: 620)
        .background(Theme.background)
        .task { await load() }
    }

    // MARK: - Compilation

    private var compilationTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("Order", selection: $query.order) {
                    ForEach(CompilationService.Query.Order.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 190)
                Stepper(String(format: "%.0f min cap", query.maximumMinutes),
                        value: $query.maximumMinutes, in: 1...60, step: 1)
                    .frame(width: 150)
                Toggle("Include posted", isOn: $query.includePosted)
                    .toggleStyle(.checkbox)
                Spacer()
            }
            .font(.caption)

            let allCategories = CompilationService.categories(in: entries)
            if !allCategories.isEmpty {
                HStack(spacing: 5) {
                    ForEach(allCategories, id: \.self) { category in
                        let on = query.categories.contains(category)
                        Button {
                            if on { query.categories.remove(category) }
                            else { query.categories.insert(category) }
                        } label: {
                            Text(category)
                                .font(.system(size: 10))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(on ? Theme.accent.opacity(0.25) : Theme.surfaceRaised)
                                .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    if !query.categories.isEmpty {
                        Button("All") { query.categories.removeAll() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textFaint)
                    }
                }
            }

            HStack {
                StatText(value: "\(picks.count)", label: "clips", tint: Theme.accent)
                StatText(value: CompilationService.totalDuration(picks).shortTimecode,
                         label: "running time")
                Spacer()
                Button {
                    build()
                } label: {
                    Label("Build compilation", systemImage: "square.stack.3d.down.right")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(picks.isEmpty)
            }

            if entries.isEmpty {
                Text("No accepted clips yet. Keep candidates in the Shorts tab and they'll pool here.")
                    .font(.caption)
                    .foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(picks) { entry in
                            HStack(spacing: 8) {
                                Text(String(format: "%.0f", entry.score * 100))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.positive)
                                    .frame(width: 30, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.title)
                                        .font(.caption)
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                    Text("\(entry.projectName) · \(entry.start.shortTimecode)")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textFaint)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if !entry.category.isEmpty {
                                    Text(entry.category)
                                        .font(.system(size: 9))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                Text(String(format: "%.0fs", entry.duration))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                if entry.posted {
                                    Image(systemName: "paperplane.fill")
                                        .font(.system(size: 8))
                                        .foregroundStyle(Theme.positive)
                                }
                            }
                            .padding(6)
                            .background(Theme.surfaceRaised.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Running bits

    private var bitsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Phrases that turned up in two or more separate VODs — the raw material of a running bit.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                Spacer()
            }
            if bits.isEmpty {
                Text("Nothing repeats across your VODs yet — this gets interesting once you have more of them ingested.")
                    .font(.caption)
                    .foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(bits) { bit in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("“\(bit.phrase)”")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Theme.accent)
                                    Spacer()
                                    Text("\(bit.projectCount) VODs · \(bit.occurrences.count) times")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Theme.textFaint)
                                }
                                ForEach(bit.occurrences.prefix(4)) { occurrence in
                                    Button {
                                        store.pendingSeek = (occurrence.projectID, occurrence.time)
                                        store.selectedProjectID = occurrence.projectID
                                        dismiss()
                                    } label: {
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            Text(occurrence.time.shortTimecode)
                                                .font(.system(size: 9, design: .monospaced))
                                                .foregroundStyle(Theme.textFaint)
                                                .frame(width: 50, alignment: .leading)
                                            Text(occurrence.line)
                                                .font(.caption2)
                                                .foregroundStyle(Theme.textSecondary)
                                                .lineLimit(1)
                                            Spacer()
                                            Text(occurrence.projectName)
                                                .font(.system(size: 9))
                                                .foregroundStyle(Theme.textFaint)
                                                .lineLimit(1)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(7)
                            .background(Theme.surfaceRaised.opacity(0.4))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Loading and building

    private func load() async {
        let projects = store.projects
        let gathered = await Task.detached(priority: .userInitiated) {
            var entries: [CompilationService.Entry] = []
            var sources: [(projectID: UUID, name: String, transcript: Transcript)] = []
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            for project in projects {
                // Categories, when an auto-clip run named them.
                var categoryByCandidate: [UUID: String] = [:]
                if let data = try? Data(contentsOf: project.paths.autoClips),
                   let run = try? decoder.decode(AutoClipRun.self, from: data) {
                    let names = Dictionary(uniqueKeysWithValues:
                        run.categories.map { ($0.id, $0.name) })
                    for candidate in run.candidates {
                        categoryByCandidate[candidate.id] = names[candidate.categoryID] ?? ""
                    }
                }
                if let data = try? Data(contentsOf: project.paths.shorts),
                   let candidates = try? decoder.decode([ShortCandidate].self, from: data) {
                    for candidate in candidates where candidate.status == .accepted {
                        entries.append(CompilationService.Entry(
                            candidateID: candidate.id,
                            projectID: project.id,
                            projectName: project.name,
                            sourcePath: project.sourcePath,
                            title: candidate.title.isEmpty
                                ? candidate.start.shortTimecode : candidate.title,
                            start: candidate.start, end: candidate.end,
                            score: candidate.score,
                            category: categoryByCandidate[candidate.id] ?? "",
                            createdAt: project.createdAt,
                            posted: candidate.postedAt != nil))
                    }
                }
                if let data = try? Data(contentsOf: project.paths.mergedTranscript),
                   let transcript = try? decoder.decode(Transcript.self, from: data),
                   !transcript.isEmpty {
                    sources.append((project.id, project.name, transcript))
                }
            }
            let bits = RecurringBitService.find(in: sources)
            return (entries, bits)
        }.value

        entries = gathered.0
        bits = gathered.1
        loading = false
    }

    /// Writes the picks onto the selected project's timeline — a compilation
    /// is just a timeline, so it edits and exports like anything else.
    private func build() {
        guard let id = store.selectedProjectID, let project = store.project(id) else {
            note = "Open a project first — the compilation is built onto its timeline."
            return
        }
        let session = ProjectSession(project: project, store: store)
        var edit = session.clipEdit
        edit.clips.append(contentsOf: CompilationService.timelineClips(from: picks))
        session.applyClipEdit(edit, action: "Build Compilation")
        note = "Added \(picks.count) clips to \(project.name) — open the Editor to arrange them."
    }
}

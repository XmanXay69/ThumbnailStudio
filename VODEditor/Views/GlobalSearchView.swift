import SwiftUI

/// ⌘⇧F: one search box over every project's transcript. Click a hit and
/// the project opens seeked to that moment.
struct GlobalSearchView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var sources: [(projectID: UUID, name: String, transcript: Transcript)] = []
    @State private var loading = true
    @FocusState private var searchFocused: Bool

    private var hits: [GlobalSearchService.Hit] {
        GlobalSearchService.search(query, in: sources)
    }

    private var grouped: [(name: String, projectID: UUID, hits: [GlobalSearchService.Hit])] {
        Dictionary(grouping: hits, by: \.projectID)
            .compactMap { id, hits in
                hits.first.map { (name: $0.projectName, projectID: id, hits: hits) }
            }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textFaint)
                TextField("Search every transcript…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.bottom, 2)
            Divider().overlay(Theme.border)

            if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading transcripts…")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if query.trimmingCharacters(in: .whitespaces).count < 2 {
                VStack(spacing: 6) {
                    Text("\(sources.count) transcript\(sources.count == 1 ? "" : "s") loaded")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text("Find every time a story got told — callbacks and recurring bits are compilation material.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textFaint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hits.isEmpty {
                Text("No lines match \u{201C}\(query)\u{201D}")
                    .font(.caption)
                    .foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(grouped, id: \.projectID) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                                ForEach(group.hits) { hit in
                                    Button {
                                        store.pendingSeek = (hit.projectID, hit.time)
                                        store.selectedProjectID = hit.projectID
                                        dismiss()
                                    } label: {
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Text(hit.time.shortTimecode)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(Theme.textFaint)
                                                .frame(width: 56, alignment: .leading)
                                            highlighted(hit.text)
                                                .font(.caption)
                                                .multilineTextAlignment(.leading)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .padding(.vertical, 3)
                                        .padding(.horizontal, 6)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .background(Theme.surfaceRaised.opacity(0.3))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                            }
                        }
                        if hits.count >= 200 {
                            Text("Showing the first 200 — narrow the search for more precision")
                                .font(.caption2)
                                .foregroundStyle(Theme.textFaint)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 640, height: 480)
        .background(Theme.background)
        .task {
            // Off the main actor: six transcripts today, sixty someday.
            let projects = store.projects
            let loaded = await Task.detached(priority: .userInitiated) {
                projects.compactMap { project
                    -> (projectID: UUID, name: String, transcript: Transcript)? in
                    guard let data = try? Data(contentsOf: project.paths.mergedTranscript),
                          let transcript = try? JSONDecoder().decode(Transcript.self, from: data),
                          !transcript.isEmpty else { return nil }
                    return (project.id, project.name, transcript)
                }
            }.value
            sources = loaded
            loading = false
            searchFocused = true
        }
    }

    /// The matched run in accent color, so the eye lands on it.
    private func highlighted(_ text: String) -> Text {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty,
              let range = text.range(of: needle, options: [.caseInsensitive]) else {
            return Text(text).foregroundColor(Theme.textPrimary)
        }
        return Text(text[text.startIndex..<range.lowerBound])
            .foregroundColor(Theme.textSecondary)
            + Text(text[range]).foregroundColor(Theme.playhead).bold()
            + Text(text[range.upperBound...]).foregroundColor(Theme.textSecondary)
    }
}

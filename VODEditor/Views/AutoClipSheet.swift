import SwiftUI

/// The find-clips setup: how many, how long, which categories — and the
/// category editor, since the descriptions are the analysis prompt.
struct AutoClipSheet: View {
    @ObservedObject var session: ProjectSession
    @Environment(\.dismiss) private var dismiss

    @State private var count = 5
    @State private var customCount = ""
    @State private var minLength: Double = 30
    @State private var maxLength: Double = 60
    @State private var selected: Set<UUID> = []
    @State private var editingCategoryID: UUID?
    @State private var backendLine = "checking local model…"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Want me to find clips in this VOD?")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Runs in the background — keep editing while it works. Expect timestamped starting points to adjust, not upload-ready clips: it's usually right, occasionally confidently wrong.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            Divider().overlay(Theme.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Text("How many")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        ForEach([1, 5, 10], id: \.self) { option in
                            Button("\(option)") { count = option; customCount = "" }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(count == option && customCount.isEmpty ? Theme.accent : nil)
                        }
                        TextField("custom", text: $customCount)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .onChange(of: customCount) { _, value in
                                if let custom = Int(value), custom > 0 { count = min(custom, 40) }
                            }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Clip length — a target, not a hard rule (natural boundaries get ±15s)")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        HStack {
                            Text("\(Int(minLength))s")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 34)
                            Slider(value: $minLength, in: 15...90, step: 5)
                                .onChange(of: minLength) { _, value in
                                    if value > maxLength - 10 { maxLength = value + 10 }
                                }
                            Slider(value: $maxLength, in: 25...120, step: 5)
                                .onChange(of: maxLength) { _, value in
                                    if value < minLength + 10 { minLength = max(15, value - 10) }
                                }
                            Text("\(Int(maxLength))s")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 34)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Categories")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Button {
                                var categories = session.project.clipCategories
                                let fresh = ClipCategory(name: "New category",
                                                         description: "Describe what to look for — this text goes straight into the analysis prompt.")
                                categories.append(fresh)
                                session.updateClipCategories(categories)
                                selected.insert(fresh.id)
                                editingCategoryID = fresh.id
                            } label: {
                                Label("Add", systemImage: "plus")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        Text("The description IS the detection: it's injected into the analysis prompt verbatim, so editing it changes what gets found.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(session.project.clipCategories) { category in
                            categoryRow(category)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(backendLine)
                            .font(.caption2)
                            .foregroundStyle(backendLine.contains("heuristics")
                                             ? Theme.warning : Theme.positive)
                            .fixedSize(horizontal: false, vertical: true)
                        if backendLine.contains("heuristics") {
                            Text("Full analysis needs Ollama with a model pulled — Setup & Tools has the two commands. The finder still works meanwhile on chat-emote spikes, chat-reading detection, and monologue shape.")
                                .font(.caption2)
                                .foregroundStyle(Theme.textFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(16)
            }

            Divider().overlay(Theme.border)

            HStack {
                Button("Skip") {
                    session.markAutoClipPromptShown()
                    dismiss()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Find clips") {
                    var request = AutoClipRequest()
                    request.count = count
                    request.minSeconds = minLength
                    request.maxSeconds = maxLength
                    request.categoryIDs = Array(selected)
                    session.startAutoClips(request: request)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(selected.isEmpty)
            }
            .padding(16)
        }
        .background(Theme.background)
        .onAppear {
            selected = Set(session.project.clipCategories.filter(\.enabled).map(\.id))
            Task {
                if await OllamaClient.ensureServer(),
                   let models = await OllamaClient.installedModels(), !models.isEmpty,
                   let model = OllamaClient.chooseModel(
                       installed: models, ramBytes: ProcessInfo.processInfo.physicalMemory) {
                    backendLine = "Local model ready: \(model) — full analysis, on-device, nothing leaves this Mac."
                } else {
                    backendLine = "heuristics only — no local model available"
                }
            }
        }
    }

    private func categoryRow(_ category: ClipCategory) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { selected.contains(category.id) },
                    set: { on in
                        if on { selected.insert(category.id) } else { selected.remove(category.id) }
                    }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                Text(category.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(editingCategoryID == category.id ? "Done" : "Edit") {
                    editingCategoryID = editingCategoryID == category.id ? nil : category.id
                }
                .buttonStyle(.link)
                .controlSize(.small)
                Button(role: .destructive) {
                    session.updateClipCategories(
                        session.project.clipCategories.filter { $0.id != category.id })
                    selected.remove(category.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textFaint)
            }
            if editingCategoryID == category.id {
                TextField("Name", text: categoryBinding(category.id, \.name))
                    .textFieldStyle(.roundedBorder)
                TextField("What to look for (goes into the prompt)",
                          text: categoryBinding(category.id, \.description), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                TextField("Chat emotes that signal it (comma-separated)", text: Binding(
                    get: {
                        (session.project.clipCategories.first { $0.id == category.id }?
                            .emoteHints ?? []).joined(separator: ", ")
                    },
                    set: { value in
                        var categories = session.project.clipCategories
                        guard let index = categories.firstIndex(where: { $0.id == category.id }) else { return }
                        categories[index].emoteHints = value
                            .components(separatedBy: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        session.updateClipCategories(categories)
                    }
                ))
                .textFieldStyle(.roundedBorder)
            } else {
                Text(category.description)
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(2)
            }
        }
        .padding(6)
        .background(Theme.surfaceRaised.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func categoryBinding(_ id: UUID,
                                 _ path: WritableKeyPath<ClipCategory, String>) -> Binding<String> {
        Binding(
            get: { (session.project.clipCategories.first { $0.id == id })?[keyPath: path] ?? "" },
            set: { value in
                var categories = session.project.clipCategories
                guard let index = categories.firstIndex(where: { $0.id == id }) else { return }
                categories[index][keyPath: path] = value
                session.updateClipCategories(categories)
            }
        )
    }
}

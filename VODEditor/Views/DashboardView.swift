import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Every VOD you're editing for everyone, on one screen: status, shorts
/// progress, posted flags — plus the export queue and the client roster.
struct DashboardView: View {
    @ObservedObject var store: ProjectStore
    /// True when the dashboard IS the detail view (nothing selected) rather
    /// than a sheet — no Done button, and Open needs no dismiss.
    var embedded = false
    @ObservedObject private var queue = ExportQueue.shared
    @ObservedObject private var clientStore = ClientStore.shared
    @Environment(\.dismiss) private var dismiss

    /// Lightweight per-project counts read straight off disk — no sessions.
    struct Summary {
        var shortsTotal = 0
        var shortsAccepted = 0
        var shortsExported = 0
        var timelineClips = 0
        var diskBytes: Int64 = 0
    }
    @State private var summaries: [UUID: Summary] = [:]
    @State private var runways: [PostingForecastService.Runway] = []
    @State private var reclaimCandidate: VODProject?
    @State private var archiveCandidate: VODProject?
    @State private var lastFreed: String?
    @State private var bundlingSession: ProjectSession?
    @State private var editingClient: ClientProfile?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Dashboard")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if !embedded {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                }
            }
            .padding(16)

            Divider().overlay(Theme.border)

            HStack(alignment: .top, spacing: 12) {
                projectsColumn
                VStack(spacing: 12) {
                    queuePanel
                    runwayPanel
                    clientsPanel
                }
                .frame(width: 300)
            }
            .padding(12)
        }
        .background(Theme.background)
        .onAppear(perform: loadSummaries)
        .confirmationDialog(
            "Reclaim derived media from \(reclaimCandidate?.name ?? "")?",
            isPresented: Binding(get: { reclaimCandidate != nil },
                                 set: { if !$0 { reclaimCandidate = nil } })
        ) {
            Button("Reclaim") {
                if let project = reclaimCandidate { reclaim(project) }
                reclaimCandidate = nil
            }
            Button("Cancel", role: .cancel) { reclaimCandidate = nil }
        } message: {
            Text("Deletes the transcription WAVs, whisper chunks, poster caches and unreferenced render intermediates. The edit, transcript and candidates stay; everything deleted regenerates on demand.")
        }
        .confirmationDialog(
            "Archive \(archiveCandidate?.name ?? "") down to its JSON?",
            isPresented: Binding(get: { archiveCandidate != nil },
                                 set: { if !$0 { archiveCandidate = nil } })
        ) {
            Button("Archive", role: .destructive) {
                if let project = archiveCandidate { archive(project) }
                archiveCandidate = nil
            }
            Button("Cancel", role: .cancel) { archiveCandidate = nil }
        } message: {
            Text("Keeps the documents, transcript, analysis and snapshots — deletes ALL media including rendered clips. The project reopens, but editing again means re-rendering from the source VOD.")
        }
        .overlay(alignment: .bottom) {
            if let freed = lastFreed {
                Text(freed)
                    .font(.caption)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceRaised)
                    .clipShape(Capsule())
                    .padding(.bottom, 10)
                    .task {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        lastFreed = nil
                    }
            }
        }
    }

    // MARK: - Projects

    private var projectsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Every project")
                InfoTip("Sizes are what each project holds on disk. Back up writes the cut, transcript and decisions to one file for an external drive — media stays behind and relinks on restore.")
                Spacer()
                Button("Restore backup…") { importBundle() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(store.projects) { project in
                        projectRow(project)
                    }
                    if store.projects.isEmpty {
                        Text("No projects yet")
                            .font(.caption)
                            .foregroundStyle(Theme.textFaint)
                            .padding(.top, 20)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        
    }

    private func projectRow(_ project: VODProject) -> some View {
        let summary = summaries[project.id] ?? Summary()
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if !project.clientName.isEmpty {
                        Text(project.clientName)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.accent.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 8) {
                    statusChip(project)
                    if summary.shortsTotal > 0 {
                        Text("\(summary.shortsTotal) shorts · \(summary.shortsAccepted) accepted · \(summary.shortsExported) exported")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if summary.timelineClips > 0 {
                        Text("\(summary.timelineClips) on timeline")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Spacer()
            Toggle("Posted", isOn: Binding(
                get: { project.postedAt != nil },
                set: { on in
                    var updated = project
                    updated.postedAt = on ? Date() : nil
                    try? store.save(updated)
                }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)
            .help(project.postedAt.map { "Marked posted \($0.formatted(date: .abbreviated, time: .shortened))" }
                  ?? "Tick once the content actually went up — the app can't know on its own")
            if summary.diskBytes > 0 {
                Text(DiskReclaimService.formatBytes(summary.diskBytes))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(summary.diskBytes > 800_000_000
                                     ? Theme.warning : Theme.textFaint)
            }
            Menu {
                Button("Back up decisions…") { exportBundle(project) }
                Divider()
                Button("Reclaim derived media…") { reclaimCandidate = project }
                Button("Archive to JSON…", role: .destructive) { archiveCandidate = project }
            } label: {
                Image(systemName: "internaldrive")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .help("Free the space this project's regenerable files hold")
            Button("Open") {
                store.selectedProjectID = project.id
                if !embedded { dismiss() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .background(Theme.surfaceRaised.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func statusChip(_ project: VODProject) -> some View {
        let (text, color): (String, Color) = {
            if project.postedAt != nil { return ("Posted", Theme.positive) }
            if project.stage == .failed { return ("Failed", Theme.danger) }
            if project.stage != .ready { return (project.stage.label, Theme.warning) }
            let summary = summaries[project.id] ?? Summary()
            if summary.shortsExported > 0 { return ("Exported", Theme.accent) }
            if summary.shortsTotal > 0 { return ("Shorts pending", Theme.warning) }
            return ("Ingested", Theme.textFaint)
        }()
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func loadSummaries(){
        var loaded: [UUID: Summary] = [:]
        for project in store.projects {
            var summary = Summary()
            if let data = try? Data(contentsOf: project.paths.shorts),
               let candidates = try? JSONDecoder().decode([ShortCandidate].self, from: data) {
                summary.shortsTotal = candidates.count
                summary.shortsAccepted = candidates.filter { $0.status == .accepted }.count
                summary.shortsExported = candidates.filter { $0.exportedPath != nil }.count
            }
            if let data = try? Data(contentsOf: project.paths.clipEdit),
               let edit = try? JSONDecoder().decode(ClipEdit.self, from: data) {
                summary.timelineClips = edit.clips.count
            }
            loaded[project.id] = summary
        }
        summaries = loaded

        // The posting forecast reads the same shorts files.
        var items: [PostingForecastService.Item] = []
        for project in store.projects {
            guard let data = try? Data(contentsOf: project.paths.shorts),
                  let candidates = try? JSONDecoder().decode([ShortCandidate].self, from: data)
            else { continue }
            let client = project.clientName.isEmpty ? "Unassigned" : project.clientName
            for candidate in candidates where candidate.exportedPath != nil {
                items.append(.init(clientName: client, postedAt: candidate.postedAt))
            }
        }
        var cadences: [String: Double] = [:]
        for client in clientStore.clients {
            cadences[client.name] = client.postsPerWeek
        }
        runways = PostingForecastService.forecast(items: items, cadences: cadences)

        // Sizes walk gigabytes of files — off the main thread, filled in
        // as they land.
        let snapshot = store.projects.map { ($0.id, $0.paths.root) }
        Task.detached(priority: .utility) {
            for (id, root) in snapshot {
                let bytes = DiskReclaimService.directoryBytes(root)
                await MainActor.run {
                    self.summaries[id]?.diskBytes = bytes
                }
            }
        }
    }

    private func exportBundle(_ project: VODProject) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ProjectBundleService.filename(for: project.name)
        panel.message = "Save this project's cut, transcript and decisions — media not included"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let session = ProjectSession(project: project, store: store)
        bundlingSession = session
        session.exportBundle(to: url)
    }

    private func importBundle() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedFileTypes = [ProjectBundleService.fileExtension, "zip"]
        panel.message = "Choose a .vodbundle to restore"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let restored = try await store.importBundle(url)
                await MainActor.run {
                    lastFreed = "Restored \(restored.name) — relink its media in the Editor"
                    loadSummaries()
                }
            } catch {
                await MainActor.run { lastFreed = error.localizedDescription }
            }
        }
    }

    private func reclaim(_ project: VODProject) {
        let paths = project.paths
        var referenced = Set<String>()
        if let data = try? Data(contentsOf: paths.clipEdit),
           let edit = try? JSONDecoder().decode(ClipEdit.self, from: data) {
            referenced = DiskReclaimService.referencedPaths(edit: edit)
        }
        let targets = DiskReclaimService.reclaimTargets(
            root: paths.root, audioDir: paths.audioDir, chunksDir: paths.chunksDir,
            thumbnailsDir: paths.thumbnailsDir,
            renderDirs: [paths.renderDir, paths.timelineClipsDir],
            transcriptExists: FileManager.default.fileExists(atPath: paths.mergedTranscript.path),
            referencedPaths: referenced)
        Task.detached(priority: .utility) {
            let freed = DiskReclaimService.delete(targets)
            await MainActor.run {
                lastFreed = "\(DiskReclaimService.formatBytes(freed)) reclaimed from \(project.name)"
                loadSummaries()
            }
        }
    }

    private func archive(_ project: VODProject) {
        let paths = project.paths
        let targets = DiskReclaimService.archiveTargets(
            root: paths.root,
            keepDirs: [paths.transcriptDir, paths.analysisDir, paths.versionsDir])
        Task.detached(priority: .utility) {
            let freed = DiskReclaimService.delete(targets)
            await MainActor.run {
                lastFreed = "\(DiskReclaimService.formatBytes(freed)) archived away from \(project.name)"
                loadSummaries()
            }
        }
    }

    // MARK: - Posting runway

    private var runwayPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Posting runway")
            if runways.isEmpty {
                Text("Nothing exported yet. Once clips export, this shows how long each account's material lasts — mark clips posted from the Shorts tab (right-click).")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(runways, id: \.clientName) { runway in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(runway.clientName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text("\(runway.readyCount) ready")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(runway.readyCount > 0 ? Theme.positive : Theme.warning)
                    }
                    if let ends = runway.runwayEnds {
                        Text("At \(cadenceLabel(runway.postsPerWeek)), runs through \(ends.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(runway.warnings, id: \.self) { warning in
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.warning)
                            Text(warning)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let client = clientStore.clients.first(where: { $0.name == runway.clientName }) {
                        HStack(spacing: 5) {
                            Text("Cadence")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.textFaint)
                            Stepper(cadenceLabel(client.postsPerWeek), value: Binding(
                                get: { client.postsPerWeek },
                                set: { value in
                                    guard var updated = clientStore.client(client.id) else { return }
                                    updated.postsPerWeek = min(21, max(0.5, value))
                                    clientStore.upsert(updated)
                                    loadSummaries()
                                }
                            ), step: 1)
                            .font(.caption2)
                            .controlSize(.mini)
                        }
                    }
                }
                .padding(6)
                .background(Theme.surfaceRaised.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        
    }

    private func cadenceLabel(_ perWeek: Double) -> String {
        if abs(perWeek - 7) < 0.01 { return "1/day" }
        if perWeek > 7 { return String(format: "%.0f/day", perWeek / 7) }
        return String(format: "%.0f/week", perWeek)
    }

    // MARK: - Queue

    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Export queue")
                Spacer()
                if queue.jobs.contains(where: {
                    if case .done = $0.status { return true }
                    if case .failed = $0.status { return true }
                    return false
                }) {
                    Button("Clear finished") { queue.clearFinished() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
            if queue.jobs.isEmpty {
                Text("Nothing queued. In the Editor, “Queue export” or “All platforms” drops a render here — they run back-to-back unattended.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(queue.jobs) { job in
                queueRow(job)
            }
        }
        .padding(10)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        
    }

    private func queueRow(_ job: ExportQueue.Job) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: job.platformSet ? "square.grid.2x2" : "square.and.arrow.up")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                Text(job.label)
                    .font(.caption)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                if case .pending = job.status {
                    Button { queue.removePending(job) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textFaint)
                }
            }
            switch job.status {
            case .pending:
                Text("Waiting")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
            case .running(let progress):
                ProgressView(value: progress).tint(Theme.accent)
            case .done(let summary):
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(Theme.positive)
            case .failed(let message):
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(6)
        .background(Theme.surfaceRaised.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Clients

    private var clientsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Clients")
                Spacer()
                Button {
                    let profile = ClientProfile(name: "New client")
                    clientStore.upsert(profile)
                    editingClient = profile
                } label: {
                    Image(systemName: "person.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if clientStore.clients.isEmpty {
                Text("One profile per person you edit for — handles, caption look, webcam framing, vocabulary, logo. Apply it from the Editor's Client menu.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(clientStore.clients) { client in
                clientRow(client)
            }
            if let editing = editingClient {
                clientEditor(editing)
            }
        }
        .padding(10)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        
    }

    private func clientRow(_ client: ClientProfile) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle.fill")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(client.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Text([client.twitchHandle.isEmpty ? nil : "twitch.tv/\(client.twitchHandle)",
                      client.instagramHandle.isEmpty ? nil : "@\(client.instagramHandle)"]
                    .compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Edit") { editingClient = client }
                .buttonStyle(.link)
                .controlSize(.small)
            Button(role: .destructive) {
                clientStore.delete(client)
                if editingClient?.id == client.id { editingClient = nil }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textFaint)
        }
        .padding(6)
        .background(editingClient?.id == client.id
                    ? Theme.accent.opacity(0.12) : Theme.surfaceRaised.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func clientEditor(_ client: ClientProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name", text: editBinding(client, \.name))
                .textFieldStyle(.roundedBorder)
            TextField("Twitch handle", text: editBinding(client, \.twitchHandle))
                .textFieldStyle(.roundedBorder)
            TextField("Instagram handle", text: editBinding(client, \.instagramHandle))
                .textFieldStyle(.roundedBorder)
            TextField("Vocabulary — names, games, recurring bits", text: editBinding(client, \.vocabulary))
                .textFieldStyle(.roundedBorder)
            TextField("End-card sign-off (LIKE & SUBSCRIBE)", text: editBinding(client, \.subscribePrompt))
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                Text("Brand colour")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                ForEach(["9146FF", "FF4D4D", "3DDC97", "FFCE45", "44A6FF", "FF7AC6"], id: \.self) { hex in
                    Button {
                        guard var updated = clientStore.client(client.id) else { return }
                        updated.brandColorHex = hex
                        clientStore.upsert(updated)
                        editingClient = updated
                    } label: {
                        Circle()
                            .fill(Color(nsColor: SocialOverlayRenderer.color(hex: hex)))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(
                                client.brandColorHex == hex ? Color.white : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                Button(client.introPath == nil ? "Pick intro sting…" : "Change intro…") {
                    pickIntro(for: client)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if let intro = client.introPath {
                    Text(URL(fileURLWithPath: intro).lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        guard var updated = clientStore.client(client.id) else { return }
                        updated.introPath = nil
                        clientStore.upsert(updated)
                        editingClient = updated
                    } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textFaint)
                }
            }
            HStack(spacing: 6) {
                Button(client.logoPath == nil ? "Pick logo…" : "Change logo…") {
                    pickLogo(for: client)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if let logo = client.logoPath {
                    Text(URL(fileURLWithPath: logo).lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Close") { editingClient = nil }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
            Text("Caption look and webcam framing come from a project: open theirs and use the Editor's Client menu → “Capture current look”.")
                .font(.caption2)
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .padding(8)
        .background(Theme.surfaceRaised.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func editBinding(_ client: ClientProfile,
                             _ path: WritableKeyPath<ClientProfile, String>) -> Binding<String> {
        Binding(
            get: { (clientStore.client(client.id) ?? client)[keyPath: path] },
            set: { value in
                guard var updated = clientStore.client(client.id) else { return }
                updated[keyPath: path] = value
                clientStore.upsert(updated)
                editingClient = updated
            }
        )
    }

    private func pickIntro(for client: ClientProfile) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose \(client.name)'s intro sting — prepend it from the editor's Bookends buttons"
        guard panel.runModal() == .OK, let url = panel.url,
              var updated = clientStore.client(client.id) else { return }
        updated.introPath = url.path
        clientStore.upsert(updated)
        editingClient = updated
    }

    private func pickLogo(for client: ClientProfile) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose \(client.name)'s logo — it lands on thumbnails as a layer"
        guard panel.runModal() == .OK, let url = panel.url,
              var updated = clientStore.client(client.id) else { return }
        updated.logoPath = url.path
        clientStore.upsert(updated)
        editingClient = updated
    }
}

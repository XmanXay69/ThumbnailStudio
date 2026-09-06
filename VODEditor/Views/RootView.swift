import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var store: ProjectStore
    @State private var showingSetup = false
    @State private var showingBatch = false
    @State private var showingLinks = false
    @State private var showingDashboard = false
    @State private var showingMediaBrowser = false
    @State private var showingGlobalSearch = false
    @State private var showingLibrary = false
    @State private var showingThumbLab = false
    /// A picked file waiting on its name — the sheet creates the project.
    @State private var pendingImport: URL?
    @ObservedObject private var exportQueue = ExportQueue.shared
    @State private var importError: String?
    /// Shares the app's single store so batch-created projects appear in the
    /// sidebar as they finish, rather than only after a reload.
    @StateObject private var batchRunner = BatchRunner(store: .shared)
    @StateObject private var downloadQueue = DownloadQueue(store: .shared)

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
        }
        .background(Theme.background)
        .onAppear {
            // Command-line runs are driven from the app delegate, not from
            // here — a view that never appears would never start them.
            guard !LaunchOptions.isHeadlessRun else { return }
            // --open <substring> lands straight in a project.
            if let query = LaunchOptions.openProjectQuery,
               let match = store.projects.first(where: {
                   $0.name.localizedCaseInsensitiveContains(query)
               }) {
                store.selectedProjectID = match.id
            }
            // Nothing works without the CLI tools, so lead with setup when
            // they're missing rather than failing at ingest time.
            if !DependencyReport.current().allSatisfied { showingSetup = true }
        }
        .sheet(isPresented: $showingSetup) {
            SetupView()
                .frame(width: 640, height: 560)
        }
        .sheet(isPresented: $showingBatch) {
            BatchView(runner: batchRunner)
                .frame(width: 620, height: 540)
        }
        .sheet(isPresented: $showingLinks) {
            LinkImportView(queue: downloadQueue)
                .frame(width: 660, height: 560)
        }
        .sheet(isPresented: $showingDashboard) {
            DashboardView(store: store)
                .frame(width: 880, height: 620)
        }
        .sheet(isPresented: $showingGlobalSearch) {
            GlobalSearchView().environmentObject(store)
        }
        .sheet(isPresented: $showingLibrary) {
            LibraryView().environmentObject(store)
        }
        .background(
            Button("") { showingThumbLab.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .opacity(0)
                .accessibilityHidden(true)
        )
        .background(
            Button("") { showingGlobalSearch = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .opacity(0)
                .accessibilityHidden(true)
        )
        .sheet(isPresented: $showingMediaBrowser) {
            MediaBrowserView()
                .frame(width: 960, height: 680)
        }
        .sheet(isPresented: Binding(
            get: { pendingImport != nil },
            set: { if !$0 { pendingImport = nil } }
        )) {
            if let url = pendingImport {
                NewProjectSheet(sourceURL: url, store: store) { pendingImport = nil }
                    .frame(width: 460)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestMediaBrowser)) { _ in
            showingMediaBrowser = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestOpenVOD)) { _ in
            openVOD()
        }
        .onChange(of: store.selectedProjectID) { _, id in
            if id != nil { showingThumbLab = false }
        }
        .alert("Could not open that file",
               isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedProjectID) {
                Section("Projects") {
                    ForEach(store.projects) { project in
                        ProjectRow(project: project)
                            .tag(project.id)
                            .contextMenu {
                                Button("Reveal Working Folder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([project.paths.root])
                                }
                                Button("Reveal Source VOD") {
                                    NSWorkspace.shared.activateFileViewerSelecting([project.sourceURL])
                                }
                                Divider()
                                Button("Delete Project", role: .destructive) {
                                    store.delete(project)
                                }
                            }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider().overlay(Theme.border)

            VStack(spacing: 8) {
                Button {
                    showingDashboard = true
                } label: {
                    Label(exportQueue.isRunning
                          ? "Dashboard · exporting…"
                          : exportQueue.pendingCount > 0
                            ? "Dashboard · \(exportQueue.pendingCount) queued"
                            : "Dashboard", systemImage: "rectangle.grid.2x2")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    showingGlobalSearch = true
                } label: {
                    Label("Search transcripts", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help("Search every project's transcript at once (⇧⌘F)")

                Button {
                    showingLibrary = true
                } label: {
                    Label("Library", systemImage: "books.vertical")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help("Build a best-of from clips you already accepted, and see the bits you keep coming back to")

                Button {
                    store.selectedProjectID = nil
                    showingThumbLab = true
                } label: {
                    Label("Thumb Lab", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(showingThumbLab ? Theme.accent : nil)
                .help("Design thumbnails with no video attached — full studio, own gallery (⇧⌘T)")

                Divider().overlay(Theme.border).padding(.vertical, 2)

                // Every way in, one menu — the rail is navigation, not a
                // wall of six identical buttons.
                Menu {
                    Button {
                        showingLinks = true
                    } label: {
                        Label("Paste a link…", systemImage: "link")
                    }
                    Button {
                        openVOD()
                    } label: {
                        Label("Open VOD…", systemImage: "film")
                    }
                    Button {
                        showingMediaBrowser = true
                    } label: {
                        Label("Find media…", systemImage: "globe")
                    }
                    Button {
                        showingBatch = true
                    } label: {
                        Label("Batch ingest…", systemImage: "square.stack.3d.down.right")
                    }
                } label: {
                    Label(downloadQueue.isRunning
                          ? "New · downloading \(downloadQueue.pendingCount)…"
                          : batchRunner.isRunning
                            ? "New · batch running…"
                            : "New", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .menuStyle(.borderedButton)
                .tint(Theme.accent)

                Button {
                    showingSetup = true
                } label: {
                    Label("Setup & Tools", systemImage: "wrench.and.screwdriver")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
        }
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var detail: some View {
        if showingThumbLab {
            ThumbLabView(onClose: { showingThumbLab = false })
        } else if let id = store.selectedProjectID, let project = store.project(id) {
            ProjectView(project: project, store: store)
                .id(project.id)
        } else if store.projects.isEmpty {
            EmptyStateView(onOpen: openVOD, onPasteLink: { showingLinks = true })
        } else {
            // The app opens here: nothing selected shows the dashboard, so the
            // first thing on screen is everyone's status.
            DashboardView(store: store, embedded: true)
        }
    }

    /// Plain NSOpenPanel — the app is unsandboxed, so anything the user can read
    /// in Finder is readable here, and the last folder is remembered.
    private func openVOD() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a Twitch VOD to ingest"
        panel.prompt = "Open"
        if let types = [UTType.movie, UTType.mpeg4Movie, UTType.video].compactMap({ $0 }) as [UTType]? {
            panel.allowedContentTypes = types
        }
        panel.allowsOtherFileTypes = true
        if let last = UserDefaults.standard.string(forKey: "lastImportFolder") {
            panel.directoryURL = URL(fileURLWithPath: last)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "lastImportFolder")
        // Naming and client come first — the sheet does the creating.
        pendingImport = url
    }
}

extension Notification.Name {
    static let requestMediaBrowser = Notification.Name("requestMediaBrowser")
}

/// Every project starts with a name and, if you're editing for someone, their
/// client — so the dashboard stays organised as the roster grows.
private struct NewProjectSheet: View {
    let sourceURL: URL
    @ObservedObject var store: ProjectStore
    let onClose: () -> Void

    @ObservedObject private var clientStore = ClientStore.shared
    @State private var name = ""
    @State private var clientID: UUID?
    @State private var creationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New project")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(sourceURL.lastPathComponent)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)

            if !clientStore.clients.isEmpty {
                Picker("Client", selection: $clientID) {
                    Text("None").tag(UUID?.none)
                    ForEach(clientStore.clients) { client in
                        Text(client.name).tag(UUID?.some(client.id))
                    }
                }
                .pickerStyle(.menu)
                Text("Applies their caption look, framing, handles and vocabulary from the start — the vocabulary even feeds transcription.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = creationError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Theme.danger)
            }

            HStack {
                Button("Cancel") { onClose() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .background(Theme.background)
        .onAppear {
            name = sourceURL.deletingPathExtension().lastPathComponent
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            var project = try store.create(sourceURL: sourceURL, name: trimmed)
            if let client = clientStore.client(clientID) {
                // The pure profile mapping; the edit half lands in
                // clipedit.json so the editor opens already dressed.
                let (updatedProject, updatedEdit) = client.applied(to: project, edit: ClipEdit())
                project = updatedProject
                try store.save(project)
                try? JSONEncoder().encode(updatedEdit)
                    .write(to: project.paths.clipEdit, options: .atomic)
            }
            store.selectedProjectID = project.id
            onClose()
        } catch {
            creationError = error.localizedDescription
        }
    }
}

private struct ProjectRow: View {
    let project: VODProject

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(project.name)
                    .lineLimit(1)
                    .foregroundStyle(Theme.textPrimary)
                if project.postedAt != nil {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.positive)
                        .help("Posted")
                }
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                if !project.clientName.isEmpty {
                    Text(project.clientName)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Theme.accent.opacity(0.15))
                        .clipShape(Capsule())
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch project.stage {
        case .ready: return Theme.positive
        case .failed: return Theme.danger
        case .created: return Theme.textFaint
        default: return Theme.warning
        }
    }

    private var statusText: String {
        if let duration = project.media?.durationSeconds, project.stage == .ready {
            return duration.timecode
        }
        return project.stage.label
    }
}

private struct EmptyStateView: View {
    let onOpen: () -> Void
    let onPasteLink: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 48))
                .foregroundStyle(Theme.textFaint)
            Text("No VOD open")
                .font(.title2)
                .foregroundStyle(Theme.textPrimary)
            Text("Paste a Twitch VOD link and it downloads and transcribes itself,\nor open a file you already have — those are read in place, never copied.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 10) {
                Button("Paste a link…", action: onPasteLink)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                Button("Open VOD…", action: onOpen)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

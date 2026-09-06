import Foundation

/// Per-project state lives in a JSON file inside the project's own directory.
/// No database server, no schema migrations to babysit for a single-user tool.
@MainActor
final class ProjectStore: ObservableObject {
    /// Single instance for the app. The batch runner and the UI have to write
    /// to the same store or new projects won't show up until a reload.
    static let shared = ProjectStore()

    @Published private(set) var projects: [VODProject] = []
    @Published var selectedProjectID: UUID?
    /// Set by global search: when the project opens, seek here once.
    @Published var pendingSeek: (projectID: UUID, time: Double)?

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init() {
        Paths.ensureAppDirectories()
        reload()
    }

    func reload() {
        let fm = FileManager.default
        let directories = (try? fm.contentsOfDirectory(at: Paths.projectsRoot,
                                                       includingPropertiesForKeys: nil)) ?? []
        projects = directories.compactMap { directory in
            let manifest = directory.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: manifest) else { return nil }
            return try? decoder.decode(VODProject.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func create(sourceURL: URL, name: String? = nil) throws -> VODProject {
        let project = VODProject(
            name: name ?? sourceURL.deletingPathExtension().lastPathComponent,
            sourcePath: sourceURL.path
        )
        try project.paths.createDirectories()
        try save(project)
        reload()
        selectedProjectID = project.id
        return project
    }

    /// Restores a .vodbundle as a new project: fresh id so it can coexist
    /// with the original, media offline until relinked.
    @discardableResult
    func importBundle(_ bundle: URL) async throws -> VODProject {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        try await Shell.runChecked(
            URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ProjectBundleService.extractArguments(bundle: bundle, destination: scratch),
            onOutputLine: { _ in }, onErrorLine: { _ in })

        // ditto --keepParent nests one directory; find the one holding
        // project.json rather than assuming a name.
        var source = scratch
        if !fm.fileExists(atPath: source.appendingPathComponent("project.json").path) {
            let children = (try? fm.contentsOfDirectory(at: scratch,
                                                        includingPropertiesForKeys: nil)) ?? []
            guard let match = children.first(where: {
                fm.fileExists(atPath: $0.appendingPathComponent("project.json").path)
            }) else { throw BundleError.notABundle }
            source = match
        }

        let newID = UUID()
        let projectURL = source.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let rewritten = ProjectBundleService.reidentified(data, newID: newID) else {
            throw BundleError.notABundle
        }
        try rewritten.write(to: projectURL, options: .atomic)

        let destination = Paths.projectsRoot.appendingPathComponent(newID.uuidString,
                                                                    isDirectory: true)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: source, to: destination)

        reload()
        guard let restored = projects.first(where: { $0.id == newID }) else {
            throw BundleError.notABundle
        }
        selectedProjectID = newID
        return restored
    }

    enum BundleError: LocalizedError {
        case notABundle
        var errorDescription: String? {
            "That file isn't a project bundle — it has no project.json inside."
        }
    }

    func save(_ project: VODProject) throws {
        let paths = project.paths
        try paths.createDirectories()
        let data = try encoder.encode(project)
        try data.write(to: paths.manifest, options: .atomic)

        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.insert(project, at: 0)
        }
    }

    func project(_ id: UUID) -> VODProject? {
        projects.first { $0.id == id }
    }

    /// Removes the project's working directory. The source VOD is never touched.
    func delete(_ project: VODProject) {
        try? FileManager.default.removeItem(at: project.paths.root)
        projects.removeAll { $0.id == project.id }
        if selectedProjectID == project.id { selectedProjectID = projects.first?.id }
    }

    /// Total disk used by generated artifacts, so it's obvious what a project
    /// costs on a nearly-full drive.
    func artifactSize(of project: VODProject) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: project.paths.root,
                                             includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

/// Sessions outlive the views that show them. Before this, navigating away
/// from a project deallocated its ProjectSession — whose deinit cancels the
/// ingest pipeline — so switching to the Thumb Lab mid-transcription killed
/// the transcription, silently, twice in one morning. Views now borrow
/// sessions from here; idle ones are evicted, running ones never are.
@MainActor
final class SessionRegistry {
    static let shared = SessionRegistry()

    private var sessions: [UUID: ProjectSession] = [:]
    private var lastUsed: [UUID: Date] = [:]

    func session(for project: VODProject, store: ProjectStore) -> ProjectSession {
        lastUsed[project.id] = Date()
        if let existing = sessions[project.id] { return existing }
        let created = ProjectSession(project: project, store: store)
        sessions[project.id] = created
        evictIdle(keeping: project.id)
        return created
    }

    /// Keeps memory sane: at most three idle sessions cached; anything
    /// running (ingesting, exporting, reframing) is untouchable.
    private func evictIdle(keeping current: UUID) {
        let idle = sessions.filter { id, session in
            id != current && !session.isRunning && !session.isExporting
        }
        guard sessions.count > 4, !idle.isEmpty else { return }
        let oldest = idle.keys.sorted {
            (lastUsed[$0] ?? .distantPast) < (lastUsed[$1] ?? .distantPast)
        }
        for id in oldest.prefix(sessions.count - 4) {
            sessions.removeValue(forKey: id)
            lastUsed.removeValue(forKey: id)
        }
    }
}

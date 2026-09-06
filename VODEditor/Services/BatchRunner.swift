import Foundation

/// Runs ingest + analysis across several VODs back to back.
///
/// Strictly sequential: whisper already saturates the GPU and each source is
/// read at multiple hundred MB/s, so running two at once would be slower than
/// running them in order.
@MainActor
final class BatchRunner: ObservableObject {
    struct Item: Identifiable, Equatable {
        enum Status: Equatable {
            case queued, running, done, failed(String), skipped(String)
        }

        let id = UUID()
        let url: URL
        var status: Status = .queued
        var detail: String = ""
        var projectID: UUID?

        var name: String { url.lastPathComponent }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false
    @Published private(set) var activeSession: ProjectSession?
    @Published private(set) var activeIndex: Int?

    private let store: ProjectStore
    private var task: Task<Void, Never>?

    init(store: ProjectStore) {
        self.store = store
    }

    var completedCount: Int {
        items.filter {
            if case .done = $0.status { return true }
            if case .skipped = $0.status { return true }
            return false
        }.count
    }

    func enqueue(_ urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            items.append(Item(url: url))
        }
    }

    func remove(_ item: Item) {
        guard !isRunning else { return }
        items.removeAll { $0.id == item.id }
    }

    func clearFinished() {
        items.removeAll {
            if case .done = $0.status { return true }
            if case .skipped = $0.status { return true }
            if case .failed = $0.status { return true }
            return false
        }
    }

    func start() {
        guard !isRunning, !items.isEmpty else { return }
        isRunning = true

        task = Task { [weak self] in
            guard let self else { return }
            for index in self.items.indices {
                if Task.isCancelled { break }
                guard case .queued = self.items[index].status else { continue }

                self.activeIndex = index
                self.items[index].status = .running
                await self.process(index: index)
                self.activeSession = nil
            }
            self.activeIndex = nil
            self.isRunning = false
        }
    }

    func cancel() {
        activeSession?.cancelIngest()
        task?.cancel()
        task = nil
        isRunning = false
        activeIndex = nil
        for index in items.indices where items[index].status == .running {
            items[index].status = .queued
        }
    }

    private func process(index: Int) async {
        let url = items[index].url

        guard FileManager.default.fileExists(atPath: url.path) else {
            items[index].status = .failed("File not found")
            return
        }

        // Re-running over a folder shouldn't redo finished work.
        let project: VODProject
        if let existing = store.projects.first(where: { $0.sourcePath == url.path }) {
            if existing.stage == .ready {
                items[index].status = .skipped("Already ingested")
                items[index].projectID = existing.id
                return
            }
            project = existing
        } else {
            do {
                project = try store.create(sourceURL: url)
            } catch {
                items[index].status = .failed(error.localizedDescription)
                return
            }
        }

        items[index].projectID = project.id
        let session = ProjectSession(project: project, store: store)
        activeSession = session

        await session.runIngestToCompletion()

        if Task.isCancelled {
            items[index].status = .queued
            return
        }

        switch session.stage {
        case .ready:
            items[index].status = .done
            let shorts = session.shorts.count
            let minutes = session.longFormExportDuration / 60
            items[index].detail = String(format: "%d shorts · %.1f min cut", shorts, minutes)
        case .failed:
            items[index].status = .failed(session.project.lastError ?? "Ingest failed")
        default:
            items[index].status = .failed("Ingest stopped at \(session.stage.label)")
        }
    }
}

import Foundation

/// Takes pasted links through to finished projects: probe, download, ingest.
///
/// It owns the ingest rather than handing it to the editor view, because a
/// `ProjectView` tears its session down when you navigate away — and the point
/// of pasting three links is being able to walk off while they run.
@MainActor
final class DownloadQueue: ObservableObject {
    /// Whether the video comes down first, or is edited where it sits.
    enum Mode: String, CaseIterable {
        case stream
        case download

        var label: String {
            switch self {
            case .stream: return "Stream it"
            case .download: return "Download it"
            }
        }
    }

    struct Item: Identifiable, Equatable {
        enum Status: Equatable {
            case probing
            case queued
            case preparing
            case downloading
            case ingesting
            case done
            case failed(String)

            var isFinished: Bool {
                if case .done = self { return true }
                if case .failed = self { return true }
                return false
            }
        }

        let id = UUID()
        let link: URL
        var video: RemoteVideo?
        var status: Status = .probing
        var progress: DownloadProgress?
        var detail: String = ""
        var projectID: UUID?
        var filePath: String?

        var title: String { video?.title ?? link.absoluteString }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false
    @Published var lastError: String?
    /// Streaming is the default because it is the difference between editing in
    /// twenty minutes and editing tomorrow.
    @Published var mode: Mode = .stream

    private let store: ProjectStore
    private var worker: Task<Void, Never>?
    private var activeSession: ProjectSession?

    init(store: ProjectStore) {
        self.store = store
    }

    var pendingCount: Int { items.filter { !$0.status.isFinished }.count }

    // MARK: - Queueing

    /// Accepts a paste of any shape — one link, or a column of them.
    @discardableResult
    func add(_ text: String) -> Int {
        let links = DownloadService.extractLinks(text)
        guard !links.isEmpty else {
            // Report why the paste was rejected rather than doing nothing.
            if case .failure(let error) = DownloadService.normalize(text) {
                lastError = error.localizedDescription
            }
            return 0
        }

        var added = 0
        for link in links where !items.contains(where: { $0.link.absoluteString == link.absoluteString }) {
            items.append(Item(link: link))
            added += 1
        }
        if added > 0 {
            lastError = nil
            probePending()
            start()
        }
        return added
    }

    func remove(_ item: Item) {
        guard item.status.isFinished || item.status == .queued || item.status == .probing else { return }
        items.removeAll { $0.id == item.id }
    }

    func clearFinished() {
        items.removeAll { $0.status.isFinished }
    }

    func cancel() {
        activeSession?.cancelIngest()
        worker?.cancel()
        worker = nil
        activeSession = nil
        isRunning = false
        for index in items.indices where items[index].status == .downloading
            || items[index].status == .ingesting || items[index].status == .preparing {
            // A cancelled download keeps its partial file; restarting resumes.
            items[index].status = .queued
            items[index].progress = nil
        }
    }

    // MARK: - Probing

    /// Reads metadata for anything newly pasted. Cheap, and it's what turns a
    /// bare URL into "4h12m, about 10 GB" before the disk fills up.
    private func probePending() {
        Task { [weak self] in
            guard let self else { return }
            guard let service = try? DownloadService() else {
                self.failAllProbing(DownloadError.toolMissing.localizedDescription)
                return
            }
            while let index = self.items.firstIndex(where: { $0.status == .probing }) {
                let link = self.items[index].link
                do {
                    let video = try await service.probe(link)
                    guard let current = self.items.firstIndex(where: { $0.link == link }) else { continue }
                    self.items[current].video = video
                    self.items[current].status = .queued
                    self.items[current].detail = [
                        video.duration.timecode,
                        video.resolutionLabel,
                        video.estimatedSizeLabel ?? "size unknown",
                    ].joined(separator: " · ")
                } catch {
                    guard let current = self.items.firstIndex(where: { $0.link == link }) else { continue }
                    self.items[current].status = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func failAllProbing(_ message: String) {
        for index in items.indices where items[index].status == .probing {
            items[index].status = .failed(message)
        }
    }

    // MARK: - Running

    func start() {
        guard !isRunning else { return }
        isRunning = true

        worker = Task { [weak self] in
            guard let self else { return }
            // Sequential on purpose: whisper saturates the GPU, and two
            // multi-gigabyte downloads share one connection anyway.
            while !Task.isCancelled {
                // Wait for a probe to finish before deciding there's no work.
                if self.items.contains(where: { $0.status == .probing }) {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                guard let index = self.items.firstIndex(where: { $0.status == .queued }) else { break }
                await self.process(index)
            }
            self.isRunning = false
            self.worker = nil
        }
    }

    private func process(_ index: Int) async {
        guard let video = items[index].video else {
            items[index].status = .failed("No metadata for that link")
            return
        }
        let link = items[index].link
        let folder = DownloadService.downloadsFolder

        // MARK: Stream — no video download at all
        //
        // Only Twitch-style HLS VODs can be edited in place. YouTube and most
        // other sites don't hand out a seekable HLS playlist, so when preparing
        // the stream fails for that reason the link falls through to a plain
        // yt-dlp download instead of failing.
        if mode == .stream {
            var streamed: VODProject?
            if let existing = store.projects.first(where: { $0.remote?.webpageURL == link.absoluteString }) {
                streamed = existing
            } else {
                items[index].status = .preparing
                var fresh = VODProject(name: video.title, sourcePath: "")
                do {
                    try fresh.paths.createDirectories()
                    let remote = try await HLSSource.prepare(link: link, into: fresh.paths.root)
                    fresh.sourcePath = remote.playlistPath
                    fresh.remote = remote
                    try store.save(fresh)
                    streamed = fresh
                    if let saved = remote.savedBytes {
                        items[index].detail = "Editing in place — "
                            + ByteCountFormatter.string(fromByteCount: saved, countStyle: .file)
                            + " not downloaded"
                    }
                } catch is HLSError {
                    try? FileManager.default.removeItem(at: fresh.paths.root)
                    items[index].detail = "This site doesn't stream — downloading the video instead"
                } catch {
                    try? FileManager.default.removeItem(at: fresh.paths.root)
                    items[index].status = .failed(error.localizedDescription)
                    return
                }
            }

            if let project = streamed {
                items[index].projectID = project.id
                items[index].filePath = project.sourcePath
                store.selectedProjectID = project.id

                if project.stage == .ready {
                    items[index].status = .done
                    items[index].detail = "Already ingested"
                    return
                }
                await ingest(project, at: index)
                return
            }
            // Fall through to the download path below.
        }

        // MARK: Download
        var file: URL
        if let existing = DownloadService.finishedFile(for: video, in: folder),
           (try? existing.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 {
            // Already downloaded in an earlier run — don't fetch ten gigabytes
            // a second time.
            file = existing
            items[index].detail = "Already downloaded"
        } else {
            items[index].status = .downloading
            do {
                let service = try DownloadService()
                file = try await service.download(
                    video, from: link, to: folder,
                    onProgress: { [weak self] progress in
                        Task { @MainActor in
                            guard let self, let current = self.items.firstIndex(where: { $0.link == link })
                            else { return }
                            self.items[current].progress = progress
                        }
                    },
                    onLog: { _ in }
                )
            } catch {
                if Task.isCancelled {
                    items[index].status = .queued
                } else {
                    items[index].status = .failed(error.localizedDescription)
                }
                return
            }
        }

        guard !Task.isCancelled else {
            items[index].status = .queued
            return
        }
        items[index].filePath = file.path
        items[index].progress = nil

        // MARK: Project
        let project: VODProject
        if let existing = store.projects.first(where: { $0.sourcePath == file.path }) {
            project = existing
        } else {
            do {
                project = try store.create(sourceURL: file, name: video.title)
            } catch {
                items[index].status = .failed(error.localizedDescription)
                return
            }
        }
        items[index].projectID = project.id
        // Selecting it here is the "immediately in the editor" part: the project
        // shows up and can be browsed while the transcript is still being built.
        store.selectedProjectID = project.id

        if project.stage == .ready {
            items[index].status = .done
            items[index].detail = "Already ingested"
            return
        }

        await ingest(project, at: index)
    }

    private func ingest(_ project: VODProject, at index: Int) async {
        items[index].status = .ingesting
        let session = ProjectSession(project: project, store: store)
        activeSession = session
        await session.runIngestToCompletion()
        activeSession = nil

        if Task.isCancelled {
            items[index].status = .queued
            return
        }
        switch session.stage {
        case .ready:
            items[index].status = .done
            items[index].detail = String(format: "%d shorts · %.1f min cut",
                                         session.shorts.count,
                                         session.longFormExportDuration / 60)
        case .failed:
            items[index].status = .failed(session.project.lastError ?? "Ingest failed")
        default:
            items[index].status = .failed("Ingest stopped at \(session.stage.label)")
        }
    }

    /// Live progress for the item currently ingesting, for the queue panel.
    var ingestDetail: String? {
        guard let session = activeSession else { return nil }
        return "\(session.stage.label) · \(Int(session.stageProgress * 100))%"
    }
}

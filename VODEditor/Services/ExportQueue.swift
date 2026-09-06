import Foundation

/// Unattended, cross-project export queue. Each job carries a snapshot of the
/// timeline document and settings taken at enqueue time — later edits don't
/// change a queued job — and jobs render strictly one at a time, since they
/// all compete for the same encoder.
@MainActor
final class ExportQueue: ObservableObject {
    static let shared = ExportQueue()

    struct Job: Identifiable {
        enum Status: Equatable {
            case pending
            case running(Double)
            case done(String)
            case failed(String)
        }
        let id = UUID()
        let projectName: String
        let clientName: String
        let edit: ClipEdit
        let settings: ExportSettings
        let renderDir: URL
        /// A file for a single export; a folder for a platform set.
        let destination: URL
        let platformSet: Bool
        var status: Status = .pending

        var label: String {
            clientName.isEmpty ? projectName : "\(projectName) · \(clientName)"
        }
    }

    @Published private(set) var jobs: [Job] = []
    private var isWorking = false

    var pendingCount: Int { jobs.filter { $0.status == .pending }.count }
    var isRunning: Bool { jobs.contains { if case .running = $0.status { return true }; return false } }

    func enqueue(projectName: String, clientName: String, edit: ClipEdit,
                 settings: ExportSettings, renderDir: URL,
                 destination: URL, platformSet: Bool) {
        jobs.append(Job(projectName: projectName, clientName: clientName, edit: edit,
                        settings: settings, renderDir: renderDir,
                        destination: destination, platformSet: platformSet))
        pump()
    }

    func removePending(_ job: Job) {
        jobs.removeAll { $0.id == job.id && $0.status == .pending }
    }

    func clearFinished() {
        jobs.removeAll {
            if case .done = $0.status { return true }
            if case .failed = $0.status { return true }
            return false
        }
    }

    private func pump() {
        guard !isWorking,
              let index = jobs.firstIndex(where: { $0.status == .pending }) else { return }
        isWorking = true
        jobs[index].status = .running(0)
        let job = jobs[index]
        Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await self.run(job)
                self.update(job.id, .done(summary))
            } catch {
                self.update(job.id, .failed(error.localizedDescription))
            }
            self.isWorking = false
            self.pump()
        }
    }

    private func update(_ id: UUID, _ status: Job.Status) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = status
    }

    private func run(_ job: Job) async throws -> String {
        // A job-private working directory, so a queued render can't clobber a
        // direct export running on the same project (the piece renderer wipes
        // its working directory).
        let workingDirectory = job.renderDir.appendingPathComponent("queue-\(job.id.uuidString)")
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let overlays = try Self.overlayInputs(for: job.edit, in: workingDirectory)
        let videoOverlays = await ExportService.videoOverlayInputs(for: job.edit)
        var voiceover: ExportService.VoiceoverInput?
        if let voURL = job.edit.voiceoverURL, FileManager.default.fileExists(atPath: voURL.path) {
            voiceover = .init(url: voURL, start: job.edit.voiceoverStart,
                              gainDB: job.edit.voiceoverGainDB)
        }
        let service = try ExportService()
        let onProgress: (Double) -> Void = { [weak self] value in
            Task { @MainActor in self?.update(job.id, .running(value)) }
        }

        if job.platformSet {
            try FileManager.default.createDirectory(at: job.destination,
                                                    withIntermediateDirectories: true)
            let stem = Self.stem(for: job)
            let master = job.destination.appendingPathComponent("\(stem)-portrait.mp4")
            _ = try await service.exportClipEdit(
                clips: job.edit.clips, overlays: overlays,
                videoOverlays: videoOverlays, voiceover: voiceover,
                sfx: ExportService.sfxInputs(for: job.edit),
                musicURL: job.edit.musicURL, musicGainDB: job.edit.musicGainDB,
                crossfade: job.edit.crossfadeDuration,
                transition: job.edit.transitionStyle,
                renderWidth: job.edit.aspect.width, renderHeight: job.edit.aspect.height,
                settings: job.settings, destination: master,
                workingDirectory: workingDirectory,
                onProgress: onProgress, onLog: { _ in })
            let outputs = try await service.exportPlatformSet(
                master: master, duration: job.edit.exportDuration, stem: stem,
                directory: job.destination, settings: job.settings, onLog: { _ in })
            return "\(outputs.count + 1) files in \(job.destination.lastPathComponent)"
        }

        let result = try await service.exportClipEdit(
            clips: job.edit.clips, overlays: overlays,
            videoOverlays: videoOverlays, voiceover: voiceover,
            sfx: ExportService.sfxInputs(for: job.edit),
            musicURL: job.edit.musicURL, musicGainDB: job.edit.musicGainDB,
            crossfade: job.edit.crossfadeDuration,
            transition: job.edit.transitionStyle,
            renderWidth: job.edit.aspect.width, renderHeight: job.edit.aspect.height,
            settings: job.settings, destination: job.destination,
            workingDirectory: workingDirectory,
            onProgress: onProgress, onLog: { _ in })
        let size = ByteCountFormatter.string(fromByteCount: result.sizeBytes, countStyle: .file)
        return "\(size) · \(result.encoderName)"
    }

    static func stem(for job: Job) -> String {
        let raw = job.edit.title.isEmpty ? job.projectName : job.edit.title
        let cleaned = raw
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        return cleaned.isEmpty ? "clip" : String(cleaned.prefix(40))
    }

    /// Same overlay inputs the direct export builds — the always-on PNG plus
    /// one gated input per timed text item.
    static func overlayInputs(for edit: ClipEdit, in directory: URL) throws -> [ExportService.TimedOverlay] {
        var overlays: [ExportService.TimedOverlay] = []
        if let png = SocialOverlayRenderer.pngData(for: edit) {
            let url = directory.appendingPathComponent("overlay.png")
            try png.write(to: url, options: .atomic)
            overlays.append(.init(url: url, start: nil, end: nil))
        }
        for item in edit.textItems where item.isTimed && !item.isBlank {
            guard let png = SocialOverlayRenderer.pngData(for: item, aspect: edit.aspect) else { continue }
            let url = directory.appendingPathComponent("text-\(item.id.uuidString).png")
            try png.write(to: url, options: .atomic)
            overlays.append(.init(url: url, start: item.startTime, end: item.endTime))
        }
        return overlays
    }
}

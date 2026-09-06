import Foundation

/// Pulls a YouTube video into the shared Downloads folder as MP4, MP3 or WAV,
/// via yt-dlp — the same tool the link importer already uses. One download at
/// a time; every project's library lists the results.
@MainActor
final class MediaDownloader: ObservableObject {
    static let shared = MediaDownloader()

    enum Format: String, CaseIterable, Identifiable {
        case mp4 = "MP4"
        case mp3 = "MP3"
        case wav = "WAV"
        var id: String { rawValue }

        var explainer: String {
            switch self {
            case .mp4: return "video, up to 1080p — lands on the timeline"
            case .mp3: return "audio only, compressed — music under the cut"
            case .wav: return "audio only, uncompressed — music under the cut"
            }
        }
    }

    @Published private(set) var files: [URL] = []
    @Published private(set) var activeLabel: String?
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastError: String?
    @Published private(set) var lastFinished: String?

    var isDownloading: Bool { activeLabel != nil }

    init() {
        Paths.ensureAppDirectories()
        refresh()
    }

    /// What's in the shared folder, newest first.
    func refresh() {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: Paths.downloadsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        files = contents
            .filter { ["mp4", "mov", "mkv", "webm", "mp3", "wav", "m4a"].contains($0.pathExtension.lowercased()) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refresh()
    }

    func download(url: String, format: Format) {
        guard !isDownloading else { return }
        guard let ytdlp = ToolLocator.locate("yt-dlp") else {
            lastError = "yt-dlp was not found. Install it with Homebrew: brew install yt-dlp"
            return
        }
        activeLabel = "\(format.rawValue) — starting…"
        progress = 0
        lastError = nil
        lastFinished = nil

        let arguments = Self.arguments(for: format, url: url, directory: Paths.downloadsRoot,
                                       ffmpegDir: ToolLocator.locate("ffmpeg")?
                                           .deletingLastPathComponent().path)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await Shell.runChecked(ytdlp, arguments: arguments, onOutputLine: { line in
                    Task { @MainActor in
                        if let value = Self.parsePercent(line) {
                            self.progress = value / 100
                            self.activeLabel = String(format: "%@ — %.0f%%", format.rawValue, value)
                        } else if line.contains("ExtractAudio") || line.contains("Merger") {
                            self.activeLabel = "\(format.rawValue) — converting…"
                        }
                    }
                }, onErrorLine: { _ in })
                self.lastFinished = "Saved to the library's Downloads section."
            } catch {
                self.lastError = error.localizedDescription
            }
            self.activeLabel = nil
            self.refresh()
        }
    }

    // MARK: - Pure helpers (verified)

    /// The yt-dlp invocation per format. ffmpeg is keg-only, so its location
    /// is passed explicitly — yt-dlp's PATH search would never find it.
    nonisolated static func arguments(for format: Format, url: String, directory: URL,
                          ffmpegDir: String?) -> [String] {
        var arguments = ["--no-playlist", "--newline", "--no-warnings"]
        switch format {
        case .mp4:
            arguments += ["-f", "bv*[ext=mp4][height<=1080]+ba[ext=m4a]/b[ext=mp4]/b",
                          "--merge-output-format", "mp4"]
        case .mp3:
            arguments += ["-x", "--audio-format", "mp3", "--audio-quality", "0"]
        case .wav:
            arguments += ["-x", "--audio-format", "wav"]
        }
        if let ffmpegDir {
            arguments += ["--ffmpeg-location", ffmpegDir]
        }
        arguments += ["-o", directory.appendingPathComponent("%(title).80s [%(id)s].%(ext)s").path]
        arguments.append(url)
        return arguments
    }

    /// The canonical watch URL when the browser is actually on a video —
    /// nil on search results, channels, the home page.
    nonisolated static func watchURL(from url: URL) -> String? {
        let host = (url.host ?? "").lowercased()
        guard host.contains("youtube.com") || host == "youtu.be" else { return nil }
        if host == "youtu.be" {
            let id = url.lastPathComponent
            return id.isEmpty || id == "/" ? nil : "https://www.youtube.com/watch?v=\(id)"
        }
        if url.path == "/watch",
           let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
               .queryItems?.first(where: { $0.name == "v" })?.value, !id.isEmpty {
            return "https://www.youtube.com/watch?v=\(id)"
        }
        if url.path.hasPrefix("/shorts/") {
            let id = url.lastPathComponent
            return id.isEmpty ? nil : "https://www.youtube.com/watch?v=\(id)"
        }
        return nil
    }

    /// Audio files route to the music bed; video files route to the timeline.
    nonisolated static func isAudio(_ url: URL) -> Bool {
        ["mp3", "wav", "m4a", "aac", "flac", "ogg"].contains(url.pathExtension.lowercased())
    }

    nonisolated static func parsePercent(_ line: String) -> Double? {
        guard line.hasPrefix("[download]"), let percentRange = line.range(of: "%") else { return nil }
        let head = line[line.startIndex..<percentRange.lowerBound]
        guard let spaceIndex = head.lastIndex(of: " ") else { return nil }
        return Double(head[head.index(after: spaceIndex)...])
    }
}

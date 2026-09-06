import Foundation

/// What a link turns out to point at, before anything is downloaded.
struct RemoteVideo: Equatable {
    var id: String
    var title: String
    var duration: Double
    var uploader: String
    var fileExtension: String
    var width: Int
    var height: Int
    var isLive: Bool
    var webpageURL: String
    /// yt-dlp rarely knows the real size of an HLS VOD, but bitrate × duration
    /// lands close: on the test VOD it predicted 9.99 GB against an actual
    /// 9.62 GB, inside 4%.
    var estimatedBytes: Int64?

    var resolutionLabel: String { width > 0 ? "\(width)×\(height)" : "unknown" }

    var estimatedSizeLabel: String? {
        estimatedBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
}

struct DownloadProgress: Equatable {
    var downloadedBytes: Int64
    var estimatedBytes: Int64?
    var bytesPerSecond: Double?
    var fragmentCount: Int?

    /// Only ever approximate — see `RemoteVideo.estimatedBytes`.
    var fraction: Double? {
        guard let estimatedBytes, estimatedBytes > 0 else { return nil }
        return min(0.999, Double(downloadedBytes) / Double(estimatedBytes))
    }

    var speedLabel: String? {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    var etaLabel: String? {
        guard let estimatedBytes, let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        let remaining = Double(estimatedBytes - downloadedBytes)
        guard remaining > 0 else { return nil }
        return (remaining / bytesPerSecond).timecode
    }
}

enum DownloadError: LocalizedError {
    case toolMissing
    case notAURL(String)
    case unsupportedScheme(String)
    case liveStream
    case probeFailed(String)
    case noFileProduced
    case notEnoughSpace(needed: Int64, free: Int64)

    var errorDescription: String? {
        switch self {
        case .toolMissing:
            return "yt-dlp was not found. Install it with Homebrew: brew install yt-dlp"
        case .notAURL(let text):
            return "“\(text)” doesn't look like a link."
        case .unsupportedScheme(let scheme):
            return "Links have to be http or https — this one is \(scheme)."
        case .liveStream:
            return "That channel is live. A live stream has no end, so there's nothing to download yet — wait for the VOD."
        case .probeFailed(let detail):
            return "Couldn't read that link: \(detail)"
        case .noFileProduced:
            return "The download finished but no file was written."
        case .notEnoughSpace(let needed, let free):
            let format: (Int64) -> String = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            return "Not enough disk space: this needs about \(format(needed)) and \(format(free)) is free."
        }
    }
}

/// Downloads a VOD from a link, via yt-dlp.
///
/// Two steps rather than one. The probe is cheap and tells you what you're about
/// to commit to — title, runtime, and roughly how many gigabytes — before a
/// four-hour stream starts landing on the disk. It also catches the case that
/// matters: a link to a channel that is currently live, which yt-dlp would
/// happily record forever.
struct DownloadService {
    let ytdlp: URL

    init() throws {
        guard let ytdlp = ToolLocator.locate("yt-dlp") else { throw DownloadError.toolMissing }
        self.ytdlp = ytdlp
    }

    /// Where downloads land. Configurable, because a four-hour VOD is ten
    /// gigabytes and not everyone wants that on the boot volume.
    static var downloadsFolder: URL {
        get {
            if let stored = UserDefaults.standard.string(forKey: "downloadsFolder"), !stored.isEmpty {
                return URL(fileURLWithPath: stored)
            }
            return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VODEditor", isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "downloadsFolder") }
    }

    // MARK: - Links

    /// Cleans up a pasted link and rejects what can't be a video URL.
    ///
    /// Pasted text arrives with all sorts of decoration — surrounding angle
    /// brackets from chat clients, quotes, a trailing full stop, a missing
    /// scheme. None of that should be a failure the user has to fix by hand.
    static func normalize(_ raw: String) -> Result<URL, DownloadError> {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'"))
        while let last = text.last, ".,;)".contains(last) { text.removeLast() }
        guard !text.isEmpty else { return .failure(.notAURL(raw)) }

        // A bare host like `twitch.tv/videos/123` is still a link people paste.
        // The dot is what separates that from a stray word: it is only required
        // when there's no scheme to go on.
        if !text.contains("://") {
            guard text.contains("."), !text.contains(" ") else { return .failure(.notAURL(raw)) }
            text = "https://" + text
        }

        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased() else {
            return .failure(.notAURL(raw))
        }
        // Checked before the host, so `file:///etc/passwd` is reported as the
        // wrong kind of link rather than a malformed one. Anything but http(s)
        // has no business being handed to a downloader.
        guard scheme == "http" || scheme == "https" else {
            return .failure(.unsupportedScheme(scheme))
        }
        guard let host = components.host, !host.isEmpty else {
            return .failure(.notAURL(raw))
        }
        guard let url = components.url else { return .failure(.notAURL(raw)) }
        return .success(url)
    }

    /// Splits a paste into links, so a block of URLs copied out of a document
    /// queues in one go.
    static func extractLinks(_ text: String) -> [URL] {
        var found: [URL] = []
        for piece in text.split(whereSeparator: { $0.isNewline || $0 == "\t" || $0 == " " }) {
            if case .success(let url) = normalize(String(piece)),
               !found.contains(where: { $0.absoluteString == url.absoluteString }) {
                found.append(url)
            }
        }
        return found
    }

    // MARK: - Probe

    /// A single metadata read. No video is touched.
    func probe(_ url: URL) async throws -> RemoteVideo {
        let separator = "\u{1F}"
        let fields = ["%(id)s", "%(title)s", "%(duration)s", "%(uploader)s", "%(ext)s",
                      "%(width)s", "%(height)s", "%(is_live)s", "%(tbr)s", "%(filesize_approx)s",
                      "%(webpage_url)s"]

        let result = try await Shell.run(ytdlp, arguments: [
            "--no-warnings", "--no-playlist", "--no-download",
            "--print", fields.joined(separator: separator),
            url.absoluteString,
        ])
        guard result.succeeded else {
            throw DownloadError.probeFailed(Self.cleanError(result.stderr))
        }

        let line = result.stdout
            .split(separator: "\n")
            .last { $0.contains(separator) }
            .map(String.init) ?? ""
        let parts = line.components(separatedBy: separator)
        guard parts.count >= 11 else {
            throw DownloadError.probeFailed("yt-dlp returned nothing usable for that link")
        }

        func value(_ index: Int) -> String? {
            let raw = parts[index].trimmingCharacters(in: .whitespaces)
            return (raw.isEmpty || raw == "NA" || raw == "None") ? nil : raw
        }

        let duration = value(2).flatMap(Double.init) ?? 0
        let isLive = (value(7).map { $0.lowercased() == "true" }) ?? false
        if isLive { throw DownloadError.liveStream }

        // filesize_approx first when yt-dlp has it; otherwise bitrate × runtime.
        var estimated = value(9).flatMap { Int64($0) ?? Int64(Double($0) ?? 0) }
        if estimated == nil, let bitrate = value(8).flatMap(Double.init), duration > 0 {
            estimated = Int64(bitrate * 1000 / 8 * duration)
        }

        return RemoteVideo(
            id: value(0) ?? "video",
            title: value(1) ?? "Untitled",
            duration: duration,
            uploader: value(3) ?? "",
            fileExtension: value(4) ?? "mp4",
            width: value(5).flatMap { Int(Double($0) ?? 0) } ?? 0,
            height: value(6).flatMap { Int(Double($0) ?? 0) } ?? 0,
            isLive: isLive,
            webpageURL: value(10) ?? url.absoluteString,
            estimatedBytes: estimated
        )
    }

    // MARK: - Download

    /// Downloads to `folder` and returns the finished file.
    ///
    /// Resumable: yt-dlp keeps a `.part` file and its fragments, so a cancelled
    /// or crashed download picks up where it stopped rather than starting the
    /// ten gigabytes again.
    func download(_ video: RemoteVideo,
                  from url: URL,
                  to folder: URL,
                  onProgress: @escaping (DownloadProgress) -> Void,
                  onLog: @escaping (String) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let needed = video.estimatedBytes {
            try Self.checkSpace(needed: needed, in: folder)
        }

        // yt-dlp shells out to ffmpeg to remux, and the build this app uses is
        // keg-only — it is not on any PATH yt-dlp would search.
        var arguments = [
            "--no-playlist", "--newline", "--no-warnings",
            "--progress-template",
            "download:VODPROGRESS %(progress.downloaded_bytes)s %(progress.speed)s %(progress.fragment_count)s",
            "--concurrent-fragments", "4",
            "--retries", "10", "--fragment-retries", "10",
            "--continue",
            "-f", "bv*+ba/b",
            "--merge-output-format", "mp4",
            "-o", folder.appendingPathComponent("%(id)s.%(ext)s").path,
        ]
        if let ffmpeg = ToolLocator.locate("ffmpeg") {
            arguments += ["--ffmpeg-location", ffmpeg.deletingLastPathComponent().path]
        }
        arguments.append(url.absoluteString)

        let estimated = video.estimatedBytes
        try await Shell.runChecked(ytdlp, arguments: arguments, onOutputLine: { line in
            if let progress = Self.parseProgress(line, estimatedBytes: estimated) {
                onProgress(progress)
            } else if line.hasPrefix("[") || line.contains("Destination") {
                onLog(line)
            }
        }, onErrorLine: { line in
            onLog(line)
        })

        guard let file = Self.finishedFile(for: video, in: folder) else {
            throw DownloadError.noFileProduced
        }
        return file
    }

    /// Fetches just the audio rendition, for transcription.
    ///
    /// This goes through yt-dlp rather than letting ffmpeg decode the audio
    /// playlist directly, for two reasons measured on the test VOD: yt-dlp
    /// pulls four fragments at once and ran at roughly twice the rate of
    /// ffmpeg's single connection, and it resumes — an interrupted ffmpeg
    /// decode starts the whole four hours again.
    func downloadAudio(from url: URL,
                       to destination: URL,
                       estimatedBytes: Int64?,
                       onProgress: @escaping (DownloadProgress) -> Void,
                       onLog: @escaping (String) -> Void) async throws -> URL {
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var arguments = [
            "--no-playlist", "--newline", "--no-warnings",
            "--progress-template",
            "download:VODPROGRESS %(progress.downloaded_bytes)s %(progress.speed)s %(progress.fragment_count)s",
            "--concurrent-fragments", "4",
            "--retries", "10", "--fragment-retries", "10",
            "--continue",
            "-f", "ba",
            "-o", destination.path,
        ]
        if let ffmpeg = ToolLocator.locate("ffmpeg") {
            arguments += ["--ffmpeg-location", ffmpeg.deletingLastPathComponent().path]
        }
        arguments.append(url.absoluteString)

        try await Shell.runChecked(ytdlp, arguments: arguments, onOutputLine: { line in
            if let progress = Self.parseProgress(line, estimatedBytes: estimatedBytes) {
                onProgress(progress)
            }
        }, onErrorLine: onLog)

        // `-o` with a literal path still gets the extension appended when the
        // template has none, so the written file is found rather than assumed.
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let stem = destination.deletingPathExtension().lastPathComponent
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                     includingPropertiesForKeys: nil)) ?? []
        guard let found = contents.first(where: {
            $0.lastPathComponent.hasPrefix(stem) && !["part", "ytdl"].contains($0.pathExtension)
        }) else { throw DownloadError.noFileProduced }
        return found
    }

    /// `VODPROGRESS <downloaded> <speed> <fragments>`.
    ///
    /// Only the byte count and speed are trusted. yt-dlp's own total and ETA for
    /// an HLS VOD come from extrapolating the current fragment: on the test VOD
    /// they swung between 8.5 GB and 16.7 GB within seconds, and the ETA read
    /// thirteen hours. The denominator comes from the probe instead.
    static func parseProgress(_ line: String, estimatedBytes: Int64?) -> DownloadProgress? {
        guard line.hasPrefix("VODPROGRESS") else { return nil }
        let fields = line.split(separator: " ").map(String.init)
        guard fields.count >= 4 else { return nil }

        func number(_ text: String) -> Double? {
            (text == "NA" || text == "None") ? nil : Double(text)
        }
        guard let downloaded = number(fields[1]) else { return nil }

        return DownloadProgress(
            downloadedBytes: Int64(downloaded),
            estimatedBytes: estimatedBytes,
            bytesPerSecond: number(fields[2]),
            fragmentCount: number(fields[3]).map { Int($0) }
        )
    }

    /// The finished file, found by matching the id yt-dlp used for the name
    /// rather than assuming the extension. Twitch ids gain a `v` prefix on the
    /// way through, so guessing the filename gets it wrong.
    static func finishedFile(for video: RemoteVideo, in folder: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return contents
            .filter { $0.deletingPathExtension().lastPathComponent == video.id }
            .filter { !["part", "ytdl", "temp"].contains($0.pathExtension) }
            .max { left, right in
                let leftSize = (try? left.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let rightSize = (try? right.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return leftSize < rightSize
            }
    }

    /// Fragments and the assembled file coexist during a download, so the
    /// headroom check asks for more than the finished size.
    static func checkSpace(needed: Int64, in folder: URL) throws {
        let probe = FileManager.default.fileExists(atPath: folder.path)
            ? folder
            : folder.deletingLastPathComponent()
        guard let free = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else { return }
        let required = Int64(Double(needed) * 1.2)
        if free < required {
            throw DownloadError.notEnoughSpace(needed: required, free: free)
        }
    }

    /// yt-dlp prefixes its errors and wraps long ones; the last ERROR line is
    /// the useful part.
    static func cleanError(_ stderr: String) -> String {
        let lines = stderr.split(separator: "\n").map(String.init)
        let error = lines.last { $0.contains("ERROR:") } ?? lines.last ?? "unknown error"
        return error
            .replacingOccurrences(of: "ERROR: ", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

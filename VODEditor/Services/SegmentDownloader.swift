import Foundation

struct SegmentProgress: Equatable {
    var completed: Int
    var total: Int
    var bytes: Int64
    var bytesPerSecond: Double?

    var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }

    var speedLabel: String? {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    var etaLabel: String? {
        guard let bytesPerSecond, bytesPerSecond > 0, completed > 0, completed < total else { return nil }
        let averageSize = Double(bytes) / Double(completed)
        let remaining = averageSize * Double(total - completed)
        return (remaining / bytesPerSecond).timecode
    }
}

enum SegmentDownloadError: LocalizedError {
    case noSegments
    case segmentFailed(index: Int, status: Int)

    var errorDescription: String? {
        switch self {
        case .noSegments:
            return "That playlist lists no segments to download."
        case .segmentFailed(let index, let status):
            return "Segment \(index) failed with HTTP \(status)."
        }
    }
}

/// Fetches HLS segments in parallel.
///
/// This exists because Twitch throttles a *single* connection hard. Measured on
/// the test VOD, pulling cold segments one at a time sustained **339 KB/s**,
/// while the same segments over four connections came down at **16.3 MB/s** —
/// forty-eight times faster. yt-dlp never escaped the single-connection cap
/// despite `--concurrent-fragments`; its fragment loop measured 284 KB/s at
/// both `-N 4` and `-N 16`. So the segment fetching is done here instead.
///
/// Segments land as individual files and are then described by a local playlist
/// handed to ffmpeg, rather than concatenated by hand: that keeps ffmpeg in
/// charge of discontinuities, which a Twitch VOD is full of.
enum SegmentDownloader {
    /// Measured against the CDN with parallel fetches of cold segments: one
    /// connection sustained 339 KB/s, four reached 16.3 MB/s, and eight and
    /// sixteen landed in the same 13–16 MB/s band. The curve is flat past four,
    /// so six sits on the plateau without opening sockets for nothing.
    static let defaultConcurrency = 6

    struct Segment {
        var index: Int
        var url: URL
        var duration: Double
        var isDiscontinuity: Bool
    }

    // MARK: - Parsing

    /// Reads the rewritten playlist, whose segment URLs are already absolute.
    static func segments(inPlaylist text: String) -> [Segment] {
        var found: [Segment] = []
        var duration: Double = 0
        var discontinuity = false

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst("#EXTINF:".count).prefix { $0 != "," }) ?? 0
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY") {
                discontinuity = true
            } else if !line.isEmpty, !line.hasPrefix("#"), let url = URL(string: line) {
                found.append(Segment(index: found.count, url: url,
                                     duration: duration, isDiscontinuity: discontinuity))
                duration = 0
                discontinuity = false
            }
        }
        return found
    }

    // MARK: - Downloading

    /// Downloads every segment into `directory` and returns a local playlist
    /// describing them, ready to hand to ffmpeg.
    ///
    /// Resumable at segment granularity: anything already on disk with the
    /// right size is left alone, so an interrupted fetch costs at most the
    /// segments that were in flight.
    static func fetch(segments: [Segment],
                      into directory: URL,
                      concurrency: Int = defaultConcurrency,
                      onProgress: @escaping (SegmentProgress) -> Void) async throws -> URL {
        guard !segments.isEmpty else { throw SegmentDownloadError.noSegments }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // One URLSession per worker, deliberately.
        //
        // A single session multiplexes concurrent requests onto one HTTP/2
        // connection, and Twitch's throttle is *per connection* — so six
        // parallel downloads through one session sustained 133 KB/s, worse than
        // doing them one at a time. Separate sessions mean separate TCP
        // connections, which is the whole point.
        let sessions = (0..<concurrency).map { _ -> URLSession in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpMaximumConnectionsPerHost = 1
            configuration.timeoutIntervalForRequest = 120
            configuration.urlCache = nil
            return URLSession(configuration: configuration)
        }
        defer { sessions.forEach { $0.finishTasksAndInvalidate() } }

        let started = Date()
        let counter = Counter()

        // Seed the counter with whatever a previous run already fetched.
        for segment in segments {
            let file = Self.file(for: segment, in: directory)
            if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 {
                await counter.add(bytes: Int64(size), alreadyOnDisk: true)
            }
        }

        let cursor = Cursor(count: segments.count)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<min(concurrency, segments.count) {
                let session = sessions[worker]
                group.addTask {
                    while let index = await cursor.next() {
                        try Task.checkCancellation()
                        try await download(segments[index], into: directory, session: session,
                                           counter: counter, started: started,
                                           total: segments.count, onProgress: onProgress)
                    }
                }
            }
            try await group.waitForAll()
        }

        let playlist = directory.appendingPathComponent("local.m3u8")
        try localPlaylist(for: segments, in: directory).write(to: playlist, atomically: true,
                                                             encoding: .utf8)
        return playlist
    }

    private static func download(_ segment: Segment,
                                 into directory: URL,
                                 session: URLSession,
                                 counter: Counter,
                                 started: Date,
                                 total: Int,
                                 onProgress: @escaping (SegmentProgress) -> Void) async throws {
        let file = Self.file(for: segment, in: directory)
        if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 {
            return
        }

        let (temporary, response) = try await session.download(from: segment.url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw SegmentDownloadError.segmentFailed(index: segment.index, status: http.statusCode)
        }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)

        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let (completed, bytes) = await counter.add(bytes: size, alreadyOnDisk: false)
        let elapsed = Date().timeIntervalSince(started)
        onProgress(SegmentProgress(completed: completed, total: total, bytes: bytes,
                                   bytesPerSecond: elapsed > 0.5 ? Double(bytes) / elapsed : nil))
    }

    static func file(for segment: Segment, in directory: URL) -> URL {
        directory.appendingPathComponent(String(format: "seg_%05d.ts", segment.index))
    }

    /// The same timing structure, pointing at the local copies.
    static func localPlaylist(for segments: [Segment], in directory: URL) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-PLAYLIST-TYPE:VOD",
                     "#EXT-X-TARGETDURATION:10", "#EXT-X-MEDIA-SEQUENCE:0"]
        for segment in segments {
            if segment.isDiscontinuity { lines.append("#EXT-X-DISCONTINUITY") }
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append(Self.file(for: segment, in: directory).path)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Hands out the next segment index to whichever worker is free.
    private actor Cursor {
        private var index = 0
        private let count: Int

        init(count: Int) { self.count = count }

        func next() -> Int? {
            guard index < count else { return nil }
            defer { index += 1 }
            return index
        }
    }

    /// Tracks completed segments and bytes across the task group.
    private actor Counter {
        private var completed = 0
        private var bytes: Int64 = 0

        @discardableResult
        func add(bytes size: Int64, alreadyOnDisk: Bool) -> (Int, Int64) {
            completed += 1
            // Bytes already on disk count towards progress but not towards the
            // rate, or a resumed fetch would report an imaginary speed.
            if !alreadyOnDisk { bytes += size }
            return (completed, bytes)
        }
    }
}

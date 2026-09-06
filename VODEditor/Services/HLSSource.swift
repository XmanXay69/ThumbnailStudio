import Foundation

/// A VOD being edited in place, over the network.
struct RemoteSource: Codable, Equatable {
    var webpageURL: String
    /// Local rewritten playlist for the video rendition. This is the project's
    /// `sourcePath`, so everything downstream treats it as the source file.
    var playlistPath: String
    /// Local rewritten playlist for the audio-only rendition, decoded straight
    /// to 16 kHz mono for transcription.
    var audioPlaylistPath: String?
    var preparedAt: Date
    var videoFormat: String
    var audioFormat: String?
    /// The CDN playlist the rewritten local copy points at. AVFoundation can't
    /// open a local playlist whose segments are remote, so playback uses this.
    var remoteVideoPlaylist: String?
    /// What the full video would have cost to download, for the comparison the
    /// UI shows.
    var fullVideoBytes: Int64?
    var audioBytes: Int64?

    var playlistURL: URL { URL(fileURLWithPath: playlistPath) }
    var audioPlaylistURL: URL? { audioPlaylistPath.map { URL(fileURLWithPath: $0) } }
    var remotePlaybackURL: URL? { remoteVideoPlaylist.flatMap { URL(string: $0) } }

    /// What editing this VOD in place saves against downloading it.
    var savedBytes: Int64? {
        guard let full = fullVideoBytes else { return nil }
        return max(0, full - (audioBytes ?? 0))
    }
}

enum HLSError: LocalizedError {
    case noPlaylist(String)
    case notAPlaylist
    case noAudioRendition

    var errorDescription: String? {
        switch self {
        case .noPlaylist(let detail):
            return "Couldn't get a stream for that link: \(detail)"
        case .notAPlaylist:
            return "That link's stream isn't an HLS playlist, so it can't be edited without downloading."
        case .noAudioRendition:
            return "That VOD has no audio-only rendition, so the transcript would need the whole video."
        }
    }
}

/// Prepares a Twitch VOD for editing without downloading it.
///
/// The trick is one line of the playlist. Twitch serves finished VODs as
/// `#EXT-X-PLAYLIST-TYPE:EVENT`, which means "segments may still be appended" —
/// so ffmpeg and yt-dlp both refuse to seek and start pulling from the top. A
/// 60-second cut two hours in didn't finish in six minutes that way. The
/// playlist is complete (it ends with `#EXT-X-ENDLIST`), so rewriting that one
/// line to `VOD` and making the segment URLs absolute gives a playlist ffmpeg
/// will seek: the same cut then took **8 seconds**, and the frame it produced
/// was bit-identical to the same timestamp of the fully downloaded file.
enum HLSSource {
    static let protocolWhitelist = "file,http,https,tcp,tls,crypto"

    /// ffmpeg blocks nested protocols by default, so a local playlist pointing
    /// at remote segments opens as "Invalid data found" until they're allowed.
    static func inputArguments(for url: URL) -> [String] {
        guard url.pathExtension.lowercased() == "m3u8" else { return ["-i", url.path] }
        return ["-protocol_whitelist", protocolWhitelist, "-i", url.path]
    }

    static func isPlaylist(_ url: URL) -> Bool { url.pathExtension.lowercased() == "m3u8" }

    // MARK: - Preparing

    static func prepare(link: URL,
                        into directory: URL,
                        onLog: @escaping (String) -> Void = { _ in }) async throws -> RemoteSource {
        guard let ytdlp = ToolLocator.locate("yt-dlp") else { throw DownloadError.toolMissing }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let video = try await mediaPlaylistURL(ytdlp: ytdlp, link: link, format: "bv*/b")
        let videoPath = directory.appendingPathComponent("stream.m3u8")
        try await writeSeekablePlaylist(from: video.url, to: videoPath)
        onLog("Prepared video playlist (\(video.format))")

        // Audio-only is what makes this worth doing: 388 MB against 9.31 GB on
        // the test VOD, and it's all transcription needs.
        var audioPath: URL?
        var audio: (url: URL, format: String, size: Int64?)?
        if let found = try? await mediaPlaylistURL(ytdlp: ytdlp, link: link, format: "ba") {
            let path = directory.appendingPathComponent("audio.m3u8")
            try await writeSeekablePlaylist(from: found.url, to: path)
            audioPath = path
            audio = found
            onLog("Prepared audio playlist (\(found.format))")
        }

        return RemoteSource(
            webpageURL: link.absoluteString,
            playlistPath: videoPath.path,
            audioPlaylistPath: audioPath?.path,
            preparedAt: Date(),
            videoFormat: video.format,
            audioFormat: audio?.format,
            remoteVideoPlaylist: video.url.absoluteString,
            fullVideoBytes: video.size,
            audioBytes: audio?.size
        )
    }

    /// Re-derives the playlists. The segment URLs are CDN paths that may stop
    /// resolving after a while; nothing downstream can tell the difference
    /// between an expired URL and a dead network, so this is offered as a
    /// deliberate refresh rather than guessed at.
    static func refresh(_ source: RemoteSource,
                        into directory: URL) async throws -> RemoteSource {
        guard let link = URL(string: source.webpageURL) else { throw HLSError.notAPlaylist }
        return try await prepare(link: link, into: directory)
    }

    // MARK: - Playlist rewriting

    private static func mediaPlaylistURL(ytdlp: URL, link: URL,
                                         format: String) async throws -> (url: URL, format: String, size: Int64?) {
        let result = try await Shell.run(ytdlp, arguments: [
            "--no-warnings", "--no-playlist", "-f", format,
            "--print", "%(urls)s\u{1F}%(format_id)s\u{1F}%(filesize_approx)s\u{1F}%(tbr)s\u{1F}%(duration)s",
            "--no-download", link.absoluteString,
        ])
        guard result.succeeded else {
            throw HLSError.noPlaylist(DownloadService.cleanError(result.stderr))
        }
        let line = result.stdout.split(separator: "\n").last { $0.contains("\u{1F}") }.map(String.init) ?? ""
        let parts = line.components(separatedBy: "\u{1F}")
        guard parts.count >= 5, let url = URL(string: parts[0].trimmingCharacters(in: .whitespaces)) else {
            throw HLSError.noPlaylist("yt-dlp returned no stream URL")
        }
        guard isPlaylist(url) else { throw HLSError.notAPlaylist }

        func value(_ index: Int) -> String? {
            let raw = parts[index].trimmingCharacters(in: .whitespaces)
            return (raw.isEmpty || raw == "NA" || raw == "None") ? nil : raw
        }
        var size = value(2).flatMap { Int64(Double($0) ?? 0) }
        if size == nil, let bitrate = value(3).flatMap(Double.init),
           let duration = value(4).flatMap(Double.init) {
            size = Int64(bitrate * 1000 / 8 * duration)
        }
        return (url, value(1) ?? format, size)
    }

    private static func writeSeekablePlaylist(from remote: URL, to destination: URL) async throws {
        let (data, response) = try await URLSession.shared.data(from: remote)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HLSError.noPlaylist("playlist returned HTTP \(http.statusCode)")
        }
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains("#EXTM3U") else { throw HLSError.notAPlaylist }
        try rewrite(text, base: remote).write(to: destination, atomically: true, encoding: .utf8)
    }

    /// EVENT → VOD, and every segment reference made absolute so the playlist
    /// still resolves once it's sitting on the local disk.
    static func rewrite(_ playlist: String, base: URL) -> String {
        let directory = base.deletingLastPathComponent()
        var lines: [String] = []

        for raw in playlist.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-PLAYLIST-TYPE:") {
                lines.append("#EXT-X-PLAYLIST-TYPE:VOD")
            } else if line.hasPrefix("#") || line.isEmpty {
                lines.append(raw)
            } else if line.hasPrefix("http://") || line.hasPrefix("https://") {
                lines.append(line)
            } else {
                lines.append(directory.appendingPathComponent(line).absoluteString)
            }
        }

        // A playlist with no type at all is treated as live, and seeks the same
        // way EVENT does — so one has to be declared either way.
        if !lines.contains(where: { $0.hasPrefix("#EXT-X-PLAYLIST-TYPE:") }),
           let index = lines.firstIndex(where: { $0.hasPrefix("#EXTM3U") }) {
            lines.insert("#EXT-X-PLAYLIST-TYPE:VOD", at: index + 1)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Total runtime from the playlist's own segment durations, so a streamed
    /// project knows its length without decoding anything.
    static func duration(ofPlaylist text: String) -> Double {
        var total = 0.0
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("#EXTINF:") {
            let value = line.dropFirst("#EXTINF:".count).prefix { $0 != "," }
            total += Double(value) ?? 0
        }
        return total
    }
}

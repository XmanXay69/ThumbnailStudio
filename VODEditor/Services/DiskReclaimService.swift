import Foundation

/// Derived media hygiene. A project accumulates gigabytes that exist only
/// to feed a step that already ran — the 16-kHz WAV whisper listened to,
/// filmstrip caches, export intermediates. This measures them, deletes
/// only what regenerates, and never touches a file the timeline points at.
enum DiskReclaimService {
    struct Footprint: Equatable {
        var totalBytes: Int64 = 0
        var reclaimableBytes: Int64 = 0
    }

    /// Directory size by full walk.
    static func directoryBytes(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url,
                                             includingPropertiesForKeys: [.fileSizeKey],
                                             options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// What reclaim would delete, honestly scoped:
    /// - the audio dir's WAVs, only once a transcript exists to show for them
    /// - whisper chunk files (re-chunked on demand)
    /// - thumbnails (posters regenerate)
    /// - render-dir files NOT referenced by the timeline, long-form or
    ///   thumbnail documents — referenced pieces are the user's clips.
    static func reclaimTargets(root: URL, audioDir: URL, chunksDir: URL,
                               thumbnailsDir: URL, renderDirs: [URL],
                               transcriptExists: Bool,
                               referencedPaths: Set<String>) -> [URL] {
        let fm = FileManager.default
        var targets: [URL] = []
        if transcriptExists {
            for file in (try? fm.contentsOfDirectory(at: audioDir,
                                                     includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension.lowercased() == "wav" {
                targets.append(file)
            }
            if fm.fileExists(atPath: chunksDir.path) {
                targets.append(chunksDir)
            }
        }
        if fm.fileExists(atPath: thumbnailsDir.path) {
            targets.append(thumbnailsDir)
        }
        for renderDir in renderDirs {
            for file in (try? fm.contentsOfDirectory(at: renderDir,
                                                     includingPropertiesForKeys: nil)) ?? []
            where !referencedPaths.contains(file.standardizedFileURL.path) {
                targets.append(file)
            }
        }
        return targets
    }

    /// Every media path a project's documents point at — these survive.
    static func referencedPaths(edit: ClipEdit) -> Set<String> {
        var paths = Set<String>()
        for clip in edit.clips { paths.insert(URL(fileURLWithPath: clip.sourcePath).standardizedFileURL.path) }
        for overlay in edit.overlayClips { paths.insert(URL(fileURLWithPath: overlay.sourcePath).standardizedFileURL.path) }
        for event in edit.sfxEvents { paths.insert(URL(fileURLWithPath: event.path).standardizedFileURL.path) }
        if let music = edit.musicPath { paths.insert(URL(fileURLWithPath: music).standardizedFileURL.path) }
        if let vo = edit.voiceoverPath { paths.insert(URL(fileURLWithPath: vo).standardizedFileURL.path) }
        return paths
    }

    @discardableResult
    static func delete(_ targets: [URL]) -> Int64 {
        let fm = FileManager.default
        var freed: Int64 = 0
        for target in targets {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: target.path, isDirectory: &isDirectory) else { continue }
            freed += isDirectory.boolValue
                ? directoryBytes(target)
                : Int64((try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            try? fm.removeItem(at: target)
        }
        return freed
    }

    /// Archive: everything goes except the JSON state — top-level documents,
    /// the transcript, the analysis JSONs, and the named snapshots. The
    /// project reopens, the story survives, media re-renders if it's ever
    /// needed again.
    static func archiveTargets(root: URL, keepDirs: [URL]) -> [URL] {
        let fm = FileManager.default
        let kept = Set(keepDirs.map { $0.standardizedFileURL.path })
        var targets: [URL] = []
        for entry in (try? fm.contentsOfDirectory(at: root,
                                                  includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            let standardized = entry.standardizedFileURL.path
            if kept.contains(standardized) { continue }
            if entry.pathExtension.lowercased() == "json" { continue }
            targets.append(entry)
        }
        return targets
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

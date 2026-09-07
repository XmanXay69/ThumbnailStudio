import Foundation

/// Every file this app owns lives under Application Support. The app is not
/// sandboxed, so these are plain paths — no container, no security-scoped
/// bookmarks. Source VODs are read in place from wherever they already are.
enum Paths {
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VODEditor", isDirectory: true)
    }

    static var projectsRoot: URL { appSupport.appendingPathComponent("Projects", isDirectory: true) }
    static var modelsRoot: URL { appSupport.appendingPathComponent("models", isDirectory: true) }

    /// User-saved thumbnail templates, shared across projects.
    static var thumbTemplatesRoot: URL {
        appSupport.appendingPathComponent("ThumbTemplates", isDirectory: true)
    }

    /// Media pulled through the in-app browser — every project's library lists
    /// this folder, so a download is one drag from any timeline. It sits on
    /// the Desktop rather than inside Application Support so the files are
    /// reachable in Finder without unhiding `~/Library`.
    static var downloadsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/VOD_Editor/Clips", isDirectory: true)
    }

    /// Where downloads lived before the move; anything still there is
    /// relocated on launch rather than stranded in a hidden folder.
    static var legacyDownloadsRoot: URL {
        appSupport.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Standalone Thumb Lab designs — thumbnails with no VOD attached.
    static var thumbLabRoot: URL {
        appSupport.appendingPathComponent("ThumbLab", isDirectory: true)
    }

    /// Your own images, organised in Finder rather than in a database.
    ///
    /// Same shape as the SFX library that already works in this codebase: a
    /// folder you can see, where a subfolder is a tag. Dropping a logo into
    /// "Logos" is the whole filing system, and it survives the app being
    /// rewritten around it.
    static var assetsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/Thumbnail Studio/Assets", isDirectory: true)
    }

    /// The sound-effect library. On the Desktop for the same reason as
    /// Clips: drop files (or folders — a folder becomes a tag) in Finder
    /// and they appear in the editor's SFX panel.
    static var sfxRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/VOD_Editor/SFX", isDirectory: true)
    }

    /// Moves every file across, never overwriting: a name that already exists
    /// on the far side gets a numbered suffix, the way Finder does it. The old
    /// directory is removed only once it is genuinely empty, so a failed move
    /// can't silently lose a file.
    @discardableResult
    static func migrateDownloads(from source: URL, to destination: URL) -> Int {
        let fm = FileManager.default
        guard source.standardizedFileURL != destination.standardizedFileURL,
              fm.fileExists(atPath: source.path) else { return 0 }
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var moved = 0
        for url in (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [] {
            var target = destination.appendingPathComponent(url.lastPathComponent)
            var suffix = 2
            while fm.fileExists(atPath: target.path) {
                let stem = url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension
                let name = ext.isEmpty ? "\(stem) (\(suffix))" : "\(stem) (\(suffix)).\(ext)"
                target = destination.appendingPathComponent(name)
                suffix += 1
            }
            if (try? fm.moveItem(at: url, to: target)) != nil { moved += 1 }
        }
        let leftovers = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
        if leftovers.isEmpty { try? fm.removeItem(at: source) }
        return moved
    }

    static func projectDir(_ id: UUID) -> URL {
        projectsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Layout of a single project's working directory.
    struct Project {
        let root: URL

        init(_ id: UUID) { root = Paths.projectDir(id) }

        var manifest: URL { root.appendingPathComponent("project.json") }
        var audioDir: URL { root.appendingPathComponent("audio", isDirectory: true) }
        var fullAudio: URL { audioDir.appendingPathComponent("full16k.wav") }
        /// Audio-only rendition fetched for a streamed project, deleted once
        /// the 16 kHz copy exists.
        var remoteAudio: URL { audioDir.appendingPathComponent("source-audio.m4a") }
        /// HLS segments pulled in parallel, deleted once decoded.
        var remoteSegments: URL { audioDir.appendingPathComponent("segments", isDirectory: true) }
        var chunksDir: URL { audioDir.appendingPathComponent("chunks", isDirectory: true) }
        var transcriptDir: URL { root.appendingPathComponent("transcript", isDirectory: true) }
        var mergedTranscript: URL { transcriptDir.appendingPathComponent("transcript.json") }
        var analysisDir: URL { root.appendingPathComponent("analysis", isDirectory: true) }
        var silence: URL { analysisDir.appendingPathComponent("silence.json") }
        var waveform: URL { analysisDir.appendingPathComponent("waveform.bin") }
        var score: URL { analysisDir.appendingPathComponent("score.json") }
        var scenes: URL { analysisDir.appendingPathComponent("scenes.json") }
        var throughlines: URL { analysisDir.appendingPathComponent("throughlines.json") }
        var styleProfile: URL { analysisDir.appendingPathComponent("style.json") }
        var audioProfile: URL { analysisDir.appendingPathComponent("audio.json") }
        var shorts: URL { root.appendingPathComponent("shorts.json") }
        var longForm: URL { root.appendingPathComponent("longform.json") }
        /// Generated ASS files live here so a failed render can be inspected.
        var renderDir: URL { root.appendingPathComponent("render", isDirectory: true) }
        var thumbnailsDir: URL { root.appendingPathComponent("thumbnails", isDirectory: true) }
        var ideas: URL { root.appendingPathComponent("ideas.json") }
        var clipEdit: URL { root.appendingPathComponent("clipedit.json") }
        /// Cached clip-finder results — re-opening a project never re-runs
        /// inference.
        var autoClips: URL { root.appendingPathComponent("autoclips.json") }
        /// The Thumbnail Studio's document.
        var thumbStudio: URL { root.appendingPathComponent("thumbstudio.json") }
        /// Named cut snapshots — "v1 safe", "aggressive trim" — one JSON each.
        var versionsDir: URL { root.appendingPathComponent("versions", isDirectory: true) }
        /// Candidates sent to the editor are rendered here as finished
        /// portrait pieces, so the timeline gets 1080×1920 with the clip's own
        /// framing and captions — not the raw landscape source.
        var timelineClipsDir: URL { root.appendingPathComponent("timeline-clips", isDirectory: true) }

        func chunkAudio(_ index: Int) -> URL {
            chunksDir.appendingPathComponent(String(format: "chunk_%04d.wav", index))
        }

        /// whisper-cli is given this as `-of`, and appends `.json` itself.
        func chunkTranscriptBase(_ index: Int) -> URL {
            transcriptDir.appendingPathComponent(String(format: "chunk_%04d", index))
        }

        func chunkTranscript(_ index: Int) -> URL {
            transcriptDir.appendingPathComponent(String(format: "chunk_%04d.json", index))
        }

        func createDirectories() throws {
            for dir in [root, audioDir, chunksDir, transcriptDir, analysisDir, renderDir, thumbnailsDir, timelineClipsDir] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }

    /// What the standalone Thumbnail Studio needs — no Clips, no SFX, no
    /// Projects folder, so a design-only app doesn't litter the Desktop.
    static func ensureThumbDirectories() {
        for dir in [appSupport, thumbTemplatesRoot, thumbLabRoot, assetsRoot] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func ensureAppDirectories() {
        for dir in [appSupport, projectsRoot, modelsRoot, downloadsRoot, thumbTemplatesRoot, sfxRoot] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        migrateDownloads(from: legacyDownloadsRoot, to: downloadsRoot)
    }
}

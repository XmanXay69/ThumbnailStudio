import AppKit
import CryptoKit
import Foundation

/// Images the studio owns rather than references.
///
/// A layer that points at a pasted screenshot in /tmp, or at a `.cutout.png`
/// written beside a photo in a folder the user may not own, is a layer that
/// breaks later. Anything the app generates or receives without a stable file
/// of its own is copied here first, named by the hash of its contents — so the
/// same image pasted twice costs one file, and re-running a cutout is free.
enum ThumbAssets {
    static var root: URL {
        Paths.appSupport.appendingPathComponent("ThumbAssets", isDirectory: true)
    }

    private static func ensureRoot() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes PNG data under a content-addressed name and returns its URL.
    /// Identical content reuses the existing file rather than writing again.
    static func store(data: Data, extension ext: String = "png", suffix: String = "") -> URL? {
        ensureRoot()
        let name = digest(data) + (suffix.isEmpty ? "" : "-\(suffix)") + "." + ext
        let url = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    static func store(image: NSImage, suffix: String = "") -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return store(data: png, suffix: suffix)
    }

    /// Deletes generated images no design points at any more.
    ///
    /// Every nudge of an edge slider writes a new cutout, because they are
    /// keyed by their settings so going back to a value you already tried is
    /// instant. That is the right trade for responsiveness and the wrong one
    /// for disk, so the unreferenced ones go at launch. A file is kept if ANY
    /// design or project thumbnail document names it — nothing is deleted on a
    /// guess about age, because a cutout a design still uses can't be
    /// regenerated without re-running Vision on a source that may have moved.
    @discardableResult
    static func pruneUnreferenced() -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil),
              !files.isEmpty else { return 0 }

        var referenced = Set<String>()
        func harvest(_ url: URL) {
            guard let data = try? Data(contentsOf: url),
                  let doc = try? JSONDecoder().decode(ThumbDocument.self, from: data) else { return }
            for layer in doc.layers {
                guard case .image(let spec) = layer.kind else { continue }
                referenced.insert(spec.path)
                if let cutout = spec.cutoutPath { referenced.insert(cutout) }
            }
        }

        for url in (try? fm.contentsOfDirectory(at: Paths.thumbLabRoot,
                                                includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "json" {
            harvest(url)
        }
        for project in (try? fm.contentsOfDirectory(at: Paths.projectsRoot,
                                                    includingPropertiesForKeys: nil)) ?? [] {
            harvest(project.appendingPathComponent("thumbstudio.json"))
        }
        for url in (try? fm.contentsOfDirectory(at: Paths.thumbTemplatesRoot,
                                                includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "json" {
            harvest(url)
        }

        // A file no *saved* document names may still be live: an undo entry
        // in a running app points at the cutout it is about to restore, and
        // the layer clipboard points at whatever you last copied. Anything
        // touched in the last day stays.
        let cutoff = Date().addingTimeInterval(-86_400)
        var removed = 0
        for file in files where !referenced.contains(file.path) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard modified < cutoff else { continue }
            if (try? fm.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    /// Where a cutout of this source file belongs. Keyed by the source's
    /// actual bytes, not its path or timestamp: replacing an image at the same
    /// path — a re-export from another app, a file on a volume with
    /// second-granularity timestamps — must not silently reuse the old
    /// subject. Falls back to path and size if the file cannot be read.
    static func cutoutURL(for sourcePath: String, tag: String) -> URL {
        ensureRoot()
        let url = URL(fileURLWithPath: sourcePath)
        let identity: Data = {
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                return Data(digest(data).utf8)
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: sourcePath)[.size]
                as? Int)??.description ?? "0"
            return Data("\(sourcePath)|\(size)".utf8)
        }()
        let key = identity + Data("|\(tag)".utf8)
        return root.appendingPathComponent("cutout-\(digest(key)).png")
    }
}

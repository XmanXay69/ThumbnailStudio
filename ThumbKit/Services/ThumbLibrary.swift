import AppKit
import Foundation

/// Every image you can reach, from two places that need no bookkeeping.
///
/// **Your folder** — `~/Desktop/Thumbnail Studio/Assets`, where a subfolder is
/// a tag. This is the SFX library's pattern, already proven in this codebase:
/// Finder is the organiser, so there is no database to corrupt, no import step,
/// and filing a logo is dragging it into a folder.
///
/// **Recents** — every image any saved design actually uses, newest design
/// first. That list maintains itself, which is the point: the images you reach
/// for again are the ones you already used.
enum ThumbLibrary {
    struct Asset: Identifiable, Equatable {
        var id: String { path }
        var path: String
        var name: String
        /// The subfolder it came from, or nil for a loose file or a recent.
        var tag: String?
        var modifiedAt: Date
        var source: Source

        enum Source: String {
            /// A file you filed yourself, under the Assets folder.
            case folder
            /// Brought into the app's own storage — picked, pasted, or dropped.
            case imported
            /// A subject lifted by Remove Background.
            case cutout
            /// A frame grabbed off a video timeline.
            case frame
            /// Referenced by a saved design but living somewhere else on disk.
            case recent

            var label: String {
                switch self {
                case .folder: return "filed"
                case .imported: return "uploaded"
                case .cutout: return "cutout"
                case .frame: return "frame"
                case .recent: return "used before"
                }
            }
        }

        var url: URL { URL(fileURLWithPath: path) }
        var exists: Bool { FileManager.default.fileExists(atPath: path) }
    }

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "gif", "tiff", "tif", "webp", "bmp",
    ]

    /// Files under the assets folder, one level of subfolder as the tag.
    static func folderAssets() -> [Asset] {
        let fm = FileManager.default
        let root = Paths.assetsRoot
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.contentModificationDateKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var found: [Asset] = []
        for case let url as URL in walker {
            guard imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let parts = relative.split(separator: "/")
            let tag = parts.count > 1 ? String(parts[0]) : nil
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            found.append(Asset(path: url.path,
                               name: url.deletingPathExtension().lastPathComponent,
                               tag: tag, modifiedAt: modified, source: .folder))
        }
        return found.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Images referenced by saved designs, most recently edited design first,
    /// each path appearing once.
    static func recentAssets(limit: Int = 60) -> [Asset] {
        var seen = Set<String>()
        var found: [Asset] = []
        for design in StandaloneThumbStore.designs() {
            guard let data = try? Data(contentsOf: design.url),
                  let document = try? JSONDecoder().decode(ThumbDocument.self, from: data)
            else { continue }
            for layer in document.layers {
                guard case .image(let spec) = layer.kind else { continue }
                // The original, not the cutout: a cutout is a derivative of
                // something already in this list.
                let path = spec.path
                guard !path.isEmpty, !seen.contains(path) else { continue }
                seen.insert(path)
                found.append(Asset(path: path,
                                   name: URL(fileURLWithPath: path)
                                       .deletingPathExtension().lastPathComponent,
                                   tag: nil, modifiedAt: design.modifiedAt, source: .recent))
                if found.count >= limit { return found }
            }
        }
        return found
    }

    /// What the app itself is holding: every image brought in through a pick,
    /// a paste or a drop, plus the cutouts and frame grabs it generated.
    ///
    /// This is the half the library used to miss entirely. `recentAssets`
    /// only finds images a SAVED DESIGN still points at, so an image you
    /// imported and then deleted the layer for had vanished from the library
    /// while the file sat in the store the whole time.
    static func storedAssets() -> [Asset] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: ThumbAssets.root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }

        return files.compactMap { url -> Asset? in
            guard imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            let file = url.lastPathComponent
            // The store names things by what made them, so the name is the
            // only provenance record there is — and the only way to tell an
            // image you chose from one the app generated for you.
            let source: Asset.Source = file.hasPrefix("cutout-") ? .cutout
                : file.hasPrefix("grab-") ? .frame : .imported
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return Asset(path: url.path,
                         name: displayName(for: url, source: source),
                         tag: nil, modifiedAt: modified, source: source)
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// A content-addressed filename is a hash, which tells you nothing. Where
    /// a saved design gives one a real name, use that instead.
    private static func displayName(for url: URL, source: Asset.Source) -> String {
        if let known = storedNames()[url.path] { return known }
        switch source {
        case .cutout: return "Cutout"
        case .frame: return "Frame"
        default: return url.deletingPathExtension().lastPathComponent
        }
    }

    /// Names recovered from the layer names in saved designs, so an imported
    /// file that once carried a filename keeps it.
    private static func storedNames() -> [String: String] {
        if let cached = nameCache { return cached }
        var found: [String: String] = [:]
        for design in StandaloneThumbStore.designs() {
            guard let data = try? Data(contentsOf: design.url),
                  let document = try? JSONDecoder().decode(ThumbDocument.self, from: data)
            else { continue }
            for layer in document.layers {
                guard case .image(let spec) = layer.kind, !layer.name.isEmpty else { continue }
                found[spec.path] = layer.name
                if let cutout = spec.cutoutPath { found[cutout] = layer.name + " cutout" }
            }
        }
        nameCache = found
        return found
    }

    /// Cleared whenever the library is rescanned, which is the only time it
    /// could be stale.
    private nonisolated(unsafe) static var nameCache: [String: String]?

    static func invalidate() { nameCache = nil }

    /// Everything, deduplicated by path: what you filed, what the app is
    /// holding, and what your designs point at elsewhere.
    static func all() -> [Asset] {
        invalidate()
        var seen = Set<String>()
        var out: [Asset] = []
        for asset in folderAssets() + storedAssets() + recentAssets()
        where !seen.contains(asset.path) {
            seen.insert(asset.path)
            out.append(asset)
        }
        return out
    }

    static func tags(in assets: [Asset]) -> [String] {
        Array(Set(assets.compactMap(\.tag))).sorted()
    }

    /// Brings a file into the app's own storage and returns the stored path.
    ///
    /// Designs point at this copy rather than at wherever you happened to drag
    /// it from, so moving or deleting the original cannot quietly empty a
    /// layer later. Storage is content-addressed, so importing the same file
    /// twice costs one copy.
    static func adopt(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let ext = imageExtensions.contains(url.pathExtension.lowercased())
            ? url.pathExtension.lowercased() : "png"
        return ThumbAssets.store(data: data, extension: ext)?.path
    }
}

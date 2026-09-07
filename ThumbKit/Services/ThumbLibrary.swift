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

        enum Source: String { case folder, recent }

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

    /// Everything, folder first, with recents that are already in the folder
    /// filtered out so nothing appears twice.
    static func all() -> [Asset] {
        let folder = folderAssets()
        let filed = Set(folder.map(\.path))
        return folder + recentAssets().filter { !filed.contains($0.path) }
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

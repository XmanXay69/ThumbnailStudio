import Foundation

/// Offline media, found and reconnected. Every path in an edit is absolute,
/// so moving a folder — which has already happened once here, when downloads
/// moved to the Desktop — silently breaks every clip that pointed into it.
/// This finds what's missing, searches a folder the user picks, and rewires
/// the whole document in one pass.
enum MediaRelinkService {
    /// Where a path lives in the document, so a match can be written back.
    enum Slot: Equatable {
        case clip(UUID)
        case overlay(UUID)
        case sfx(UUID)
        case music
        case voiceover
        case library(Int)

        var label: String {
            switch self {
            case .clip: return "Timeline clip"
            case .overlay: return "Overlay"
            case .sfx: return "Sound effect"
            case .music: return "Music bed"
            case .voiceover: return "Voice-over"
            case .library: return "Library item"
            }
        }
    }

    struct Missing: Identifiable, Equatable {
        var id: String { "\(slot)-\(path)" }
        var slot: Slot
        var path: String
        /// Filled once a candidate replacement is found.
        var replacement: String?

        var filename: String { URL(fileURLWithPath: path).lastPathComponent }
        var displayName: String {
            URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
    }

    /// Every media reference in the edit whose file is gone. Pure apart from
    /// the existence checks.
    static func missing(in edit: ClipEdit,
                        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> [Missing] {
        var found: [Missing] = []
        for clip in edit.clips where !exists(clip.sourcePath) {
            found.append(Missing(slot: .clip(clip.id), path: clip.sourcePath))
        }
        for overlay in edit.overlayClips where !exists(overlay.sourcePath) {
            found.append(Missing(slot: .overlay(overlay.id), path: overlay.sourcePath))
        }
        for event in edit.sfxEvents where !exists(event.path) {
            found.append(Missing(slot: .sfx(event.id), path: event.path))
        }
        if let music = edit.musicPath, !exists(music) {
            found.append(Missing(slot: .music, path: music))
        }
        if let voiceover = edit.voiceoverPath, !exists(voiceover) {
            found.append(Missing(slot: .voiceover, path: voiceover))
        }
        for (index, item) in edit.library.enumerated() where !exists(item) {
            found.append(Missing(slot: .library(index), path: item))
        }
        // One entry per reference — each slot needs its own rewrite. The UI
        // groups them by file so the user only locates each file once.
        return found.sorted { $0.path < $1.path }
    }

    /// Groups missing entries by file, so the UI offers one "locate" per
    /// actual file rather than per reference.
    static func groupedByFile(_ missing: [Missing]) -> [(path: String, slots: [Slot])] {
        var order: [String] = []
        var map: [String: [Slot]] = [:]
        for entry in missing {
            if map[entry.path] == nil { order.append(entry.path) }
            map[entry.path, default: []].append(entry.slot)
        }
        return order.map { (path: $0, slots: map[$0] ?? []) }
    }

    /// Walks a folder and indexes every file by name — the search half of a
    /// relink. Case-insensitive, because volumes differ.
    static func index(folder: URL, maxFiles: Int = 20_000) -> [String: [String]] {
        var byName: [String: [String]] = [:]
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder,
                                         includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return byName }
        var count = 0
        for case let url as URL in walker {
            guard count < maxFiles else { break }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            byName[url.lastPathComponent.lowercased(), default: []].append(url.path)
            count += 1
        }
        return byName
    }

    /// Matches missing files against an index: exact filename first, then a
    /// stem match (extension changed by a re-encode). Ambiguity resolves to
    /// the shortest path, which is the least-nested — usually the original
    /// rather than a copy in a subfolder.
    static func resolve(_ missing: [Missing],
                        against index: [String: [String]]) -> [Missing] {
        // Stem lookup built lazily from the same index.
        var byStem: [String: [String]] = [:]
        for (name, paths) in index {
            let stem = (name as NSString).deletingPathExtension
            byStem[stem, default: []].append(contentsOf: paths)
        }
        return missing.map { entry in
            var updated = entry
            let name = entry.filename.lowercased()
            let candidates = index[name]
                ?? byStem[(name as NSString).deletingPathExtension]
                ?? []
            updated.replacement = candidates.min { $0.count < $1.count }
            return updated
        }
    }

    /// Writes resolved replacements back into the document. Entries without
    /// a replacement are left alone, so a partial fix is still a fix.
    static func apply(_ resolved: [Missing], to edit: ClipEdit) -> (ClipEdit, Int) {
        var out = edit
        var fixed = 0
        for entry in resolved {
            guard let replacement = entry.replacement else { continue }
            switch entry.slot {
            case .clip(let id):
                guard let index = out.clips.firstIndex(where: { $0.id == id }) else { continue }
                out.clips[index].sourcePath = replacement
            case .overlay(let id):
                guard let index = out.overlayClips.firstIndex(where: { $0.id == id }) else { continue }
                out.overlayClips[index].sourcePath = replacement
            case .sfx(let id):
                guard let index = out.sfxEvents.firstIndex(where: { $0.id == id }) else { continue }
                out.sfxEvents[index].path = replacement
            case .music:
                out.musicPath = replacement
            case .voiceover:
                out.voiceoverPath = replacement
            case .library(let index):
                guard out.library.indices.contains(index) else { continue }
                out.library[index] = replacement
            }
            fixed += 1
        }
        return (out, fixed)
    }
}

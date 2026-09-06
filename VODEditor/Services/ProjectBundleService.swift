import Foundation

/// A project's *decisions* — the documents, transcript and analysis — as one
/// file you can drop on an external drive. Media is deliberately excluded:
/// 7.5 GB of source video doesn't belong in a backup you'll actually make,
/// and the source VOD can be re-downloaded. What can't be recovered is the
/// editing: the cut, the captions, the accept/reject calls, the snapshots.
///
/// A restored project opens with its media offline; one relink reconnects it.
enum ProjectBundleService {
    static let fileExtension = "vodbundle"

    /// The state files worth carrying, relative to a project root. Anything
    /// absent is skipped rather than failing the export.
    static let documentNames = [
        "project.json", "shorts.json", "longform.json",
        "clipedit.json", "thumbstudio.json", "autoclips.json",
    ]
    static let documentDirectories = ["transcript", "analysis", "versions"]

    /// What `ditto` should archive: existing documents plus the state dirs.
    static func itemsToArchive(root: URL,
                               exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) })
        -> [String] {
        var items: [String] = []
        for name in documentNames where exists(root.appendingPathComponent(name)) {
            items.append(name)
        }
        for directory in documentDirectories
        where exists(root.appendingPathComponent(directory, isDirectory: true)) {
            items.append(directory)
        }
        return items
    }

    /// `ditto -c -k --sequesterRsrc <root> <dest>` over a staging dir. Using
    /// ditto rather than hand-rolling zip keeps it a normal macOS archive the
    /// user can unzip in Finder.
    static func archiveArguments(stagingDir: URL, destination: URL) -> [String] {
        ["-c", "-k", "--sequesterRsrc", "--keepParent",
         stagingDir.path, destination.path]
    }

    static func extractArguments(bundle: URL, destination: URL) -> [String] {
        ["-x", "-k", bundle.path, destination.path]
    }

    /// A safe filename for the bundle: project name, punctuation flattened.
    static func filename(for projectName: String, date: Date = Date()) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = projectName.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let stem = cleaned.isEmpty ? "project" : String(cleaned.prefix(60))
        return "\(stem) \(formatter.string(from: date)).\(fileExtension)"
    }

    /// After extraction the project needs a fresh id so restoring twice, or
    /// restoring onto a machine that still has the original, doesn't collide.
    static func reidentified(_ projectJSON: Data, newID: UUID) -> Data? {
        guard var object = (try? JSONSerialization.jsonObject(with: projectJSON))
            as? [String: Any] else { return nil }
        object["id"] = newID.uuidString
        if let name = object["name"] as? String, !name.hasSuffix(" (restored)") {
            object["name"] = name + " (restored)"
        }
        return try? JSONSerialization.data(withJSONObject: object,
                                           options: [.prettyPrinted, .sortedKeys])
    }
}

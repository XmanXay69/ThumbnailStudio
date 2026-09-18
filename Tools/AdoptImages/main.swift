import AppKit
import Foundation

/// Brings every image a saved design points at into the app's own storage, and
/// rewrites the design to point at the copy.
///
/// A design that names a file in ~/Downloads is a design that breaks when that
/// folder is tidied — and, on a Mac with iCloud Optimise Storage, one that
/// stalls when the file is evicted and has to be fetched back. Storage here is
/// content-addressed, so the same picture used by four designs costs one copy.
///
///   Tools/adopt-images.sh [--dry-run]
///
/// Originals are never deleted. Copying is this tool's whole job; deciding
/// what to throw away is the owner's.
let dryRun = CommandLine.arguments.contains("--dry-run")
let fm = FileManager.default

func designFiles() -> [URL] {
    var found: [URL] = []
    for root in [Paths.thumbLabRoot, Paths.thumbTemplatesRoot] {
        let files = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        found += files.filter { $0.pathExtension == "json" }
    }
    let projects = (try? fm.contentsOfDirectory(at: Paths.projectsRoot,
                                                includingPropertiesForKeys: nil)) ?? []
    for project in projects {
        let thumb = project.appendingPathComponent("thumbstudio.json")
        if fm.fileExists(atPath: thumb.path) { found.append(thumb) }
    }
    return found
}

/// Already ours? Then leave it alone.
func isAppOwned(_ path: String) -> Bool {
    path.hasPrefix(ThumbAssets.root.path) || path.hasPrefix(Paths.assetsRoot.path)
}

/// Whether this reference is one we would move. Asked directly rather than
/// inferred from whether a copy happened, so a dry run reports the same set of
/// designs the real run rewrites — the first version counted newly-seen files,
/// so a design sharing an image with an earlier one looked untouched.
func needsAdopting(_ path: String) -> Bool {
    !path.isEmpty && !isAppOwned(path)
}

var adopted: [String: String] = [:]
var copiedBytes = 0
var rewritten = 0
var missing: [String] = []

func adopt(_ path: String) -> String? {
    guard !path.isEmpty, !isAppOwned(path) else { return nil }
    if let already = adopted[path] { return already }
    guard fm.fileExists(atPath: path) else {
        if !missing.contains(path) { missing.append(path) }
        return nil
    }
    let size = ((try? fm.attributesOfItem(atPath: path)[.size]) as? Int) ?? 0
    // A dry run must not write anything, including the copy — otherwise
    // "nothing written" is a lie and running it twice is not free.
    guard !dryRun else {
        adopted[path] = path
        copiedBytes += size
        return nil
    }
    guard let stored = ThumbLibrary.adopt(URL(fileURLWithPath: path)) else {
        if !missing.contains(path) { missing.append(path) }
        return nil
    }
    adopted[path] = stored
    copiedBytes += size
    return stored
}

for file in designFiles() {
    guard let data = try? Data(contentsOf: file),
          var document = try? JSONDecoder().decode(ThumbDocument.self, from: data)
    else { continue }
    var changed = false
    for index in document.layers.indices {
        guard case .image(var spec) = document.layers[index].kind else { continue }
        if needsAdopting(spec.path) {
            changed = true
            // Keep the filename as the layer's name before the path stops
            // carrying one. Storage is content-addressed, so after this the
            // file is called 552008be984a6ecfe.png — and a layers panel
            // listing three of those is not a list anyone can navigate.
            if document.layers[index].name.isEmpty {
                document.layers[index].name = URL(fileURLWithPath: spec.path)
                    .deletingPathExtension().lastPathComponent
            }
            if let moved = adopt(spec.path) { spec.path = moved }
        }
        if let cutout = spec.cutoutPath, needsAdopting(cutout) {
            changed = true
            if let moved = adopt(cutout) { spec.cutoutPath = moved }
        }
        // A text layer can hold an image too.
        document.layers[index].kind = .image(spec)
    }
    for index in document.layers.indices {
        guard case .text(var spec) = document.layers[index].kind,
              let fill = spec.imageFillPath, needsAdopting(fill) else { continue }
        changed = true
        if let moved = adopt(fill) { spec.imageFillPath = moved }
        document.layers[index].kind = .text(spec)
    }
    guard changed else { continue }
    rewritten += 1
    print("  \(file.lastPathComponent)")
    if !dryRun, let encoded = try? JSONEncoder().encode(document) {
        try? encoded.write(to: file, options: .atomic)
    }
}

print("")
let megabytes = Double(copiedBytes) / 1_000_000
print(String(format: "%d image%@ (%.1f MB) %@, %d design%@ repointed%@",
             adopted.count, adopted.count == 1 ? "" : "s", megabytes,
             dryRun ? "would be brought in" : "brought in",
             rewritten, rewritten == 1 ? "" : "s",
             dryRun ? "  (dry run — nothing written)" : ""))
if !missing.isEmpty {
    print("could not read \(missing.count):")
    for path in missing { print("  \(path)") }
}
print("originals left where they are: nothing was deleted")

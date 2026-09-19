import AppKit
import Foundation

/// What the Thumbnail Studio needs from whoever owns the document. Two
/// owners exist: a project session (thumbnails attached to a VOD) and the
/// standalone Thumb Lab (thumbnails that never touch a video).
@MainActor
protocol ThumbStore: ObservableObject {
    var thumbDoc: ThumbDocument { get }
    var isCuttingOut: Bool { get }
    var thumbStudioError: String? { get }
    var timelineUndoManager: UndoManager? { get set }

    func applyThumbDoc(_ document: ThumbDocument, action: String?)
    func removeBackground(layerID: UUID)

    /// Ends the current undo-coalescing run, so the next mutation starts a new
    /// step. A held arrow key is one undo entry; letting go should end it.
    func endUndoRun()

    /// Where pasted and generated images are written. App-owned by default —
    /// a layer must never point at a file the app did not put somewhere stable.
    var assetDirectory: URL { get }
}

extension ThumbStore {
    var assetDirectory: URL { ThumbAssets.root }
}

/// A design in the Thumb Lab: one JSON file, no project, no video. The lab
/// folder is the gallery — every design is its own document with the same
/// undo behaviour the project studio has.
@MainActor
final class StandaloneThumbStore: ObservableObject, ThumbStore {
    @Published private(set) var thumbDoc: ThumbDocument
    @Published var isCuttingOut = false
    @Published var thumbStudioError: String?
    weak var timelineUndoManager: UndoManager?

    /// The file is this design's identity, and renaming moves it — so this
    /// is a var, and a rename keeps the same store and the same undo stack.
    private(set) var fileURL: URL
    private var lastUndoAction: String?
    private var lastUndoRegistration = Date.distantPast
    /// The file's timestamp as of our own last read or write. Anything newer
    /// on disk was written by somebody else.
    private var knownModified: Date?
    /// Set when the file this store represents has gone. Writes stop rather
    /// than recreating it.
    private var isDetached = false
    private var detachedMessage: String { Self.detachedMessage }
    static let detachedMessage =
        "This design was renamed or deleted in another window — edits here aren't being saved."


    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(ThumbDocument.self, from: data) {
            thumbDoc = decoded
        } else {
            thumbDoc = ThumbDocument()
        }
        knownModified = Self.modified(at: fileURL)
    }

    private static func modified(at url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Designs live in one folder that both the standalone studio and the VOD
    /// editor's Thumb Lab can open, and every edit writes through immediately.
    /// Two apps on the same design would otherwise silently overwrite each
    /// other, so whoever comes to the front adopts what's on disk first. You
    /// can only type in one app at a time, which makes this enough.
    func reloadIfChangedExternally() {
        guard let onDisk = Self.modified(at: fileURL) else {
            // The other app renamed or trashed this design. Persisting again
            // would resurrect it at the old path — undoing a delete the user
            // confirmed, or forking the work under two names after a rename.
            isDetached = true
            thumbStudioError = Self.detachedMessage
            return
        }
        guard let known = knownModified, onDisk > known else {
            knownModified = onDisk
            return
        }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(ThumbDocument.self, from: data)
        else { return }
        knownModified = onDisk
        guard decoded != thumbDoc else { return }
        thumbDoc = decoded
        // Scoped to this store: in the VOD editor the undo manager is the
        // window's, shared with the timeline, and clearing it wholesale would
        // throw away edits that have nothing to do with thumbnails.
        timelineUndoManager?.removeAllActions(withTarget: self)
        thumbStudioError = "Reloaded — this design was edited in another window."
    }

    /// A fresh design file in the lab folder, named and sized up front.
    static func create(named name: String, width: Int, height: Int) -> StandaloneThumbStore {
        var document = ThumbDocument()
        document.width = width
        document.height = height
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = cleaned.isEmpty ? "Design" : String(cleaned.prefix(60))
        try? FileManager.default.createDirectory(at: Paths.thumbLabRoot,
                                                 withIntermediateDirectories: true)
        var url = Paths.thumbLabRoot.appendingPathComponent("\(stem).json")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = Paths.thumbLabRoot.appendingPathComponent("\(stem) \(suffix).json")
            suffix += 1
        }
        let store = StandaloneThumbStore(fileURL: url)
        store.thumbDoc = document
        store.persist()
        return store
    }

    /// Renames the design on disk. Keeps this store and its undo history —
    /// only the file moves. Returns false when the name was unusable.
    @discardableResult
    func rename(to newName: String) -> Bool {
        let cleaned = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let stem = cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(60))
        guard stem != fileURL.deletingPathExtension().lastPathComponent else { return true }
        var target = Paths.thumbLabRoot.appendingPathComponent("\(stem).json")
        var suffix = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = Paths.thumbLabRoot.appendingPathComponent("\(stem) \(suffix).json")
            suffix += 1
        }
        guard (try? FileManager.default.moveItem(at: fileURL, to: target)) != nil else {
            thumbStudioError = "Couldn't rename this design."
            return false
        }
        objectWillChange.send()
        fileURL = target
        knownModified = Self.modified(at: target)
        return true
    }

    /// A copy of a design on disk, named the way Finder names copies. Returns
    /// the new file's URL so the gallery can select it.
    @discardableResult
    static func duplicate(_ design: Design) -> URL? {
        var name = design.name + " copy"
        var target = Paths.thumbLabRoot.appendingPathComponent("\(name).json")
        var suffix = 2
        while FileManager.default.fileExists(atPath: target.path) {
            name = design.name + " copy \(suffix)"
            target = Paths.thumbLabRoot.appendingPathComponent("\(name).json")
            suffix += 1
        }
        guard (try? FileManager.default.copyItem(at: design.url, to: target)) != nil else {
            return nil
        }
        return target
    }

    func applyThumbDoc(_ document: ThumbDocument, action: String?) {
        thumbStudioError = isDetached ? detachedMessage : nil
        let previous = thumbDoc
        if let action, previous != document {
            if !UndoCoalescing.shouldCoalesce(action: action, lastAction: lastUndoAction,
                                              lastAt: lastUndoRegistration, now: Date()) {
                registerUndo(returningTo: previous, action: action)
            }
            lastUndoAction = action
            lastUndoRegistration = Date()
        }
        thumbDoc = document
        persist()
    }

    private func registerUndo(returningTo previous: ThumbDocument, action: String) {
        guard let undo = timelineUndoManager else { return }
        undo.registerUndo(withTarget: self) { store in
            let current = store.thumbDoc
            store.registerUndo(returningTo: current, action: action)
            store.lastUndoAction = nil
            store.thumbDoc = previous
            store.persist()
        }
        undo.setActionName(action)
    }

    /// Called when this design is closed. Its undo entries target this store
    /// and would otherwise stay on the window's undo manager, so pressing ⌘Z
    /// in the next design you open would rewrite the previous one's file.
    func detachUndo() {
        timelineUndoManager?.removeAllActions(withTarget: self)
        timelineUndoManager = nil
        endUndoRun()
    }

    func endUndoRun() {
        lastUndoAction = nil
        lastUndoRegistration = .distantPast
    }

    private func persist() {
        guard !isDetached else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(thumbDoc).write(to: fileURL, options: .atomic)
        knownModified = Self.modified(at: fileURL)
    }

    func removeBackground(layerID: UUID) {
        guard case .image(let spec)? = thumbDoc.layers.first(where: { $0.id == layerID })?.kind,
              !spec.path.isEmpty else { return }
        isCuttingOut = true
        thumbStudioError = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = CutoutRun.perform(spec: spec)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isCuttingOut = false
                switch result {
                case .success(let cutout):
                    // Re-read now, not before: Vision took a moment and the
                    // user may have moved, typed or deleted something in it.
                    var document = self.thumbDoc
                    guard let index = document.layers.firstIndex(where: { $0.id == layerID }),
                          case .image(var current) = document.layers[index].kind
                    else { return }
                    CutoutRun.applyResult(cutout, to: &current)
                    document.layers[index].kind = .image(current)
                    // A cutout landing is new bytes behind the layer.
                    AdjustedImageCache.shared.invalidateSources()
                    self.applyThumbDoc(document, action: "Remove Background")
                case .failure(let error):
                    self.thumbStudioError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - The gallery

    struct Design: Identifiable, Equatable {
        var id: String { url.path }
        var url: URL
        var name: String
        var modifiedAt: Date
        var width: Int
        var height: Int
    }

    /// Every design in the lab, newest first.
    nonisolated static func designs() -> [Design] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: Paths.thumbLabRoot,
                                                includingPropertiesForKeys: [.contentModificationDateKey]))
            ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Design? in
                guard let data = try? Data(contentsOf: url),
                      let doc = try? JSONDecoder().decode(ThumbDocument.self, from: data)
                else { return nil }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return Design(url: url,
                              name: url.deletingPathExtension().lastPathComponent,
                              modifiedAt: modified,
                              width: doc.width, height: doc.height)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }
}

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
}

extension ProjectSession: ThumbStore {}

/// A design in the Thumb Lab: one JSON file, no project, no video. The lab
/// folder is the gallery — every design is its own document with the same
/// undo behaviour the project studio has.
@MainActor
final class StandaloneThumbStore: ObservableObject, ThumbStore {
    @Published private(set) var thumbDoc: ThumbDocument
    @Published var isCuttingOut = false
    @Published var thumbStudioError: String?
    weak var timelineUndoManager: UndoManager?

    let fileURL: URL
    private var lastUndoAction: String?
    private var lastUndoRegistration = Date.distantPast

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(ThumbDocument.self, from: data) {
            thumbDoc = decoded
        } else {
            thumbDoc = ThumbDocument()
        }
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

    func applyThumbDoc(_ document: ThumbDocument, action: String?) {
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

    private func persist() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(thumbDoc).write(to: fileURL, options: .atomic)
    }

    func removeBackground(layerID: UUID) {
        guard case .image(let spec)? = thumbDoc.layers.first(where: { $0.id == layerID })?.kind,
              !spec.path.isEmpty else { return }
        isCuttingOut = true
        thumbStudioError = nil
        let sourcePath = spec.path
        Task.detached { [weak self] in
            let destination = URL(fileURLWithPath: sourcePath)
                .deletingPathExtension().appendingPathExtension("cutout.png")
            do {
                try CutoutService.removeBackground(from: URL(fileURLWithPath: sourcePath),
                                                   writingTo: destination)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    var document = self.thumbDoc
                    if let index = document.layers.firstIndex(where: { $0.id == layerID }),
                       case .image(var updated) = document.layers[index].kind {
                        updated.cutoutPath = destination.path
                        updated.useCutout = true
                        updated.strokeWidth = max(updated.strokeWidth, 6)
                        document.layers[index].kind = .image(updated)
                    }
                    self.isCuttingOut = false
                    self.applyThumbDoc(document, action: "Remove Background")
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isCuttingOut = false
                    self?.thumbStudioError = error.localizedDescription
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
    static func designs() -> [Design] {
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

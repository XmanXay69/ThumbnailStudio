import AppKit
import Foundation
import ImageIO

/// Small previews of library images, made once and kept.
///
/// The library panel draws a grid of cards, and each one was calling
/// `NSImage(contentsOfFile:)` inline — a fresh full-size image per card, every
/// time the panel's body ran, which is every keystroke in its search field and
/// every star toggled. On this Mac that is 35 megapixels of decode for 19
/// cards, and the panel is now open all the time rather than behind a sheet.
///
/// ImageIO makes the thumbnail directly from the file, so a 4K screenshot never
/// becomes a 4K bitmap on the way to a 108-point card.
@MainActor
final class ThumbThumbnailCache: ObservableObject {
    static let shared = ThumbThumbnailCache()

    /// Generous enough for a 2× card and nothing like the source.
    nonisolated static let pixels = 320

    private var cache: [String: NSImage?] = [:]
    private var loading: Set<String> = []

    @Published private(set) var generation = 0

    /// Never blocks and never decodes on the calling thread. nil means "not
    /// ready yet"; the card draws its checkerboard until `generation` moves.
    func thumbnail(for path: String) -> NSImage? {
        if let hit = cache[path] { return hit }
        guard !loading.contains(path) else { return nil }
        loading.insert(path)
        Task.detached(priority: .utility) {
            let image = ThumbThumbnailCache.make(path)
            await MainActor.run { ThumbThumbnailCache.shared.store(path, image) }
        }
        return nil
    }

    private func store(_ path: String, _ image: NSImage?) {
        // A bound, not a policy. A library of thousands would still only ever
        // hold this many small bitmaps.
        if cache.count > 400 { cache.removeAll() }
        cache[path] = image
        loading.remove(path)
        generation &+= 1
    }

    func invalidate() {
        cache.removeAll()
        generation &+= 1
    }

    nonisolated static func make(_ path: String) -> NSImage? {
        guard !path.isEmpty,
              let source = CGImageSourceCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

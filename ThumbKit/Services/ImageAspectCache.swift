import AppKit
import Foundation
import ImageIO

/// Height over width for an image file, read once, and never on the thread
/// that is trying to draw.
///
/// This exists because the canvas needs a layer's aspect to size its selection
/// box, and asking the file for it is a disk read. The first version did that
/// read inline and its own comment claimed it "keeps the file off the main
/// thread", which it did not: `CGImageSourceCreateWithURL` opens the file, and
/// `open()` is a blocking syscall.
///
/// That is fine until a file is slow to open — evicted from iCloud, on a
/// sleeping external drive, on a stalled volume — and then it is not slow, it
/// is forever. The read happened inside SwiftUI's layout pass, so the window
/// could not finish sizing itself, and the app came up as a 0×0 ghost with its
/// main thread asleep in the kernel at 0% CPU. Observed, sampled, and the
/// reason this class now answers immediately or not at all.
@MainActor
final class ImageAspectCache: ObservableObject {
    static let shared = ImageAspectCache()

    private var cache: [String: Double?] = [:]
    /// Paths already being read, so a path that is asked for on every frame is
    /// only ever read once — and a path that never comes back is never
    /// retried into a pile of stuck threads.
    private var inFlight: Set<String> = []

    /// Bumped whenever a value lands. Views that asked, got nil and drew a
    /// fallback observe this so they redraw with the real number.
    @Published private(set) var generation = 0

    /// Never blocks. Returns nil the first time it is asked about a path and
    /// starts reading in the background; the answer arrives via `generation`.
    ///
    /// Callers already treat nil as "use the layer's stored height", so the
    /// visible cost is a selection box that is briefly the wrong shape. The
    /// alternative was an app that could not draw at all.
    func aspect(of path: String) -> Double? {
        guard !path.isEmpty else { return nil }
        if let hit = cache[path] { return hit }
        guard !inFlight.contains(path) else { return nil }
        inFlight.insert(path)
        Task.detached(priority: .userInitiated) {
            let value = ImageAspectCache.readAspect(path)
            await MainActor.run { ImageAspectCache.shared.store(path, value) }
        }
        return nil
    }

    /// What is known right now, with no read started. For callers that must
    /// not cause work — a check asserting the cache is cold, say.
    func cached(_ path: String) -> Double?? { cache[path] }

    private func store(_ path: String, _ value: Double?) {
        // The old cache dropped everything at 500 entries. Keeping that: it is
        // a bound, not a policy, and an LRU here would be solving a problem
        // nobody has.
        if cache.count > 500 { cache.removeAll() }
        cache[path] = value
        inFlight.remove(path)
        generation &+= 1
    }

    /// Reads the header only — not the pixels. Safe to call anywhere, and
    /// deliberately the only part of this class that touches a file.
    nonisolated static func readAspect(_ path: String) -> Double? {
        guard !path.isEmpty,
              let source = CGImageSourceCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0 else { return nil }
        return height / width
    }

    func invalidate() {
        cache.removeAll()
        // In-flight reads are deliberately NOT cleared: they are already
        // running, and dropping the record would let the next frame start a
        // second read of the same file. Their results land and are stored,
        // which is correct — the file has not changed, only our cache of it.
        generation &+= 1
    }
}

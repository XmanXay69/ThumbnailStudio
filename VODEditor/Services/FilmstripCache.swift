import AVFoundation
import AppKit
import Foundation

/// Thumbnails for timeline filmstrips. Times are bucketed before hitting the
/// cache — coarse buckets when zoomed out, fine when zoomed in — so zooming
/// reuses frames instead of regenerating them (the mipmap idea, two tiers).
@MainActor
final class FilmstripCache: ObservableObject {
    static let shared = FilmstripCache()

    private let cache = NSCache<NSString, NSImage>()
    private var generators: [String: AVAssetImageGenerator] = [:]
    private var inFlight: Set<String> = []

    init() {
        cache.countLimit = 600
    }

    /// The cache bucket for a source time: 2s tiles zoomed in, 8s zoomed out.
    nonisolated static func bucket(_ time: Double, fine: Bool) -> Double {
        let size = fine ? 2.0 : 8.0
        return (time / size).rounded(.down) * size + size / 2
    }

    func thumbnail(path: String, at time: Double, fine: Bool) -> NSImage? {
        let bucketed = Self.bucket(time, fine: fine)
        let key = "\(path)|\(bucketed)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        request(path: path, time: bucketed, key: key)
        return nil
    }

    private func request(path: String, time: Double, key: NSString) {
        let keyString = key as String
        guard !inFlight.contains(keyString) else { return }
        inFlight.insert(keyString)
        let generator: AVAssetImageGenerator
        if let existing = generators[path] {
            generator = existing
        } else {
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: 160, height: 160)
            generator.appliesPreferredTrackTransform = true
            // Filmstrips are context, not frame-exact reference — loose
            // tolerance decodes from the nearest keyframe and is 10× faster.
            generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
            generators[path] = generator
            if generators.count > 12 { generators.removeValue(forKey: generators.keys.first!) }
        }
        Task { [weak self] in
            defer { self?.inFlight.remove(keyString) }
            guard let (cgImage, _) = try? await generator.image(
                at: CMTime(seconds: time, preferredTimescale: 600)) else { return }
            let image = NSImage(cgImage: cgImage, size: .zero)
            self?.cache.setObject(image, forKey: key)
            self?.objectWillChange.send()
        }
    }
}

import AVFoundation
import AppKit
import SwiftUI

/// One poster frame per candidate, so the bin shows what a clip *is*
/// without playing it. Frames come from the keyframe nearest the moment
/// (fast) and live in a memory cache — reclaim can drop any disk copies
/// and nothing breaks.
@MainActor
final class PosterCache {
    static let shared = PosterCache()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight = Set<String>()

    init() {
        cache.countLimit = 400
    }

    func poster(url: URL, at time: Double,
                onReady: @escaping () -> Void) -> NSImage? {
        let key = "\(url.path)#\(Int(time))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard !inFlight.contains(key as String) else { return nil }
        inFlight.insert(key as String)
        Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 4, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 4, preferredTimescale: 600)
            let cg = try? generator.copyCGImage(
                at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
            await MainActor.run {
                self.inFlight.remove(key as String)
                if let cg {
                    let image = NSImage(cgImage: cg,
                                        size: NSSize(width: cg.width, height: cg.height))
                    self.cache.setObject(image, forKey: key)
                    onReady()
                }
            }
        }
        return nil
    }
}

/// The visual half of a candidate card: a 16:9 poster with graceful
/// placeholder while the frame decodes.
struct PosterFrame: View {
    let url: URL?
    let time: Double
    var height: CGFloat = 76

    @State private var reload = 0

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.35))
            if let url,
               let image = PosterCache.shared.poster(url: url, at: time,
                                                     onReady: { reload += 1 }) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        .id(reload)
    }
}

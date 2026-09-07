import AppKit
import Foundation

/// The store-agnostic half of Remove Background. Both stores own the same
/// document type and the same failure surface, so the work — read the layer's
/// settings, lift, write into the app's asset folder — belongs in one place
/// rather than being copied into each.
///
/// It deliberately returns only the cutout's path, never a whole document:
/// Vision takes up to a couple of seconds, and applying a document snapshot
/// captured before it started would revert everything the user did meanwhile.
enum CutoutRun {
    /// Runs off the main actor. The caller re-reads its current document and
    /// patches the one layer.
    nonisolated static func perform(spec: ImageSpec) -> Result<URL, Error> {
        guard !spec.path.isEmpty else {
            return .failure(CutoutService.CutoutError.unreadable)
        }
        let options = CutoutService.Options(instance: spec.cutoutInstance,
                                            contract: spec.cutoutContract,
                                            feather: spec.cutoutFeather,
                                            contrast: spec.cutoutContrast)
        let tag = "\(options.instance.map(String.init) ?? "all")-\(options.contract)"
            + "-\(options.feather)-\(options.contrast)"
        let destination = ThumbAssets.cutoutURL(for: spec.path, tag: tag)
        do {
            // Content-addressed, so re-picking settings you already tried is
            // instant rather than another second of Vision.
            if !FileManager.default.fileExists(atPath: destination.path) {
                try CutoutService.removeBackground(from: URL(fileURLWithPath: spec.path),
                                                   writingTo: destination, options: options)
            }
        } catch {
            return .failure(error)
        }
        return .success(destination)
    }

    /// The treatment a freshly lifted subject gets. A cutout dropped flat onto
    /// a background reads as a sticker; the shadow is what separates it, and
    /// both apps applied one (a shadow here, an outline there) before this was
    /// shared code.
    static func applyResult(_ cutout: URL, to spec: inout ImageSpec) {
        let isFirstLift = spec.cutoutPath == nil
        spec.cutoutPath = cutout.path
        spec.useCutout = true
        if isFirstLift {
            spec.shadowEnabled = true
            spec.strokeWidth = max(spec.strokeWidth, 6)
        }
    }
}

import AppKit
import Foundation

/// The store-agnostic half of Remove Background. Both stores own the same
/// document type and the same failure surface, so the actual work — read the
/// spec's settings, lift, write into the app's asset folder, hand back an
/// updated document — belongs in one place rather than being copied into each.
enum CutoutRun {
    /// The document with the layer's cutout applied, or the error to show.
    /// Runs off the main actor; the caller applies the result on it.
    nonisolated static func perform(document: ThumbDocument,
                                    layerID: UUID) -> Result<ThumbDocument, Error> {
        guard let index = document.layers.firstIndex(where: { $0.id == layerID }),
              case .image(var spec) = document.layers[index].kind,
              !spec.path.isEmpty else {
            return .failure(CutoutService.CutoutError.unreadable)
        }
        let options = CutoutService.Options(instance: spec.cutoutInstance,
                                            contract: spec.cutoutContract,
                                            feather: spec.cutoutFeather,
                                            contrast: spec.cutoutContrast)
        let tag = "\(options.instance.map(String.init) ?? "all")-\(options.contract)-\(options.feather)-\(options.contrast)"
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
        var updated = document
        spec.cutoutPath = destination.path
        spec.useCutout = true
        updated.layers[index].kind = .image(spec)
        return .success(updated)
    }
}

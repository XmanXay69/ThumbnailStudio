// FILE 3 — ThumbKit/ThumbLayerClipboard.swift
// Layer clipboard, including pasting an image off the system pasteboard.
// =====================================================================
import AppKit
import Foundation
import UniformTypeIdentifiers

/// Copy and paste for layers, and for whatever the system pasteboard is
/// holding. Layers travel as JSON under a private type so a copy survives
/// switching designs, quitting, and pasting into another window; a screenshot
/// or a Finder file pastes as a new image layer.
///
/// Images cannot travel as bytes inside a `ThumbDocument`: `ImageSpec` holds a
/// path and `ThumbnailRenderer` loads from that path. So pasted pixels are
/// written to a file first, and the layer points at it.
enum ThumbLayerClipboard {

    static let layerType = NSPasteboard.PasteboardType("com.xavier.thumbnailstudio.layers")

    enum Paste {
        case layers([ThumbLayer])
        case image(ImageSpec)
        case text(String)
        case nothing

        var undoActionName: String {
            switch self {
            case .layers: return "Paste Layer"
            case .image: return "Paste Image"
            case .text: return "Paste Text"
            case .nothing: return ""
            }
        }
    }

    /// Writes layers to the pasteboard. Also writes a plain-text summary so
    /// pasting into a notes app gives something readable rather than nothing.
    @discardableResult
    static func copy(_ layers: [ThumbLayer],
                     to pasteboard: NSPasteboard = .general) -> Bool {
        guard !layers.isEmpty,
              let data = try? JSONEncoder().encode(layers) else { return false }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: layerType)
        pasteboard.setString(layers.map(\.displayName).joined(separator: ", "), forType: .string)
        return true
    }

    /// True when a paste would do something. Drives menu enable/disable, so it
    /// must be cheap — it reads type names, never the payload.
    static func canPaste(from pasteboard: NSPasteboard = .general) -> Bool {
        guard let types = pasteboard.types else { return false }
        if types.contains(layerType) { return true }
        if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) { return true }
        if types.contains(.fileURL) { return true }
        if types.contains(.string) { return true }
        return false
    }

    /// Reads the pasteboard in priority order: our own layers, then a file, an
    /// image, and finally text. `assetDirectory` is where raw pixels land —
    /// pass the design's own asset folder so the file lives as long as the
    /// design does.
    static func paste(from pasteboard: NSPasteboard = .general,
                      assetDirectory: URL) -> Paste {
        // 1. Our own layers, styling and all.
        if let data = pasteboard.data(forType: layerType),
           let layers = try? JSONDecoder().decode([ThumbLayer].self, from: data),
           !layers.isEmpty {
            return .layers(layers)
        }

        // 2. An image file copied in Finder — referenced in place, no copy, so
        //    editing the original updates the design.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first(where: { isImageFile($0) }) {
            return .image(ImageSpec(path: url.path))
        }

        // 3. Raw pixels — a screenshot, or a copy out of Preview or a browser.
        if let image = NSImage(pasteboard: pasteboard),
           let url = write(image, into: assetDirectory) {
            return .image(ImageSpec(path: url.path))
        }

        // 4. Text last: only when nothing richer is on the board.
        if let string = pasteboard.string(forType: .string),
           !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(string)
        }
        return .nothing
    }

    /// A layer built from a paste result, sized to sit comfortably on the
    /// canvas: images keep their aspect, text arrives at headline size.
    static func layer(for paste: Paste) -> ThumbLayer? {
        switch paste {
        case .image(let spec):
            var layer = ThumbLayer(name: URL(fileURLWithPath: spec.path).lastPathComponent,
                                   kind: .image(spec), widthFraction: 0.5)
            if let image = NSImage(contentsOfFile: spec.path), image.size.width > 0 {
                layer.heightFraction = 0.5 * Double(image.size.height / image.size.width)
            }
            return layer
        case .text(let string):
            var spec = TextSpec(text: String(string.prefix(120)))
            spec.sizeFraction = 0.14
            return ThumbLayer(kind: .text(spec), widthFraction: 0.85)
        case .layers, .nothing:
            return nil
        }
    }

    private static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return type.conforms(to: .image)
    }

    /// PNG, because pastes are usually screenshots with alpha, and because the
    /// renderer's cutout path expects lossless input.
    private static func write(_ image: NSImage, into directory: URL) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Pasted \(UUID().uuidString).png")
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        return url
    }
}


// =====================================================================

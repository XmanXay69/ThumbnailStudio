import AppKit
import Foundation
import SwiftUI

/// The handful of fonts and images you actually use, kept at the top.
///
/// A thumbnail channel reaches for the same three faces and the same logo
/// forever, and scrolling past four hundred installed families to find one of
/// them is the whole problem. Nothing here is clever: it is two sets of
/// strings, written to one small file.
struct ThumbFavouriteSet: Codable, Equatable {
    /// Font family names.
    var fonts: [String] = []
    /// Asset paths.
    var assets: [String] = []

    /// Adds or removes, and returns whether it is now a favourite.
    ///
    /// Order is insertion order, newest last, because a list that reshuffles
    /// itself alphabetically every time you star something is a list you have
    /// to re-read. Deduplicated on the way in.
    @discardableResult
    mutating func toggleFont(_ name: String) -> Bool {
        if let index = fonts.firstIndex(of: name) {
            fonts.remove(at: index)
            return false
        }
        fonts.append(name)
        return true
    }

    @discardableResult
    mutating func toggleAsset(_ path: String) -> Bool {
        if let index = assets.firstIndex(of: path) {
            assets.remove(at: index)
            return false
        }
        assets.append(path)
        return true
    }

    func hasFont(_ name: String) -> Bool { fonts.contains(name) }
    func hasAsset(_ path: String) -> Bool { assets.contains(path) }

    /// Drops entries that no longer resolve — a font uninstalled, an image
    /// deleted — so a stale favourite cannot pin a dead row to the top of a
    /// menu forever.
    func pruned(installedFonts: Set<String>, fileExists: (String) -> Bool) -> ThumbFavouriteSet {
        ThumbFavouriteSet(fonts: fonts.filter { installedFonts.contains($0) },
                          assets: assets.filter(fileExists))
    }
}

/// Reads and writes the favourites file. Separated from the observable object
/// so the harness can exercise it without a running app.
enum ThumbFavouritesFile {
    static var url: URL {
        Paths.appSupport.appendingPathComponent("ThumbFavourites.json")
    }

    static func load(from url: URL = url) -> ThumbFavouriteSet {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ThumbFavouriteSet.self, from: data)
        else { return ThumbFavouriteSet() }
        return decoded
    }

    /// Writes atomically. A favourite is a one-keystroke action, so a
    /// half-written file from a crash mid-save would lose the lot.
    static func save(_ set: ThumbFavouriteSet, to url: URL = url) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(set) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// The app's live copy. One instance, because both apps and every panel that
/// shows a star have to agree about what is starred.
@MainActor
final class ThumbFavourites: ObservableObject {
    static let shared = ThumbFavourites()

    @Published private(set) var set: ThumbFavouriteSet

    init(set: ThumbFavouriteSet? = nil) {
        self.set = set ?? ThumbFavouritesFile.load()
    }

    func toggleFont(_ name: String) {
        set.toggleFont(name)
        ThumbFavouritesFile.save(set)
    }

    func toggleAsset(_ path: String) {
        set.toggleAsset(path)
        ThumbFavouritesFile.save(set)
    }

    func hasFont(_ name: String) -> Bool { set.hasFont(name) }
    func hasAsset(_ path: String) -> Bool { set.hasAsset(path) }

    /// Favourite fonts that are still installed, in the order they were starred.
    var fonts: [String] {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return set.fonts.filter { installed.contains($0) }
    }
}

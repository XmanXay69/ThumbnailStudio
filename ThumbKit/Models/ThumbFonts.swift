import AppKit
import Foundation

/// What fonts are actually on this Mac, and how a `TextSpec` resolves to one.
///
/// The studio used to offer a fixed list of "thumbnail picks" — Anton, Bangers,
/// Montserrat — none of which are installed here, and it defaulted to Anton.
/// `NSFont(name:)` returns nil for a missing face and the renderer quietly fell
/// back to system heavy, so the inspector said one thing and the canvas drew
/// another. Nothing here offers a font it cannot draw.
enum ThumbFonts {
    /// The faces worth reaching for on a thumbnail: heavy, wide, legible small.
    /// Filtered to what exists, in preference order.
    static let preferredNames = [
        "Impact", "Anton", "Bangers", "Arial Black", "Haettenschweiler",
        "Futura", "Avenir Next", "Helvetica Neue", "Montserrat",
    ]

    /// Installed families from that list, best first. Never empty — the system
    /// font is the floor.
    static var picks: [String] {
        let families = Set(NSFontManager.shared.availableFontFamilies)
        let found = preferredNames.filter { families.contains($0) }
        return found.isEmpty ? [systemFamily] : found
    }

    static var systemFamily: String {
        NSFont.systemFont(ofSize: 24, weight: .heavy).familyName ?? "Helvetica"
    }

    /// The default for a new text layer: the best pick that is actually here.
    static var defaultFamily: String { picks.first ?? systemFamily }

    static func isInstalled(_ family: String) -> Bool {
        NSFontManager.shared.availableFontFamilies.contains(family)
            || NSFont(name: family, size: 12) != nil
    }

    /// Face names within a family — "Bold", "Black", "Condensed Heavy" — with
    /// the heaviest first, because that is what a thumbnail wants.
    static func faces(in family: String) -> [String] {
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        return members
            .compactMap { member -> (String, Int)? in
                guard let name = member[1] as? String,
                      let weight = member[2] as? Int else { return nil }
                // Italics are a separate axis and mostly noise on a thumbnail.
                guard !name.lowercased().contains("italic") else { return nil }
                return (name, weight)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// The font a spec should actually draw with.
    ///
    /// Falls back deliberately rather than silently: family, then the family's
    /// heaviest face, then the system heavy face. `resolvedDescription` says
    /// which happened so the inspector can be honest about it.
    static func font(for spec: TextSpec, size: CGFloat) -> NSFont {
        if let face = spec.fontFace,
           let member = NSFontManager.shared.font(withFamily: spec.fontName,
                                                  traits: [], weight: 5, size: size),
           let exact = NSFont(descriptor: member.fontDescriptor
                                .withFace(face), size: size) {
            return exact
        }
        if let named = NSFont(name: spec.fontName, size: size) { return named }
        if isInstalled(spec.fontName),
           let heaviest = faces(in: spec.fontName).first,
           let byFace = NSFont(descriptor: NSFontDescriptor(fontAttributes: [
               .family: spec.fontName, .face: heaviest,
           ]), size: size) {
            return byFace
        }
        return NSFont.systemFont(ofSize: size, weight: .heavy)
    }

    /// nil when the spec's font is drawing as asked; otherwise what actually
    /// happened, for the inspector to show.
    static func substitution(for spec: TextSpec) -> String? {
        guard !isInstalled(spec.fontName) else { return nil }
        return "\(spec.fontName) isn't installed — drawing in \(systemFamily)"
    }
}

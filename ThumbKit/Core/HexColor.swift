import AppKit
import Foundation

/// Hex strings to NSColor, one implementation for the whole codebase. The
/// thumbnail renderer stores every colour as "RRGGBB" in its document, and the
/// VOD overlay renderer does the same, so the parse lives here rather than
/// inside either of them.
enum HexColor {
    /// "RRGGBB" (leading "#" and spaces tolerated) → NSColor. Anything that
    /// isn't six hex digits falls back to white, which is what the old
    /// `SocialOverlayRenderer.color(hex:)` did.
    static func color(hex: String) -> NSColor {
        var value: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard Scanner(string: cleaned).scanHexInt64(&value), cleaned.count == 6 else { return .white }
        return NSColor(calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// The inverse — an NSColor as the "RRGGBB" the documents store.
    static func hex(from color: NSColor) -> String {
        let rgba = color.usingColorSpace(.deviceRGB) ?? .white
        return String(format: "%02X%02X%02X",
                      Int(rgba.redComponent * 255),
                      Int(rgba.greenComponent * 255),
                      Int(rgba.blueComponent * 255))
    }
}

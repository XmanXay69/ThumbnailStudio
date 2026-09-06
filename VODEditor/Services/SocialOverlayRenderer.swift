import AppKit
import Foundation

/// Draws the social overlay — the clip title across the top, and the Twitch
/// and Instagram handles beside their logos on the left — as one transparent
/// PNG matching the edit's aspect (1080×1920 or 1920×1080). Text and badge
/// sizes scale with frame height so both aspects carry the same look.
///
/// One renderer, two consumers: the editor previews this exact image over the
/// player, and the export hands the same PNG to ffmpeg as an overlay input. A
/// single code path is what keeps the preview honest. The logos are drawn with
/// NSBezierPath rather than shipped as assets, so there's nothing to bundle
/// and they stay sharp at any size.
enum SocialOverlayRenderer {
    static let canvasWidth = 1080
    static let canvasHeight = 1920

    /// Twitch brand purple, Instagram's gradient endpoints.
    private static let twitchPurple = NSColor(calibratedRed: 0.569, green: 0.275, blue: 1.0, alpha: 1)
    private static let instagramColors = [
        NSColor(calibratedRed: 0.51, green: 0.23, blue: 0.71, alpha: 1),   // purple
        NSColor(calibratedRed: 0.99, green: 0.11, blue: 0.11, alpha: 1),   // red
        NSColor(calibratedRed: 0.99, green: 0.69, blue: 0.27, alpha: 1),   // orange
    ]

    static func image(for edit: ClipEdit) -> NSImage? {
        guard edit.hasStaticOverlay else { return nil }
        let size = CGSize(width: edit.aspect.width, height: edit.aspect.height)
        guard let rep = canvas(size) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high

        drawTitle(edit.title, in: size)
        drawBadges(edit, in: size)
        // Timed items are rendered separately — they come and go with the
        // playhead, so they can't live in the always-on PNG.
        for item in edit.textItems where !item.isTimed { drawTextItem(item, in: size) }

        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private static func canvas(_ size: CGSize) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        rep?.size = NSSize(width: size.width, height: size.height)
        return rep
    }

    static func pngData(for edit: ClipEdit) -> Data? {
        guard let image = image(for: edit),
              let rep = image.representations.first as? NSBitmapImageRep else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// One timed text item on its own transparent canvas — the export overlays
    /// it with an enable window, the preview shows it when the playhead is
    /// inside one.
    static func image(for item: TextItem, aspect: EditAspect = .portrait) -> NSImage? {
        guard !item.isBlank else { return nil }
        let size = CGSize(width: aspect.width, height: aspect.height)
        guard let rep = canvas(size) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        drawTextItem(item, in: size)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    static func pngData(for item: TextItem, aspect: EditAspect = .portrait) -> Data? {
        guard let image = image(for: item, aspect: aspect),
              let rep = image.representations.first as? NSBitmapImageRep else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Title

    /// Heavy white text with a black stroke, centred near the top — drawn in
    /// two passes because a single stroked pass eats into the fill.
    private static func drawTitle(_ title: String, in size: CGSize) {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let font = roundedFont(size: size.height * 0.0396, weight: .heavy)

        let width = size.width - 120
        let measured = NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph])
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin])
        let rect = NSRect(x: 60,
                          y: size.height - size.height * 0.0573 - ceil(measured.height),
                          width: width, height: ceil(measured.height) + 4)

        strokedText(text, font: font, paragraph: paragraph, strokeWidth: 14).draw(in: rect)
        NSAttributedString(string: text, attributes: [
            .font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.white,
        ]).draw(in: rect)
    }

    // MARK: - Free text

    /// One measurement used for both drawing and the editor's drag targets, so
    /// the grab area can't drift from the pixels.
    static func textBlockSize(for item: TextItem, aspect: EditAspect = .portrait) -> CGSize {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .zero }
        let size = CGSize(width: aspect.width, height: aspect.height)
        let (font, paragraph) = textItemAttributes(item, height: size.height)
        let maxWidth = size.width - 80
        let measured = NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph])
            .boundingRect(with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin])
        return CGSize(width: min(maxWidth, ceil(measured.width) + 10),
                      height: ceil(measured.height) + 6)
    }

    private static func drawTextItem(_ item: TextItem, in size: CGSize) {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let aspect: EditAspect = size.width > size.height ? .landscape : .portrait
        let (font, paragraph) = textItemAttributes(item, height: size.height)
        let block = textBlockSize(for: item, aspect: aspect)
        // (x, y) is the block's centre as fractions from the top-left; AppKit's
        // origin is the bottom.
        let rect = NSRect(x: size.width * CGFloat(item.x) - block.width / 2,
                          y: size.height * (1 - CGFloat(item.y)) - block.height / 2,
                          width: block.width, height: block.height)

        let fill = color(hex: item.colorHex)
        // A dark fill gets a white outline so it stays readable on dark video.
        let outline: NSColor = luminance(of: fill) < 0.4 ? .white : .black
        NSAttributedString(string: text, attributes: [
            .font: font, .paragraphStyle: paragraph,
            .strokeColor: outline, .strokeWidth: 14, .foregroundColor: outline,
        ]).draw(in: rect)
        NSAttributedString(string: text, attributes: [
            .font: font, .paragraphStyle: paragraph, .foregroundColor: fill,
        ]).draw(in: rect)
    }

    private static func textItemAttributes(_ item: TextItem, height: CGFloat) -> (NSFont, NSParagraphStyle) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let size = max(20, CGFloat(item.size) * height)
        return (roundedFont(size: size, weight: .heavy), paragraph)
    }

    static func color(hex: String) -> NSColor {
        var value: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard Scanner(string: cleaned).scanHexInt64(&value), cleaned.count == 6 else { return .white }
        return NSColor(calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    private static func luminance(of color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
    }

    // MARK: - Badges

    private static func drawBadges(_ edit: ClipEdit, in size: CGSize) {
        guard edit.showHandles else { return }
        var rows: [(icon: (NSRect) -> Void, handle: String)] = []
        let instagram = edit.instagramHandle.trimmingCharacters(in: .whitespaces)
        let twitch = edit.twitchHandle.trimmingCharacters(in: .whitespaces)
        // Instagram above Twitch, as in the reference layout.
        if !instagram.isEmpty { rows.append((drawInstagramIcon, instagram)) }
        if !twitch.isEmpty { rows.append((drawTwitchIcon, twitch)) }
        guard !rows.isEmpty else { return }

        let iconSize: CGFloat = size.height * 0.05
        let rowGap: CGFloat = size.height * 0.0177
        let stackHeight = CGFloat(rows.count) * iconSize + CGFloat(rows.count - 1) * rowGap
        // handleY is a fraction from the *top*; AppKit's origin is the bottom.
        let stackTop = size.height * (1 - edit.handleY) + stackHeight / 2
        let font = roundedFont(size: size.height * 0.0323, weight: .bold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        // Mirrored on the right: the logo hugs the right edge and the text
        // right-aligns against it.
        if edit.handlesOnRight {
            paragraph.alignment = .right
        }
        for (index, row) in rows.enumerated() {
            let top = stackTop - CGFloat(index) * (iconSize + rowGap)
            let iconX = edit.handlesOnRight ? size.width - 44 - iconSize : 44
            let iconRect = NSRect(x: iconX, y: top - iconSize, width: iconSize, height: iconSize)
            row.icon(iconRect)

            let textHeight = row.handle.size(withAttributes: [.font: font]).height
            let textRect = edit.handlesOnRight
                ? NSRect(x: 70,
                         y: iconRect.midY - textHeight / 2,
                         width: iconRect.minX - 26 - 70,
                         height: textHeight + 4)
                : NSRect(x: iconRect.maxX + 26,
                         y: iconRect.midY - textHeight / 2,
                         width: size.width - iconRect.maxX - 70,
                         height: textHeight + 4)
            strokedText(row.handle, font: font, paragraph: paragraph, strokeWidth: 12).draw(in: textRect)
            NSAttributedString(string: row.handle, attributes: [
                .font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.white,
            ]).draw(in: textRect)
        }
    }

    // MARK: - Logos

    /// The Twitch glyph: white mark with the notched corner and two eyes, on
    /// the brand-purple rounded square.
    private static func drawTwitchIcon(in rect: NSRect) {
        let badge = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.width * 0.22)
        twitchPurple.setFill()
        badge.fill()

        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            // Glyph authored in a 100×100 box with a top-left origin.
            NSPoint(x: rect.minX + rect.width * x / 100,
                    y: rect.maxY - rect.height * y / 100)
        }
        let body = NSBezierPath()
        body.move(to: point(30, 14))
        body.line(to: point(22, 30))
        body.line(to: point(22, 74))
        body.line(to: point(40, 74))
        body.line(to: point(40, 86))
        body.line(to: point(52, 74))
        body.line(to: point(68, 74))
        body.line(to: point(84, 58))
        body.line(to: point(84, 14))
        body.close()
        NSColor.white.setFill()
        body.fill()

        twitchPurple.setFill()
        NSBezierPath(rect: NSRect(x: point(48, 52).x, y: point(48, 52).y,
                                  width: rect.width * 0.08, height: rect.height * 0.22)).fill()
        NSBezierPath(rect: NSRect(x: point(64, 52).x, y: point(64, 52).y,
                                  width: rect.width * 0.08, height: rect.height * 0.22)).fill()
    }

    /// The Instagram camera outline on the brand gradient.
    private static func drawInstagramIcon(in rect: NSRect) {
        let badge = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.24, yRadius: rect.width * 0.24)
        NSGradient(colors: instagramColors)?.draw(in: badge, angle: 60)

        NSColor.white.setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: rect.width * 0.18, dy: rect.height * 0.18),
                                   xRadius: rect.width * 0.14, yRadius: rect.width * 0.14)
        outline.lineWidth = rect.width * 0.065
        outline.stroke()

        let lens = NSBezierPath(ovalIn: NSRect(x: rect.midX - rect.width * 0.14,
                                               y: rect.midY - rect.height * 0.14,
                                               width: rect.width * 0.28, height: rect.height * 0.28))
        lens.lineWidth = rect.width * 0.065
        lens.stroke()

        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.maxX - rect.width * 0.31,
                                    y: rect.maxY - rect.height * 0.31,
                                    width: rect.width * 0.07, height: rect.height * 0.07)).fill()
    }

    // MARK: - Text helpers

    private static func strokedText(_ text: String, font: NSFont,
                                    paragraph: NSParagraphStyle, strokeWidth: CGFloat) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font,
            .paragraphStyle: paragraph,
            .strokeColor: NSColor.black,
            .strokeWidth: strokeWidth,
            .foregroundColor: NSColor.black,
        ])
    }

    /// The rounded, heavy face the reference layout uses; falls back down the
    /// list on machines without it.
    private static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        for name in ["Arial Rounded MT Bold", "Avenir Next Heavy", "Impact"] {
            if let font = NSFont(name: name, size: size) { return font }
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }
}

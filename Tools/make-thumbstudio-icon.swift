import AppKit

// Renders the Thumb Lab app icon at every size an .appiconset needs.
// Drawn with AppKit rather than an SVG toolchain because this Mac has no
// rasteriser installed and the app already draws everything this way.
//
//   swift makeicon.swift <output appiconset dir>

let sizes = [16, 32, 64, 128, 256, 512, 1024]

func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

/// The artwork, drawn in a 1024-point square. Everything scales from `s`.
func drawIcon(side: CGFloat) {
    let s = side / 1024
    func p(_ v: CGFloat) -> CGFloat { v * s }

    // Squircle plate.
    let plate = NSRect(x: p(76), y: p(76), width: p(872), height: p(872))
    let plagePath = NSBezierPath(roundedRect: plate, xRadius: p(196), yRadius: p(196))
    NSGraphicsContext.current?.cgContext.saveGState()
    plagePath.addClip()
    NSGradient(colors: [hex(0x2B2F3A), hex(0x14161C), hex(0x0B0C10)],
               atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)?
        .draw(in: plate, angle: -78)
    NSGraphicsContext.current?.cgContext.restoreGState()

    // A 16:9 artboard split by the diagonal cut this app is built around,
    // with a lifted subject standing on it. That is the whole app in one
    // glyph: cut, colour, cutout.
    let board = NSRect(x: p(196), y: p(306), width: p(632), height: p(356))
    let boardPath = NSBezierPath(roundedRect: board, xRadius: p(40), yRadius: p(40))

    let ctx = NSGraphicsContext.current?.cgContext
    ctx?.saveGState()
    boardPath.addClip()

    // Right side: hot amber. Left side: deep violet. The seam is the cut.
    NSGradient(starting: hex(0xFFC24A), ending: hex(0xFF6A2C))?
        .draw(in: board, angle: -55)
    let leftPanel = NSBezierPath()
    leftPanel.move(to: NSPoint(x: board.minX, y: board.minY))
    leftPanel.line(to: NSPoint(x: board.minX + p(286), y: board.minY))
    leftPanel.line(to: NSPoint(x: board.minX + p(150), y: board.maxY))
    leftPanel.line(to: NSPoint(x: board.minX, y: board.maxY))
    leftPanel.close()
    NSGradient(starting: hex(0x7B4BFF), ending: hex(0x4A2BC4))?
        .draw(in: leftPanel, angle: -55)
    ctx?.restoreGState()

    // The lifted subject: white, because a cutout on this app always gets the
    // keyline treatment. Offset right so the cut stays readable.
    let headCenter = NSPoint(x: p(596), y: p(556))
    let subject = NSBezierPath()
    subject.append(NSBezierPath(ovalIn: NSRect(x: headCenter.x - p(80), y: headCenter.y - p(80),
                                               width: p(160), height: p(160))))
    subject.append(NSBezierPath(roundedRect:
        NSRect(x: headCenter.x - p(142), y: p(306), width: p(284), height: p(182)),
        xRadius: p(92), yRadius: p(92)))
    ctx?.saveGState()
    boardPath.addClip()
    hex(0x0B0C10, 0.35).setFill()
    let dropped = subject.copy() as! NSBezierPath
    dropped.transform(using: AffineTransform(translationByX: p(14), byY: -p(14)))
    dropped.fill()
    NSColor.white.setFill()
    subject.fill()
    ctx?.restoreGState()

    // Selection handles — only where they are more than a smudge.
    if side >= 128 {
        hex(0xFFFFFF, 0.95).setFill()
        for corner in [NSPoint(x: board.minX, y: board.minY), NSPoint(x: board.maxX, y: board.minY),
                       NSPoint(x: board.minX, y: board.maxY), NSPoint(x: board.maxX, y: board.maxY)] {
            NSBezierPath(ovalIn: NSRect(x: corner.x - p(24), y: corner.y - p(24),
                                        width: p(48), height: p(48))).fill()
        }
    }
}

func render(side: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    drawIcon(side: CGFloat(side))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AppIcon.appiconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for side in sizes {
    guard let data = render(side: side) else { continue }
    try? data.write(to: URL(fileURLWithPath: "\(out)/icon_\(side).png"))
}
print("wrote \(sizes.count) icons to \(out)")

import Foundation

/// The Thumbnail Studio's document: a canvas and a back-to-front layer stack.
/// Positions and sizes are fractions of the canvas, so the same document
/// renders identically at any pixel size — and the preview literally IS the
/// export render, scaled to fit the window.
struct ThumbDocument: Codable, Equatable {
    var width: Int = 1280
    var height: Int = 720
    /// Canvas fill under every layer. nil means the studio's own default,
    /// which the inspector's swatch also shows — so the swatch never
    /// misreports what the renderer paints.
    var backgroundHex: String?
    static let defaultBackgroundHex = "141414"
    /// Leaves the canvas empty instead of painting a base colour, so a PNG
    /// export carries real alpha. Distinct from `backgroundHex == nil`, which
    /// means "no colour chosen, use the default" — an overlay and an
    /// unstyled document are not the same thing.
    var transparentBackground: Bool = false
    var layers: [ThumbLayer] = []
    var groups: [ThumbGroup] = []

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        width = value(.width, 1280)
        height = value(.height, 720)
        backgroundHex = try? container.decodeIfPresent(String.self, forKey: .backgroundHex)
        transparentBackground = value(.transparentBackground, false)
        layers = value(.layers, [])
        groups = value(.groups, [])
    }

    /// Canvas presets — YouTube first, since that's the point.
    static let canvasPresets: [(name: String, width: Int, height: Int)] = [
        ("YouTube 1280×720", 1280, 720),
        ("HD 1920×1080", 1920, 1080),
        ("Vertical cover 1080×1920", 1080, 1920),
        ("Square 1080×1080", 1080, 1080),
    ]

    /// Canvas dimensions the renderer can actually allocate. The upper bound
    /// is a 8192-square bitmap — 256 MB at 4 bytes a pixel — which is already
    /// far past anything a thumbnail needs and short of where NSBitmapImageRep
    /// starts refusing.
    static func clampedDimension(_ value: Double) -> Int {
        guard value.isFinite else { return 1280 }
        return min(8192, max(64, Int(value.rounded())))
    }

    /// YouTube stamps the duration badge in the lower-right; text under it is
    /// wasted. Fractions of the canvas.
    static let durationSafeZone = (x: 0.80, y: 0.855, width: 0.19, height: 0.125)

    /// Canva's align row: snap a layer to a canvas edge or centre. Layer
    /// positions are centres, so horizontal uses the layer's own width;
    /// vertical needs the drawn height, which text and images derive at
    /// render time — the caller passes it in.
    mutating func align(layerID: UUID, horizontal: HorizontalAlign? = nil,
                        vertical: VerticalAlign? = nil,
                        drawnHeightFraction: Double = 0.3) {
        guard let index = layers.firstIndex(where: { $0.id == layerID }) else { return }
        let half = layers[index].widthFraction / 2
        let halfV = drawnHeightFraction / 2
        switch horizontal {
        case .left: layers[index].x = min(1, max(0, half))
        case .center: layers[index].x = 0.5
        case .right: layers[index].x = min(1, max(0, 1 - half))
        case nil: break
        }
        switch vertical {
        case .top: layers[index].y = min(1, max(0, halfV))
        case .middle: layers[index].y = 0.5
        case .bottom: layers[index].y = min(1, max(0, 1 - halfV))
        case nil: break
        }
    }

    enum HorizontalAlign { case left, center, right }
    enum VerticalAlign { case top, middle, bottom }

    /// Stacking-order moves. `layers` is back-to-front, so "forward" means
    /// toward the end of the array.
    enum LayerMove: String {
        case toFront, forward, backward, toBack
    }

    /// Restacks one layer. Returns false when the move is a no-op (already
    /// at that edge, or unknown id) so callers can skip the undo entry.
    @discardableResult
    mutating func move(layerID: UUID, _ direction: LayerMove) -> Bool {
        guard let index = layers.firstIndex(where: { $0.id == layerID }) else { return false }
        let layer = layers[index]
        switch direction {
        case .toFront:
            guard index < layers.count - 1 else { return false }
            layers.remove(at: index)
            layers.append(layer)
        case .forward:
            guard index < layers.count - 1 else { return false }
            layers.swapAt(index, index + 1)
        case .backward:
            guard index > 0 else { return false }
            layers.swapAt(index, index - 1)
        case .toBack:
            guard index > 0 else { return false }
            layers.remove(at: index)
            layers.insert(layer, at: 0)
        }
        return true
    }
}

/// A named set of layers that behave as one.
///
/// Membership lives on the LAYERS, as a `groupID`, rather than here as a list
/// of children — and the document stays one flat array rather than becoming a
/// tree. That is the whole reason this was affordable: every verb in the app
/// already takes a `Set<UUID>`, so expanding a selection to a group's members
/// makes move, delete, duplicate, lock, hide, align and arrange work on groups
/// without any of them being touched. A tree would have meant rewriting the
/// renderer, hit testing, z-order and the layers panel at once.
///
/// The price is that groups do not nest. That is a real limit and it is the
/// right trade: the problem being solved is "I reselect the same three layers
/// every time", not "I need a hierarchy".
struct ThumbGroup: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = "Group"
    /// Collapsed groups show one row in the layers panel instead of N.
    var isCollapsed: Bool = false

    init(id: UUID = UUID(), name: String = "Group", isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        id = value(.id, UUID())
        name = value(.name, "Group")
        isCollapsed = value(.isCollapsed, false)
    }
}

/// Effects that sit around a layer rather than inside it.
///
/// On `ThumbLayer` and not on the three specs, because a glow is a glow
/// whether it is behind text, a cutout or a panel — and because the renderer
/// applies all four the same way, from the layer's own alpha. The stroke and
/// drop shadow already on `TextSpec` and `ImageSpec` are left where they are:
/// they were there first, they work, and moving them would rewrite every
/// saved design for no gain.
///
/// Sizes are in pixels at 720p and scale with the canvas, exactly as
/// `strokeWidth` and `boxPadding` already do, so a design looks the same
/// exported at 1280 or 3840.
struct LayerEffects: Codable, Equatable {
    /// The thumbnail effect. A bright halo behind the glyphs is what makes
    /// text survive a busy game screenshot, and it was the one thing this
    /// editor could not do that every channel it competes with does.
    var glowEnabled: Bool = false
    var glowHex: String = "00FF66"
    var glowRadius: Double = 18
    var glowOpacity: Double = 0.9
    /// Fattens the silhouette before blurring, the way Photoshop's Spread
    /// does. Without it a large radius only ever gives you a faint mist,
    /// because blurring thin glyphs spreads their alpha to nothing.
    var glowSpread: Double = 0.25

    var innerShadowEnabled: Bool = false
    var innerShadowHex: String = "000000"
    var innerShadowRadius: Double = 10
    var innerShadowOpacity: Double = 0.65
    var innerShadowDistance: Double = 6
    /// Degrees, 90 being from above — the light direction everyone assumes.
    var innerShadowAngle: Double = 90

    var colorOverlayEnabled: Bool = false
    var colorOverlayHex: String = "FF3B30"
    var colorOverlayOpacity: Double = 1

    var gradientOverlayEnabled: Bool = false
    var gradientFromHex: String = "FFD60A"
    var gradientToHex: String = "FF375F"
    var gradientAngleDegrees: Double = 90
    var gradientOpacity: Double = 1

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        glowEnabled = value(.glowEnabled, false)
        glowHex = value(.glowHex, "00FF66")
        glowRadius = value(.glowRadius, 18)
        glowOpacity = value(.glowOpacity, 0.9)
        glowSpread = value(.glowSpread, 0.25)
        innerShadowEnabled = value(.innerShadowEnabled, false)
        innerShadowHex = value(.innerShadowHex, "000000")
        innerShadowRadius = value(.innerShadowRadius, 10)
        innerShadowOpacity = value(.innerShadowOpacity, 0.65)
        innerShadowDistance = value(.innerShadowDistance, 6)
        innerShadowAngle = value(.innerShadowAngle, 90)
        colorOverlayEnabled = value(.colorOverlayEnabled, false)
        colorOverlayHex = value(.colorOverlayHex, "FF3B30")
        colorOverlayOpacity = value(.colorOverlayOpacity, 1)
        gradientOverlayEnabled = value(.gradientOverlayEnabled, false)
        gradientFromHex = value(.gradientFromHex, "FFD60A")
        gradientToHex = value(.gradientToHex, "FF375F")
        gradientAngleDegrees = value(.gradientAngleDegrees, 90)
        gradientOpacity = value(.gradientOpacity, 1)
    }

    /// Whether any of this does anything. Checked before the renderer takes
    /// the expensive path, so a design with no effects costs exactly what it
    /// cost before they existed.
    var isActive: Bool {
        (glowEnabled && glowRadius > 0.01 && glowOpacity > 0.001)
            || (innerShadowEnabled && innerShadowOpacity > 0.001)
            || (colorOverlayEnabled && colorOverlayOpacity > 0.001)
            || (gradientOverlayEnabled && gradientOpacity > 0.001)
    }

    /// Whether anything here repaints the layer's own colour. Those two are
    /// the effects that have to respect a stroke; a glow and an inner shadow
    /// do not.
    var hasOverlay: Bool {
        (colorOverlayEnabled && colorOverlayOpacity > 0.001)
            || (gradientOverlayEnabled && gradientOpacity > 0.001)
    }

    /// How far outside its own bounds this layer now paints, in pixels at
    /// 720p. The glow reaches past the glyphs, so anything measuring where a
    /// layer lands — the badge test, the edge test — has to know about it.
    var outerReach: Double {
        guard glowEnabled, glowOpacity > 0.001 else { return 0 }
        return glowRadius * (1 + glowSpread)
    }
}

/// One layer. Geometry lives here; what it draws lives in `kind`.
struct ThumbLayer: Codable, Identifiable, Equatable {
    enum Kind: Codable, Equatable {
        case image(ImageSpec)
        case text(TextSpec)
        case shape(ShapeSpec)
    }

    var id: UUID = UUID()
    var name: String = ""
    var kind: Kind
    /// Centre, as fractions of the canvas.
    var x: Double = 0.5
    var y: Double = 0.5
    /// Width as a fraction of canvas width. Text sizes from its own font
    /// spec; images derive height from their aspect; shapes use
    /// `heightFraction`.
    var widthFraction: Double = 0.5
    var heightFraction: Double = 0.3
    var rotationDegrees: Double = 0
    var opacity: Double = 1
    /// "normal", "multiply", "screen", "overlay".
    var blendMode: String = "normal"
    var isVisible: Bool = true
    var isLocked: Bool = false
    var effects = LayerEffects()
    /// Which group this belongs to, if any.
    var groupID: UUID?

    init(id: UUID = UUID(), name: String = "", kind: Kind,
         x: Double = 0.5, y: Double = 0.5,
         widthFraction: Double = 0.5, heightFraction: Double = 0.3,
         rotationDegrees: Double = 0, opacity: Double = 1,
         blendMode: String = "normal", isVisible: Bool = true, isLocked: Bool = false,
         effects: LayerEffects = LayerEffects(), groupID: UUID? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.x = x
        self.y = y
        self.widthFraction = widthFraction
        self.heightFraction = heightFraction
        self.rotationDegrees = rotationDegrees
        self.opacity = opacity
        self.blendMode = blendMode
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.effects = effects
        self.groupID = groupID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        id = value(.id, UUID())
        name = value(.name, "")
        kind = try container.decode(Kind.self, forKey: .kind)
        x = value(.x, 0.5)
        y = value(.y, 0.5)
        widthFraction = value(.widthFraction, 0.5)
        heightFraction = value(.heightFraction, 0.3)
        rotationDegrees = value(.rotationDegrees, 0)
        opacity = value(.opacity, 1)
        blendMode = value(.blendMode, "normal")
        isVisible = value(.isVisible, true)
        isLocked = value(.isLocked, false)
        effects = value(.effects, LayerEffects())
        groupID = try? container.decodeIfPresent(UUID.self, forKey: .groupID)
    }

    var displayName: String {
        if !name.isEmpty { return name }
        switch kind {
        case .image(let spec): return URL(fileURLWithPath: spec.path).lastPathComponent
        case .text(let spec): return spec.text.isEmpty ? "Text" : String(spec.text.prefix(24))
        case .shape(let spec): return spec.shape.capitalized
        }
    }
}

/// An image on the canvas — a file from disk, or a frame grabbed off the
/// timeline (same spec; the grab just writes a PNG first).
struct ImageSpec: Codable, Equatable {
    var path: String
    /// Set once Remove Background has run; `useCutout` swaps it in.
    var cutoutPath: String?
    var useCutout: Bool = false
    /// How the cutout was made, kept so reopening a design can reproduce it
    /// and so nudging the edge controls re-lifts rather than starting over.
    /// nil instance means "every subject Vision found".
    var cutoutInstance: Int?
    var cutoutContract: Double = 1.0
    var cutoutFeather: Double = 1.0
    var cutoutContrast: Double = 0.35
    var flippedHorizontally: Bool = false
    /// Adjustments, all zero-centred.
    var brightness: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var exposure: Double = 0
    var vibrance: Double = 0
    /// Recover blown skies and lift crushed shadows independently, which is
    /// most of what a gameplay grab needs. 0…1 each.
    var highlights: Double = 0
    var shadows: Double = 0
    /// White balance, zero-centred. Warm/cool and green/magenta.
    var temperature: Double = 0
    var tint: Double = 0
    /// Unsharp mask amount, and its inverse. A frame grab is usually a little
    /// soft; a compressed one is usually a little noisy.
    var sharpness: Double = 0
    var noiseReduction: Double = 0
    /// Darkens the corners, which is how you push a face forward without
    /// touching the face.
    var vignette: Double = 0
    /// Rotates every hue, in degrees. Cheap way to recolour a UI element.
    var hue: Double = 0
    /// "none", "mono", "chrome", "fade", "instant", "noir".
    var filterPreset: String = "none"
    /// Optional crop, fractions of the source image.
    var crop: NormalizedRect?
    /// Diagonal cut: "none", "left", "right", "top", "bottom" — that edge
    /// becomes a slant, the thumbnail split-screen look. `cutAmount` is how
    /// deep the slant travels; `cutFlip` picks which corner moves.
    var cutEdge: String = "none"
    var cutAmount: Double = 0.22
    var cutFlip: Bool = false
    /// Canva-style frame: "none", "rounded", "circle" — clips the image
    /// before drawing, with an optional border on the mask edge.
    var maskShape: String = "none"
    var maskCornerRadius: Double = 28
    var borderWidth: Double = 0
    var borderHex: String = "FFFFFF"
    /// The standard thumbnail treatment on cutout subjects.
    var shadowEnabled: Bool = false
    var shadowBlur: Double = 18
    var shadowOffset: Double = 8
    var shadowHex: String = "000000"
    var strokeWidth: Double = 0
    var strokeHex: String = "FFFFFF"

    init(path: String) { self.path = path }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        path = try container.decode(String.self, forKey: .path)
        cutoutPath = try? container.decodeIfPresent(String.self, forKey: .cutoutPath)
        useCutout = value(.useCutout, false)
        cutoutInstance = try? container.decodeIfPresent(Int.self, forKey: .cutoutInstance)
        cutoutContract = value(.cutoutContract, 1.0)
        cutoutFeather = value(.cutoutFeather, 1.0)
        cutoutContrast = value(.cutoutContrast, 0.35)
        flippedHorizontally = value(.flippedHorizontally, false)
        brightness = value(.brightness, 0)
        contrast = value(.contrast, 0)
        saturation = value(.saturation, 0)
        exposure = value(.exposure, 0)
        vibrance = value(.vibrance, 0)
        highlights = value(.highlights, 0)
        shadows = value(.shadows, 0)
        temperature = value(.temperature, 0)
        tint = value(.tint, 0)
        sharpness = value(.sharpness, 0)
        noiseReduction = value(.noiseReduction, 0)
        vignette = value(.vignette, 0)
        hue = value(.hue, 0)
        filterPreset = value(.filterPreset, "none")
        crop = try? container.decodeIfPresent(NormalizedRect.self, forKey: .crop)
        cutEdge = value(.cutEdge, "none")
        cutAmount = value(.cutAmount, 0.22)
        cutFlip = value(.cutFlip, false)
        maskShape = value(.maskShape, "none")
        maskCornerRadius = value(.maskCornerRadius, 28)
        borderWidth = value(.borderWidth, 0)
        borderHex = value(.borderHex, "FFFFFF")
        shadowEnabled = value(.shadowEnabled, false)
        shadowBlur = value(.shadowBlur, 18)
        shadowOffset = value(.shadowOffset, 8)
        shadowHex = value(.shadowHex, "000000")
        strokeWidth = value(.strokeWidth, 0)
        strokeHex = value(.strokeHex, "FFFFFF")
    }

    /// Whether any adjustment is doing anything.
    ///
    /// Derived from the values rather than hand-listed: the previous version
    /// enumerated fields by name, which meant every adjustment added here had
    /// to be remembered in two other places or it silently did nothing.
    var hasAdjustments: Bool {
        adjustmentValues.contains { abs($0) > 0.001 } || filterPreset != "none"
    }

    /// Every zero-centred adjustment, in one list, so the cache key and the
    /// "is anything on?" test can never drift from the filters themselves.
    var adjustmentValues: [Double] {
        [brightness, contrast, saturation, exposure, vibrance,
         highlights, shadows, temperature, tint,
         sharpness, noiseReduction, vignette, hue]
    }

    var effectivePath: String { useCutout ? (cutoutPath ?? path) : path }
}

/// Text — the big thumbnail kind: heavy face, hard stroke, optional gradient.
struct TextSpec: Codable, Equatable {
    var text: String = "TEXT"
    /// A family name. The default is resolved at run time from what is
    /// actually installed — hardcoding "Anton" meant the inspector claimed a
    /// font the renderer could not draw.
    var fontName: String = ThumbFonts.defaultFamily
    /// A face within that family — "Black", "Condensed Heavy". nil takes the
    /// family's own default.
    var fontFace: String?
    /// Thumbnail text is usually set in caps; doing it here rather than making
    /// the user retype means the words stay editable.
    var uppercase: Bool = false
    /// Font size as a fraction of canvas height.
    var sizeFraction: Double = 0.16
    var letterSpacing: Double = 0
    var lineHeightMultiple: Double = 1
    /// "left", "center", "right".
    var alignment: String = "center"
    var fillHex: String = "FFFFFF"
    /// A vertical gradient when set — fill at the top, this at the bottom.
    var gradientHex: String?
    /// An image showing through the letters instead of a flat fill. Takes
    /// precedence over the gradient when both are set.
    var imageFillPath: String?
    var strokeHex: String = "000000"
    /// Stroke width in pixels at 720p; scales with the canvas.
    var strokeWidth: Double = 10
    var shadowEnabled: Bool = true
    var shadowBlur: Double = 10
    var shadowOffset: Double = 5
    var shadowHex: String = "000000"
    var boxEnabled: Bool = false
    var boxHex: String = "FF0000"
    var boxPadding: Double = 14
    var boxCorner: Double = 10

    init(text: String = "TEXT") { self.text = text }

    /// What actually gets drawn. Uppercasing lives here so the renderer, the
    /// measurement and the hit box can never disagree about it.
    var renderedText: String { uppercase ? text.uppercased() : text }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        text = value(.text, "TEXT")
        fontName = value(.fontName, ThumbFonts.defaultFamily)
        fontFace = try? container.decodeIfPresent(String.self, forKey: .fontFace)
        uppercase = value(.uppercase, false)
        sizeFraction = value(.sizeFraction, 0.16)
        letterSpacing = value(.letterSpacing, 0)
        lineHeightMultiple = value(.lineHeightMultiple, 1)
        alignment = value(.alignment, "center")
        fillHex = value(.fillHex, "FFFFFF")
        gradientHex = try? container.decodeIfPresent(String.self, forKey: .gradientHex)
        imageFillPath = try? container.decodeIfPresent(String.self, forKey: .imageFillPath)
        strokeHex = value(.strokeHex, "000000")
        strokeWidth = value(.strokeWidth, 10)
        shadowEnabled = value(.shadowEnabled, true)
        shadowBlur = value(.shadowBlur, 10)
        shadowOffset = value(.shadowOffset, 5)
        shadowHex = value(.shadowHex, "000000")
        boxEnabled = value(.boxEnabled, false)
        boxHex = value(.boxHex, "FF0000")
        boxPadding = value(.boxPadding, 14)
        boxCorner = value(.boxCorner, 10)
    }
}

/// Rectangle, ellipse, line, arrow, polygon.
struct ShapeSpec: Codable, Equatable {
    var shape: String = "rectangle"
    var fillHex: String? = "FF0000"
    /// When set, the fill runs fillHex → this, along the angle.
    var fillGradientHex: String?
    var gradientAngleDegrees: Double = 90
    /// Same diagonal cut as images — slanted colour panels are the other
    /// half of the split-thumbnail look.
    var cutEdge: String = "none"
    var cutAmount: Double = 0.22
    var cutFlip: Bool = false
    var strokeHex: String = "FFFFFF"
    var strokeWidth: Double = 0
    var cornerRadius: Double = 12
    var sides: Int = 5

    init(shape: String = "rectangle") { self.shape = shape }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        shape = value(.shape, "rectangle")
        fillHex = try? container.decodeIfPresent(String.self, forKey: .fillHex)
        fillGradientHex = try? container.decodeIfPresent(String.self, forKey: .fillGradientHex)
        gradientAngleDegrees = value(.gradientAngleDegrees, 90)
        cutEdge = value(.cutEdge, "none")
        cutAmount = value(.cutAmount, 0.22)
        cutFlip = value(.cutFlip, false)
        strokeHex = value(.strokeHex, "FFFFFF")
        strokeWidth = value(.strokeWidth, 0)
        cornerRadius = value(.cornerRadius, 12)
        sides = value(.sides, 5)
    }

    static let shapes = ["rectangle", "ellipse", "line", "arrow", "polygon",
                         "star", "bubble"]
}

/// Starter templates aimed at IRL/Just Chatting: big face, bold text, high
/// contrast. Applying a template keeps its layout and styling; the face slot
/// is an image layer you replace with a frame grab.
enum ThumbTemplates {
    static func starters() -> [(name: String, document: ThumbDocument)] {
        [("Big Reaction", bigReaction()), ("Versus", versus()),
         ("Story Time", storyTime()), ("Clean Bold", cleanBold())]
    }

    private static func placeholderFace(x: Double, width: Double) -> ThumbLayer {
        var spec = ImageSpec(path: "")
        spec.shadowEnabled = true
        var layer = ThumbLayer(name: "Face (replace me)", kind: .image(spec),
                               x: x, y: 0.52, widthFraction: width)
        layer.heightFraction = width * 1.2
        return layer
    }

    private static func headline(_ text: String, y: Double, size: Double = 0.2,
                                 fill: String = "FFFFFF",
                                 gradient: String? = "FFD60A") -> ThumbLayer {
        var spec = TextSpec(text: text)
        spec.sizeFraction = size
        spec.fillHex = fill
        spec.gradientHex = gradient
        spec.strokeWidth = 12
        return ThumbLayer(name: text, kind: .text(spec), x: 0.5, y: y, widthFraction: 0.9)
    }

    private static func bigReaction() -> ThumbDocument {
        var doc = ThumbDocument()
        var burst = ShapeSpec(shape: "polygon")
        burst.sides = 12
        burst.fillHex = "FFD60A"
        doc.layers = [
            ThumbLayer(name: "Burst", kind: .shape(burst), x: 0.72, y: 0.42,
                       widthFraction: 0.5, heightFraction: 0.85, opacity: 0.9),
            placeholderFace(x: 0.72, width: 0.42),
            headline("HE DID WHAT?!", y: 0.82),
        ]
        return doc
    }

    private static func versus() -> ThumbDocument {
        var doc = ThumbDocument()
        var bar = ShapeSpec(shape: "rectangle")
        bar.fillHex = "FF453A"
        bar.cornerRadius = 0
        doc.layers = [
            placeholderFace(x: 0.22, width: 0.38),
            placeholderFace(x: 0.78, width: 0.38),
            ThumbLayer(name: "Slash", kind: .shape(bar), x: 0.5, y: 0.5,
                       widthFraction: 0.04, heightFraction: 1.2, rotationDegrees: 14),
            headline("1 V 1", y: 0.5, size: 0.24, gradient: nil),
        ]
        return doc
    }

    private static func storyTime() -> ThumbDocument {
        var doc = ThumbDocument()
        var box = ShapeSpec(shape: "rectangle")
        box.fillHex = "000000"
        box.cornerRadius = 18
        var boxLayer = ThumbLayer(name: "Panel", kind: .shape(box), x: 0.32, y: 0.5,
                                  widthFraction: 0.56, heightFraction: 0.62)
        boxLayer.opacity = 0.62
        doc.layers = [
            placeholderFace(x: 0.78, width: 0.4),
            boxLayer,
            headline("STORY TIME", y: 0.36, size: 0.17),
            headline("you won't believe this", y: 0.58, size: 0.09,
                     fill: "FFFFFF", gradient: nil),
        ]
        return doc
    }

    private static func cleanBold() -> ThumbDocument {
        var doc = ThumbDocument()
        doc.layers = [
            placeholderFace(x: 0.5, width: 0.44),
            headline("THE VIDEO", y: 0.14, size: 0.18, gradient: nil),
            headline("WATCH THIS", y: 0.86, size: 0.18),
        ]
        return doc
    }
}

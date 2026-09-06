import Foundation

struct TitleIdea: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var text: String
    /// What in the stream it's drawn from. A title you can't trace back to a
    /// moment is a title that lies about the video.
    var why: String

    var length: Int { text.count }
    /// YouTube truncates around here in search and on mobile.
    var fitsSearchResults: Bool { text.count <= 60 }
}

/// Everything the packaging pass produces in one call.
struct IdeaPack: Codable, Equatable {
    var generatedAt: Date
    var scopeLabel: String
    var titles: [TitleIdea] = []
    /// Opening lines for the vertical cuts, where the first second decides it.
    var hooks: [String] = []
    /// Two to four words, for burning onto the thumbnail.
    var thumbnailTexts: [String] = []
    var descriptionText: String = ""
    var tags: [String] = []
    /// Which moment the model thought would make the strongest still.
    var bestMomentSeconds: Double?
    /// A prompt for image generation, when a frame from the stream won't do.
    var imagePrompt: String = ""
}

/// Where the thumbnail text sits, as the nine positions ASS understands.
enum ThumbnailTextPosition: String, Codable, CaseIterable {
    case topLeft, top, topRight
    case left, center, right
    case bottomLeft, bottom, bottomRight

    var label: String {
        switch self {
        case .topLeft: return "Top left"
        case .top: return "Top"
        case .topRight: return "Top right"
        case .left: return "Left"
        case .center: return "Centre"
        case .right: return "Right"
        case .bottomLeft: return "Bottom left"
        case .bottom: return "Bottom"
        case .bottomRight: return "Bottom right"
        }
    }

    /// ASS uses numpad alignment.
    var assAlignment: Int {
        switch self {
        case .bottomLeft: return 1
        case .bottom: return 2
        case .bottomRight: return 3
        case .left: return 4
        case .center: return 5
        case .right: return 6
        case .topLeft: return 7
        case .top: return 8
        case .topRight: return 9
        }
    }

    var isTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var isBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    var isLeading: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var isTrailing: Bool { self == .topRight || self == .right || self == .bottomRight }
}

/// Thumbnail text is not caption text — it's three words at 150 points with a
/// stroke you can read at 120 pixels wide, so it gets its own style rather than
/// borrowing `CaptionStyle`.
struct ThumbnailTextStyle: Codable, Equatable {
    var fontName: String = "Impact"
    var fontSize: Int = 130
    var fill: CaptionColor = .white
    var outline: CaptionColor = .black
    var outlineWidth: Double = 7
    var shadow: Double = 2
    var useBox: Bool = false
    var boxColor: CaptionColor = CaptionColor(red: 0, green: 0, blue: 0, alpha: 0.65)
    var position: ThumbnailTextPosition = .bottomLeft
    var marginVertical: Int = 60
    var marginHorizontal: Int = 60
    var uppercase: Bool = true
    var maxCharactersPerLine: Int = 14

    static let standard = ThumbnailTextStyle()
}

/// An image sitting on top of the frame: your logo, a facecam cutout, a sticker,
/// or a piece of overlay art Claude drew.
struct ThumbnailLayer: Codable, Equatable, Identifiable {
    enum Origin: String, Codable {
        /// A file the user brought.
        case file
        /// SVG written by Claude and rasterised locally.
        case designed
    }

    var id: UUID = UUID()
    var path: String
    var origin: Origin = .file
    var name: String = ""

    /// Centre of the layer, as a fraction of the frame. Resolution-independent,
    /// so the same draft composes correctly at 1280×720 and 1080×1920.
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    /// Width as a fraction of the frame's width; height follows the aspect.
    var width: Double = 0.35
    var opacity: Double = 1
    var flipped: Bool = false
    var isVisible: Bool = true

    var url: URL { URL(fileURLWithPath: path) }
    var displayName: String {
        name.isEmpty ? url.deletingPathExtension().lastPathComponent : name
    }
}

/// One thumbnail in progress.
struct ThumbnailDraft: Codable, Equatable {
    /// Where in the VOD the still comes from. Nil when a generated image is
    /// standing in for it.
    var frameTime: Double?
    var generatedImagePath: String?
    var text: String = ""
    var style: ThumbnailTextStyle = .standard
    /// Horizontal centre of the 9:16 crop for the vertical cover.
    var cropCenterX: Double = 0.5
    /// Composited over the frame, bottom of the list first, with the text drawn
    /// last so it always stays legible.
    var layers: [ThumbnailLayer] = []

    var generatedImageURL: URL? { generatedImagePath.map { URL(fileURLWithPath: $0) } }

    static let horizontalSize = (width: 1280, height: 720)
    static let verticalSize = (width: 1080, height: 1920)
}

/// A frame pulled from the VOD, offered as a thumbnail background.
struct FrameCandidate: Identifiable, Equatable {
    var id: Int
    var time: Double
    var path: String
    /// What was being said, so the strip reads as moments rather than stills.
    var caption: String
    var score: Double

    var url: URL { URL(fileURLWithPath: path) }
}

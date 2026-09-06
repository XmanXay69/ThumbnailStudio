import Foundation

/// One person you edit for: their handles, caption look, webcam framing,
/// vocabulary, and logo — applied to any project in one click instead of
/// retyping and re-picking per VOD.
struct ClientProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var twitchHandle: String = ""
    var instagramHandle: String = ""
    /// Any image file; applied as a thumbnail layer.
    var logoPath: String?
    /// The brand look — font, colours, karaoke — captured whole.
    var captionStyle: CaptionStyle = .standard
    /// The webcam box is constant for a streamer, so it travels with them.
    var defaultLayout: ShortLayout = .fill
    /// Names, co-streamers, game terms — feeds whisper's prompt and every
    /// manual Claude prompt.
    var vocabulary: String = ""
    /// Brand colour for end cards and accents, RRGGBB.
    var brandColorHex: String = "9146FF"
    /// The end-card sign-off line.
    var subscribePrompt: String = "LIKE & SUBSCRIBE"
    /// Optional intro sting video, prepended to long-form cuts on request.
    var introPath: String?
    /// Posting cadence for the runway forecast, posts per week.
    var postsPerWeek: Double = 7

    init(id: UUID = UUID(), name: String = "", twitchHandle: String = "",
         instagramHandle: String = "", logoPath: String? = nil,
         captionStyle: CaptionStyle = .standard, defaultLayout: ShortLayout = .fill,
         vocabulary: String = "") {
        self.id = id
        self.name = name
        self.twitchHandle = twitchHandle
        self.instagramHandle = instagramHandle
        self.logoPath = logoPath
        self.captionStyle = captionStyle
        self.defaultLayout = defaultLayout
        self.vocabulary = vocabulary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        id = value(.id, UUID())
        name = value(.name, "")
        twitchHandle = value(.twitchHandle, "")
        instagramHandle = value(.instagramHandle, "")
        logoPath = try? container.decodeIfPresent(String.self, forKey: .logoPath)
        captionStyle = value(.captionStyle, CaptionStyle.standard)
        defaultLayout = value(.defaultLayout, ShortLayout.fill)
        vocabulary = value(.vocabulary, "")
        brandColorHex = value(.brandColorHex, "9146FF")
        subscribePrompt = value(.subscribePrompt, "LIKE & SUBSCRIBE")
        introPath = try? container.decodeIfPresent(String.self, forKey: .introPath)
        postsPerWeek = value(.postsPerWeek, 7)
    }

    // MARK: - Capture and apply

    /// Everything a project already knows about its streamer, lifted into a
    /// reusable profile.
    static func captured(from project: VODProject, edit: ClipEdit, named name: String) -> ClientProfile {
        ClientProfile(
            name: name,
            twitchHandle: edit.twitchHandle,
            instagramHandle: edit.instagramHandle,
            logoPath: nil,
            captionStyle: project.captionStyle,
            defaultLayout: project.defaultShortLayout,
            vocabulary: project.vocabularyPrompt
        )
    }

    /// The profile stamped onto a project and its editor document. Pure, so
    /// the mapping is testable; the session persists the results.
    func applied(to project: VODProject, edit: ClipEdit) -> (VODProject, ClipEdit) {
        var updatedProject = project
        updatedProject.clientProfileID = id
        updatedProject.clientName = name
        updatedProject.captionStyle = captionStyle
        updatedProject.defaultShortLayout = defaultLayout
        if !vocabulary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updatedProject.vocabularyPrompt = vocabulary
        }
        var updatedEdit = edit
        updatedEdit.twitchHandle = twitchHandle
        updatedEdit.instagramHandle = instagramHandle
        if let logo = logoPath,
           !updatedProject.thumbnail.layers.contains(where: { $0.path == logo }) {
            updatedProject.thumbnail.layers.append(
                ThumbnailLayer(path: logo, origin: .file, name: "\(name) logo",
                               centerX: 0.88, centerY: 0.12, width: 0.16)
            )
        }
        return (updatedProject, updatedEdit)
    }
}

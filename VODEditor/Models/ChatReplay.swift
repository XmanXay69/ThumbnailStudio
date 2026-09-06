import Foundation

struct ChatMessage: Equatable {
    var offset: Double      // seconds from stream start
    var body: String
    var author: String
}

/// Twitch chat replay, as exported by TwitchDownloaderCLI.
///
/// For IRL and Just Chatting content, message density is usually a better
/// excitement signal than audio — the room going quiet while chat explodes is a
/// clip, and audio energy alone misses it entirely.
enum ChatReplay {
    private struct TDRoot: Decodable {
        struct Comment: Decodable {
            struct Commenter: Decodable { let display_name: String? }
            struct Message: Decodable { let body: String? }
            let content_offset_seconds: Double?
            let commenter: Commenter?
            let message: Message?
        }
        let comments: [Comment]?
    }

    /// Fallback shape: a bare array of `{offset/time, message/text, user}`.
    private struct LooseMessage: Decodable {
        let offset: Double?
        let time: Double?
        let content_offset_seconds: Double?
        let message: String?
        let text: String?
        let body: String?
        let user: String?
        let author: String?
    }

    static func load(from url: URL) throws -> [ChatMessage] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()

        if let root = try? decoder.decode(TDRoot.self, from: data), let comments = root.comments {
            return comments.compactMap { comment in
                guard let offset = comment.content_offset_seconds,
                      let body = comment.message?.body, !body.isEmpty else { return nil }
                return ChatMessage(offset: offset, body: body,
                                   author: comment.commenter?.display_name ?? "")
            }
            .sorted { $0.offset < $1.offset }
        }

        if let loose = try? decoder.decode([LooseMessage].self, from: data) {
            return loose.compactMap { item in
                guard let offset = item.offset ?? item.time ?? item.content_offset_seconds,
                      let body = item.message ?? item.text ?? item.body, !body.isEmpty else { return nil }
                return ChatMessage(offset: offset, body: body, author: item.user ?? item.author ?? "")
            }
            .sorted { $0.offset < $1.offset }
        }

        throw ChatReplayError.unrecognizedFormat
    }
}

enum ChatReplayError: LocalizedError {
    case unrecognizedFormat

    var errorDescription: String? {
        "Unrecognized chat format. Export with TwitchDownloaderCLI as JSON, or use an array of {offset, message} objects."
    }
}

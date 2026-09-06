import SwiftUI

/// Thumbnail Studio: the design half of the VOD editor, on its own. Same
/// documents, same renderer, no video pipeline — you can have it open while a
/// four-hour VOD is transcribing next door and neither knows about the other.
@main
struct ThumbStudioApp: App {
    init() { Paths.ensureThumbDirectories() }

    var body: some Scene {
        WindowGroup {
            ThumbLabView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .frame(minWidth: 1100, minHeight: 700)
                .background(Theme.background)
        }
    }
}

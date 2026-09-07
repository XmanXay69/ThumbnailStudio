import SwiftUI
import AppKit

/// Thumbnail Studio: the design half of the VOD editor, on its own. Same
/// documents, same renderer, no video pipeline — so it can be open while a
/// four-hour VOD is transcribing next door and neither knows about the other.
@main
struct ThumbStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate

    init() {
        Paths.ensureThumbDirectories()
        // Tuning a cutout's edge writes a file per setting so going back is
        // instant; the ones nothing points at any more go now.
        Task.detached(priority: .background) { ThumbAssets.pruneUnreferenced() }
    }

    var body: some Scene {
        WindowGroup {
            ThumbLabView()
                .frame(minWidth: 1160, minHeight: 720)
                .studioWindowBackground()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1440, height: 900)
        // Every ⌘ shortcut lives in the menu bar, where macOS renders it,
        // validates it and enables it for free. The bare keys — Delete,
        // arrows, Tab, Escape — belong to ThumbKeyRouter, which stands down
        // while a text field has focus.
        .commands { ThumbCommands() }
    }
}

final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // One appearance, committed. A design tool whose chrome flips between
        // light and dark makes the same artwork read as two different things,
        // and the user compensates in the artwork.
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

import SwiftUI

/// One shortcut, in the order a person reads it: what it does, then how.
struct ThumbShortcut: Identifiable {
    let id = UUID()
    let keys: [String]
    let title: String

    init(_ keys: String, _ title: String) {
        // Space-separated so "⇧ ⌘ K" renders as three caps.
        self.keys = keys.split(separator: " ").map(String.init)
        self.title = title
    }
}

struct ThumbShortcutGroup: Identifiable {
    let id = UUID()
    let name: String
    let shortcuts: [ThumbShortcut]
}

/// The whole map, in one literal. This is the list the cheatsheet renders and
/// the list the tooltips quote, so a shortcut can only be documented once.
enum ThumbShortcuts {
    static let groups: [ThumbShortcutGroup] = [
        ThumbShortcutGroup(name: "Selection", shortcuts: [
            ThumbShortcut("click", "Select a layer"),
            ThumbShortcut("⇥", "Select the layer behind"),
            ThumbShortcut("⇧ ⇥", "Select the layer in front"),
            ThumbShortcut("⌘ A", "Select every layer"),
            ThumbShortcut("esc", "Deselect"),
            ThumbShortcut("↩", "Edit the selected text layer"),
        ]),
        ThumbShortcutGroup(name: "Moving", shortcuts: [
            ThumbShortcut("← → ↑ ↓", "Nudge one pixel"),
            ThumbShortcut("⇧ ←→↑↓", "Nudge ten pixels"),
            ThumbShortcut("drag", "Move, with snap guides"),
            ThumbShortcut("space drag", "Pan the canvas"),
        ]),
        ThumbShortcutGroup(name: "Editing", shortcuts: [
            ThumbShortcut("⌫", "Delete the selection"),
            ThumbShortcut("⌘ D", "Duplicate"),
            ThumbShortcut("⌘ C", "Copy"),
            ThumbShortcut("⌘ X", "Cut"),
            ThumbShortcut("⌘ V", "Paste — layers, a file, or a screenshot"),
            ThumbShortcut("⌘ Z", "Undo"),
            ThumbShortcut("⇧ ⌘ Z", "Redo"),
        ]),
        ThumbShortcutGroup(name: "Layers", shortcuts: [
            ThumbShortcut("⌘ T", "Add a text layer"),
            ThumbShortcut("⇧ ⌘ I", "Add an image…"),
            ThumbShortcut("⇧ ⌘ K", "Remove background"),
            ThumbShortcut("⇧ ⌘ L", "Lock / unlock"),
            ThumbShortcut("⇧ ⌘ H", "Hide / show"),
        ]),
        ThumbShortcutGroup(name: "Arrange", shortcuts: [
            ThumbShortcut("⌘ ]", "Bring forward"),
            ThumbShortcut("⌘ [", "Send backward"),
            ThumbShortcut("⌥ ⌘ ]", "Bring to front"),
            ThumbShortcut("⌥ ⌘ [", "Send to back"),
        ]),
        ThumbShortcutGroup(name: "View & file", shortcuts: [
            ThumbShortcut("⌘ =", "Zoom in"),
            ThumbShortcut("⌘ -", "Zoom out"),
            ThumbShortcut("⌘ 0", "Zoom to fit"),
            ThumbShortcut("⌘ 1", "Actual size"),
            ThumbShortcut("⌘ '", "Toggle the duration safe zone"),
            ThumbShortcut("⌘ P", "Preview where it will be seen"),
            ThumbShortcut("⌘ R", "Review this thumbnail"),
            ThumbShortcut("⌘ L", "Library"),
            ThumbShortcut("⌘ N", "New design"),
            ThumbShortcut("⌘ S", "Save"),
            ThumbShortcut("⌘ E", "Export image…"),
            ThumbShortcut("⌘ /", "This list"),
        ]),
    ]

    /// Tooltip text for a control, with its shortcut appended the way the
    /// system does it: `.help(ThumbShortcuts.help("Duplicate", "⌘ D"))`.
    static func help(_ title: String, _ keys: String) -> String {
        "\(title)  \(keys.replacingOccurrences(of: " ", with: ""))"
    }
}

/// The ⌘/ panel. Two columns, grouped, dismissed by Escape or Done.
struct ThumbShortcutCheatSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var columns: ([ThumbShortcutGroup], [ThumbShortcutGroup]) {
        let all = ThumbShortcuts.groups
        let split = (all.count + 1) / 2
        return (Array(all.prefix(split)), Array(all.dropFirst(split)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Keyboard")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Studio.Palette.textPrimary)
                Spacer()
                Text("⌘ /")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Studio.Palette.textTertiary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            ScrollView {
                HStack(alignment: .top, spacing: 34) {
                    column(columns.0)
                    column(columns.1)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
            }

            Divider().overlay(Studio.Palette.textTertiary.opacity(0.25))
            HStack {
                Text("Arrow keys, ⌫ and ↩ act on the canvas — never while you're typing in a field.")
                    .font(.caption2)
                    .foregroundStyle(Studio.Palette.textTertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 620, height: 520)
        .background(Studio.Palette.windowBackground)
    }

    private func column(_ groups: [ThumbShortcutGroup]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 9) {
                    Text(group.name.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Studio.Palette.textTertiary)
                    ForEach(group.shortcuts) { shortcut in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            HStack(spacing: 3) {
                                ForEach(Array(shortcut.keys.enumerated()), id: \.offset) { _, key in
                                    KeyCap(label: key)
                                }
                            }
                            .frame(width: 96, alignment: .leading)
                            Text(shortcut.title)
                                .font(.system(size: 12))
                                .foregroundStyle(Studio.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A key rendered as a physical cap, so the eye can scan the column.
private struct KeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(Studio.Palette.textPrimary)
            .padding(.horizontal, label.count > 2 ? 6 : 5)
            .padding(.vertical, 2)
            .frame(minWidth: 20)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Studio.Palette.control)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            )
    }
}


// =====================================================================

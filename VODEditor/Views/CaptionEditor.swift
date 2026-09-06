import SwiftUI
import AppKit

extension CaptionColor {
    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    init(_ color: Color) {
        let converted = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(red: Double(converted.redComponent),
                  green: Double(converted.greenComponent),
                  blue: Double(converted.blueComponent),
                  alpha: Double(converted.alphaComponent))
    }
}

enum FontCatalog {
    /// Installed family names, used for the full picker.
    static let installed: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    private static let installedSet = Set(installed)

    /// Curated caption faces, filtered to what's actually on this machine —
    /// Montserrat/Anton/Bangers usually aren't installed on stock macOS, and
    /// libass would silently substitute something else.
    static var suggested: [String] {
        CaptionStyle.suggestedFonts.filter { installedSet.contains($0) }
    }

    static func isInstalled(_ family: String) -> Bool { installedSet.contains(family) }
}

/// Editable caption lines for the selected clip. Whisper mishears slang and
/// usernames constantly, so fixing one has to be a text edit here — never a
/// reason to re-run transcription.
struct CaptionEditor: View {
    let lines: [CaptionLine]
    let candidate: ShortCandidate
    let currentTimeInClip: Double
    let onEdit: (Int, String) -> Void
    let onResetLine: (Int) -> Void
    let onSeek: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: "Captions")
                Text("\(lines.count) lines")
                    .font(.caption)
                    .foregroundStyle(Theme.textFaint)
                Spacer()
            }
            .padding(10)

            Divider().overlay(Theme.border)

            if lines.isEmpty {
                Text("No speech in this range.")
                    .font(.caption)
                    .foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(lines) { line in
                            CaptionRow(
                                line: line,
                                isActive: currentTimeInClip >= line.start && currentTimeInClip < line.end,
                                isEdited: candidate.captionEdits[String(line.id)] != nil,
                                onEdit: { onEdit(line.id, $0) },
                                onReset: { onResetLine(line.id) },
                                onSeek: { onSeek(line.start) }
                            )
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        
    }
}

private struct CaptionRow: View {
    let line: CaptionLine
    let isActive: Bool
    let isEdited: Bool
    let onEdit: (String) -> Void
    let onReset: () -> Void
    let onSeek: () -> Void

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onSeek) {
                Text(line.start.shortTimecode)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isActive ? Theme.accent : Theme.textFaint)
                    .frame(width: 42, alignment: .leading)
            }
            .buttonStyle(.plain)

            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
                .onSubmit { onEdit(draft) }
                .onChange(of: focused) { _, nowFocused in
                    if !nowFocused, draft != line.text { onEdit(draft) }
                }

            if isEdited {
                Button(action: onReset) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textFaint)
                .help("Revert to the transcribed text")
            }
        }
        .padding(6)
        .background(isActive ? Theme.accent.opacity(0.12) : Theme.surfaceRaised.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .onAppear { draft = line.text }
        .onChange(of: line.text) { _, newValue in
            if !focused { draft = newValue }
        }
    }
}

/// Caption styling. Everything here maps directly onto ASS style fields, so the
/// preview and the burned-in result stay in agreement.
struct CaptionStyleControls: View {
    @Binding var style: CaptionStyle
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Cue length")

            Picker("Group by", selection: $style.grouping) {
                ForEach(CaptionGrouping.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: style.grouping) { _, _ in onCommit() }

            if style.grouping == .phrase {
                LabeledContent("Words per cue") {
                    HStack {
                        // Committed on every step rather than at drag end: the
                        // preview reads the committed style, so a deferred
                        // commit would leave the slider and the video disagreeing
                        // for the length of the drag.
                        Slider(value: Binding(
                            get: { Double(style.wordsPerCue) },
                            set: { style.wordsPerCue = Int($0.rounded()) }
                        ), in: 2...14, step: 1)
                        .onChange(of: style.wordsPerCue) { _, _ in onCommit() }
                        Text("\(style.wordsPerCue)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 20)
                    }
                }
                InfoTip("A cue breaks early on a full stop and late on a comma, and always at a pause — so the count is a target, not a hard rule.")
            } else {
                InfoTip("One cue per transcribed sentence. Whisper's segments run 15–25 words, which is a lot of text to burn into a vertical clip.")
            }

            Divider().overlay(Theme.border)

            SectionLabel(text: "Caption style")

            if !FontCatalog.isInstalled(style.fontName) {
                Label("“\(style.fontName)” isn't installed — libass will substitute another face.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Font", selection: $style.fontName) {
                if !FontCatalog.suggested.isEmpty {
                    Section("Suggested") {
                        ForEach(FontCatalog.suggested, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("All installed") {
                    ForEach(FontCatalog.installed, id: \.self) { Text($0).tag($0) }
                }
            }
            .onChange(of: style.fontName) { _, _ in onCommit() }

            LabeledContent("Size") {
                HStack {
                    Slider(value: Binding(
                        get: { Double(style.fontSize) },
                        set: { style.fontSize = Int($0) }
                    ), in: 32...140, step: 2) { _ in onCommit() }
                    Text("\(style.fontSize)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 28)
                }
            }

            HStack {
                ColorPicker("Fill", selection: Binding(
                    get: { style.fill.swiftUIColor },
                    set: { style.fill = CaptionColor($0); onCommit() }
                ), supportsOpacity: false)
                ColorPicker("Outline", selection: Binding(
                    get: { style.outline.swiftUIColor },
                    set: { style.outline = CaptionColor($0); onCommit() }
                ), supportsOpacity: false)
            }
            .font(.caption)

            LabeledContent("Outline width") {
                Slider(value: $style.outlineWidth, in: 0...12, step: 0.5) { _ in onCommit() }
            }

            Toggle("Background box", isOn: $style.useBox)
                .onChange(of: style.useBox) { _, _ in onCommit() }
            if style.useBox {
                ColorPicker("Box colour", selection: Binding(
                    get: { style.boxColor.swiftUIColor },
                    set: { style.boxColor = CaptionColor($0); onCommit() }
                ), supportsOpacity: true)
                .font(.caption)
            }

            Picker("Position", selection: $style.position) {
                ForEach(CaptionPosition.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: style.position) { _, _ in onCommit() }

            LabeledContent("Margin") {
                HStack {
                    Slider(value: Binding(
                        get: { Double(style.marginVertical) },
                        set: { style.marginVertical = Int($0) }
                    ), in: 40...700, step: 10) { _ in onCommit() }
                    Text("\(style.marginVertical)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 34)
                }
            }

            Toggle("Word-by-word highlight", isOn: $style.karaoke)
                .onChange(of: style.karaoke) { _, _ in onCommit() }
            if style.karaoke {
                ColorPicker("Highlight", selection: Binding(
                    get: { style.highlightColor.swiftUIColor },
                    set: { style.highlightColor = CaptionColor($0); onCommit() }
                ), supportsOpacity: false)
                .font(.caption)
            }

            Toggle("Uppercase", isOn: $style.uppercase)
                .onChange(of: style.uppercase) { _, _ in onCommit() }

            LabeledContent("Line length") {
                HStack {
                    Slider(value: Binding(
                        get: { Double(style.maxCharactersPerLine) },
                        set: { style.maxCharactersPerLine = Int($0) }
                    ), in: 12...44, step: 1) { _ in onCommit() }
                    Text("\(style.maxCharactersPerLine)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 24)
                }
            }
        }
        .font(.caption)
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

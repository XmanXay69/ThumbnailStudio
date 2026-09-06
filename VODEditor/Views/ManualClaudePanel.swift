import SwiftUI
import AppKit

/// The manual Claude loop, as one reusable block: a Copy-prompt button puts a
/// ready-made prompt on the clipboard (paste it into a claude.ai chat —
/// covered by the subscription, no API key), and the reply pasted back into
/// the box below is parsed and applied.
struct ManualClaudePanel: View {
    /// Label on the copy button — sites vary it to show batch progress.
    var copyLabel: String = "Copy prompt"
    /// Builds the prompt; nil means not ready, and `notReadyText` shows why.
    let makePrompt: () -> String?
    var notReadyText: String = "Nothing to work from yet."
    /// Parses and applies the pasted reply, returning a short success line.
    let apply: (String) throws -> String

    @State private var reply = ""
    @State private var note: String?
    @State private var noteIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    if let prompt = makePrompt() {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(prompt, forType: .string)
                        note = "Prompt copied — paste it into a claude.ai chat, then paste the reply below."
                        noteIsError = false
                    } else {
                        note = notReadyText
                        noteIsError = true
                    }
                } label: {
                    Label(copyLabel, systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Apply reply") {
                    do {
                        note = try apply(reply)
                        noteIsError = false
                        reply = ""
                    } catch {
                        note = error.localizedDescription
                        noteIsError = true
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            TextEditor(text: $reply)
                .font(.system(size: 10, design: .monospaced))
                .frame(height: 54)
                .scrollContentBackground(.hidden)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if reply.isEmpty {
                        Text("Paste Claude's reply here")
                            .font(.caption2)
                            .foregroundStyle(Theme.textFaint)
                            .padding(.top, 4)
                            .padding(.leading, 6)
                            .allowsHitTesting(false)
                    }
                }

            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(noteIsError ? Theme.danger : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

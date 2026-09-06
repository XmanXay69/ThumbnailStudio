import SwiftUI

/// Transcript list that follows the playhead. Clicking a line seeks precisely;
/// the active line highlights word-by-word using the DTW token timings.
struct TranscriptPane: View {
    let transcript: Transcript
    let currentTime: Double
    let onSeek: (Double) -> Void
    /// Supplied in Browse, where the transcript is the caption source and a
    /// mistranscription should be fixable in place.
    var onEdit: ((Int, String) -> Void)?
    /// Voice-match guesses (segment id → "you"), shown only when reliable.
    var speakerGuesses: [Int: Bool]? = nil
    /// Present when the pane can trigger the guess pass.
    var onLabelSpeakers: (() -> Void)?

    @State private var query = ""
    @State private var followPlayhead = true
    @State private var isEditing = false

    private var activeIndex: Int? {
        transcript.indexOfSegment(at: currentTime)
    }

    private var visibleSegments: [TranscriptSegment] {
        guard !query.isEmpty else { return transcript.segments }
        return transcript.segments.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.border)
            content
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            SectionLabel(text: "Transcript")

            if !transcript.isEmpty {
                Text("\(transcript.segments.count) lines")
                    .font(.caption)
                    .foregroundStyle(Theme.textFaint)
            }
            if let onLabelSpeakers, !transcript.isEmpty {
                Button {
                    onLabelSpeakers()
                } label: {
                    Image(systemName: speakerGuesses == nil
                          ? "person.wave.2" : "person.wave.2.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(speakerGuesses == nil ? Theme.textFaint : Theme.accent)
                .help("Guess who's talking from mic level — your voice sits hotter than in-game voices. A heuristic, not diarization.")
            }

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textFaint)
                    .font(.caption)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 180)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if onEdit != nil {
                Toggle(isOn: $isEditing) {
                    Image(systemName: "pencil")
                }
                .toggleStyle(.button)
                .help("Edit caption text — corrections flow into every export")
            }

            Toggle(isOn: $followPlayhead) {
                Image(systemName: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .help("Follow playhead")
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if transcript.isEmpty {
            VStack(spacing: 6) {
                Text("No transcript yet")
                    .foregroundStyle(Theme.textSecondary)
                Text("Run ingest to transcribe this VOD.")
                    .font(.caption)
                    .foregroundStyle(Theme.textFaint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleSegments.isEmpty {
            Text("No lines match “\(query)”")
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleSegments) { segment in
                            TranscriptRow(
                                segment: segment,
                                isActive: segment.id == activeIndexID,
                                currentTime: currentTime,
                                isEditing: isEditing,
                                youGuess: speakerGuesses?[segment.id],
                                onSeek: onSeek,
                                onEdit: onEdit
                            )
                            .id(segment.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: activeIndexID) { _, newValue in
                    guard followPlayhead, query.isEmpty, let newValue else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
    }

    private var activeIndexID: Int? {
        activeIndex.map { transcript.segments[$0].id }
    }
}

private struct TranscriptRow: View {
    let segment: TranscriptSegment
    let isActive: Bool
    let currentTime: Double
    var isEditing: Bool = false
    /// true = reads as the streamer's mic; false = someone else; nil = no
    /// guess to show.
    var youGuess: Bool? = nil
    let onSeek: (Double) -> Void
    var onEdit: ((Int, String) -> Void)?

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if isEditing, let onEdit {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button { onSeek(segment.start) } label: {
                    Text(segment.start.timecode)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(isActive ? Theme.accent : Theme.textFaint)
                        .frame(width: 62, alignment: .leading)
                }
                .buttonStyle(.plain)

                TextField("", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($focused)
                    .onSubmit { onEdit(segment.id, draft) }
                    .onChange(of: focused) { _, nowFocused in
                        if !nowFocused, draft != segment.text { onEdit(segment.id, draft) }
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isActive ? Theme.accent.opacity(0.12) : Theme.surfaceRaised.opacity(0.35))
            .onAppear { draft = segment.text }
            .onChange(of: segment.text) { _, newValue in
                if !focused { draft = newValue }
            }
        } else {
            display
        }
    }

    private var display: some View {
        Button {
            onSeek(segment.start)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(segment.start.timecode)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isActive ? Theme.accent : Theme.textFaint)
                    .frame(width: 62, alignment: .leading)

                if let youGuess {
                    Image(systemName: youGuess ? "mic.fill" : "person.2")
                        .font(.system(size: 8))
                        .foregroundStyle(youGuess ? Theme.accent : Theme.textFaint)
                        .frame(width: 12)
                        .help(youGuess ? "Reads as your mic" : "Reads as someone else (guess)")
                }

                text
                    .font(.system(size: 13))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isActive ? Theme.accent.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Word-level highlighting only for the active line — building attributed
    /// runs for every row would be wasted work on a multi-thousand-line list.
    @ViewBuilder
    private var text: some View {
        if isActive, !segment.words.isEmpty {
            segment.words.reduce(Text("")) { partial, word in
                let spoken = currentTime >= word.start
                let current = currentTime >= word.start && currentTime < word.end
                return partial + Text(word.text)
                    .foregroundColor(current ? Theme.playhead : (spoken ? Theme.textPrimary : Theme.textSecondary))
                    .fontWeight(current ? .semibold : .regular)
            }
        } else {
            Text(segment.text)
                .foregroundColor(isActive ? Theme.textPrimary : Theme.textSecondary)
        }
    }
}

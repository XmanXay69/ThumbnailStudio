import SwiftUI
import UniformTypeIdentifiers

/// Horizontal timeline for the long-form edit: segments as blocks in sequence,
/// waveform under each, a caption track below, trim handles on each block and
/// drag-to-reorder.
///
/// The x axis is *composition* time — the assembled cut with dead air already
/// removed — so what you scrub matches what gets exported.
struct TimelineTrack: View {
    let segments: [LongFormSegment]
    let assembled: AssembledEdit
    let waveform: WaveformData?
    let captionLines: [CaptionLine]
    let currentTime: Double
    @Binding var selectedID: UUID?
    @Binding var pixelsPerSecond: Double

    let onSeek: (Double) -> Void
    let onTrim: (UUID, Double, Double) -> Void
    let onReorder: (UUID, UUID?) -> Void
    let onRemove: (UUID) -> Void
    let onDropFromBin: (UUID, UUID?) -> Void

    private let blockHeight: CGFloat = 96
    private let captionHeight: CGFloat = 26
    private let rulerHeight: CGFloat = 18

    private var totalWidth: CGFloat {
        max(200, CGFloat(assembled.duration * pixelsPerSecond))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            ScrollView(.horizontal, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        ruler
                        blocks
                        captionTrack
                    }
                    playhead
                }
                .frame(width: totalWidth, alignment: .topLeading)
                .padding(.vertical, 4)
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            SectionLabel(text: "Timeline")
            Text("\(segments.count) segments · \(assembled.duration.timecode)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Picker("", selection: $pixelsPerSecond) {
                Text("Fit").tag(2.0)
                Text("1×").tag(6.0)
                Text("2×").tag(12.0)
                Text("4×").tag(24.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
        }
    }

    // MARK: - Ruler

    private var ruler: some View {
        Canvas { context, size in
            let candidates: [Double] = [5, 15, 30, 60, 120, 300, 600]
            let step = candidates.first { $0 * pixelsPerSecond >= 90 } ?? 900
            var tick: Double = 0
            while tick <= assembled.duration {
                let x = CGFloat(tick * pixelsPerSecond)
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height - 6))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(Theme.border), lineWidth: 1)
                context.draw(
                    Text(tick.shortTimecode)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.textFaint),
                    at: CGPoint(x: x + 3, y: size.height - 7),
                    anchor: .bottomLeading
                )
                tick += step
            }
        }
        .frame(width: totalWidth, height: rulerHeight)
        .contentShape(Rectangle())
        .gesture(seekGesture)
    }

    // MARK: - Blocks

    private var blocks: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                let width = CGFloat(assembled.duration(ofSegment: segment.id) * pixelsPerSecond)
                TimelineBlock(
                    segment: segment,
                    pieces: assembled.pieces.filter { $0.segmentID == segment.id },
                    waveform: waveform,
                    pixelsPerSecond: pixelsPerSecond,
                    isSelected: segment.id == selectedID,
                    height: blockHeight,
                    onSelect: { selectedID = segment.id },
                    onTrim: { start, end in onTrim(segment.id, start, end) },
                    onRemove: { onRemove(segment.id) }
                )
                .frame(width: max(6, width), height: blockHeight)
                .draggable(segment.id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first, let dropped = UUID(uuidString: raw),
                          dropped != segment.id else { return false }
                    // A block already on the timeline reorders; one from the bin
                    // gets included at this position.
                    if segments.contains(where: { $0.id == dropped }) {
                        onReorder(dropped, segment.id)
                    } else {
                        onDropFromBin(dropped, segment.id)
                    }
                    return true
                }
            }

            // Tail drop zone so something can be appended to the end.
            Rectangle()
                .fill(Color.clear)
                .frame(width: 60, height: blockHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first, let dropped = UUID(uuidString: raw) else { return false }
                    if segments.contains(where: { $0.id == dropped }) {
                        onReorder(dropped, nil)
                    } else {
                        onDropFromBin(dropped, nil)
                    }
                    return true
                }
        }
    }

    // MARK: - Captions

    /// Drawn as a single Canvas rather than a stack of views — a 28-minute cut
    /// carries well over a thousand caption lines.
    private var captionTrack: some View {
        Canvas { context, size in
            for line in captionLines {
                let x = CGFloat(line.start * pixelsPerSecond)
                let width = CGFloat((line.end - line.start) * pixelsPerSecond)
                guard x < size.width, x + width > 0, width > 1 else { continue }

                let rect = CGRect(x: x, y: 3, width: max(1, width - 1), height: size.height - 6)
                context.fill(Path(roundedRect: rect, cornerRadius: 2),
                             with: .color(Theme.accent.opacity(0.22)))

                if width > 44 {
                    context.draw(
                        Text(line.text)
                            .font(.system(size: 9))
                            .foregroundColor(Theme.textSecondary),
                        in: rect.insetBy(dx: 4, dy: 3)
                    )
                }
            }
        }
        .frame(width: totalWidth, height: captionHeight)
        .background(Theme.background.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .gesture(seekGesture)
    }

    // MARK: - Playhead

    private var playhead: some View {
        Rectangle()
            .fill(Theme.playhead)
            .frame(width: 1.5, height: rulerHeight + blockHeight + captionHeight + 12)
            .offset(x: CGFloat(currentTime * pixelsPerSecond))
            .allowsHitTesting(false)
    }

    private var seekGesture: some Gesture {
        DragGesture(minimumDistance: 0).onChanged { value in
            onSeek(max(0, min(assembled.duration, value.location.x / pixelsPerSecond)))
        }
    }
}

/// One segment on the timeline. Draws its own waveform from the source ranges
/// it covers, and carries trim handles on both edges.
private struct TimelineBlock: View {
    let segment: LongFormSegment
    let pieces: [AssembledPiece]
    let waveform: WaveformData?
    let pixelsPerSecond: Double
    let isSelected: Bool
    let height: CGFloat
    let onSelect: () -> Void
    let onTrim: (Double, Double) -> Void
    let onRemove: () -> Void

    @State private var dragStart: Double?
    @State private var dragEnd: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawWaveform(context: context, size: size)
                    drawPieceSeams(context: context, size: size)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(segment.start.timecode)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.playhead.opacity(0.9))
                    if geometry.size.width > 70 {
                        Text(segment.title)
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                    }
                }
                .padding(4)
                .allowsHitTesting(false)

                handle(isStart: true, containerWidth: geometry.size.width)
                handle(isStart: false, containerWidth: geometry.size.width)
            }
            .background(isSelected ? Theme.accent.opacity(0.22) : Theme.surfaceRaised)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? Theme.accent : Theme.border, lineWidth: isSelected ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .contextMenu {
                Button("Remove from timeline", role: .destructive, action: onRemove)
            }
            .help("\(segment.start.timecode) – \(segment.end.timecode) · score \(String(format: "%.2f", segment.score))")
        }
    }

    private func handle(isStart: Bool, containerWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Theme.accent.opacity(isSelected ? 0.9 : 0.45))
            .frame(width: 5, height: height)
            .offset(x: isStart ? 0 : max(0, containerWidth - 5))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Handle drags move the source in/out points, so the
                        // delta is converted from pixels back to seconds.
                        let delta = Double(value.translation.width) / pixelsPerSecond
                        if isStart {
                            let base = dragStart ?? segment.start
                            if dragStart == nil { dragStart = base }
                            onTrim(min(base + delta, segment.end - 5), segment.end)
                        } else {
                            let base = dragEnd ?? segment.end
                            if dragEnd == nil { dragEnd = base }
                            onTrim(segment.start, max(base + delta, segment.start + 5))
                        }
                    }
                    .onEnded { _ in
                        dragStart = nil
                        dragEnd = nil
                    }
            )
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    private func drawWaveform(context: GraphicsContext, size: CGSize) {
        guard let waveform, !pieces.isEmpty else { return }
        let blockStart = pieces[0].compositionStart
        let midY = size.height / 2

        for piece in pieces {
            let originX = CGFloat((piece.compositionStart - blockStart) * pixelsPerSecond)
            let pieceWidth = CGFloat(piece.duration * pixelsPerSecond)
            guard pieceWidth >= 1 else { continue }

            let buckets = max(1, Int(pieceWidth))
            let values = waveform.envelope(from: piece.source.start, to: piece.source.end, buckets: buckets)
            guard !values.isEmpty else { continue }

            let columnWidth = pieceWidth / CGFloat(values.count)
            var path = Path()
            for (index, value) in values.enumerated() {
                let barHeight = max(1, CGFloat(value) * size.height * 0.7)
                path.addRect(CGRect(x: originX + CGFloat(index) * columnWidth,
                                    y: midY - barHeight / 2,
                                    width: max(0.7, columnWidth * 0.9),
                                    height: barHeight))
            }
            context.fill(path, with: .color(isSelected ? Theme.waveform : Theme.waveform.opacity(0.55)))
        }
    }

    /// Marks where dead air was cut out of the middle of a segment.
    private func drawPieceSeams(context: GraphicsContext, size: CGSize) {
        guard pieces.count > 1 else { return }
        let blockStart = pieces[0].compositionStart
        for piece in pieces.dropFirst() {
            let x = CGFloat((piece.compositionStart - blockStart) * pixelsPerSecond)
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(Theme.warning.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }
    }
}

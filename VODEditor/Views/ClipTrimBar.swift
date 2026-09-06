import SwiftUI

/// Trim control for one clip: waveform and score curve across a context window,
/// with draggable in/out handles and a playhead.
struct ClipTrimBar: View {
    let waveform: WaveformData?
    let curve: ScoreCurve
    let duration: Double
    let currentTime: Double
    @Binding var start: Double
    @Binding var end: Double
    let minDuration: Double
    let maxDuration: Double
    let onSeek: (Double) -> Void

    /// Context shown either side of the clip so the trim isn't blind.
    private let padding: Double = 12
    private let barHeight: CGFloat = 84

    private var windowStart: Double { max(0, start - padding) }
    private var windowEnd: Double { min(duration, end + padding) }
    private var windowSpan: Double { max(windowEnd - windowStart, 0.001) }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                SectionLabel(text: "Trim")
                Spacer()
                Text("\(start.timecode) → \(end.timecode)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                Text(String(format: "%.1fs", end - start))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(durationIsValid ? Theme.positive : Theme.warning)
            }

            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        drawEnvelope(context: context, size: size)
                        drawScore(context: context, size: size)
                        dimOutside(context: context, size: size)
                        drawPlayhead(context: context, size: size)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0).onChanged { value in
                            guard width > 0 else { return }
                            let ratio = max(0, min(1, value.location.x / width))
                            onSeek(windowStart + Double(ratio) * windowSpan)
                        }
                    )

                    handle(at: start, width: width, isStart: true)
                    handle(at: end, width: width, isStart: false)
                }
            }
            .frame(height: barHeight)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
        }
    }

    private var durationIsValid: Bool {
        let span = end - start
        return span >= minDuration && span <= maxDuration
    }

    private func x(for time: Double, width: CGFloat) -> CGFloat {
        CGFloat((time - windowStart) / windowSpan) * width
    }

    private func handle(at time: Double, width: CGFloat, isStart: Bool) -> some View {
        let position = x(for: time, width: width)
        return RoundedRectangle(cornerRadius: 2)
            .fill(Theme.accent)
            .frame(width: 8, height: barHeight)
            .overlay(
                Rectangle().fill(Theme.textPrimary.opacity(0.7))
                    .frame(width: 2, height: 22)
            )
            .position(x: position, y: barHeight / 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard width > 0 else { return }
                        let ratio = max(0, min(1, value.location.x / width))
                        let time = windowStart + Double(ratio) * windowSpan
                        if isStart {
                            // Keep the clip inside the platform duration range
                            // while dragging rather than snapping back after.
                            start = min(max(0, time), end - minDuration)
                            if end - start > maxDuration { start = end - maxDuration }
                        } else {
                            end = max(min(duration, time), start + minDuration)
                            if end - start > maxDuration { end = start + maxDuration }
                        }
                    }
            )
            .help(isStart ? "Drag to set the in point" : "Drag to set the out point")
    }

    // MARK: - Drawing

    private func drawEnvelope(context: GraphicsContext, size: CGSize) {
        guard let waveform else { return }
        let buckets = max(1, Int(size.width))
        let values = waveform.envelope(from: windowStart, to: windowEnd, buckets: buckets)
        guard !values.isEmpty else { return }

        let midY = size.height / 2
        let columnWidth = size.width / CGFloat(values.count)
        var path = Path()
        for (index, value) in values.enumerated() {
            let height = max(1, CGFloat(value) * size.height * 0.8)
            path.addRect(CGRect(x: CGFloat(index) * columnWidth, y: midY - height / 2,
                                width: max(0.8, columnWidth * 0.9), height: height))
        }
        context.fill(path, with: .color(Theme.waveform.opacity(0.85)))
    }

    /// The interest curve that produced this candidate, drawn as a line so it's
    /// visible *why* the clip is where it is.
    private func drawScore(context: GraphicsContext, size: CGSize) {
        guard !curve.isEmpty else { return }
        var path = Path()
        let steps = max(2, Int(size.width / 2))
        for step in 0...steps {
            let time = windowStart + windowSpan * Double(step) / Double(steps)
            let value = curve.value(at: time)
            let point = CGPoint(x: size.width * CGFloat(step) / CGFloat(steps),
                                y: size.height - CGFloat(value) * size.height * 0.9)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        context.stroke(path, with: .color(Theme.positive.opacity(0.8)), lineWidth: 1.5)
    }

    private func dimOutside(context: GraphicsContext, size: CGSize) {
        let startX = x(for: start, width: size.width)
        let endX = x(for: end, width: size.width)
        context.fill(Path(CGRect(x: 0, y: 0, width: max(0, startX), height: size.height)),
                     with: .color(Theme.background.opacity(0.7)))
        context.fill(Path(CGRect(x: endX, y: 0, width: max(0, size.width - endX), height: size.height)),
                     with: .color(Theme.background.opacity(0.7)))
    }

    private func drawPlayhead(context: GraphicsContext, size: CGSize) {
        guard currentTime >= windowStart, currentTime <= windowEnd else { return }
        let position = x(for: currentTime, width: size.width)
        var path = Path()
        path.move(to: CGPoint(x: position, y: 0))
        path.addLine(to: CGPoint(x: position, y: size.height))
        context.stroke(path, with: .color(Theme.playhead), lineWidth: 1.5)
    }
}

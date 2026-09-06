import SwiftUI

/// Two-lane scrubber: a full-VOD overview and a zoomed window around the
/// playhead. Both are click- and drag-seekable.
///
/// The peak data is re-bucketed to the pixel width on every draw, so a 4-hour
/// envelope renders at whatever zoom without keeping per-zoom copies around.
struct WaveformScrubber: View {
    let waveform: WaveformData?
    let silence: [SilenceInterval]
    let duration: Double
    let currentTime: Double
    @Binding var zoomSeconds: Double
    let onSeek: (Double, Bool) -> Void

    private let overviewHeight: CGFloat = 40
    private let detailHeight: CGFloat = 92

    var body: some View {
        VStack(spacing: 8) {
            header
            overviewLane
            detailLane
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            SectionLabel(text: "Waveform")
            Spacer()
            if waveform == nil {
                Text("not generated yet")
                    .font(.caption)
                    .foregroundStyle(Theme.textFaint)
            }
            Picker("", selection: $zoomSeconds) {
                Text("15s").tag(15.0)
                Text("1m").tag(60.0)
                Text("5m").tag(300.0)
                Text("20m").tag(1200.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
        }
    }

    // MARK: - Overview

    private var overviewLane: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            Canvas { context, size in
                drawEnvelope(context: context, size: size, from: 0, to: duration,
                             color: Theme.waveformDim)

                // Viewport box showing what the detail lane covers.
                if duration > 0, zoomSeconds < duration {
                    let start = windowStart
                    let boxX = CGFloat(start / duration) * size.width
                    let boxWidth = max(2, CGFloat(zoomSeconds / duration) * size.width)
                    context.fill(
                        Path(CGRect(x: boxX, y: 0, width: boxWidth, height: size.height)),
                        with: .color(Theme.accent.opacity(0.18))
                    )
                    context.stroke(
                        Path(CGRect(x: boxX, y: 0, width: boxWidth, height: size.height)),
                        with: .color(Theme.accent.opacity(0.5)), lineWidth: 1
                    )
                }

                drawPlayhead(context: context, size: size, at: currentTime, from: 0, to: duration)
            }
            .frame(height: overviewHeight)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(seekGesture(width: width, from: { 0 }, to: { self.duration }))
        }
        .frame(height: overviewHeight)
    }

    // MARK: - Detail

    private var windowStart: Double {
        guard duration > 0 else { return 0 }
        return max(0, min(currentTime - zoomSeconds / 2, max(0, duration - zoomSeconds)))
    }

    private var windowEnd: Double { min(duration, windowStart + zoomSeconds) }

    private var detailLane: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            Canvas { context, size in
                let start = windowStart
                let end = windowEnd

                // Dead air, shaded behind the envelope.
                for interval in silence where interval.end > start && interval.start < end {
                    let x1 = CGFloat((max(interval.start, start) - start) / max(end - start, 0.001)) * size.width
                    let x2 = CGFloat((min(interval.end, end) - start) / max(end - start, 0.001)) * size.width
                    context.fill(
                        Path(CGRect(x: x1, y: 0, width: max(1, x2 - x1), height: size.height)),
                        with: .color(Theme.background.opacity(0.65))
                    )
                }

                drawEnvelope(context: context, size: size, from: start, to: end, color: Theme.waveform)
                drawRuler(context: context, size: size, from: start, to: end)
                drawPlayhead(context: context, size: size, at: currentTime, from: start, to: end)
            }
            .frame(height: detailHeight)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(seekGesture(width: width, from: { self.windowStart }, to: { self.windowEnd }))
        }
        .frame(height: detailHeight)
    }

    // MARK: - Drawing

    private func drawEnvelope(context: GraphicsContext, size: CGSize,
                              from start: Double, to end: Double, color: Color) {
        guard let waveform, end > start else { return }
        let buckets = max(1, Int(size.width))
        let values = waveform.envelope(from: start, to: end, buckets: buckets)
        guard !values.isEmpty else { return }

        let midY = size.height / 2
        let columnWidth = size.width / CGFloat(values.count)
        var path = Path()
        for (index, value) in values.enumerated() {
            let height = max(1, CGFloat(value) * size.height * 0.92)
            let x = CGFloat(index) * columnWidth
            path.addRect(CGRect(x: x, y: midY - height / 2,
                                width: max(0.8, columnWidth * 0.9), height: height))
        }
        context.fill(path, with: .color(color))
    }

    private func drawPlayhead(context: GraphicsContext, size: CGSize,
                              at time: Double, from start: Double, to end: Double) {
        guard end > start, time >= start, time <= end else { return }
        let x = CGFloat((time - start) / (end - start)) * size.width
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(path, with: .color(Theme.playhead), lineWidth: 1.5)
    }

    /// Time ticks at a spacing that stays legible across zoom levels.
    private func drawRuler(context: GraphicsContext, size: CGSize, from start: Double, to end: Double) {
        let span = end - start
        guard span > 0 else { return }
        let candidates: [Double] = [1, 5, 10, 30, 60, 300, 600, 1800]
        let step = candidates.first { span / $0 <= 12 } ?? 3600

        var tick = (start / step).rounded(.up) * step
        while tick < end {
            let x = CGFloat((tick - start) / span) * size.width
            var path = Path()
            path.move(to: CGPoint(x: x, y: size.height - 12))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(Theme.border), lineWidth: 1)
            context.draw(
                Text(tick.shortTimecode)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.textFaint),
                at: CGPoint(x: x + 2, y: size.height - 18),
                anchor: .bottomLeading
            )
            tick += step
        }
    }

    private func seekGesture(width: CGFloat,
                             from: @escaping () -> Double,
                             to: @escaping () -> Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = from()
                let end = to()
                guard end > start, width > 0 else { return }
                let ratio = max(0, min(1, value.location.x / width))
                onSeek(start + Double(ratio) * (end - start), false)
            }
    }
}

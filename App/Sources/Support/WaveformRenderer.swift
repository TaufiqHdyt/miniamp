import AppKit
import MiniAmpKit

/// A rolling mono waveform. Each column shows the whole amplitude range of its samples.
@MainActor
final class WaveformRenderer: VisualizerRenderer {
    let layer = CALayer()
    private let trace = CAShapeLayer()
    private let analyzer = WaveformAnalyzer()
    private var plot = CGRect.zero
    private var columnCount = 0

    var isSettled: Bool { analyzer.columns.isEmpty }

    init() {
        trace.strokeColor = NSColor(srgbRed: 0.38, green: 0.88, blue: 0.74, alpha: 1).cgColor
        trace.fillColor = nil
        trace.lineCap = .round
        trace.lineJoin = .round
        layer.addSublayer(trace)
    }

    func layout(in bounds: CGRect, scale: CGFloat) {
        layer.frame = bounds
        trace.frame = layer.bounds
        trace.contentsScale = scale
        trace.lineWidth = 1
        plot = layer.bounds.insetBy(dx: 6, dy: 6)
        columnCount = plot.isEmpty ? 0 : min(1024, max(1, Int(plot.width * scale)))
    }

    func advance(from tap: SampleTap?, dt: Double) -> Bool {
        let wasSettled = isSettled
        if let tap, columnCount > 0 {
            analyzer.update(from: tap, columnCount: columnCount)
        } else {
            reset()
        }
        return !wasSettled || !isSettled
    }

    func draw(reducesMotion: Bool) {
        guard columnCount > 0 else { trace.path = nil; return }
        let path = CGMutablePath()
        let columns = analyzer.columns
        let amplitude = plot.height * 0.5
        if columns.isEmpty {
            path.move(to: CGPoint(x: plot.minX, y: plot.midY))
            path.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
        } else {
            let step = plot.width / CGFloat(columns.count)
            for (index, column) in columns.enumerated() {
                let x = plot.minX + (CGFloat(index) + 0.5) * step
                let low = plot.midY + amplitude * clampedAmplitude(column.minimum)
                let high = plot.midY + amplitude * clampedAmplitude(column.maximum)
                let middle = (low + high) / 2
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: middle))
                } else {
                    path.addLine(to: CGPoint(x: x, y: middle))
                }
                if low != high {
                    path.addLine(to: CGPoint(x: x, y: low))
                    path.addLine(to: CGPoint(x: x, y: high))
                    path.addLine(to: CGPoint(x: x, y: middle))
                }
            }
        }
        trace.path = path
        trace.opacity = columns.isEmpty ? 0.3 : 1
    }

    private func clampedAmplitude(_ sample: Float) -> CGFloat {
        sample.isNaN ? 0 : CGFloat(min(max(sample, -1), 1))
    }

    func reset() { analyzer.reset() }
}

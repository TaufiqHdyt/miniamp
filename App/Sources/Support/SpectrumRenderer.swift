import AppKit
import MiniAmpKit

/// The classic segmented spectrum. Per frame, only changed bar and cap layers move.
@MainActor
final class SpectrumRenderer: VisualizerRenderer {
    let layer = CALayer()
    private var analyzer: SpectrumAnalyzer?
    private var plot = CGRect.zero
    var isSettled: Bool { analyzer?.isSettled ?? true }

    private let grid = CAShapeLayer()
    private let gradient = CAGradientLayer()
    /// Holds the bars; masked by `segments`, so the gaps between segments show what's behind
    /// (glass, or the panel's black) rather than being painted over in a colour.
    private let barsLayer = CALayer()
    /// The gradient shows through these: a layer per bar.
    private let barMask = CALayer()
    private var bars: [CALayer] = []
    private var barFrames: [(x: CGFloat, width: CGFloat)] = []
    private let segments = CAShapeLayer()
    private let capLayer = CALayer()
    private var caps: [CALayer] = []

    static let background = NSColor(white: 0.04, alpha: 1)
    /// Classic: green at the bottom, yellow two-thirds up, red at the top.
    static let colors: [NSColor] = [
        NSColor(srgbRed: 0.10, green: 0.75, blue: 0.16, alpha: 1),
        NSColor(srgbRed: 0.45, green: 0.85, blue: 0.15, alpha: 1),
        NSColor(srgbRed: 0.95, green: 0.82, blue: 0.18, alpha: 1),
        NSColor(srgbRed: 0.93, green: 0.30, blue: 0.13, alpha: 1),
    ]
    static let stops: [NSNumber] = [0, 0.45, 0.72, 1]
    static let capColor = NSColor(white: 0.62, alpha: 1)
    static let segment: CGFloat = 3
    static let segmentGap: CGFloat = 1
    private static let inset: CGFloat = 6

    init() {
        grid.fillColor = NSColor(white: 1, alpha: 0.09).cgColor
        gradient.colors = Self.colors.map(\.cgColor)
        gradient.locations = Self.stops
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.mask = barMask
        // The segments, as a mask: the bars show only within them.
        segments.fillColor = NSColor.black.cgColor
        segments.actions = Self.noActions
        gradient.actions = Self.noActions
        barsLayer.addSublayer(gradient)
        barsLayer.mask = segments
        for sublayer in [grid, barsLayer, capLayer] {
            sublayer.actions = Self.noActions
            layer.addSublayer(sublayer)
        }
        barMask.actions = Self.noActions
    }

    // MARK: Layout

    private func barCount(scale: CGFloat) -> Int {
        let preferred = min(max(Int(plot.width / 18), 32), 64)
        // Leave at least one device pixel each for bars and gaps.
        let fitting = (Int(plot.width * scale) + 1) / 2
        return max(1, min(preferred, fitting))
    }

    /// Centre equal-width bars and gaps on device pixels.
    private func barFrame(_ index: Int, of count: Int, scale: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let pixels = (plot.width * scale).rounded(.down)
        let gap = max((pixels / CGFloat(count) * 0.22).rounded(.down), 1)
        let width = max(((pixels - gap * CGFloat(count - 1)) / CGFloat(count)).rounded(.down), 1)
        let spare = pixels - width * CGFloat(count) - gap * CGFloat(count - 1)
        let left = (plot.minX * scale + max(spare, 0) / 2).rounded(.down)
        return ((left + CGFloat(index) * (width + gap)) / scale, width / scale)
    }

    func layout(in bounds: CGRect, scale: CGFloat) {
        plot = CGRect(x: Self.inset, y: Self.inset,
                      width: max(bounds.width - 2 * Self.inset, 0),
                      height: max(bounds.height - 2 * Self.inset, 0))
        layer.frame = bounds
        layer.isHidden = plot.width * scale < 1 || plot.height < Self.segment
        for sublayer in [grid, barsLayer, segments, capLayer] { sublayer.frame = layer.bounds }
        for sublayer in [grid, gradient, barMask, segments, capLayer] { sublayer.contentsScale = scale }
        gradient.frame = plot
        barMask.frame = CGRect(origin: .zero, size: plot.size)
        let count = barCount(scale: scale)
        if analyzer?.bandCount != count { analyzer = SpectrumAnalyzer(bandCount: count) }
        if bars.count != count { makeBars(count) }
        barFrames = (0..<count).map { barFrame($0, of: count, scale: scale) }
        grid.path = gridPath()
        segments.path = segmentPath()
    }

    /// Dots at each bar's centre, every four segments up.
    private func gridPath() -> CGPath {
        let path = CGMutablePath()
        let pitch = (Self.segment + Self.segmentGap) * 4
        var y = plot.minY + pitch / 2
        while y < plot.maxY {
            for bar in barFrames {
                path.addRect(CGRect(x: (bar.x + bar.width / 2).rounded(.down), y: y.rounded(.down), width: 1, height: 1))
            }
            y += pitch
        }
        return path
    }

    /// Bands across the plot, a segment tall with a gap between: where the bars show.
    private func segmentPath() -> CGPath {
        let path = CGMutablePath()
        var y = plot.minY
        while y < plot.maxY {
            path.addRect(CGRect(x: plot.minX, y: y, width: plot.width, height: min(Self.segment, plot.maxY - y)))
            y += Self.segment + Self.segmentGap
        }
        return path
    }

    private static let noActions: [String: any CAAction] = [
        "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "hidden": NSNull(), "path": NSNull(),
    ]

    private func makeBars(_ count: Int) {
        bars.forEach { $0.removeFromSuperlayer() }
        caps.forEach { $0.removeFromSuperlayer() }
        bars = (0..<count).map { _ in
            let bar = CALayer()
            bar.backgroundColor = NSColor.black.cgColor
            bar.actions = Self.noActions
            barMask.addSublayer(bar)
            return bar
        }
        caps = (0..<count).map { _ in
            let cap = CALayer()
            cap.backgroundColor = Self.capColor.cgColor
            cap.actions = Self.noActions
            capLayer.addSublayer(cap)
            return cap
        }
    }

    /// Bars and caps where the analyser has them.
    func draw(reducesMotion: Bool) {
        guard let analyzer, barFrames.count == analyzer.bandCount else { return }
        let count = analyzer.bandCount, height = plot.height
        let pitch = Self.segment + Self.segmentGap
        for index in 0..<count {
            let frame = barFrames[index]
            // Whole segments only, as on a real LED meter.
            let level = (CGFloat(analyzer.levels[index]) * height / pitch).rounded() * pitch
            // Only what moved: an unchanged layer still costs the commit.
            let bar = CGRect(x: frame.x - plot.minX, y: 0, width: frame.width, height: level)
            if bars[index].frame != bar { bars[index].frame = bar }
            // The cap in the segment just above its peak, lined up with the bar's segments.
            let peak = (CGFloat(analyzer.peaks[index]) * height / pitch).rounded() * pitch
            let hidden = reducesMotion || analyzer.peaks[index] <= 0
            if caps[index].isHidden != hidden { caps[index].isHidden = hidden }
            let top = ((height - Self.segment) / pitch).rounded(.down) * pitch
            let cap = CGRect(x: frame.x, y: plot.minY + min(peak, top), width: frame.width, height: 2)
            if !hidden, caps[index].frame != cap { caps[index].frame = cap }
        }
    }

    func advance(from tap: SampleTap?, dt: Double) -> Bool {
        guard let analyzer else { return false }
        let wasSettled = analyzer.isSettled
        if let tap {
            analyzer.update(from: tap, dt: dt)
        } else {
            analyzer.fade(by: dt)
        }
        return !wasSettled || !analyzer.isSettled
    }

    func reset() {
        if let analyzer { self.analyzer = SpectrumAnalyzer(bandCount: analyzer.bandCount) }
    }
}

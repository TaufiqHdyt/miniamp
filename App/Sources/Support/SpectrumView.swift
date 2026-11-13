import AppKit
import MiniAmpKit
import SwiftUI

/// A Winamp-style spectrum analyser of what's playing: green bars turning yellow, then red,
/// as they rise, made of thin segments, with grey peak caps that hang and fall, on a black
/// panel with a dotted grid.
///
/// Drawn by `SpectrumNSView` with Core Animation, so a frame costs an FFT and moving a layer
/// per bar and per cap, not a SwiftUI update. (Shape layers whose paths change every frame
/// are redrawn in the app; plain layers are only moved, by the window server.) Reads `player.state` here so the view hears about play and pause.
struct SpectrumView: View {
    let player: Player
    /// Bars to show; nil fits as many as the width takes (about 18 points each, 32 to 64).
    var bars: Int?

    var body: some View {
        SpectrumRepresentable(tap: player.visualizerTap, bars: bars, isPlaying: player.state == .playing)
            .accessibilityElement()
            .accessibilityLabel("Spectrum visualizer")
            .accessibilityHidden(true)
    }
}

private struct SpectrumRepresentable: NSViewRepresentable {
    let tap: SampleTap?
    let bars: Int?
    let isPlaying: Bool

    func makeNSView(context: Context) -> SpectrumNSView { SpectrumNSView(tap: tap) }

    func updateNSView(_ view: SpectrumNSView, context: Context) {
        view.fixedBars = bars
        view.isPlaying = isPlaying
    }
}

final class SpectrumNSView: NSView {
    var isPlaying = false {
        didSet { if isPlaying != oldValue { update() } }
    }

    var fixedBars: Int? {
        didSet { if fixedBars != oldValue { needsLayout = true } }
    }

    private let tap: SampleTap?
    private var analyzer: SpectrumAnalyzer?
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    /// Whether this view counts among the tap's users.
    private var capturing = false
    private var windowVisible = false
    private var occlusionObserver: NSObjectProtocol?

    private let grid = CAShapeLayer()
    private let gradient = CAGradientLayer()
    /// The gradient shows through these: a layer per bar.
    private let barMask = CALayer()
    private var bars: [CALayer] = []
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
    static let inset: CGFloat = 6

    init(tap: SampleTap?) {
        self.tap = tap
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Self.background.cgColor
        layer?.masksToBounds = true

        grid.fillColor = NSColor(white: 1, alpha: 0.09).cgColor
        gradient.colors = Self.colors.map(\.cgColor)
        gradient.locations = Self.stops
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.mask = barMask
        // The gaps between segments, painted over the bars in the panel's colour.
        segments.fillColor = Self.background.cgColor
        for sublayer in [grid, gradient, segments, capLayer] {
            sublayer.actions = Self.noActions
            layer?.addSublayer(sublayer)
        }
        barMask.actions = Self.noActions
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(reduceMotionChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    isolated deinit {
        link?.invalidate()
        if capturing { tap?.setActive(false) }
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Layout

    /// The panel's drawing area, inside a small margin.
    private var plot: CGRect { bounds.insetBy(dx: Self.inset, dy: Self.inset) }

    private var barCount: Int {
        if let fixedBars { return max(fixedBars, 1) }
        return min(max(Int(plot.width / 18), 32), 64)
    }

    /// Each bar's left edge and width.
    private func barFrame(_ index: Int, of count: Int) -> (x: CGFloat, width: CGFloat) {
        let gap = max((plot.width / CGFloat(count) * 0.22).rounded(), 1)
        let width = (plot.width - gap * CGFloat(count - 1)) / CGFloat(count)
        return (plot.minX + CGFloat(index) * (width + gap), width)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [grid, segments, capLayer] { sublayer.frame = bounds }
        gradient.frame = plot
        barMask.frame = CGRect(origin: .zero, size: plot.size)
        if analyzer?.bandCount != barCount { analyzer = SpectrumAnalyzer(bandCount: barCount) }
        if bars.count != barCount { makeBars(barCount) }
        grid.path = gridPath()
        segments.path = segmentPath()
        draw()
        CATransaction.commit()
    }

    /// Dots at each bar's centre, every four segments up.
    private func gridPath() -> CGPath {
        let path = CGMutablePath()
        let count = barCount, pitch = (Self.segment + Self.segmentGap) * 4
        var y = plot.minY + pitch / 2
        while y < plot.maxY {
            for index in 0..<count {
                let bar = barFrame(index, of: count)
                path.addRect(CGRect(x: (bar.x + bar.width / 2).rounded(.down), y: y.rounded(.down), width: 1, height: 1))
            }
            y += pitch
        }
        return path
    }

    /// Horizontal lines across the plot, splitting the bars into segments.
    private func segmentPath() -> CGPath {
        let path = CGMutablePath()
        var y = plot.minY + Self.segment
        while y < plot.maxY {
            path.addRect(CGRect(x: plot.minX, y: y, width: plot.width, height: Self.segmentGap))
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
    private func draw() {
        guard let analyzer, bars.count == analyzer.bandCount else { return }
        let count = analyzer.bandCount, height = plot.height
        let pitch = Self.segment + Self.segmentGap
        for index in 0..<count {
            let frame = barFrame(index, of: count)
            // Whole segments only, as on a real LED meter.
            let level = (CGFloat(analyzer.levels[index]) * height / pitch).rounded() * pitch
            // Only what moved: an unchanged layer still costs the commit.
            let bar = CGRect(x: frame.x - plot.minX, y: 0, width: frame.width, height: level)
            if bars[index].frame != bar { bars[index].frame = bar }
            let peak = CGFloat(analyzer.peaks[index]) * height
            let hidden = reducesMotion || peak <= 0
            if caps[index].isHidden != hidden { caps[index].isHidden = hidden }
            let cap = CGRect(x: frame.x, y: plot.minY + min(peak, height - 2).rounded(), width: frame.width, height: 2)
            if !hidden, caps[index].frame != cap { caps[index].frame = cap }
        }
    }

    // MARK: Running

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
            if link == nil {
                let link = displayLink(target: self, selector: #selector(tick))
                link.add(to: .main, forMode: .common)
                self.link = link
            }
        } else {
            link?.invalidate()
            link = nil
        }
        update()
    }

    @objc private func reduceMotionChanged() { update() }

    /// Runs the display link while there's something to draw that can be seen: playing, or
    /// the bars still falling after a pause. The tap captures only while this is playing.
    private func update() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        let wantsCapture = visible && isPlaying
        if wantsCapture != capturing {
            capturing = wantsCapture
            tap?.setActive(wantsCapture)
        }
        let rate: Float = reducesMotion ? 10 : 60
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: min(rate, 30), maximum: rate, preferred: rate)
        let running = visible && (isPlaying || !(analyzer?.isSettled ?? true))
        if running, link?.isPaused == true { lastTimestamp = nil }
        link?.isPaused = !running
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let analyzer else { return }
        let dt = lastTimestamp.map { min(max(link.timestamp - $0, 0), 0.1) } ?? link.duration
        lastTimestamp = link.timestamp
        if let tap, capturing {
            analyzer.update(from: tap, dt: dt)
        } else {
            analyzer.fade(by: dt)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        draw()
        CATransaction.commit()
        if !isPlaying, analyzer.isSettled { link.isPaused = true }
    }
}

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
            .accessibilityAddTraits(.isImage)
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
        timer?.cancel()
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

    /// Each bar's left edge and width, on whole points so every bar and gap is as wide as the
    /// next and their edges are sharp; what's left over is split between the two sides.
    private func barFrame(_ index: Int, of count: Int) -> (x: CGFloat, width: CGFloat) {
        let gap = max((plot.width / CGFloat(count) * 0.22).rounded(), 1)
        let width = max(((plot.width - gap * CGFloat(count - 1)) / CGFloat(count)).rounded(.down), 1)
        let spare = plot.width - width * CGFloat(count) - gap * CGFloat(count - 1)
        return ((plot.minX + max(spare, 0) / 2).rounded(.down) + CGFloat(index) * (width + gap), width)
    }

    /// Shape layers drawn at the screen's scale, so the segment gaps and grid dots are sharp
    /// on Retina (layers added by hand start at 1×).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for sublayer in [grid, gradient, barMask, segments, capLayer] { sublayer.contentsScale = scale }
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
            // The cap in the segment just above its peak, lined up with the bar's segments.
            let peak = (CGFloat(analyzer.peaks[index]) * height / pitch).rounded() * pitch
            let hidden = reducesMotion || analyzer.peaks[index] <= 0
            if caps[index].isHidden != hidden { caps[index].isHidden = hidden }
            let top = ((height - Self.segment) / pitch).rounded(.down) * pitch
            let cap = CGRect(x: frame.x, y: plot.minY + min(peak, top), width: frame.width, height: 2)
            if !hidden, caps[index].frame != cap { caps[index].frame = cap }
        }
    }

    // MARK: Running

    /// Frames a second (a few under Reduce Motion).
    static let frameRate = 30.0

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
        }
        update()
    }

    @objc private func reduceMotionChanged() { update() }

    /// Runs the frames while there's something to draw that can be seen: playing, or the bars
    /// still falling after a pause. The tap captures only while this is playing.
    ///
    /// A plain timer and an explicit transaction rather than a display link: an NSView's
    /// display link runs AppKit's whole display cycle each frame (animations, tracking areas,
    /// the window's update), which cost more than the visualizer itself.
    private func update() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        let wantsCapture = visible && isPlaying
        if wantsCapture != capturing {
            capturing = wantsCapture
            tap?.setActive(wantsCapture)
        }
        let running = visible && (isPlaying || !(analyzer?.isSettled ?? true))
        run(running ? (reducesMotion ? 10 : Self.frameRate) : nil)
    }

    private var timer: DispatchSourceTimer?
    private var timerRate: Double?
    private var lastTick: CFTimeInterval?

    /// Ticks `rate` times a second, or stops.
    private func run(_ rate: Double?) {
        guard rate != timerRate else { return }
        timer?.cancel()
        timer = nil
        timerRate = rate
        lastTick = nil
        guard let rate else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1 / rate, leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard let analyzer else { return }
        let now = CACurrentMediaTime()
        let dt = lastTick.map { min(max(now - $0, 0), 0.1) } ?? 1 / (timerRate ?? Self.frameRate)
        lastTick = now
        if let tap, capturing {
            analyzer.update(from: tap, dt: dt)
        } else {
            analyzer.fade(by: dt)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        draw()
        CATransaction.commit()
        if !isPlaying, analyzer.isSettled { run(nil) }
    }
}

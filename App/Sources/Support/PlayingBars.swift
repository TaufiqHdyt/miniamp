import AppKit
import SwiftUI

/// Marks the song playing, as Apple Music does: little bars bouncing like a level meter while
/// it plays, resting low while it's paused (and kept still under Reduce Motion).
struct PlayingBars: View {
    var isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let animating = isPlaying && !reduceMotion
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animating)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let count = PlayingBarsShape.count
                let gap = size.width * 0.12
                let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
                for bar in 0..<count {
                    let level = animating ? PlayingBarsShape.level(bar, at: time) : PlayingBarsShape.rest[bar]
                    let height = max(size.height * level, width)
                    let rect = CGRect(x: CGFloat(bar) * (width + gap), y: size.height - height, width: width, height: height)
                    canvas.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .foreground)
                }
            }
        }
        .frame(width: 14, height: 12)
        .foregroundStyle(Color.accentColor)
        .accessibilityElement()
        .accessibilityLabel(isPlaying ? "Playing" : "Paused")
    }
}

/// The bars' shared rhythm.
enum PlayingBarsShape {
    static let count = 4
    /// Heights while paused, as fractions of the full height.
    static let rest: [CGFloat] = [0.35, 0.6, 0.45, 0.3]
    /// Each bar a different pair of speeds, so they never move in step.
    private static let speeds: [(Double, Double)] = [(9.1, 3.7), (7.3, 5.9), (10.7, 4.3), (8.2, 6.6)]

    static func level(_ bar: Int, at time: Double) -> CGFloat {
        let (a, b) = speeds[bar]
        let wave = (sin(time * a + Double(bar)) + sin(time * b + Double(bar) * 2.1)) / 2 // -1...1
        return CGFloat(0.55 + 0.45 * wave)
    }
}

/// The same bars for AppKit (the song list), drawn by Core Animation so they move without
/// redrawing the table.
final class PlayingBarsView: NSView {
    var isPlaying = false {
        didSet { if isPlaying != oldValue { updateAnimations() } }
    }

    private var bars: [CALayer] = []
    /// The height the running animations were made for; layout passes at that height leave them be.
    private var animatedHeight: CGFloat?
    /// Each bar's time between low and high, and where in that it starts.
    private static let durations: [CFTimeInterval] = [0.47, 0.62, 0.42, 0.7]
    private static let offsets: [CFTimeInterval] = [0, 0.21, 0.37, 0.12]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<PlayingBarsShape.count {
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(reduceMotionChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let color = NSColor.controlAccentColor.cgColor
        for bar in bars { bar.backgroundColor = color }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let count = CGFloat(bars.count)
        let gap = bounds.width * 0.12
        let width = (bounds.width - gap * (count - 1)) / count
        for (index, bar) in bars.enumerated() {
            let height = max(bounds.height * PlayingBarsShape.rest[index], width)
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            bar.position = CGPoint(x: CGFloat(index) * (width + gap) + width / 2, y: 0)
            bar.cornerRadius = width / 2
        }
        CATransaction.commit()
        updateAnimations()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimations()
    }

    @objc private func reduceMotionChanged() { updateAnimations() }

    private func updateAnimations() {
        setAccessibilityLabel(isPlaying ? "Playing" : "Paused")
        let animates = isPlaying && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animates, animatedHeight == bounds.height { return }
        animatedHeight = animates ? bounds.height : nil
        for (index, bar) in bars.enumerated() {
            guard animates else {
                bar.removeAnimation(forKey: "level")
                continue
            }
            let width = bar.bounds.width
            let animation = CABasicAnimation(keyPath: "bounds.size.height")
            animation.fromValue = max(bounds.height * 0.2, width)
            animation.toValue = bounds.height
            animation.duration = Self.durations[index]
            animation.timeOffset = Self.offsets[index]
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(animation, forKey: "level")
        }
    }
}

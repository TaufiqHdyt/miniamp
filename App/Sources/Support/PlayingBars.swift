import AppKit
import SwiftUI

/// Marks the song playing, as Apple Music does: little bars bouncing like a level meter while
/// it plays, resting low while it's paused (and kept still under Reduce Motion).
///
/// Drawn by `PlayingBarsView`, whose Core Animation runs outside the app. A SwiftUI timeline
/// redrawing them would update the view graph 30 times a second, and each update lays out the
/// whole window: that tripled the app's CPU while playing, even with the bars hidden.
struct PlayingBars: NSViewRepresentable {
    var isPlaying: Bool

    func makeNSView(context: Context) -> PlayingBarsView { PlayingBarsView(frame: .zero) }

    func updateNSView(_ view: PlayingBarsView, context: Context) { view.isPlaying = isPlaying }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PlayingBarsView, context: Context) -> CGSize? {
        CGSize(width: 14, height: 12)
    }
}

/// The bars' heights while paused, as fractions of the full height.
enum PlayingBarsShape {
    static let count = 4
    static let rest: [CGFloat] = [0.35, 0.6, 0.45, 0.3]
}

/// The bars, drawn by Core Animation so they move without redrawing the table or the window.
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

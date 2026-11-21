import AppKit
import MiniAmpKit
import os
import SwiftUI

enum VisualizerType: String, CaseIterable {
    case spectrum, waveform

    var title: String {
        switch self {
        case .spectrum: "Classic Spectrum"
        case .waveform: "Waveform"
        }
    }
}

struct VisualizerView: NSViewRepresentable {
    let type: VisualizerType
    let tap: SampleTap?
    let isPlaying: Bool
    let isSendingDoP: Bool

    func makeNSView(context: Context) -> VisualizerNSView { VisualizerNSView() }

    func updateNSView(_ view: VisualizerNSView, context: Context) {
        view.configure(type: type, tap: tap, isPlaying: isPlaying, isSendingDoP: isSendingDoP)
    }

    static func dismantleNSView(_ view: VisualizerNSView, coordinator: ()) {
        view.configure(type: nil, tap: nil, isPlaying: false, isSendingDoP: false)
    }
}

@MainActor
protocol VisualizerRenderer: AnyObject {
    var layer: CALayer { get }
    var isSettled: Bool { get }
    func layout(in bounds: CGRect, scale: CGFloat)
    /// Advances the visualization and reports whether it needs to be redrawn.
    func advance(from tap: SampleTap?, dt: Double) -> Bool
    func draw(reducesMotion: Bool)
    func reset()
}

final class VisualizerNSView: NSView {
    private static let frameLog = OSSignposter(subsystem: "dev.miniamp", category: .pointsOfInterest)

    private var type: VisualizerType?
    private var renderer: (any VisualizerRenderer)?
    private var tap: SampleTap?
    private var isPlaying = false
    private var isSendingDoP = false
    private var capturing = false
    private var occlusionObserver: NSObjectProtocol?
    private var timer: DispatchSourceTimer?
    private var timerRate: Double?
    private var lastTick: CFTimeInterval?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(reduceMotionChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    isolated deinit {
        timer?.cancel()
        if capturing { tap?.setActive(false) }
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func configure(type: VisualizerType?, tap: SampleTap?, isPlaying: Bool, isSendingDoP: Bool) {
        let sourceChanged = self.tap !== tap
        let enteredDoP = isSendingDoP && !self.isSendingDoP
        if sourceChanged {
            setCapturing(false)
            self.tap = tap
        }
        self.isPlaying = isPlaying
        self.isSendingDoP = isSendingDoP

        if self.type != type {
            self.type = type
            renderer?.layer.removeFromSuperlayer()
            switch type {
            case .spectrum: renderer = SpectrumRenderer()
            case .waveform: renderer = WaveformRenderer()
            case nil: renderer = nil
            }
            if let renderer { layer?.addSublayer(renderer.layer) }
            needsLayout = true
        } else if sourceChanged || enteredDoP {
            renderer?.reset()
            draw()
        }
        update()
    }

    override func layout() {
        super.layout()
        guard let renderer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.layout(in: bounds, scale: window?.backingScaleFactor ?? 1)
        renderer.draw(reducesMotion: reducesMotion)
        CATransaction.commit()
        update()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

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
        needsLayout = true
        update()
    }

    private var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    @objc private func reduceMotionChanged() {
        draw()
        update()
    }

    private func setCapturing(_ active: Bool) {
        guard active != capturing else { return }
        capturing = active
        tap?.setActive(active)
    }

    private func update() {
        let visible = window?.occlusionState.contains(.visible) == true
        let hasDrawable = visible && !bounds.isEmpty && renderer != nil && !isSendingDoP
        setCapturing(hasDrawable && isPlaying && tap != nil)
        let running = hasDrawable && (capturing || renderer?.isSettled == false)
        run(running ? (reducesMotion ? 10 : 30) : nil)
    }

    // A main-queue timer avoids running AppKit's whole display cycle on every frame.
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
        guard let rate = timerRate, let renderer, let type else { return }
        let log = Self.frameLog
        let interval = log.isEnabled ? log.beginInterval("Visualizer Frame", "\(type.rawValue, privacy: .public)") : nil
        defer {
            if let interval { log.endInterval("Visualizer Frame", interval) }
        }
        let now = CACurrentMediaTime()
        let dt = lastTick.map { min(max(now - $0, 0), 0.1) } ?? 1 / rate
        lastTick = now
        if renderer.advance(from: capturing ? tap : nil, dt: dt) { draw() }
        if !capturing, renderer.isSettled { run(nil) }
    }

    private func draw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer?.draw(reducesMotion: reducesMotion)
        CATransaction.commit()
    }
}

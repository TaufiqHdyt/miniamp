import AppKit
import SwiftUI

extension View {
    /// Calls `action` with whether any part of the window is on screen: false while it's
    /// minimized, hidden with the app, on another Space, or fully covered by other windows.
    func onWindowVisibilityChange(_ action: @escaping (Bool) -> Void) -> some View {
        background(WindowVisibilityReader(onChange: action))
    }
}

private struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            let visible = window?.occlusionState.contains(.visible) ?? false
            guard visible != lastReported else { return }
            lastReported = visible
            onChange?(visible)
        }

        isolated deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

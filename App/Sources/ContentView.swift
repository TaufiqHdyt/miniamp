import MiniAmpKit
import SwiftUI
import UniformTypeIdentifiers

/// M1 test bench: open a file, play it bit-perfect, and show what the device is doing.
/// The real interface arrives in M4.
struct ContentView: View {
    @State private var player = Player()
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("Open…") { importing = true }
                    .keyboardShortcut("o")
                Button("Stop") { player.stop() }
                    .disabled(player.state == .stopped)
                Spacer()
                Text(stateLabel).foregroundStyle(.secondary)
            }

            if let path = player.signalPath {
                SignalPathView(path: path)
            } else {
                Text("Open a FLAC, MP3, ALAC, or AAC file.").foregroundStyle(.secondary)
            }

            if let warning = player.deviceWarning {
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let error {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 260)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): play(url)
            case .failure(let e): error = e.localizedDescription
            }
        }
        .task { autoplayIfRequested() }
    }

    private var stateLabel: String {
        switch player.state {
        case .stopped: "Stopped"
        case .preparing: "Preparing device…"
        case .playing: "Playing"
        }
    }

    /// Player owns the file's security-scoped access, from opening it until stop.
    private func play(_ url: URL) {
        error = nil
        Task {
            do { try await player.play(url) } catch { self.error = "\(error)" }
        }
    }

    /// Debug hook for automated checks: `miniamp -autoplay /path/in/container/file.flac`.
    private func autoplayIfRequested() {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "autoplay") {
            play(URL(fileURLWithPath: path))
        }
        #endif
    }
}

private struct SignalPathView: View {
    let path: SignalPath

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("File").foregroundStyle(.secondary)
                Text(path.fileDescription).monospaced()
            }
            GridRow {
                Text("Device").foregroundStyle(.secondary)
                Text(path.deviceDescription).monospaced()
            }
            GridRow {
                Text("Format").foregroundStyle(.secondary)
                Text(path.devicePhysicalFormat).monospaced()
            }
            GridRow {
                Text("Path").foregroundStyle(.secondary)
                if path.isResampled {
                    Label("Resampled to \(FormatSelection.formatRate(path.deviceSampleRate))",
                          systemImage: "waveform.badge.exclamationmark")
                        .foregroundStyle(.orange)
                } else {
                    Label("Native rate, no conversion", systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                }
            }
        }
    }
}

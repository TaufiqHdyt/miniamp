import AVFoundation
import Observation
import os

/// Bit-perfect playback of a single file: player node → output node, no mixer.
///
/// The queue, seeking, and gapless playback arrive in M2.
@MainActor
@Observable
public final class Player {
    public enum State: Sendable { case stopped, preparing, playing }

    public private(set) var state: State = .stopped
    public private(set) var signalPath: SignalPath?
    /// Set when the device couldn't be configured for the file; playback continues regardless.
    public private(set) var deviceWarning: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    /// Bumped on every play/stop so stale callbacks and superseded requests are ignored.
    @ObservationIgnored private var generation = 0
    /// Counts play requests, for readable traces: "[3] open …" … "[3] stop".
    @ObservationIgnored private var playID = 0
    /// The file whose security-scoped access we hold. Released on stop, failure, or the next play,
    /// and never by anything else, so access can't end while the file is still being read.
    @ObservationIgnored private var scopedURL: URL?

    private static let log = Logger(subsystem: "dev.miniamp", category: "player")

    public init() {
        engine.attach(node)
    }

    public func play(_ url: URL) async throws {
        stop()
        let gen = generation
        playID += 1
        let id = playID
        state = .preparing

        // Files from the open panel (and, later, bookmarks) need this in the sandbox.
        // Plain paths return false, which is fine: they're readable without it.
        if url.startAccessingSecurityScopedResource() {
            scopedURL = url
            Self.log.debug("[\(id)] security-scoped access granted")
        }

        do {
            let file = try AVAudioFile(forReading: url)
            let device = try AudioDevice.defaultOutput()
            Self.log.debug("[\(id)] open \(url.lastPathComponent, privacy: .public): \(file.fileFormat, privacy: .public), \(file.length) frames")

            // The engine is stopped here, so the device can change rate without
            // pulling the output unit's format out from under a running graph.
            var warning: String?
            do {
                try await DeviceConfigurator.configure(device, sampleRate: file.fileFormat.sampleRate)
            } catch {
                warning = "\(error)"
                Self.log.error("Device setup failed: \(warning ?? "", privacy: .public)")
            }
            guard gen == generation else {
                Self.log.debug("[\(id)] superseded during device setup")
                return
            }

            try Self.connectBitPerfect(node, in: engine, format: file.processingFormat)
            Self.log.debug("[\(id)] connect player → output: \(file.processingFormat, privacy: .public)")
            node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in self?.didFinish(generation: gen, id: id) }
            }
            engine.prepare()
            try engine.start()
            try node.playAudio()
            Self.log.debug("[\(id)] engine started; output node in: \(self.engine.outputNode.inputFormat(forBus: 0), privacy: .public), hw: \(self.engine.outputNode.outputFormat(forBus: 0), privacy: .public)")

            deviceWarning = warning
            signalPath = SignalPath(file: file, url: url, device: device, engine: engine)
            state = .playing
            if let signalPath { Self.log.info("\(signalPath.summary, privacy: .public)") }
        } catch {
            Self.log.error("[\(id)] play failed: \(error, privacy: .public)")
            if gen == generation {
                releaseAccess()
                state = .stopped
            }
            throw error
        }
    }

    public func stop() {
        if state != .stopped { Self.log.debug("[\(self.playID)] stop") }
        generation += 1
        node.stop()
        engine.stop()
        releaseAccess()
        state = .stopped
    }

    private func releaseAccess() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    private func didFinish(generation gen: Int, id: Int) {
        guard gen == generation else { return }
        Self.log.debug("[\(id)] finished playing")
        stop()
    }

    /// Connects the player straight to the output node using the file's processing format.
    ///
    /// The main mixer is never touched (accessing `mainMixerNode` would insert one), so the only
    /// conversion left is the output unit's float → device physical format, which is lossless for
    /// integer sources up to 24 bits. When the device runs at the file's rate, nothing resamples.
    static func connectBitPerfect(_ node: AVAudioPlayerNode, in engine: AVAudioEngine, format: AVAudioFormat) throws {
        engine.disconnectNodeOutput(node)
        try engine.connectNode(node, to: engine.outputNode, format: format)
    }
}

import AVFoundation
import Observation
import os

/// Queue playback with two signal paths.
///
/// - Bit-perfect (the default): player node → output node, no mixer, nothing else attached.
/// - DSP mode: player node → EQ unit → output node. The one unit does the EQ bands and, as its
///   global gain, ReplayGain and the preamps. Turning DSP mode off detaches it again.
///
/// Tracks with the same processing format play back to back on one node (gapless). A format
/// change between tracks stops the engine, reconfigures the device, and starts again.
@MainActor
@Observable
public final class Player {
    public enum State: Sendable { case stopped, preparing, playing, paused }

    public internal(set) var state: State = .stopped
    public internal(set) var queue = PlayQueue<URL>()
    public internal(set) var signalPath: SignalPath?
    /// Set when the device couldn't be configured for the file; playback continues regardless.
    public internal(set) var deviceWarning: String?
    /// The playhead for display: it changes when the whole second does (and on seek, start,
    /// and stop), not on every tick, since each change re-lays out the views that show it.
    /// Read `currentTime` for the exact value.
    public private(set) var position: Duration = .zero
    /// The exact playhead, updated on every tick. Not observable.
    public var currentTime: Duration { playhead }
    /// The playhead now, read from the render clock rather than the last tick (ticks are a
    /// second apart). For things that follow playback closely, like synced lyrics.
    public var exactTime: Duration {
        guard let file = currentFile else { return playhead }
        return Self.time(currentFrame(), file)
    }
    /// Set false while nothing shows the position (window hidden or covered): `position` then
    /// stops changing, so nothing re-renders. Setting it true brings `position` up to date.
    public var updatesPosition = true {
        didSet { if updatesPosition != oldValue { publishPosition(force: true) } }
    }
    public internal(set) var duration: Duration = .zero
    /// Goes up by one on every seek, so observers that only sync the playhead now and then
    /// (Control Center) know when it jumped.
    public private(set) var seekCount = 0
    /// Goes up by one each time a track begins from its start (a new track, gapless or not, or
    /// the same one again on repeat). Restarting mid-track after a device change doesn't count.
    public internal(set) var trackStarts = 0
    /// The device playback goes to (or would go to, when stopped).
    public internal(set) var outputDevice: AudioDevice?
    public private(set) var availableDevices: [AudioDevice] = []
    /// The output device's own volume, 0...1; nil when it has no volume control.
    public private(set) var volume: Float?

    /// The device to play to, by UID. Nil follows the system default output.
    public var preferredDeviceUID: String? {
        didSet { if oldValue != preferredDeviceUID { Task { await reconcileOutput("preferred device changed") } } }
    }

    /// Exclusive access to the output device while playing.
    public var hogMode = false {
        didSet { if oldValue != hogMode { Task { await restartInPlace("hog mode \(hogMode ? "on" : "off")") } } }
    }

    public var repeatMode: PlayQueue<URL>.Repeat {
        get { queue.repeatMode }
        set {
            queue.repeatMode = newValue
            Task { await queueChanged() }
        }
    }

    public var isShuffled: Bool { queue.isShuffled }

    /// Stop when the current track ends instead of going on (the sleep timer's "end of song").
    /// The next track is then cued, paused at its start. Resets itself once it has acted.
    public var stopsAfterCurrentTrack = false {
        didSet { if oldValue != stopsAfterCurrentTrack { Task { await queueChanged() } } }
    }
    /// Called when playback stopped because of `stopsAfterCurrentTrack`.
    @ObservationIgnored public var onStoppedAfterTrack: (@MainActor () -> Void)?

    // MARK: DSP settings

    /// DSP mode (EQ and ReplayGain) instead of bit-perfect. Switching restarts playback where it is.
    public var dspMode = false {
        didSet { if oldValue != dspMode { Task { await restartInPlace("DSP mode \(dspMode ? "on" : "off")") } } }
    }
    /// Applies live, in DSP mode only.
    public var equalizer = Equalizer() {
        didSet { if oldValue != equalizer { applyDSP() } }
    }
    public var replayGainMode: ReplayGain.Mode = .off {
        didSet { if oldValue != replayGainMode { applyDSP() } }
    }
    /// dB added to ReplayGain's gain (only while ReplayGain is on).
    public var replayGainPreamp: Double = 0 {
        didSet { if oldValue != replayGainPreamp { applyDSP() } }
    }
    /// Keeps ReplayGain from raising a track past its peak.
    public var preventsClipping = true {
        didSet { if oldValue != preventsClipping { applyDSP() } }
    }
    /// The ReplayGain for a file, from the library. Called on the main actor as each track starts.
    @ObservationIgnored public var replayGainLookup: (@MainActor (URL) -> ReplayGain?)?

    // Members without `private` are used by the engine setup in Player+Engine.swift.

    /// Renders on demand (manual rendering mode): decoding, scheduling, and any resampling.
    @ObservationIgnored let engine = AVAudioEngine()
    @ObservationIgnored let node = AVAudioPlayerNode()
    /// DSP mode's EQ and gain. Attached to the engine only in DSP mode.
    @ObservationIgnored let eq = AVAudioUnitEQ(numberOfBands: Equalizer.frequencies.count)
    /// Whether the graph was last connected through `eq`.
    @ObservationIgnored var graphHasDSP = false
    /// The current track's ReplayGain, looked up when it started.
    @ObservationIgnored var currentReplayGain: ReplayGain?
    /// The hardware output, owned by us and bound to one device. Nil only if Core Audio
    /// can't create an output unit at all.
    @ObservationIgnored let output = try? HALOutput()
    /// The device rate playback was set up for; a different rate means someone else changed it.
    @ObservationIgnored var expectedDeviceRate: Double = 0
    @ObservationIgnored var activeDeviceWatcher: Task<Void, Never>?
    @ObservationIgnored let scheduler: TrackScheduler
    /// Bumped on every start/stop so superseded requests are ignored.
    @ObservationIgnored var generation = 0
    /// Counts start requests, for readable traces: "[3] open …" … "[3] stop".
    @ObservationIgnored var playID = 0
    @ObservationIgnored var currentFile: AVAudioFile?
    /// Node start time of the segment that's currently playing.
    @ObservationIgnored var currentNodeStart: AVAudioFramePosition = 0
    /// Item index scheduled after the current one, if any.
    @ObservationIgnored var preloadedItem: Int?
    @ObservationIgnored var preloadAttempted = false
    /// Last position seen while rendering; used when the engine has already stopped.
    @ObservationIgnored var lastKnownFrame: AVAudioFramePosition = 0
    @ObservationIgnored private var playhead: Duration = .zero
    @ObservationIgnored private var scopedURLs: [URL] = []
    @ObservationIgnored var ticker: Task<Void, Never>?
    @ObservationIgnored private var deviceWatcher: Task<Void, Never>?
    @ObservationIgnored private var volumeWatcher: Task<Void, Never>?
    @ObservationIgnored private var volumeDevice: AudioDevice?
    /// Name of `outputDevice`, kept because it can't be read once the device is unplugged.
    @ObservationIgnored var outputDeviceName = ""

    /// How long before a track ends the next one is opened and scheduled.
    static let preloadLead: Duration = .seconds(5)
    /// "Previous" restarts the current track when it's past this point.
    static let restartThreshold: Duration = .seconds(3)
    /// Time for rendered audio to leave the hardware (I/O buffer plus device latency, with margin).
    static let drainTime: Duration = .milliseconds(100)

    static let log = Logger(subsystem: "dev.miniamp", category: "player")

    public init() {
        engine.attach(node)
        scheduler = TrackScheduler(node: node)
        scheduler.onSegmentFinished = { [weak self] segment in self?.segmentFinished(segment) }

        deviceWatcher = Task { [weak self] in
            for await _ in AudioSystem.deviceChanges() {
                // Plugging and unplugging produce a burst of notifications; let it settle.
                try? await Task.sleep(for: .milliseconds(300))
                await self?.reconcileOutput("devices changed")
            }
        }
        availableDevices = (try? AudioSystem.outputDevices()) ?? []
        if let device = try? resolveDevice() {
            outputDevice = device
            watchVolume(device)
        }
    }

    // MARK: - Queue

    /// Output render callbacks served so far. Diagnostics only.
    public nonisolated static var renderCallCount: Int { HALOutput.renderCalls.load(ordering: .relaxed) }
    /// Diagnostics (miniampctl leaktest): count renders that delivered audio to a device other
    /// than the one playback is bound to. Costs a property read per render, so it's off by default.
    public nonisolated static var verifiesOutputDevice: Bool {
        get { HALOutput.verifyDeviceOnRender.load(ordering: .relaxed) }
        set { HALOutput.verifyDeviceOnRender.store(newValue, ordering: .relaxed) }
    }
    public nonisolated static var misdirectedRenderCount: Int { HALOutput.misdirectedRenders.load(ordering: .relaxed) }

    public func play(_ url: URL) async throws {
        try await setQueue([url])
    }

    /// Replaces the queue and starts playing at `index`.
    public func setQueue(_ urls: [URL], startAt index: Int = 0) async throws {
        releaseAccess()
        // Files from the open panel need this in the sandbox; plain paths return false and
        // are readable anyway. Access is held for as long as the URLs are queued.
        scopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }

        let repeatMode = queue.repeatMode
        let shuffle = queue.isShuffled
        queue = PlayQueue(urls, startAt: index)
        queue.repeatMode = repeatMode
        if shuffle { queue.setShuffle(true) }

        guard let position = queue.position else { return stop() }
        try await start(position: position, frame: 0, autoplay: true)
    }

    public func setShuffle(_ on: Bool) {
        queue.setShuffle(on)
        Task { await queueChanged() }
    }

    public func next() async throws {
        guard let position = queue.upcoming(automatic: false) else { return }
        try await start(position: position, frame: 0, autoplay: state != .paused)
    }

    /// Restarts the current track if it's past the first few seconds, otherwise goes back one.
    public func previous() async throws {
        if playhead > Self.restartThreshold || !queue.goBack() {
            seek(to: .zero)
            return
        }
        guard let position = queue.position else { return }
        try await start(position: position, frame: 0, autoplay: state != .paused)
    }

    public func jump(toItem index: Int) async throws {
        guard let position = queue.order.firstIndex(of: index) else { return }
        try await start(position: position, frame: 0, autoplay: true)
    }

    // MARK: - Transport

    public func togglePlayPause() async throws {
        switch state {
        case .playing: pause()
        case .paused: try resume()
        case .stopped:
            if let position = queue.position { try await start(position: position, frame: 0, autoplay: true) }
        case .preparing: break
        }
    }

    public func pause() {
        guard state == .playing else { return }
        lastKnownFrame = currentFrame()
        output?.stop()
        node.pause()
        ticker?.cancel()
        state = .paused
        if let file = currentFile { setPlayhead(Self.time(lastKnownFrame, file), force: true) }
        Self.log.debug("[\(self.playID)] pause at \(self.playhead.formatted(), privacy: .public)")
    }

    public func resume() throws {
        guard state == .paused, let output else { return }
        try output.start()
        try node.startPlayback()
        state = .playing
        startTicker()
        Self.log.debug("[\(self.playID)] resume")
    }

    public func stop() {
        if state != .stopped { Self.log.debug("[\(self.playID)] stop") }
        generation += 1
        ticker?.cancel()
        activeDeviceWatcher?.cancel()
        output?.stop()
        scheduler.reset()
        engine.stop()
        releaseHogMode(outputDevice)
        currentFile = nil
        preloadedItem = nil
        lastKnownFrame = 0
        setPlayhead(.zero, force: true)
        state = .stopped
    }

    /// Moves the playhead within the current track. Works while playing or paused.
    public func seek(to time: Duration) {
        guard state == .playing || state == .paused, let file = currentFile, let item = queue.currentIndex else {
            return
        }
        let frame = min(max(Self.frames(time, file), 0), max(file.length - 1, 0))
        scheduler.reset()
        scheduler.append(file, from: frame, token: item)
        currentNodeStart = 0
        preloadedItem = nil
        preloadAttempted = false
        lastKnownFrame = frame
        setPlayhead(Self.time(frame, file), force: true)
        seekCount += 1
        if state == .playing {
            do { try node.startPlayback() } catch { Self.log.error("seek: \(error, privacy: .public)") }
        }
        Self.log.debug("[\(self.playID)] seek to \(self.playhead.formatted(), privacy: .public)")
    }

    // MARK: - Output

    public func setVolume(_ value: Float) {
        guard let device = outputDevice else { return }
        do {
            try device.setVolume(value)
        } catch {
            Self.log.error("volume: \(error, privacy: .public)")
        }
        volume = device.volume()
    }

    func resolveDevice() throws -> AudioDevice {
        if let uid = preferredDeviceUID, let device = AudioSystem.device(uid: uid) { return device }
        // Hogging a device makes macOS move the default output elsewhere. That change is ours,
        // so following it would hop to the other device, hog it, and bounce back forever.
        if let active = outputDevice, active.hogModeOwner() == getpid(), active.isAlive { return active }
        return try AudioDevice.defaultOutput()
    }

    func watchVolume(_ device: AudioDevice) {
        volume = device.volume()
        guard device != volumeDevice else { return }
        volumeDevice = device
        volumeWatcher?.cancel()
        volumeWatcher = Task { [weak self] in
            for await _ in device.volumeChanges() {
                guard let self, self.volumeDevice == device else { return }
                self.volume = device.volume()
            }
        }
    }

    /// Watches the device we're playing to for removal or a rate change made elsewhere.
    func watchActiveDevice(_ device: AudioDevice) {
        activeDeviceWatcher?.cancel()
        activeDeviceWatcher = Task { [weak self] in
            let changes = HAL.changes(device.id, [
                .init(kAudioDevicePropertyDeviceIsAlive),
                .init(kAudioDevicePropertyNominalSampleRate),
            ])
            for await _ in changes {
                guard !Task.isCancelled else { return }
                // Separate task: reconciling restarts playback, which cancels this watcher,
                // and that cancellation mustn't reach the restart itself.
                Task { await self?.reconcileOutput("output device changed") }
            }
        }
    }

    /// Brings playback in line with the devices that exist now.
    ///
    /// - The active device disappeared (headphones unplugged): pause, and move to the new
    ///   device paused. Audio never jumps to the speakers on its own.
    /// - Another device should be used (default changed, or the preferred one came back):
    ///   move there, keeping play/pause state.
    /// - Same device, but the engine stopped (rate changed by another app): rebuild in place.
    private func reconcileOutput(_ reason: String) async {
        availableDevices = (try? AudioSystem.outputDevices()) ?? []
        let target = try? resolveDevice()

        guard state == .playing || state == .paused, let active = outputDevice else {
            if state == .stopped, let target {
                outputDevice = target
                watchVolume(target)
            }
            return
        }
        let wasPlaying = state == .playing
        let frame = currentFrame()

        if !active.isAlive {
            Self.log.notice("\(reason, privacy: .public): \(self.outputDeviceName, privacy: .public) is gone; pausing")
            try? await restart(at: frame, autoplay: false)
        } else if let target, target != active {
            Self.log.notice("\(reason, privacy: .public): moving to \(target.name, privacy: .public)")
            try? await restart(at: frame, autoplay: wasPlaying)
        } else if let rate = try? active.nominalSampleRate(), !FormatSelection.sameRate(rate, expectedDeviceRate) {
            Self.log.notice("\(reason, privacy: .public): another app set \(active.name, privacy: .public) to \(rate) Hz; following it")
            try? await restart(at: frame, autoplay: wasPlaying, keepDeviceRate: true)
        }
    }

    // MARK: - DSP

    /// A new track is current: look up its ReplayGain and set the gain for it.
    func trackChanged(to url: URL) {
        currentReplayGain = replayGainLookup?(url)
        applyDSP()
    }

    /// Asks the library again for the current track's ReplayGain (after an analysis measured it).
    public func reloadReplayGain() {
        guard let url = queue.current, state != .stopped else { return }
        trackChanged(to: url)
    }

    /// Sets the EQ unit from the settings, and the signal path's description of it. Safe while
    /// playing: the unit's parameters change without stopping anything.
    func applyDSP() {
        equalizer.configure(eq)
        let gain = dspGain
        eq.globalGain = min(max(Float(gain), -96), 24)
        guard var path = signalPath else { return }
        path.processing = graphHasDSP ? processing(gain: gain) : nil
        if path != signalPath { signalPath = path }
    }

    /// ReplayGain and the preamps, dB.
    private var dspGain: Double {
        var gain = Double(equalizer.isEnabled ? equalizer.preamp : 0)
        if replayGainMode != .off {
            gain += currentReplayGain?.gain(replayGainMode, preamp: replayGainPreamp, preventClipping: preventsClipping)
                ?? replayGainPreamp
        }
        return gain
    }

    func processing(gain: Double? = nil) -> SignalPath.Processing {
        SignalPath.Processing(
            equalizer: equalizer.isShaping ? (equalizer.preset?.name ?? "Custom") : nil,
            replayGain: replayGainMode, trackHasReplayGain: currentReplayGain != nil, gain: gain ?? dspGain)
    }

    private func restartInPlace(_ reason: String) async {
        guard state == .playing || state == .paused else { return }
        Self.log.debug("\(reason, privacy: .public): restarting at current position")
        try? await restart(at: currentFrame(), autoplay: state == .playing)
    }

    private func restart(at frame: AVAudioFramePosition, autoplay: Bool, keepDeviceRate: Bool = false) async throws {
        guard let position = queue.position else { return }
        try await start(position: position, frame: frame, autoplay: autoplay, keepDeviceRate: keepDeviceRate)
    }

    /// Ticks once a second, just after the playhead reaches each whole second: that's when
    /// the displayed time changes, and a second is plenty for preloading the next track five
    /// seconds ahead. (It ticked every 250 ms, four wakeups a second, for the same display.)
    func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.tickAndDelay() else { return }
                try? await Task.sleep(for: delay, tolerance: .milliseconds(50))
            }
        }
    }

    private func tickAndDelay() -> Duration {
        tick()
        let attoseconds = playhead.components.attoseconds
        let toNextSecond = Duration.seconds(1) - .nanoseconds(attoseconds / 1_000_000_000)
        // A little past the boundary, so the next tick lands on the new second.
        return max(toNextSecond + .milliseconds(20), .milliseconds(100))
    }

    /// Updates the position and opens the next track when the current one is nearly over.
    private func tick() {
        guard state == .playing, let (segment, frame) = scheduler.currentPosition() else { return }
        if segment.nodeStart > currentNodeStart {
            // The render clock is past a gapless boundary; the completion callback may lag.
            advance(to: segment)
        }
        guard let file = currentFile else { return }
        lastKnownFrame = frame
        setPlayhead(Self.time(frame, file))

        if !preloadAttempted, duration - playhead <= Self.preloadLead {
            preloadNext(after: file)
        }
    }

    func setPlayhead(_ time: Duration, force: Bool = false) {
        playhead = time
        publishPosition(force: force)
    }

    /// Copies the playhead to `position` when the displayed second changes (or when forced).
    private func publishPosition(force: Bool = false) {
        guard updatesPosition else { return }
        if force || Self.wholeSeconds(playhead) != Self.wholeSeconds(position) {
            position = playhead
        }
    }

    static func wholeSeconds(_ time: Duration) -> Int64 { time.components.seconds }

    private func preloadNext(after file: AVAudioFile) {
        preloadAttempted = true
        guard !stopsAfterCurrentTrack else { return }
        guard let next = queue.upcoming(automatic: true) else { return }
        let item = queue.order[next]
        let url = queue.items[item]
        do {
            let nextFile = try AVAudioFile(forReading: url)
            guard nextFile.processingFormat == file.processingFormat else {
                Self.log.debug("[\(self.playID)] next is \(nextFile.processingFormat, privacy: .public); a different format, so not gapless")
                return
            }
            scheduler.append(nextFile, token: item)
            preloadedItem = item
            Self.log.debug("[\(self.playID)] scheduled \(url.lastPathComponent, privacy: .public) gaplessly")
        } catch {
            Self.log.error("[\(self.playID)] can't open next \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
        }
    }

    /// The preloaded segment has started: make it current without touching the engine.
    private func advance(to segment: TrackScheduler.Segment) {
        guard segment.nodeStart > currentNodeStart else { return }
        currentNodeStart = segment.nodeStart
        queue.jump(toItem: segment.token)
        currentFile = segment.file
        preloadedItem = nil
        preloadAttempted = false
        duration = Self.time(segment.file.length, segment.file)
        // The new track has only just started. Without this the playhead keeps the old
        // track's end until the next tick, and anything that reads it now (Control Center)
        // gets that. A tick that got here first sets the exact frame right after.
        lastKnownFrame = 0
        setPlayhead(.zero, force: true)
        trackStarts += 1
        if let device = outputDevice {
            signalPath = SignalPath(file: segment.file, url: queue.items[segment.token], device: device, engine: engine)
        }
        playID += 1
        trackChanged(to: queue.items[segment.token])
        Self.log.info("[\(self.playID)] gapless → \(self.queue.items[segment.token].lastPathComponent, privacy: .public)")
    }

    private func segmentFinished(_ segment: TrackScheduler.Segment) {
        if let next = scheduler.segments.first {
            advance(to: next)
            return
        }
        guard state == .playing, segment.nodeStart >= currentNodeStart else { return }
        Self.log.debug("[\(self.playID)] finished playing")
        let gen = generation
        Task {
            // The last frames are rendered but still in the hardware's buffers; let them out
            // before the output is stopped or switched.
            try? await Task.sleep(for: Self.drainTime)
            guard gen == generation else { return }
            await trackEnded()
        }
    }

    /// Nothing was scheduled after the track that just ended: start the next one from scratch
    /// (it has a different format) or stop at the end of the queue.
    private func trackEnded() async {
        if stopsAfterCurrentTrack {
            stopsAfterCurrentTrack = false
            Self.log.debug("[\(self.playID)] stopping after the track, as asked")
            if let next = queue.upcoming(automatic: false), next != queue.position {
                do { try await start(position: next, frame: 0, autoplay: false) } catch { stop() }
            } else {
                stop()
            }
            onStoppedAfterTrack?()
            return
        }
        guard let next = queue.upcoming(automatic: true) else {
            stop()
            return
        }
        do {
            try await start(position: next, frame: 0, autoplay: true)
        } catch {
            Self.log.error("can't continue: \(error, privacy: .public)")
        }
    }

    /// Shuffle or repeat changed: if the wrong track is already scheduled next, reschedule.
    private func queueChanged() async {
        let upcoming = stopsAfterCurrentTrack ? nil : queue.upcoming(automatic: true).map { queue.order[$0] }
        if preloadedItem != nil, preloadedItem != upcoming {
            Self.log.debug("[\(self.playID)] queue changed; rescheduling")
            seek(to: playhead)
        } else if preloadedItem == nil {
            preloadAttempted = false
        }
    }

    private func currentFrame() -> AVAudioFramePosition {
        guard state == .playing, let (segment, frame) = scheduler.currentPosition(),
              segment.nodeStart == currentNodeStart else { return lastKnownFrame }
        return frame
    }

    func releaseHogMode(_ device: AudioDevice?) {
        guard let device, device.hogModeOwner() == getpid() else { return }
        do {
            try device.setHogMode(false)
            Self.log.debug("hog mode released on \(device.name, privacy: .public); owner now \(device.hogModeOwner().map(String.init) ?? "none", privacy: .public)")
        } catch {
            Self.log.error("can't release hog mode on \(device.name, privacy: .public): \(error, privacy: .public)")
        }
    }

    private func releaseAccess() {
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs = []
    }
}

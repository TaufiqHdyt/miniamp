import AVFoundation
import Observation
import os

/// Bit-perfect queue playback: player node → output node, no mixer.
///
/// Tracks with the same processing format play back to back on one node (gapless). A format
/// change between tracks stops the engine, reconfigures the device, and starts again.
@MainActor
@Observable
public final class Player {
    public enum State: Sendable { case stopped, preparing, playing, paused }

    public private(set) var state: State = .stopped
    public private(set) var queue = PlayQueue<URL>()
    public private(set) var signalPath: SignalPath?
    /// Set when the device couldn't be configured for the file; playback continues regardless.
    public private(set) var deviceWarning: String?
    /// The playhead for display: it changes when the whole second does (and on seek, start,
    /// and stop), not on every tick, since each change re-lays out the views that show it.
    /// Read `currentTime` for the exact value.
    public private(set) var position: Duration = .zero
    /// The exact playhead, updated on every tick. Not observable.
    public var currentTime: Duration { playhead }
    /// Set false while nothing shows the position (window hidden or covered): `position` then
    /// stops changing, so nothing re-renders. Setting it true brings `position` up to date.
    public var updatesPosition = true {
        didSet { if updatesPosition != oldValue { publishPosition(force: true) } }
    }
    public private(set) var duration: Duration = .zero
    /// The device playback goes to (or would go to, when stopped).
    public private(set) var outputDevice: AudioDevice?
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

    /// Renders on demand (manual rendering mode): decoding, scheduling, and any resampling.
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    /// The hardware output, owned by us and bound to one device. Nil only if Core Audio
    /// can't create an output unit at all.
    @ObservationIgnored private let output = try? HALOutput()
    /// The device rate playback was set up for; a different rate means someone else changed it.
    @ObservationIgnored private var expectedDeviceRate: Double = 0
    @ObservationIgnored private var activeDeviceWatcher: Task<Void, Never>?
    @ObservationIgnored private let scheduler: TrackScheduler
    /// Bumped on every start/stop so superseded requests are ignored.
    @ObservationIgnored private var generation = 0
    /// Counts start requests, for readable traces: "[3] open …" … "[3] stop".
    @ObservationIgnored private var playID = 0
    @ObservationIgnored private var currentFile: AVAudioFile?
    /// Node start time of the segment that's currently playing.
    @ObservationIgnored private var currentNodeStart: AVAudioFramePosition = 0
    /// Item index scheduled after the current one, if any.
    @ObservationIgnored private var preloadedItem: Int?
    @ObservationIgnored private var preloadAttempted = false
    /// Last position seen while rendering; used when the engine has already stopped.
    @ObservationIgnored private var lastKnownFrame: AVAudioFramePosition = 0
    @ObservationIgnored private var playhead: Duration = .zero
    @ObservationIgnored private var scopedURLs: [URL] = []
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var deviceWatcher: Task<Void, Never>?
    @ObservationIgnored private var volumeWatcher: Task<Void, Never>?
    @ObservationIgnored private var volumeDevice: AudioDevice?
    /// Name of `outputDevice`, kept because it can't be read once the device is unplugged.
    @ObservationIgnored private var outputDeviceName = ""

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
        try node.playAudio()
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
        if state == .playing {
            do { try node.playAudio() } catch { Self.log.error("seek: \(error, privacy: .public)") }
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

    private func resolveDevice() throws -> AudioDevice {
        if let uid = preferredDeviceUID, let device = AudioSystem.device(uid: uid) { return device }
        // Hogging a device makes macOS move the default output elsewhere. That change is ours,
        // so following it would hop to the other device, hog it, and bounce back forever.
        if let active = outputDevice, active.hogModeOwner() == getpid(), active.isAlive { return active }
        return try AudioDevice.defaultOutput()
    }

    private func watchVolume(_ device: AudioDevice) {
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
    private func watchActiveDevice(_ device: AudioDevice) {
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

    private func restartInPlace(_ reason: String) async {
        guard state == .playing || state == .paused else { return }
        Self.log.debug("\(reason, privacy: .public): restarting at current position")
        try? await restart(at: currentFrame(), autoplay: state == .playing)
    }

    private func restart(at frame: AVAudioFramePosition, autoplay: Bool, keepDeviceRate: Bool = false) async throws {
        guard let position = queue.position else { return }
        try await start(position: position, frame: frame, autoplay: autoplay, keepDeviceRate: keepDeviceRate)
    }

    // MARK: - Engine

    /// Opens the item at `position`, configures the device for it, and starts the graph.
    /// `keepDeviceRate` leaves the device at whatever rate it has (resampling if needed).
    private func start(position p: Int, frame: AVAudioFramePosition, autoplay: Bool,
                       keepDeviceRate: Bool = false) async throws {
        generation += 1
        let gen = generation
        playID += 1
        let id = playID
        let item = queue.order[p]
        let url = queue.items[item]
        ticker?.cancel()
        state = .preparing

        do {
            let file = try AVAudioFile(forReading: url)
            let device = try resolveDevice()
            Self.log.debug("[\(id)] open \(url.lastPathComponent, privacy: .public): \(file.fileFormat, privacy: .public), \(file.length) frames")

            // The engine is stopped here, so the device can change rate without
            // pulling the output unit's format out from under a running graph.
            activeDeviceWatcher?.cancel()
            output?.stop()
            scheduler.reset()
            engine.stop()
            if let old = outputDevice, old != device { releaseHogMode(old) }

            var warning: String?
            do {
                expectedDeviceRate = try await DeviceConfigurator.configure(
                    device, sampleRate: file.fileFormat.sampleRate, hogMode: hogMode, keepRate: keepDeviceRate)
            } catch {
                warning = "\(error)"
                Self.log.error("[\(id)] device setup failed: \(warning ?? "", privacy: .public)")
            }
            guard gen == generation else {
                Self.log.debug("[\(id)] superseded during device setup")
                return
            }

            queue.move(toPosition: p)
            currentFile = file
            preloadedItem = nil
            preloadAttempted = false

            // Right after hog mode or a format change the device restarts, and the output unit
            // can briefly report a configuration change or an invalid hardware format. Those
            // settle within a few hundred milliseconds, so retry them; anything else is real.
            var attempt = 1
            while true {
                do {
                    try startGraph(file: file, device: device, item: item, frame: frame, autoplay: autoplay, id: id)
                    break
                } catch let error as NSError where Self.isTransientStartError(error) && attempt < 4 {
                    Self.log.notice("[\(id)] device still settling (attempt \(attempt)): \(error.userInfo, privacy: .public)")
                    attempt += 1
                    try await Task.sleep(for: .milliseconds(150))
                    guard gen == generation else { return }
                }
            }

            outputDevice = device
            outputDeviceName = device.name
            watchVolume(device)
            watchActiveDevice(device)
            deviceWarning = warning
            duration = Self.time(file.length, file)
            lastKnownFrame = frame
            setPlayhead(Self.time(frame, file), force: true)
            signalPath = SignalPath(file: file, url: url, device: device, engine: engine)
            state = autoplay ? .playing : .paused
            if autoplay { startTicker() }
            if let signalPath { Self.log.info("[\(id)] \(signalPath.summary, privacy: .public)") }
        } catch {
            Self.log.error("[\(id)] play failed: \(error, privacy: .public)")
            if gen == generation { state = .stopped }
            throw error
        }
    }

    /// Sets up the engine in manual rendering mode and binds our output unit to it.
    /// Safe to call again after a failure.
    ///
    /// The engine renders at the device's rate with the file's channel count. If the file's
    /// rate differs (the fallback case), the engine's output node resamples at mastering
    /// quality; otherwise nothing converts. The output unit maps channels (mono to both sides)
    /// and converts float to the device's physical format.
    private func startGraph(file: AVAudioFile, device: AudioDevice, item: Int, frame: AVAudioFramePosition,
                            autoplay: Bool, id: Int) throws {
        guard let output else {
            throw CoreAudioError(status: kAudioUnitErr_FailedInitialization, operation: "Create output unit")
        }
        output.stop()
        scheduler.reset()
        engine.stop()

        let channels = file.processingFormat.channelCount
        let deviceRate = (try? device.nominalSampleRate()) ?? file.processingFormat.sampleRate
        guard let renderFormat = AVAudioFormat(standardFormatWithSampleRate: deviceRate, channels: channels) else {
            throw CoreAudioError(status: kAudioUnitErr_FormatNotSupported, operation: "Render format")
        }
        if engine.isInManualRenderingMode, engine.manualRenderingFormat != renderFormat {
            engine.disableManualRenderingMode()
        }
        if !engine.isInManualRenderingMode {
            try engine.enableManualRenderingMode(.realtime, format: renderFormat, maximumFrameCount: HALOutput.maximumFrames)
        }
        do { try OutputUnit.setMaximumResamplingQuality(on: engine) } catch {
            Self.log.error("[\(id)] \(error, privacy: .public)")
        }
        try Self.connectBitPerfect(node, in: engine, format: file.processingFormat)
        Self.log.debug("[\(id)] connect player → \(device.name, privacy: .public): \(file.processingFormat, privacy: .public), rendering \(renderFormat, privacy: .public)")

        currentNodeStart = 0
        scheduler.append(file, from: frame, token: item)
        engine.prepare()
        try engine.start()

        let renderBlock = engine.manualRenderingBlock
        let map = OutputUnit.channelMap(sourceChannels: Int(channels), deviceChannels: device.outputChannelCount)
        try output.configure(device: device, format: renderFormat, channelMap: map) { frames, data in
            renderBlock(frames, data, nil) == .success
        }
        if autoplay {
            try output.start()
            try node.playAudio()
        }
        Self.log.debug("[\(id)] started; output unit on \(device.name, privacy: .public), \(autoplay ? "playing" : "paused", privacy: .public)")
    }

    /// AVAudioEngine errors that mean "the device hasn't settled yet", seen right after hog mode.
    static func isTransientStartError(_ error: NSError) -> Bool {
        error.domain == "com.apple.coreaudio.avfaudio"
            && (error.code == -10863 /* kAudioUnitErr_CannotDoInCurrentContext: config changed / no IO cycle */
                || error.code == -10875 /* kAudioUnitErr_FailedInitialization: invalid hardware format */)
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
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

    private func setPlayhead(_ time: Duration, force: Bool = false) {
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
        guard let next = queue.upcoming(automatic: true) else { return }
        let item = queue.order[next]
        let url = queue.items[item]
        do {
            let nextFile = try AVAudioFile(forReading: url)
            guard nextFile.processingFormat == file.processingFormat else {
                Self.log.debug("[\(self.playID)] next is \(nextFile.processingFormat, privacy: .public); device must switch, so not gapless")
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
        if let device = outputDevice {
            signalPath = SignalPath(file: segment.file, url: queue.items[segment.token], device: device, engine: engine)
        }
        playID += 1
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
        let upcoming = queue.upcoming(automatic: true).map { queue.order[$0] }
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

    private func releaseHogMode(_ device: AudioDevice?) {
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

    static func time(_ frames: AVAudioFramePosition, _ file: AVAudioFile) -> Duration {
        .seconds(Double(frames) / file.processingFormat.sampleRate)
    }

    static func frames(_ time: Duration, _ file: AVAudioFile) -> AVAudioFramePosition {
        let (seconds, attoseconds) = time.components
        return AVAudioFramePosition((Double(seconds) + Double(attoseconds) / 1e18) * file.processingFormat.sampleRate)
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

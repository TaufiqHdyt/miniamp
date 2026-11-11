import AVFoundation

/// Starting a track: opening the file, setting up the device and the engine for it, or
/// swapping it in on an output that's already running.
extension Player {
    /// Opens the item at `position`, configures the device for it, and starts the graph.
    /// `keepDeviceRate` leaves the device at whatever rate it has (resampling if needed).
    func start(position p: Int, frame: AVAudioFramePosition, autoplay: Bool,
                       keepDeviceRate: Bool = false) async throws {
        generation += 1
        let gen = generation
        playID += 1
        let id = playID
        let item = queue.order[p]
        let url = queue.items[item]
        let wasPlaying = state == .playing
        ticker?.cancel()
        state = .preparing

        do {
            let file = try AVAudioFile(forReading: url)
            let device = try resolveDevice()
            Self.log.debug("[\(id)] open \(url.lastPathComponent, privacy: .public): \(file.fileFormat, privacy: .public), \(file.length) frames")

            if autoplay, wasPlaying, canSwapInPlace(file: file, device: device, keepDeviceRate: keepDeviceRate) {
                do {
                    try swapInPlace(file: file, item: item, frame: frame)
                    queue.move(toPosition: p)
                    finishStart(file: file, url: url, device: device, frame: frame, autoplay: true, id: id)
                    Self.log.debug("[\(id)] swapped in place; output kept running")
                    return
                } catch {
                    Self.log.notice("[\(id)] swap in place failed, setting up from scratch: \(error, privacy: .public)")
                }
            }

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
            finishStart(file: file, url: url, device: device, frame: frame, autoplay: autoplay, id: id)
        } catch {
            Self.log.error("[\(id)] play failed: \(error, privacy: .public)")
            if gen == generation { state = .stopped }
            throw error
        }
    }

    private func finishStart(file: AVAudioFile, url: URL, device: AudioDevice, frame: AVAudioFramePosition,
                             autoplay: Bool, id: Int) {
        duration = Self.time(file.length, file)
        lastKnownFrame = frame
        setPlayhead(Self.time(frame, file), force: true)
        signalPath = SignalPath(file: file, url: url, device: device, engine: engine)
        state = autoplay ? .playing : .paused
        if autoplay { startTicker() }
        if let signalPath { Self.log.info("[\(id)] \(signalPath.summary, privacy: .public)") }
    }

    /// Whether `file` can start on the running output without touching the device: same device,
    /// already at the rate the file needs (its own, or the fallback), same channel count, and
    /// hog mode as wanted. True for every track on a fixed-rate device such as Bluetooth speakers.
    private func canSwapInPlace(file: AVAudioFile, device: AudioDevice, keepDeviceRate: Bool) -> Bool {
        guard let output, output.isRunning, device == outputDevice, currentFile != nil,
              engine.isInManualRenderingMode, engine.isRunning,
              engine.manualRenderingFormat.channelCount == file.processingFormat.channelCount,
              hogMode == (device.hogModeOwner() == getpid()),
              let rate = try? device.nominalSampleRate(),
              FormatSelection.sameRate(rate, engine.manualRenderingFormat.sampleRate),
              FormatSelection.sameRate(rate, expectedDeviceRate)
        else { return false }
        if keepDeviceRate { return true }
        guard let ranges = try? device.availableNominalSampleRates(),
              let target = FormatSelection.fallbackRate(for: file.fileFormat.sampleRate, supported: ranges)
        else { return false }
        return FormatSelection.sameRate(target, rate)
    }

    /// Starts `file` while the output keeps running. A file in the current format is scheduled
    /// like a seek. Another format needs the player reconnected, which needs the engine stopped,
    /// so the output plays silence for those few milliseconds.
    private func swapInPlace(file: AVAudioFile, item: Int, frame: AVAudioFramePosition) throws {
        guard let output else { return }
        currentFile = file
        preloadedItem = nil
        preloadAttempted = false
        if file.processingFormat == node.outputFormat(forBus: 0) {
            scheduler.reset()
            currentNodeStart = 0
            scheduler.append(file, from: frame, token: item)
            try node.playAudio()
            return
        }
        output.hold()
        var renderBlock: AVAudioEngineManualRenderingBlock?
        defer { output.release(render: renderBlock.map { block in { frames, data in block(frames, data, nil) == .success } }) }
        scheduler.reset()
        engine.stop()
        Self.resetTimeline(engine)
        try? OutputUnit.setMaximumResamplingQuality(on: engine)
        try Self.connectBitPerfect(node, in: engine, format: file.processingFormat)
        currentNodeStart = 0
        scheduler.append(file, from: frame, token: item)
        engine.prepare()
        try engine.start()
        renderBlock = engine.manualRenderingBlock
        try node.playAudio()
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
        Self.resetTimeline(engine)

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

    static func time(_ frames: AVAudioFramePosition, _ file: AVAudioFile) -> Duration {
        .seconds(Double(frames) / file.processingFormat.sampleRate)
    }

    static func frames(_ time: Duration, _ file: AVAudioFile) -> AVAudioFramePosition {
        AVAudioFramePosition(time.seconds * file.processingFormat.sampleRate)
    }

    /// Puts the engine's render clock back to zero. Without this it keeps counting across a
    /// stop and start, and a player node reconnected at another sample rate waits for that
    /// clock to catch up: silence that grew with how long the engine had played (seconds,
    /// after a few minutes). Call with the engine stopped, before scheduling anything.
    static func resetTimeline(_ engine: AVAudioEngine) {
        engine.reset()
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

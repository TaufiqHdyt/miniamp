import Accelerate
import AudioToolbox
import AVFoundation
import CoreAudio
import os
import Synchronization

/// An AUHAL output unit that miniamp owns, bound to one device, pulling audio from a render block.
///
/// AVAudioEngine's own output node follows the system default device: when headphones are
/// unplugged it moves itself to the speakers and keeps playing. This unit plays only to the
/// device it was bound to. When that device disappears the AUHAL briefly rebinds to the default
/// device and keeps asking for audio, so output is muted from the HAL's notification threads the
/// moment the device is gone, before Player (on the main actor) gets to pause.
final class HALOutput: @unchecked Sendable {
    typealias RenderBlock = (AVAudioFrameCount, UnsafeMutablePointer<AudioBufferList>) -> Bool

    static let log = Logger(subsystem: "dev.miniamp", category: "output")
    static let maximumFrames: AVAudioFrameCount = 4096

    let unit: AudioUnit
    /// Read on the I/O thread. Only replaced while the unit is uninitialized or held.
    private var render: RenderBlock?
    private(set) var isRunning = false
    /// Set from HAL notification threads when the bound device is gone; read on the I/O thread.
    private let muted = Atomic<Bool>(false)
    /// The app volume's gain (Float bits), set from any thread. 1 leaves samples untouched.
    private let gainBits = Atomic<UInt32>(Float(1).bitPattern)
    /// The gain the last render ended at; only the I/O thread touches it.
    private var appliedGain: Float = 1
    /// Set while the engine behind the render block is rebuilt: the I/O thread outputs silence
    /// instead of rendering, and the device keeps running. `rendering` lets `hold` wait out a
    /// render already in progress.
    private let holding = Atomic<Bool>(false)
    private let rendering = Atomic<Bool>(false)
    private let boundDevice = Atomic<UInt32>(kAudioObjectUnknown)
    private var deviceWatch: [ListenerRegistration] = []

    init() throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CoreAudioError(status: kAudioUnitErr_InvalidElement, operation: "Find HAL output unit")
        }
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unit), "Create HAL output unit")
        self.unit = unit!

        // Output only: disable the input element so no microphone permission or input device is involved.
        try set(kAudioOutputUnitProperty_EnableIO, UInt32(0), scope: kAudioUnitScope_Input, element: 1, "Disable input")
        try set(kAudioOutputUnitProperty_EnableIO, UInt32(1), scope: kAudioUnitScope_Output, element: 0, "Enable output")
    }

    deinit {
        deviceWatch.forEach { $0.remove() }
        AudioUnitRemovePropertyListenerWithUserData(unit, kAudioOutputUnitProperty_CurrentDevice,
                                                    currentDeviceChanged, Unmanaged.passUnretained(self).toOpaque())
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    var currentDevice: AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, &size)
        return status == noErr ? id : nil
    }

    /// Binds the unit to `device` and sets everything about the stream. Stops the unit first.
    ///
    /// `format` is what the render block produces (deinterleaved Float32). When its rate differs
    /// from the device's, this unit's converter resamples at its best quality.
    func configure(device: AudioDevice, format: AVAudioFormat, channelMap: [Int32], render: @escaping RenderBlock) throws {
        stop()
        AudioUnitUninitialize(unit)
        self.render = nil

        try set(kAudioOutputUnitProperty_CurrentDevice, device.id, "Set output device \(device.name)")
        try withUnsafePointer(to: format.streamDescription.pointee) {
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, $0,
                                           UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                      "Set client format \(format)")
        }
        try set(kAudioUnitProperty_MaximumFramesPerSlice, UInt32(Self.maximumFrames), "Set maximum frames")
        try? set(kAudioUnitProperty_SampleRateConverterComplexity, kAudioUnitSampleRateConverterComplexity_Mastering,
                 "Set resampler complexity")
        try? set(kAudioUnitProperty_RenderQuality, UInt32(kRenderQuality_Max), "Set render quality")
        try channelMap.withUnsafeBytes {
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Global, 0,
                                           $0.baseAddress, UInt32($0.count)), "Set channel map \(channelMap)")
        }

        self.render = render
        var callback = AURenderCallbackStruct(inputProc: halRenderCallback,
                                              inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                       &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  "Set render callback")
        try check(AudioUnitInitialize(unit), "Initialize output unit")
        watch(device)
        Self.log.debug("bound to \(device.name, privacy: .public): \(format, privacy: .public), channel map \(channelMap, privacy: .public)")
    }

    func start() throws {
        guard !isRunning else { return }
        try check(AudioOutputUnitStart(unit), "Start output unit")
        isRunning = true
    }

    /// Outputs silence until `release`, without stopping the device. Returns once no render is
    /// in progress, so the engine can be stopped and rebuilt safely. Keeping the device running
    /// matters for Bluetooth: stopping it suspends the stream, and the speaker takes a moment
    /// to come back, cutting off the start of the next track.
    func hold() {
        holding.store(true, ordering: .sequentiallyConsistent)
        while rendering.load(ordering: .sequentiallyConsistent) { usleep(100) }
    }

    /// Ends a `hold`, optionally rendering from a new block from now on (the engine's render
    /// block may not survive the engine being stopped and started).
    func release(render newRender: RenderBlock? = nil) {
        if let newRender { render = newRender }
        holding.store(false, ordering: .sequentiallyConsistent)
    }

    func stop() {
        guard isRunning else { return }
        AudioOutputUnitStop(unit)
        isRunning = false
    }

    /// Mutes as soon as the bound device dies or the AUHAL moves off it. The notifications
    /// arrive on HAL threads, so this doesn't wait for the main actor.
    private func watch(_ device: AudioDevice) {
        deviceWatch.forEach { $0.remove() }
        boundDevice.store(device.id, ordering: .releasing)
        muted.store(false, ordering: .releasing)
        let id = device.id
        let check: @Sendable () -> Void = { [weak self] in
            let alive = (try? HAL.get(id, .init(kAudioDevicePropertyDeviceIsAlive), initial: UInt32(0))) ?? 0
            if alive == 0 { self?.mute("device \(id) is gone") }
        }
        deviceWatch = [
            ListenerRegistration(object: id, addresses: [.init(kAudioDevicePropertyDeviceIsAlive)], onChange: check),
            ListenerRegistration(object: AudioObjectID(kAudioObjectSystemObject),
                                 addresses: [.init(kAudioHardwarePropertyDevices)], onChange: check),
        ]
        let me = Unmanaged.passUnretained(self).toOpaque()
        AudioUnitRemovePropertyListenerWithUserData(unit, kAudioOutputUnitProperty_CurrentDevice, currentDeviceChanged, me)
        AudioUnitAddPropertyListener(unit, kAudioOutputUnitProperty_CurrentDevice, currentDeviceChanged, me)
    }

    fileprivate func currentDeviceDidChange() {
        let bound = boundDevice.load(ordering: .acquiring)
        if let current = currentDevice, current != bound { mute("output unit moved from \(bound) to \(current)") }
    }

    private func mute(_ reason: String) {
        guard !muted.exchange(true, ordering: .acquiringAndReleasing) else { return }
        Self.log.notice("muted: \(reason, privacy: .public)")
    }

    /// Render callbacks that delivered audio, for diagnostics (miniampctl leaktest).
    static let renderCalls = Atomic<Int>(0)
    /// Diagnostics only: when set, each render that delivers audio checks which device the unit
    /// is on, and counts those that weren't the bound device (audio that went somewhere else).
    static let verifyDeviceOnRender = Atomic<Bool>(false)
    static let misdirectedRenders = Atomic<Int>(0)

    /// Called on the I/O thread.
    fileprivate func renderInto(_ frames: UInt32, _ data: UnsafeMutablePointer<AudioBufferList>,
                                _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>) {
        if !muted.load(ordering: .acquiring) {
            // Announce the render before checking `holding`; `hold` sets it before checking
            // `rendering`. Either this sees the hold, or `hold` waits for this render.
            rendering.store(true, ordering: .sequentiallyConsistent)
            defer { rendering.store(false, ordering: .sequentiallyConsistent) }
            if !holding.load(ordering: .sequentiallyConsistent) {
                Self.renderCalls.add(1, ordering: .relaxed)
                if Self.verifyDeviceOnRender.load(ordering: .relaxed), currentDevice != boundDevice.load(ordering: .relaxed) {
                    Self.misdirectedRenders.add(1, ordering: .relaxed)
                }
                if let render, render(frames, data) {
                    let target = Float(bitPattern: gainBits.load(ordering: .relaxed))
                    Self.applyGain(from: appliedGain, to: target, data)
                    appliedGain = target
                    return
                }
            }
        }
        // Muted, held, no data, or a render error: output silence rather than whatever was in the buffers.
        for buffer in UnsafeMutableAudioBufferListPointer(data) {
            if let bytes = buffer.mData { memset(bytes, 0, Int(buffer.mDataByteSize)) }
        }
        flags.pointee.insert(.unitRenderAction_OutputIsSilence)
    }

    /// Scales what's rendered from now on: the app volume. Takes effect on the next render,
    /// ramped over it so a change doesn't click.
    func setGain(_ gain: Float) {
        gainBits.store(min(max(gain, 0), 1).bitPattern, ordering: .relaxed)
    }

    /// Sets the gain with no ramp, so the next render starts at it. Only while stopped: the
    /// gain the last render ended at belongs to the I/O thread.
    func resetGain(_ gain: Float) {
        precondition(!isRunning, "resetGain while the output is running")
        setGain(gain)
        appliedGain = min(max(gain, 0), 1)
    }

    /// Multiplies Float32 buffers by a gain going linearly from `start` to `end` across them.
    /// At 1 throughout, nothing is touched: the samples stay bit-for-bit what was rendered.
    static func applyGain(from start: Float, to end: Float, _ data: UnsafeMutablePointer<AudioBufferList>) {
        guard start != 1 || end != 1 else { return }
        for buffer in UnsafeMutableAudioBufferListPointer(data) {
            guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            if start == end {
                var gain = end
                vDSP_vsmul(samples, 1, &gain, samples, 1, vDSP_Length(count))
            } else {
                var gain = start
                var step = (end - start) / Float(count)
                vDSP_vrampmul(samples, 1, &gain, &step, samples, 1, vDSP_Length(count))
            }
        }
    }

    private func set<T>(_ property: AudioUnitPropertyID, _ value: T, scope: AudioUnitScope = kAudioUnitScope_Global,
                        element: AudioUnitElement = 0, _ operation: @autoclosure () -> String) throws {
        let status = withUnsafeBytes(of: value) {
            AudioUnitSetProperty(unit, property, scope, element, $0.baseAddress, UInt32($0.count))
        }
        try check(status, operation())
    }
}

private func halRenderCallback(
    refCon: UnsafeMutableRawPointer,
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timestamp: UnsafePointer<AudioTimeStamp>,
    bus: UInt32,
    frames: UInt32,
    data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let data else { return noErr }
    Unmanaged<HALOutput>.fromOpaque(refCon).takeUnretainedValue().renderInto(frames, data, flags)
    return noErr
}

private func currentDeviceChanged(refCon: UnsafeMutableRawPointer, unit: AudioUnit, property: AudioUnitPropertyID,
                                  scope: AudioUnitScope, element: AudioUnitElement) {
    Unmanaged<HALOutput>.fromOpaque(refCon).takeUnretainedValue().currentDeviceDidChange()
}

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
    /// Read on the I/O thread. Only replaced while the unit is uninitialized (not rendering).
    private var render: RenderBlock?
    private(set) var isRunning = false
    /// Set from HAL notification threads when the bound device is gone; read on the I/O thread.
    private let muted = Atomic<Bool>(false)
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
            Self.renderCalls.add(1, ordering: .relaxed)
            if Self.verifyDeviceOnRender.load(ordering: .relaxed), currentDevice != boundDevice.load(ordering: .relaxed) {
                Self.misdirectedRenders.add(1, ordering: .relaxed)
            }
            if let render, render(frames, data) { return }
        }
        // Muted, no data, or a render error: output silence rather than whatever was in the buffers.
        for buffer in UnsafeMutableAudioBufferListPointer(data) {
            if let bytes = buffer.mData { memset(bytes, 0, Int(buffer.mDataByteSize)) }
        }
        flags.pointee.insert(.unitRenderAction_OutputIsSilence)
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

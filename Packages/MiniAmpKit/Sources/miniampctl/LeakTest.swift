import CoreAudio
import Foundation
import MiniAmpKit

/// Simulates unplugging the output device mid-playback and measures whether audio escapes to
/// the fallback device (the speakers) before the player pauses.
///
/// A private aggregate device wrapping the default output stands in for headphones. Destroying
/// it is what the HAL does when headphones are pulled. Core Audio's per-process
/// kAudioDevicePropertyDeviceIsRunning on the real device then shows whether this process is
/// driving it, sampled every millisecond on a background thread.
@MainActor
func leakTest(_ path: String) async throws {
    let real = try AudioDevice.defaultOutput()
    let aggregateUID = "dev.miniamp.leaktest.\(getpid())"
    let description: [String: Any] = [
        kAudioAggregateDeviceUIDKey: aggregateUID,
        kAudioAggregateDeviceNameKey: "miniamp leak test",
        kAudioAggregateDeviceIsPrivateKey: 1,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: real.uid]],
        kAudioAggregateDeviceMainSubDeviceKey: real.uid,
    ]
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    var status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
    guard status == noErr else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "create aggregate"])
    }
    var destroyed = false
    defer { if !destroyed { AudioHardwareDestroyAggregateDevice(aggregateID) } }
    try await Task.sleep(for: .milliseconds(500)) // let the HAL publish it

    Player.verifiesOutputDevice = true
    let player = Player()
    player.preferredDeviceUID = aggregateUID
    try await player.setQueue([URL(fileURLWithPath: path)])
    print("playing to: \(player.outputDevice?.name ?? "?"); real device: \(real.name)")
    let rendersBefore = Player.renderCallCount
    try await Task.sleep(for: .seconds(1))
    print("output render callbacks in the second before unplug: \(Player.renderCallCount - rendersBefore)")
    print("before unplug, \(real.name) running in this process: \(isRunningHere(real.id))")

    // Sample the real device from a background thread while the main actor handles the unplug.
    let sampler = RunningSampler(device: real.id)
    sampler.start()
    let misdirectedBefore = Player.misdirectedRenderCount
    let t0 = DispatchTime.now().uptimeNanoseconds
    status = AudioHardwareDestroyAggregateDevice(aggregateID)
    destroyed = true
    print("unplugged (destroy aggregate: \(status))")

    var leftPlaying: Double?
    while DispatchTime.now().uptimeNanoseconds - t0 < 2_000_000_000 {
        if leftPlaying == nil, player.state != .playing {
            leftPlaying = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    let samples = sampler.stop()
    let stoppedAt = leftPlaying ?? .infinity
    let runningWhilePlaying = samples.filter { $0.running && $0.ms < stoppedAt }
    let runningAfter = samples.filter { $0.running && $0.ms >= stoppedAt }

    print(String(format: "player left .playing after %.0f ms (state now: \(player.state))", stoppedAt))
    print("\(real.name) running in this process while player was still playing: \(runningWhilePlaying.count) ms"
          + (runningWhilePlaying.first.map { String(format: " (from %.0f ms)", $0.ms) } ?? ""))
    print("\(real.name) running after player paused: \(runningAfter.count) ms (expected 0 for a paused player)")
    let rendersAtUnplug = samples.first?.renders ?? 0
    let rendersWhilePlaying = (samples.last(where: { $0.ms < stoppedAt })?.renders ?? rendersAtUnplug) - rendersAtUnplug
    let rendersAfterPause = (samples.last?.renders ?? 0) - (samples.last(where: { $0.ms < stoppedAt })?.renders ?? rendersAtUnplug)
    print("output render callbacks after unplug: \(rendersWhilePlaying) while still playing, \(rendersAfterPause) after pausing")
    let misdirected = Player.misdirectedRenderCount - misdirectedBefore
    print("renders that delivered audio to a device other than the bound one: \(misdirected)")
    print("player is now on: \(player.outputDevice?.name ?? "?"), position \(player.position)")
    // Audio reaches another device only if the output unit renders while it's on that device.
    // A render or two can still go to the dying aggregate, and the real device can briefly run
    // (the unit rebinding, muted, or the aggregate's teardown); neither is audible.
    let leaked = misdirected > 0 || rendersAfterPause > 0
    print(leaked ? "RESULT: LEAK (output kept rendering after its device was removed)" : "RESULT: no leak")
    player.stop()
}

private func isRunningHere(_ id: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunning,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr && value != 0
}

/// Polls a device's per-process running state every millisecond on its own thread.
private final class RunningSampler: @unchecked Sendable {
    struct Sample { let ms: Double; let running: Bool; let renders: Int }
    private let device: AudioObjectID
    private let lock = NSLock()
    private var samples: [Sample] = []
    private var done = false
    private var thread: Thread?

    init(device: AudioObjectID) { self.device = device }

    func start() {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let thread = Thread { [self] in
            while true {
                lock.lock(); let stop = done; lock.unlock()
                if stop { return }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                let running = isRunningHere(device)
                let renders = Player.renderCallCount
                lock.lock(); samples.append(Sample(ms: ms, running: running, renders: renders)); lock.unlock()
                usleep(1_000)
            }
        }
        self.thread = thread
        thread.start()
    }

    func stop() -> [Sample] {
        lock.lock(); done = true; let result = samples; lock.unlock()
        return result
    }
}

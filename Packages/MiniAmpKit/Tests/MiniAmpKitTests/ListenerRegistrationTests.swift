import CoreAudio
import Foundation
import Synchronization
import Testing
@testable import MiniAmpKit

/// HAL listeners must actually go away when removed. With the block API they never did, so
/// stale watchers piled up and fired for devices that no longer existed.
@Suite struct ListenerRegistrationTests {
    @Test func removedListenerStopsFiring() async throws {
        let fired = Atomic<Int>(0)
        let reg = ListenerRegistration(object: AudioObjectID(kAudioObjectSystemObject),
                                       addresses: [.init(kAudioHardwarePropertyDevices)]) { fired.add(1, ordering: .relaxed) }
        /// Adds and removes a private aggregate device, which changes the system's device list.
        func churn() async throws {
            let uid = "dev.miniamp.test.\(UUID().uuidString)"
            let desc: [String: Any] = [kAudioAggregateDeviceUIDKey: uid, kAudioAggregateDeviceNameKey: "miniamp listener test",
                                       kAudioAggregateDeviceIsPrivateKey: 1]
            var id = AudioObjectID(0)
            #expect(AudioHardwareCreateAggregateDevice(desc as CFDictionary, &id) == noErr)
            try await Task.sleep(for: .milliseconds(300))
            AudioHardwareDestroyAggregateDevice(id)
            try await Task.sleep(for: .milliseconds(300))
        }
        try await churn()
        let before = fired.load(ordering: .relaxed)
        reg.remove()
        try await churn()
        let after = fired.load(ordering: .relaxed)
        #expect(before > 0)
        #expect(after == before)
    }
}

import CoreAudio
import Foundation
import Synchronization

public struct CoreAudioError: Error, CustomStringConvertible, Sendable {
    public let status: OSStatus
    public let operation: String

    public var description: String {
        let code = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let fourCC = bytes.allSatisfy { (0x20...0x7E).contains($0) }
            ? "'\(String(decoding: bytes, as: UTF8.self))'" : "\(status)"
        return "\(operation) failed (\(fourCC))"
    }
}

public struct TimeoutError: Error, CustomStringConvertible, Sendable {
    public let operation: String
    public var description: String { "Timed out waiting for \(operation)" }
}

func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation()) }
}

extension AudioObjectPropertyAddress {
    init(_ selector: AudioObjectPropertySelector,
         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) {
        self.init(mSelector: selector, mScope: scope, mElement: element)
    }
}

/// Thin typed wrappers over AudioObjectGet/SetPropertyData.
enum HAL {
    static func get<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T) throws -> T {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
        }
        try check(status, "Get property \(address.mSelector)")
        return value
    }

    static func getArray<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, of _: T.Type) throws -> [T] {
        var address = address
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size),
                  "Get property size \(address.mSelector)")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer),
                  "Get property \(address.mSelector)")
        let typed = buffer.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func getString(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> String {
        var address = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value),
                  "Get property \(address.mSelector)")
        return (value?.takeRetainedValue() as String?) ?? ""
    }

    static func set<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) throws {
        var address = address
        let status = withUnsafeBytes(of: value) {
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32($0.count), $0.baseAddress!)
        }
        try check(status, "Set property \(address.mSelector)")
    }

    /// Runs `change`, then waits until the HAL reports `address` changed and `isDone` holds.
    /// The listener is installed before `change` runs, so a fast notification isn't missed.
    static func change(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        timeout: Duration,
        operation: String,
        until isDone: @escaping @Sendable () -> Bool,
        _ change: () throws -> Void
    ) async throws {
        let (events, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let registration = ListenerRegistration(object: object, addresses: [address]) { continuation.yield() }
        defer {
            registration.remove()
            continuation.finish()
        }
        guard registration.isRegistered else {
            throw CoreAudioError(status: kAudioHardwareUnknownPropertyError, operation: "Add listener for \(operation)")
        }

        if isDone() { return }
        try change()
        if isDone() { return }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in events where isDone() { return }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimeoutError(operation: operation)
            }
            try await group.next()
            group.cancelAll()
        }
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    /// Yields whenever any of `addresses` changes on `object`. The listeners are removed when
    /// the consuming task stops iterating.
    static func changes(_ object: AudioObjectID, _ addresses: [AudioObjectPropertyAddress]) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let registration = ListenerRegistration(object: object, addresses: addresses) {
                continuation.yield()
            }
            continuation.onTermination = { _ in registration.remove() }
        }
    }
}

/// Owns a set of HAL property listeners so they can be removed from any thread.
///
/// Uses the function-pointer API rather than AudioObjectAddPropertyListenerBlock: a Swift
/// closure passed as a block is bridged to a new block object on each call, so the remove call
/// never matched what was added and every listener stayed installed for the life of the process.
final class ListenerRegistration: @unchecked Sendable {
    /// The listener's context. Retained while registered; released a little after removal,
    /// so a notification already in flight on a HAL thread never sees freed memory.
    private final class Context: @unchecked Sendable {
        let onChange: @Sendable () -> Void
        let removed = Atomic<Bool>(false)
        init(_ onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    }

    private let object: AudioObjectID
    private let registered: [AudioObjectPropertyAddress]
    private let context: Context
    private let pointer: UnsafeMutableRawPointer

    init(object: AudioObjectID, addresses: [AudioObjectPropertyAddress], onChange: @escaping @Sendable () -> Void) {
        self.object = object
        context = Context(onChange)
        pointer = Unmanaged.passRetained(context).toOpaque()
        let pointer = pointer
        registered = addresses.filter { address in
            var address = address
            return AudioObjectAddPropertyListener(object, &address, halListener, pointer) == noErr
        }
    }

    var isRegistered: Bool { !registered.isEmpty }

    /// Idempotent.
    func remove() {
        guard !context.removed.exchange(true, ordering: .acquiringAndReleasing) else { return }
        for address in registered {
            var address = address
            AudioObjectRemovePropertyListener(object, &address, halListener, pointer)
        }
        let pointer = UInt(bitPattern: pointer)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            Unmanaged<Context>.fromOpaque(UnsafeRawPointer(bitPattern: pointer)!).release()
        }
    }

    deinit { remove() }

    fileprivate static func deliver(_ pointer: UnsafeMutableRawPointer) {
        let context = Unmanaged<Context>.fromOpaque(pointer).takeUnretainedValue()
        if !context.removed.load(ordering: .acquiring) { context.onChange() }
    }
}

private func halListener(_ object: AudioObjectID, _ count: UInt32, _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
                         _ context: UnsafeMutableRawPointer?) -> OSStatus {
    if let context { ListenerRegistration.deliver(context) }
    return noErr
}

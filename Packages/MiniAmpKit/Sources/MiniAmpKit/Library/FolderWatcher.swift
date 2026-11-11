import CoreServices
import Foundation
import os

/// Reports which paths changed under a set of folders, using FSEvents with per-file events.
///
/// Events are coalesced for `latency` seconds, so copying an album in arrives as one batch
/// rather than one event per write. When FSEvents can't say exactly what changed (its buffer
/// overflowed, or the folder itself was moved), the batch asks for a full rescan of that root.
public final class FolderWatcher: @unchecked Sendable {
    public struct Batch: Sendable, Equatable {
        /// Changed files and directories, created, modified, renamed (both names), or removed.
        public var paths: Set<String> = []
        /// Roots whose contents should be rescanned in full.
        public var rescan: Set<String> = []
    }

    static let log = Logger(subsystem: "dev.miniamp", category: "watcher")

    public let roots: [String]
    private let onChange: @Sendable (Batch) -> Void
    private let queue = DispatchQueue(label: "dev.miniamp.folder-watcher")
    private static let onQueue = DispatchSpecificKey<Bool>()
    /// Touched only on `queue` (and in init/deinit).
    private var stream: FSEventStreamRef?

    /// Starts watching immediately. `roots` should be canonical paths (see `LibraryPaths.canonical`),
    /// since FSEvents reports paths that way. `onChange` runs on a private serial queue.
    public init(roots: [String], latency: TimeInterval = 1.0, onChange: @escaping @Sendable (Batch) -> Void) {
        self.roots = roots.map(LibraryPaths.normalized)
        self.onChange = onChange
        guard !roots.isEmpty else { return }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, fsEventsCallback, &context, roots as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else {
            Self.log.error("can't create an FSEvents stream for \(roots, privacy: .public)")
            return
        }
        self.stream = stream
        queue.setSpecific(key: Self.onQueue, value: true)
        FSEventStreamSetDispatchQueue(stream, queue)
        if !FSEventStreamStart(stream) {
            Self.log.error("can't start the FSEvents stream for \(roots, privacy: .public)")
        }
    }

    deinit { invalidate() }

    /// Stops delivery. Blocks until any callback in progress has returned.
    public func invalidate() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        // Drain: a callback that already started finishes before this returns (unless this is it).
        if DispatchQueue.getSpecific(key: Self.onQueue) == nil { queue.sync {} }
    }

    fileprivate func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        var batch = Batch()
        for (path, flag) in zip(paths, flags) {
            let path = LibraryPaths.normalized(path)
            let flag = Int(flag)
            if flag & kFSEventStreamEventFlagHistoryDone != 0 { continue }
            let root = roots.first { path == $0 || path.hasPrefix($0 + "/") }
                ?? roots.first { $0.hasPrefix(path + "/") || $0 == path } // RootChanged reports the root (or a parent)
            guard let root else { continue }
            if flag & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0 {
                batch.rescan.insert(root)
            } else {
                batch.paths.insert(path)
            }
        }
        // Paths under a root that's being rescanned anyway add nothing.
        batch.paths = batch.paths.filter { path in !batch.rescan.contains { path == $0 || path.hasPrefix($0 + "/") } }
        guard !batch.paths.isEmpty || !batch.rescan.isEmpty else { return }
        Self.log.debug("changed: \(batch.paths.count) paths, rescan \(batch.rescan, privacy: .public)")
        onChange(batch)
    }
}

private func fsEventsCallback(_ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int,
                              _ paths: UnsafeMutableRawPointer, _ flags: UnsafePointer<FSEventStreamEventFlags>,
                              _ ids: UnsafePointer<FSEventStreamEventId>) {
    guard let info else { return }
    let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
    let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
    watcher.handle(paths: array, flags: Array(UnsafeBufferPointer(start: flags, count: count)))
}

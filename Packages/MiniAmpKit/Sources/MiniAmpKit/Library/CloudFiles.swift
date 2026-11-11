import Darwin
import Foundation

/// Files whose data lives only in the cloud: iCloud Drive with "Optimize Mac Storage", or any
/// other File Provider (Dropbox, OneDrive, Google Drive) that offloads files. The file is still
/// listed with its real name and size, but reading it starts a download.
///
/// The scanner never triggers those downloads: a library scan shouldn't pull gigabytes from the
/// network, and a read that waits on a download would stall the scan.
public enum CloudFiles {
    /// `SF_DATALESS` from <sys/stat.h>: the file's contents aren't on this Mac.
    static let datalessFlag: UInt32 = 0x4000_0000

    /// True when the file's data isn't local. Checks the file's flags, which doesn't download anything.
    public static func isEvicted(_ path: String) -> Bool {
        var info = Darwin.stat()
        return lstat(path, &info) == 0 && info.st_flags & datalessFlag != 0
    }

    /// Runs `body` with downloads of offloaded files turned off for this thread, so a read of one
    /// fails at once instead of waiting for the network. `body` must not suspend (the policy
    /// belongs to the thread, and an async task can resume on another).
    static func withoutDownloading<R>(_ body: () throws -> R) rethrows -> R {
        let type = Int32(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES)
        let scope = Int32(IOPOL_SCOPE_THREAD)
        let previous = getiopolicy_np(type, scope)
        setiopolicy_np(type, scope, Int32(IOPOL_MATERIALIZE_DATALESS_FILES_OFF))
        defer { if previous >= 0 { setiopolicy_np(type, scope, previous) } }
        return try body()
    }

    /// Asks for the file to be downloaded, without waiting. When the data arrives FSEvents reports
    /// the change, and the library reads the file's tags.
    public static func startDownloading(_ url: URL) {
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            // Not an iCloud item (another File Provider): reading from it downloads it.
            Task.detached(priority: .utility) {
                let handle = try? FileHandle(forReadingFrom: url)
                _ = try? handle?.read(upToCount: 1)
                try? handle?.close()
            }
        }
    }
}

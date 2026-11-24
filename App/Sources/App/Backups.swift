import AppKit
import MiniAmpKit
import os
import UniformTypeIdentifiers

/// File menu and Finder actions for library backups.
///
/// A restore replaces the database under a running library (its folders, watchers, and
/// playback all depend on it), so it isn't done in place: the backup is copied into the app's
/// container, the app relaunches, and the copy is restored before the library opens.
@MainActor
enum Backups {
    static let log = Logger(subsystem: "dev.miniamp", category: "backup")
    static var contentType: UTType { UTType(exportedAs: "dev.miniamp.library-backup", conformingTo: .data) }

    /// Where a backup waits for the relaunch that restores it.
    static var pendingRestoreURL: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("miniamp/restore.\(LibraryBackup.fileExtension)")
    }

    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }

    // MARK: Back up

    static func backUp(_ app: AppState) {
        guard let library = app.library else { return }
        let panel = NSSavePanel()
        panel.title = "Back Up Library"
        panel.message = "Saves the library, playlists, play history, and settings. Your music files aren't included."
        panel.nameFieldStringValue = "miniamp \(Date().formatted(.iso8601.year().month().day())).\(LibraryBackup.fileExtension)"
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Property-list values only (strings, numbers, data, arrays, dictionaries), read once here.
        nonisolated(unsafe) let settings = Preferences.exportable()
        let database = library.database
        let version = appVersion
        app.perform {
            try await Task.detached(priority: .userInitiated) {
                try LibraryBackup.write(database, settings: settings, appVersion: version, to: url)
            }.value
            log.notice("backed up to \(url.path, privacy: .private)")
        }
    }

    // MARK: Restore

    static func chooseBackup(_ app: AppState) {
        let panel = NSOpenPanel()
        panel.title = "Open miniamp Backup"
        panel.allowedContentTypes = [contentType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url, in: app)
    }

    static func open(_ url: URL, in app: AppState) {
        guard url.isFileURL, url.pathExtension.lowercased() == LibraryBackup.fileExtension,
              let library = app.library else { return }
        app.perform {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let info = try await Task.detached(priority: .userInitiated) {
                try readBackup(at: url) { try LibraryBackup.info(of: $0) }
            }.value

            let canRestore = UserDefaults.standard.string(forKey: "libraryDatabase") == nil
            let alert = NSAlert()
            alert.messageText = "Open backup from \(info.createdAt.formatted(date: .long, time: .shortened))"
            let summary = "This backup has \(info.tracks) songs, \(info.playlists) playlists, and \(info.plays) plays."
            alert.informativeText = summary + " Merge Listening Stats imports plays for songs already in your library."
            alert.addButton(withTitle: "Merge Listening Stats")
            alert.addButton(withTitle: "Cancel")
            if canRestore { alert.addButton(withTitle: "Restore Library…") }
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let database = library.database
                let result = try await Task.detached(priority: .userInitiated) {
                    try readBackup(at: url) { try LibraryBackup.mergePlayHistory(from: $0, into: database) }
                }.value
                app.playHistoryRevision += 1
                let completed = NSAlert()
                completed.messageText = "Listening Stats Merged"
                completed.informativeText = "Added \(result.added) plays and updated \(result.updated). Plays without a unique local match: \(result.unmatched)."
                if result.unmatched > 0 {
                    completed.informativeText += " Add the missing music to this Mac’s library and open the backup again."
                }
                completed.runModal()
            case .alertThirdButtonReturn where canRestore:
                try await confirmRestore(url, info: info, app: app)
            default:
                break
            }
        }
    }

    private static func confirmRestore(_ url: URL, info: LibraryBackup.Info, app: AppState) async throws {
        let alert = NSAlert()
        alert.messageText = "Restore the library from \(info.createdAt.formatted(date: .long, time: .shortened))?"
        alert.informativeText = """
            The backup has \(info.tracks) songs, \(info.playlists) playlists, and \(info.plays) plays. It replaces \
            the library, playlists, play history, and settings you have now. miniamp restarts to restore it.
            """
        alert.addButton(withTitle: "Restore and Restart")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let pending = pendingRestoreURL else { return }
        try await Task.detached(priority: .userInitiated) {
            try readBackup(at: url) { readable in
                if FileManager.default.fileExists(atPath: pending.path) {
                    try FileManager.default.removeItem(at: pending)
                }
                try FileManager.default.copyItem(at: readable, to: pending)
            }
        }.value
        app.player.stop()
        relaunch()
    }

    /// Coordinates with iCloud Drive so the backup is available before SQLite opens it.
    private nonisolated static func readBackup<T>(at url: URL, _ read: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            result = Result { try read(readable) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    private static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error { log.error("relaunch: \(error, privacy: .public)") }
                NSApp.terminate(nil)
            }
        }
    }

    /// At launch, before the library opens: restores a backup left by the restore confirmation. Returns
    /// a message for the user if it couldn't.
    static func restorePending(into database: AppDatabase, artwork: ArtworkCache?) -> String? {
        guard let pending = pendingRestoreURL, FileManager.default.fileExists(atPath: pending.path) else { return nil }
        defer { try? FileManager.default.removeItem(at: pending) }
        // The instance that asked for this may still be quitting.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").count > 1 {
            Thread.sleep(forTimeInterval: 0.1)
        }
        do {
            let settings = try LibraryBackup.restore(from: pending, into: database, artwork: artwork)
            Preferences.importSettings(settings)
            log.notice("restored a backup")
            return nil
        } catch {
            log.error("restore: \(error, privacy: .public)")
            return "The backup couldn't be restored: \(error)"
        }
    }
}

import AppKit
import MiniAmpKit
import os
import UniformTypeIdentifiers

/// File › Back Up Library… and Restore from Backup….
///
/// A restore replaces the database under a running library (its folders, watchers, and
/// playback all depend on it), so it isn't done in place: the backup is copied into the app's
/// container, the app relaunches, and the copy is restored before the library opens.
@MainActor
enum Backups {
    static let log = Logger(subsystem: "dev.miniamp", category: "backup")
    static var contentType: UTType { UTType(filenameExtension: LibraryBackup.fileExtension, conformingTo: .data) ?? .data }

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

    static func chooseRestore(_ app: AppState) {
        let panel = NSOpenPanel()
        panel.title = "Restore from Backup"
        panel.allowedContentTypes = [contentType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let info: LibraryBackup.Info
        do { info = try LibraryBackup.info(of: url) } catch { return app.error = "\(error)" }

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

        do {
            guard let pending = pendingRestoreURL else { return }
            try? FileManager.default.removeItem(at: pending)
            try FileManager.default.copyItem(at: url, to: pending)
        } catch {
            return app.error = "Couldn't get the backup ready: \(error.localizedDescription)"
        }
        app.player.stop()
        relaunch()
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

    /// At launch, before the library opens: restores a backup left by `chooseRestore`. Returns
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

import AppKit
import MiniAmpKit
import SwiftUI
import UniformTypeIdentifiers

enum KeyboardSheet: String, Identifiable {
    case jump, time, commands, shortcuts, output
    var id: Self { self }
}

enum AppAction: String, CaseIterable, Identifiable {
    case previous = "Previous Track"
    case play = "Play, Resume, or Restart"
    case pause = "Pause or Resume"
    case playPause = "Play or Pause"
    case stop = "Stop"
    case next = "Next Track"
    case shuffle = "Toggle Shuffle"
    case repeatMode = "Cycle Repeat"
    case stopAfterTrack = "Stop After This Track"
    case jump = "Jump to Song…"
    case jumpTime = "Jump to Time…"
    case find = "Find in Library"
    case open = "Open Files…"
    case openFolder = "Play Folder…"
    case addFolder = "Add Music Folder…"
    case songs = "Songs"
    case queue = "Queue"
    case nowPlaying = "Now Playing"
    case lyrics = "Lyrics"
    case visualizer = "Visualizer"
    case volumeUp = "Volume Up"
    case volumeDown = "Volume Down"
    case mute = "Mute or Unmute"
    case output = "Audio Output…"
    case equalizer = "Equalizer…"
    case newPlaylist = "New Playlist"
    case stats = "Listening Stats"
    case duplicates = "Duplicates"
    case commands = "Find a Command…"
    case shortcuts = "Keyboard Shortcuts"

    var id: Self { self }

    var classicKey: String? {
        switch self {
        case .previous: "z"
        case .play: "x"
        case .pause: "c"
        case .stop: "v"
        case .next: "b"
        case .shuffle: "s"
        case .repeatMode: "r"
        case .jump: "j"
        case .open: "l"
        case .openFolder: "L"
        default: nil
        }
    }

    var shortcut: KeyboardShortcut? {
        switch self {
        case .previous: .init(.leftArrow)
        case .next: .init(.rightArrow)
        case .stop: .init(".")
        case .shuffle: .init("s", modifiers: [.command, .option])
        case .repeatMode: .init("r", modifiers: [.command, .option])
        case .stopAfterTrack: .init("v", modifiers: .control)
        case .jump: .init("j", modifiers: [.command, .shift])
        case .jumpTime: .init("j")
        case .find: .init("f")
        case .open: .init("o")
        case .openFolder: .init("o", modifiers: [.command, .option])
        case .addFolder: .init("o", modifiers: [.command, .shift])
        case .songs: .init("1")
        case .queue: .init("2")
        case .nowPlaying: .init("3")
        case .lyrics: .init("l", modifiers: [.command, .option])
        case .visualizer: .init("v", modifiers: [.command, .option, .shift])
        case .volumeUp: .init(.upArrow)
        case .volumeDown: .init(.downArrow)
        case .mute: .init(.downArrow, modifiers: [.command, .option])
        case .equalizer: .init("e", modifiers: [.command, .option])
        case .newPlaylist: .init("n")
        case .commands: .init("p", modifiers: [.command, .shift])
        case .shortcuts: .init("/", modifiers: [.command, .option])
        default: nil
        }
    }

    var windowKey: Bool {
        switch self {
        case .previous, .next, .volumeUp, .volumeDown, .mute, .stopAfterTrack: true
        default: false
        }
    }

    func keys(classic: Bool) -> String {
        var keys: [String] = []
        if classic, let classicKey {
            keys.append(self == .openFolder ? "⇧L" : classicKey.uppercased())
        }
        if let shortcut {
            let modifiers = shortcut.modifiers
            let prefix = (modifiers.contains(.control) ? "⌃" : "")
                + (modifiers.contains(.option) ? "⌥" : "")
                + (modifiers.contains(.shift) ? "⇧" : "")
                + (modifiers.contains(.command) ? "⌘" : "")
            let key: String = switch shortcut.key {
            case .upArrow: "↑"
            case .downArrow: "↓"
            case .leftArrow: "←"
            case .rightArrow: "→"
            default: String(shortcut.key.character).uppercased()
            }
            keys.append(prefix + key)
        }
        if self == .playPause { keys.append("Space") }
        if self == .shortcuts { keys.insert("?", at: 0) }
        return keys.joined(separator: " / ")
    }

    @MainActor
    func isEnabled(in app: AppState) -> Bool {
        let player = app.player
        return switch self {
        case .play, .playPause, .previous, .next: !player.queue.isEmpty
        case .pause, .jumpTime: player.state == .playing || player.state == .paused
        case .stop: player.state != .stopped
        case .stopAfterTrack: player.state == .playing || player.state == .paused || app.sleepTimer.mode == .endOfTrack
        case .lyrics, .visualizer, .nowPlaying: app.currentURL != nil
        case .volumeUp: !player.isSendingDoP && player.appVolume < 1
        case .volumeDown: !player.isSendingDoP && player.appVolume > 0
        case .mute: !player.isSendingDoP
        case .find, .addFolder, .newPlaylist, .stats, .duplicates: app.library != nil
        case .jump: app.library != nil || !player.queue.isEmpty
        default: true
        }
    }
}

extension AppState {
    func run(_ action: AppAction) {
        guard action.isEnabled(in: self) else { return }
        let player = player
        switch action {
        case .previous: perform { try await player.previous() }
        case .play:
            if player.state == .playing { player.seek(to: .zero) }
            else { perform { try await player.togglePlayPause() } }
        case .pause, .playPause: perform { try await player.togglePlayPause() }
        case .stop: player.stop()
        case .next: perform { try await player.next() }
        case .shuffle: player.setShuffle(!player.isShuffled)
        case .repeatMode: player.repeatMode = player.repeatMode.next
        case .stopAfterTrack:
            if sleepTimer.mode == .endOfTrack { sleepTimer.cancel() }
            else { sleepTimer.stopAtEndOfTrack() }
        case .jump: keyboardSheet = .jump
        case .jumpTime: keyboardSheet = .time
        case .find:
            showFullView(nil, focus: false)
            searchFocusRequests += 1
        case .open: importingFiles = true
        case .openFolder: playFolder()
        case .addFolder: addingFolder = true
        case .songs: sidebarRequest = .songs
        case .queue: showFullView(.upNext)
        case .nowPlaying: toggleNowPlaying()
        case .lyrics: toggleFullLyrics()
        case .visualizer: toggleVisualizer()
        case .volumeUp: changeVolume(by: 0.0625)
        case .volumeDown: changeVolume(by: -0.0625)
        case .mute: toggleMute()
        case .output: keyboardSheet = .output
        case .equalizer: equalizerRequests += 1
        case .newPlaylist: newPlaylist()
        case .stats: sidebarRequest = .stats
        case .duplicates: sidebarRequest = .duplicates
        case .commands: keyboardSheet = .commands
        case .shortcuts: keyboardSheet = .shortcuts
        }
    }

    func changeVolume(by amount: Float) {
        guard !player.isSendingDoP else { return }
        player.appVolume = min(max(player.appVolume + amount, 0), 1)
    }

    private func playFolder() {
        let panel = NSOpenPanel()
        panel.title = "Play Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let folder = panel.url else { return }
            self.perform {
                let scoped = folder.startAccessingSecurityScopedResource()
                defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                let urls = await Task.detached(priority: .userInitiated) { Self.audioFiles(in: folder) }.value
                guard !urls.isEmpty else {
                    self.error = "No playable audio files were found in this folder."
                    return
                }
                // Keep the folder's security scope while the queued descendants are in use.
                try await self.player.setQueue(urls, accessFolder: folder)
            }
        }
    }

    nonisolated private static func audioFiles(in folder: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentTypeKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys),
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var audio: [URL] = []
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            if values.contentType?.conforms(to: .audio) == true
                || DSDFile.fileExtensions.contains(url.pathExtension.lowercased()) {
                audio.append(url)
            }
        }
        return audio.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

/// Bare Winamp keys are local to the main player window. Editors and panels keep their own keys.
struct WindowKeyboard: NSViewRepresentable {
    let app: AppState

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view, weak coordinator] event in
            guard let window = view?.window, event.window === window, window.attachedSheet == nil else { return event }
            return coordinator?.handle(event, editingText: window.firstResponder is NSText) == true ? nil : event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.app = app
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    @MainActor
    final class Coordinator {
        weak var app: AppState?
        var monitor: Any?

        func handle(_ event: NSEvent, editingText: Bool) -> Bool {
            guard let app, let key = event.charactersIgnoringModifiers else { return false }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if (key == "\t" || key == "\u{19}"), modifiers.subtracting([.control, .shift]).isEmpty {
                return true
            }
            guard !editingText else { return false }
            if key == " ", modifiers.isEmpty {
                if !event.isARepeat { app.run(.playPause) }
                return true
            }
            if modifiers == .command || modifiers == [.command, .option] || modifiers == .control {
                let action: AppAction?
                switch (key, modifiers) {
                case ("\u{F702}", .command): action = .previous
                case ("\u{F703}", .command): action = .next
                case ("\u{F700}", .command): action = .volumeUp
                case ("\u{F701}", .command): action = .volumeDown
                case ("\u{F701}", [.command, .option]): action = .mute
                case ("v", .control): action = .stopAfterTrack
                case ("i", [.command, .option]): action = .queue
                case ("\u{F702}", [.command, .option]), ("\u{F703}", [.command, .option]):
                    app.skip(by: key == "\u{F702}" ? -AppState.skipStep : AppState.skipStep)
                    return true
                default: action = nil
                }
                if let action {
                    if !event.isARepeat || action == .volumeUp || action == .volumeDown { app.run(action) }
                    return true
                }
            }
            if app.winampShortcuts, modifiers.isEmpty, event.modifierFlags.contains(.numericPad) {
                let action: AppAction?
                switch key {
                case "0": action = .open
                case "2": action = .volumeDown
                case "4": action = .previous
                case "5": action = .play
                case "6": action = .next
                case "8": action = .volumeUp
                case ".", ",": action = .jump
                case "7", "9":
                    app.skip(by: key == "7" ? -5 : 5)
                    return true
                default: action = nil
                }
                if let action {
                    if !event.isARepeat || action == .volumeUp || action == .volumeDown { app.run(action) }
                    return true
                }
            }
            guard modifiers.isEmpty || modifiers == .shift else { return false }
            let action: AppAction?
            if event.characters == "?" {
                action = .shortcuts
            } else if app.winampShortcuts {
                let character = modifiers == .shift ? key.uppercased() : key.lowercased()
                action = AppAction.allCases.first { $0.classicKey == character }
                if modifiers == .shift && action != .openFolder { return false }
            } else {
                return false
            }
            guard let action else { return false }
            if !event.isARepeat { app.run(action) }
            return true
        }
    }
}

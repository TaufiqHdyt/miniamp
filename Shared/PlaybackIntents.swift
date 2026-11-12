import AppIntents

/// What the widget's buttons ask for.
enum PlaybackCommand: Sendable {
    case togglePlayPause, next, previous
}

/// Set by the app; the intents below run in its process (they're audio playback intents),
/// so in the widget's own process there's nothing to call and they do nothing.
@MainActor
enum PlaybackCommands {
    static var handle: ((PlaybackCommand) async -> Void)?
}

struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Plays or pauses miniamp.")

    @MainActor
    func perform() async throws -> some IntentResult {
        await PlaybackCommands.handle?(.togglePlayPause)
        return .result()
    }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Song"

    @MainActor
    func perform() async throws -> some IntentResult {
        await PlaybackCommands.handle?(.next)
        return .result()
    }
}

struct PreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Song"

    @MainActor
    func perform() async throws -> some IntentResult {
        await PlaybackCommands.handle?(.previous)
        return .result()
    }
}

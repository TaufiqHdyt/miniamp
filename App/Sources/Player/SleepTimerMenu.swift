import MiniAmpKit
import SwiftUI

/// The sleep timer's choices, shared by the Controls menu and the player bar.
struct SleepTimerChoices: View {
    let timer: SleepTimer

    static let minutes = [15, 30, 45, 60, 90, 120]

    var body: some View {
        Button("Off") { timer.cancel() }
            .disabled(!timer.isActive)
        Divider()
        ForEach(Self.minutes, id: \.self) { minutes in
            Button(Self.label(minutes)) { timer.start(.seconds(minutes * 60)) }
        }
        Divider()
        Toggle("End of Current Song", isOn: Binding(get: { timer.mode == .endOfTrack }, set: { on in
            if on { timer.stopAtEndOfTrack() } else { timer.cancel() }
        }))
    }

    static func label(_ minutes: Int) -> String {
        switch minutes {
        case 60: "1 Hour"
        case 120: "2 Hours"
        case let m where m % 60 == 0: "\(m / 60) Hours"
        default: "\(minutes) Minutes"
        }
    }
}

/// A moon in the player bar: lit, with the time left, while a timer is set.
struct SleepTimerButton: View {
    let timer: SleepTimer

    var body: some View {
        Menu {
            SleepTimerChoices(timer: timer)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: timer.isActive ? "moon.zzz.fill" : "moon.zzz")
                switch timer.mode {
                case .until(let deadline):
                    // Counts down by itself, without re-rendering anything else.
                    Text(timerInterval: Date()...max(deadline, Date()), countsDown: true)
                        .monospacedDigit()
                        .font(.caption)
                case .endOfTrack:
                    Text("End of song").font(.caption)
                case .off:
                    EmptyView()
                }
            }
            .foregroundStyle(timer.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }

    private var help: String {
        switch timer.mode {
        case .off: "Sleep timer"
        case .until(let deadline): "Pauses at \(deadline.formatted(date: .omitted, time: .shortened))"
        case .endOfTrack: "Stops at the end of this song"
        }
    }
}

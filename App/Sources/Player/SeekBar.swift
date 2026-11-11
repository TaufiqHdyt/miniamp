import MiniAmpKit
import SwiftUI

/// A thin progress line, as in Apple Music. Hovering thickens it and shows the elapsed time
/// and the length on either side; click or drag anywhere on it to seek.
///
/// The only view that reads `player.position`, so a position change re-renders just this.
struct SeekBar: View {
    let player: Player
    /// Where a drag is, 0...1; nil follows the player.
    @State private var scrub: Double?
    @State private var hovering = false

    var body: some View {
        let total = player.duration.seconds
        let active = (player.state == .playing || player.state == .paused) && total > 0
        let fraction = active ? scrub ?? min(max(player.position.seconds / total, 0), 1) : 0
        let showsTimes = active && (hovering || scrub != nil)
        HStack(spacing: 8) {
            TimeLabel(seconds: active ? fraction * total : nil, alignment: .trailing)
                .opacity(showsTimes ? 1 : 0)
            GeometryReader { geometry in
                let width = geometry.size.width
                let thick = active && (hovering || scrub != nil)
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(thick ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .frame(width: max(width * fraction, 0))
                }
                .frame(height: thick ? 6 : 3)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard active, width > 0 else { return }
                        scrub = min(max(drag.location.x / width, 0), 1)
                    }
                    .onEnded { _ in
                        if let scrub, active { player.seek(to: .seconds(scrub * total)) }
                        scrub = nil
                    })
            }
            .frame(height: 12)
            TimeLabel(seconds: active ? total : nil, alignment: .leading)
                .opacity(showsTimes ? 1 : 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .animation(.easeOut(duration: 0.15), value: showsTimes)
        .onHover { hovering = $0 }
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue(active ? "\(TimeFormat.minutes(Int(fraction * total))) of \(TimeFormat.minutes(Int(total)))" : "Not playing")
        .accessibilityAdjustableAction { direction in
            guard active else { return }
            let step = direction == .increment ? 10.0 : -10.0
            player.seek(to: .seconds(min(max(player.position.seconds + step, 0), total)))
        }
    }
}

/// Fixed width, so a change of digits doesn't move anything around it.
private struct TimeLabel: View {
    let seconds: Double?
    var alignment: Alignment = .center

    var body: some View {
        Text(seconds.map { TimeFormat.minutes(Int($0.rounded(.down))) } ?? "–:––")
            .monospacedDigit()
            .frame(width: 44, alignment: alignment)
    }
}

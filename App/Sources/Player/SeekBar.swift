import MiniAmpKit
import SwiftUI

/// A thin progress line, as in Apple Music, with the time played on its left and the time
/// left on its right. Hovering thickens it; click or drag anywhere on it to seek.
///
/// The only view that reads `player.position`, so a position change re-renders just this.
struct SeekBar: View {
    let player: Player
    /// The length of the song being loaded, from its tags: shown (from 0:00) while it loads,
    /// rather than no times at all for a moment.
    var loadingDurationMs: Int?
    /// Where a drag is, 0...1; nil follows the player.
    @State private var scrub: Double?
    @State private var hovering = false

    var body: some View {
        let total = player.duration.seconds
        let active = (player.state == .playing || player.state == .paused) && total > 0
        let fraction = active ? scrub ?? min(max(player.position.seconds / total, 0), 1) : 0
        let loading = player.state == .preparing ? loadingDurationMs.map { Double($0) / 1000 } : nil
        let played = active ? fraction * total : loading.map { _ in 0 }
        let length = active ? total : loading ?? 0
        HStack(spacing: 8) {
            TimeLabel(text: played.map { TimeFormat.minutes(Int($0.rounded(.down))) }, alignment: .trailing)
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
            TimeLabel(text: played.map { "-" + TimeFormat.minutes(Int((length - $0).rounded(.up))) }, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
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
    /// Nil while nothing plays: the space stays, empty.
    let text: String?
    var alignment: Alignment = .center

    var body: some View {
        Text(text ?? "")
            .monospacedDigit()
            .frame(width: 52, alignment: alignment)
    }
}

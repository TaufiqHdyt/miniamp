import MiniAmpKit
import SwiftUI

struct OutputPanel: View {
    let player: Player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Read each device's name and kind once per refresh; they're HAL calls.
        // Hardware only: no virtual devices (BlackHole, Zoom), and no aggregates, which just
        // combine devices that are already listed.
        let rows = player.availableDevices
            .map { Row(device: $0, name: $0.name, kind: $0.kind) }
            .filter { $0.kind != .aggregate && $0.kind != .virtual }
        let computer = rows.filter { $0.kind != .airPlay }
        let airPlay = rows.filter { $0.kind == .airPlay }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Audio Output").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            section("Computer", computer)
            if !airPlay.isEmpty {
                Divider().padding(.vertical, 4)
                section("Speakers & TVs", airPlay)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    @ViewBuilder private func section(_ title: String, _ rows: [Row]) -> some View {
        if !rows.isEmpty {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            ForEach(rows) { row in
                DeviceRow(row: row, player: player)
            }
        }
    }

    struct Row: Identifiable {
        let device: AudioDevice
        let name: String
        let kind: AudioDevice.Kind
        var id: AudioDevice.ID { device.id }
    }
}

private struct DeviceRow: View {
    let row: OutputPanel.Row
    let player: Player
    @State private var hovering = false

    private var selected: Bool { player.outputDevice == row.device }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(selected ? .white : .primary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)))

            VStack(alignment: .leading, spacing: 4) {
                Text(row.name).lineLimit(1).truncationMode(.tail)
                if selected, let volume = player.volume {
                    Slider(value: Binding(get: { Double(volume) }, set: { player.setVolume(Float($0)) }), in: 0...1)
                        .controlSize(.mini)
                        .accessibilityLabel("\(row.name) volume")
                }
            }

            Spacer(minLength: 0)

            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(hovering && !selected ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard !selected else { return }
            Preferences.setOutputDevice(row.device.uid, on: player)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { Preferences.setOutputDevice(row.device.uid, on: player) }
    }

    private var symbol: String {
        switch row.kind {
        case .builtInSpeakers: row.name.contains("MacBook") ? "laptopcomputer" : "desktopcomputer"
        case .builtInHeadphones, .bluetooth: row.name.contains("AirPods") ? "airpods" : "headphones"
        case .airPlay: row.name.localizedCaseInsensitiveContains("TV") ? "appletv" : "hifispeaker"
        case .display: "tv"
        case .usb: "hifispeaker"
        case .virtual, .aggregate: "waveform"
        case .other: "speaker.wave.2"
        }
    }
}

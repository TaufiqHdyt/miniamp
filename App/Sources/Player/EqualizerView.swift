import MiniAmpKit
import SwiftUI

/// The Equalizer window: on/off, presets, preamp, and a slider per band. Changes apply as
/// they're made, in DSP mode; in bit-perfect mode the window says so and offers the switch.
struct EqualizerView: View {
    @Bindable var player: Player

    private static let sliderHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Toggle("Equalizer", isOn: $player.equalizer.isEnabled)
                    .toggleStyle(.switch)
                    .fontWeight(.semibold)
                Spacer()
                Menu(player.equalizer.preset?.name ?? "Custom") {
                    ForEach(Equalizer.Preset.all) { preset in
                        Button(preset.name) {
                            player.equalizer.apply(preset)
                            player.equalizer.isEnabled = true
                        }
                    }
                }
                .fixedSize()
            }

            HStack(alignment: .bottom, spacing: 6) {
                band(value: $player.equalizer.preamp, label: "Pre")
                Divider().frame(height: Self.sliderHeight + 30)
                ForEach(Equalizer.frequencies.indices, id: \.self) { index in
                    band(value: $player.equalizer.gains[index], label: Self.label(Equalizer.frequencies[index]))
                }
            }
            .disabled(!player.equalizer.isEnabled)

            if !player.dspMode {
                HStack {
                    Label("Bit-perfect mode is on, so the EQ isn't applied.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Use DSP Mode") { player.dspMode = true }
                }
                .font(.callout)
            } else if let clip = clippingHint {
                Label(clip, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
        }
        .padding(20)
        .fixedSize()
    }

    /// A vertical slider with its value above and its band below. Double-click the value to reset it.
    private func band(value: Binding<Float>, label: String) -> some View {
        VStack(spacing: 4) {
            // "0", never "+0" or "−0".
            Text(value.wrappedValue.rounded() == 0 ? "0" : String(format: "%+.0f", value.wrappedValue))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .onTapGesture(count: 2) { value.wrappedValue = 0 }
                .help("Double-click to reset")
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() }),
                   in: Equalizer.gainRange)
                .frame(width: Self.sliderHeight)
                .rotationEffect(.degrees(-90))
                .frame(width: 30, height: Self.sliderHeight)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label == "Pre" ? "Preamp" : label.hasSuffix("k") ? "\(label.dropLast()) kHz band" : "\(label) Hz band")
    }

    /// Boosts past what the preamp takes back can clip a loud track.
    private var clippingHint: String? {
        let eq = player.equalizer
        guard eq.isEnabled, let boost = eq.gains.max(), boost + eq.preamp > 0 else { return nil }
        return String(format: "With the preamp, the biggest boost is %+.0f dB, so loud tracks may clip. A preamp of %.0f dB avoids it.",
                      boost + eq.preamp, -boost)
    }

    private static func label(_ frequency: Float) -> String {
        frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
    }
}

import MiniAmpKit
import SwiftUI

/// The file's format and what the device is doing with it, said plainly. Click for details.
struct QualityBadge: View {
    let path: SignalPath
    /// Just the coloured symbol, for tight spaces; the format moves into the tooltip.
    var iconOnly = false
    @State private var showsDetails = false

    var body: some View {
        Button { showsDetails.toggle() } label: {
            if iconOnly {
                Image(systemName: symbol)
                    .imageScale(.large)
                    .foregroundStyle(color)
            } else {
                Label(title, systemImage: symbol)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .foregroundStyle(color)
                    .background(color.opacity(0.12), in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .help(iconOnly ? "\(title)\n\n\(headline)" : headline)
        .popover(isPresented: $showsDetails, arrowEdge: .top) {
            SignalDetails(path: path, headline: headline, title: iconOnly ? title : nil)
        }
        .accessibilityLabel(iconOnly ? "\(title). \(headline)" : headline)
    }

    private var format: String {
        let rate = FormatSelection.formatRate(path.fileSampleRate)
        return path.fileBitDepth.map { "\(path.codec) \(rate)/\($0)" } ?? "\(path.codec) \(rate)"
    }

    private var title: String {
        switch path.verdict {
        case .bitPerfect: "\(format) · Bit-perfect"
        case .nativeRate: "\(format) · Native rate"
        case .resampled(let from, let to):
            "\(path.codec) \(FormatSelection.formatRate(from)) → \(FormatSelection.formatRate(to)) · Resampled"
        case .reducedBitDepth(_, let to): "\(format) → \(to)-bit"
        case .processed:
            path.isResampled
                ? "\(path.codec) \(FormatSelection.formatRate(path.fileSampleRate)) → \(FormatSelection.formatRate(path.deviceSampleRate)) · DSP"
                : "\(format) · DSP"
        }
    }

    private var symbol: String {
        switch path.verdict {
        case .bitPerfect: "checkmark.seal.fill"
        case .nativeRate: "checkmark.circle"
        case .resampled, .reducedBitDepth: "exclamationmark.triangle.fill"
        case .processed: "slider.vertical.3"
        }
    }

    private var color: Color {
        switch path.verdict {
        case .bitPerfect: .green
        case .nativeRate: .secondary
        case .resampled, .reducedBitDepth: .orange
        case .processed: .blue
        }
    }

    var headline: String {
        switch path.verdict {
        case .bitPerfect:
            "Bit-perfect: the device runs at the file's rate and receives its samples unchanged."
        case .nativeRate:
            "Native rate: the device runs at the file's rate, so nothing is resampled. \(path.codec) is lossy, so there are no original samples to be bit-perfect to."
        case .resampled(let from, let to):
            "Resampled: \(path.deviceName) can't play \(FormatSelection.formatRate(from)), so the audio is converted to \(FormatSelection.formatRate(to)) at high quality."
        case .reducedBitDepth(let from, let to):
            "The device takes \(to)-bit samples, so the file's \(from)-bit samples lose their lowest bits."
        case .processed:
            "DSP mode: the samples are changed on the way (\(path.processing?.description ?? "gain")). Choose Bit-perfect in Settings › Sound to hear the file unchanged."
                + (path.isResampled ? " The device can't play \(FormatSelection.formatRate(path.fileSampleRate)), so it's also resampled to \(FormatSelection.formatRate(path.deviceSampleRate))." : "")
        }
    }
}

private struct SignalDetails: View {
    let path: SignalPath
    let headline: String
    /// The badge's label, shown here when the badge itself is just an icon.
    var title: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(.headline) }
            Text(headline).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("File").foregroundStyle(.secondary)
                    Text(path.fileDescription + (path.fileChannels == 1 ? ", mono" : ""))
                }
                GridRow {
                    Text("Device").foregroundStyle(.secondary)
                    Text(path.deviceDescription)
                }
                GridRow {
                    Text("Format").foregroundStyle(.secondary)
                    Text(path.devicePhysicalFormat)
                }
                if let processing = path.processing {
                    GridRow {
                        Text("DSP").foregroundStyle(.secondary)
                        Text(processing.description)
                    }
                }
                GridRow {
                    Text("Access").foregroundStyle(.secondary)
                    Text(path.isExclusive ? "Exclusive (hog mode)" : "Shared")
                }
            }
            .font(.callout.monospaced())
            if !path.isExclusive {
                Text("Shared: other apps' sounds can mix in. Turn on exclusive access in Settings to keep the device to miniamp.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

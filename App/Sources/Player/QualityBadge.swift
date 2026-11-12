import MiniAmpKit
import SwiftUI

/// What the device is doing with the file, as a coloured symbol; the format and a plain
/// explanation are in its tooltip, and more in the popover it opens.
struct QualityBadge: View {
    let path: SignalPath
    @State private var showsDetails = false

    var body: some View {
        Button { showsDetails.toggle() } label: {
            Image(systemName: symbol)
                .imageScale(.large)
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .help("\(title)\n\n\(headline)")
        .popover(isPresented: $showsDetails, arrowEdge: .top) {
            SignalDetails(path: path, headline: headline, title: title)
        }
        .accessibilityLabel("\(title). \(headline)")
    }

    private var format: String {
        if path.dsd != nil { return path.codec }
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
        case .volumeScaled(let percent): "\(format) · Volume \(percent)%"
        case .dsdOverPCM: "\(format) · DoP"
        case .dsdConverted(let to): "\(format) → PCM \(FormatSelection.formatRate(to))"
        }
    }

    private var symbol: String {
        switch path.verdict {
        case .bitPerfect, .dsdOverPCM: "checkmark.seal.fill"
        case .nativeRate: "checkmark.circle"
        case .resampled, .reducedBitDepth, .dsdConverted: "exclamationmark.triangle.fill"
        case .processed: "slider.vertical.3"
        case .volumeScaled: "speaker.wave.1.fill"
        }
    }

    private var color: Color {
        switch path.verdict {
        case .bitPerfect, .dsdOverPCM: .green
        case .nativeRate: .secondary
        case .resampled, .reducedBitDepth, .dsdConverted: .orange
        case .processed: .blue
        case .volumeScaled: .secondary
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
        case .volumeScaled(let percent):
            "Volume at \(percent)%: the samples are scaled down on the way, so they aren't bit-perfect. At 100% they reach the device unchanged; turn the device itself down (in the output menu) to keep them that way."
        case .dsdOverPCM:
            "DSD over PCM (DoP): the DSD bits reach \(path.deviceName) unchanged, packed in \(FormatSelection.formatRate(path.engineSampleRate)) frames, and the DAC plays them as DSD. miniamp's volume doesn't apply; use the DAC's."
        case .dsdConverted(let to):
            "Converted to PCM: the DSD is filtered down to \(FormatSelection.formatRate(path.engineSampleRate)) PCM"
                + (path.isResampled ? " and resampled to \(FormatSelection.formatRate(to)), the closest rate \(path.deviceName) can play" : "")
                + ". A DAC that plays DSD over PCM can get the DSD itself: turn on DoP in Settings › Playback."
        case .processed:
            "DSP mode: the samples are changed on the way (\(path.processing?.description ?? "gain")). Choose Bit-perfect in Settings › Sound to hear the file unchanged."
                + (path.isResampled ? " The device can't play \(FormatSelection.formatRate(path.fileSampleRate)), so it's also resampled to \(FormatSelection.formatRate(path.deviceSampleRate))." : "")
        }
    }
}

private struct SignalDetails: View {
    let path: SignalPath
    let headline: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
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

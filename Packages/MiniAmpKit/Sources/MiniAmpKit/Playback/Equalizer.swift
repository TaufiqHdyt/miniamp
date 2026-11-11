import AVFoundation

/// A 10-band graphic EQ: octave bands from 32 Hz to 16 kHz, a preamp, and presets.
public struct Equalizer: Sendable, Equatable, Codable {
    /// Band centers, Hz. The lowest is a low shelf and the highest a high shelf; the rest are
    /// one-octave peaking filters.
    public static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16_000]
    public static let gainRange: ClosedRange<Float> = -12...12

    public var isEnabled = false
    /// dB per band, in `frequencies` order.
    public var gains: [Float] = Array(repeating: 0, count: Equalizer.frequencies.count)
    /// dB before the bands; turn it down by about the biggest boost to leave headroom.
    public var preamp: Float = 0

    public init(isEnabled: Bool = false, gains: [Float]? = nil, preamp: Float = 0) {
        self.isEnabled = isEnabled
        if let gains { self.gains = Self.fit(gains) }
        self.preamp = preamp
    }

    /// The preset these settings match, if any.
    public var preset: Preset? { Preset.all.first { $0.gains == gains && $0.preamp == preamp } }

    public mutating func apply(_ preset: Preset) {
        gains = preset.gains
        preamp = preset.preamp
    }

    /// Whether the bands would change the sound (enabled, and not all flat).
    public var isShaping: Bool { isEnabled && (gains.contains { $0 != 0 } || preamp != 0) }

    private static func fit(_ gains: [Float]) -> [Float] {
        let n = frequencies.count
        return (gains + Array(repeating: 0, count: n)).prefix(n).map { min(max($0, gainRange.lowerBound), gainRange.upperBound) }
    }

    /// Sets up `eq`'s bands for these settings (it needs `frequencies.count` of them).
    func configure(_ eq: AVAudioUnitEQ) {
        for (index, band) in eq.bands.enumerated() where index < Self.frequencies.count {
            band.filterType = index == 0 ? .lowShelf : index == Self.frequencies.count - 1 ? .highShelf : .parametric
            band.frequency = Self.frequencies[index]
            band.bandwidth = 1
            band.gain = gains[index]
            band.bypass = !isEnabled || gains[index] == 0
        }
    }

    public struct Preset: Sendable, Equatable, Identifiable {
        public var name: String
        public var gains: [Float]
        public var preamp: Float
        public var id: String { name }

        // The preamp of each matches its biggest boost, so a full-scale track doesn't clip.
        public static let all: [Preset] = [
            Preset(name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], preamp: 0),
            Preset(name: "Bass Boost", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0], preamp: -6),
            Preset(name: "Bass Cut", gains: [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0], preamp: 0),
            Preset(name: "Treble Boost", gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6], preamp: -6),
            Preset(name: "Treble Cut", gains: [0, 0, 0, 0, 0, -1, -2, -4, -5, -6], preamp: 0),
            Preset(name: "Loudness", gains: [5, 4, 1, 0, -1, 0, 1, 3, 4, 3], preamp: -5),
            Preset(name: "Vocal", gains: [-2, -2, -1, 1, 3, 3, 2, 1, 0, -1], preamp: -3),
            Preset(name: "Rock", gains: [4, 3, 2, 0, -1, -1, 1, 2, 3, 4], preamp: -4),
            Preset(name: "Electronic", gains: [5, 4, 1, 0, -2, 1, 1, 2, 4, 5], preamp: -5),
            Preset(name: "Classical", gains: [3, 2, 1, 0, 0, 0, -1, -1, 0, 2], preamp: -3),
            Preset(name: "Small Speakers", gains: [-6, -3, 2, 3, 2, 1, 0, 1, 2, 1], preamp: -3),
        ]
    }
}

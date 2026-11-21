/// Reduces the latest 40 ms of mono PCM to min/max pairs, preserving peaks between columns.
public final class WaveformAnalyzer {
    public struct Column {
        public let minimum: Float
        public let maximum: Float
    }

    private var samples = [Float](repeating: 0, count: SampleTap.capacity / 2)
    public private(set) var columns: [Column] = []

    public init() {}

    public func update(from tap: SampleTap, columnCount: Int) {
        let count = max(1, min(Int(tap.sampleRate * 0.04), samples.count))
        let heard = samples.withUnsafeMutableBufferPointer { tap.latest(count, into: $0.baseAddress!) }
        guard heard else { reset(); return }
        samples.withUnsafeBufferPointer {
            analyze(UnsafeBufferPointer(rebasing: $0[..<count]), columnCount: columnCount)
        }
    }

    public func reset() {
        columns.removeAll(keepingCapacity: true)
    }

    func analyze(_ input: UnsafeBufferPointer<Float>, columnCount: Int) {
        reset()
        let count = min(columnCount, input.count)
        guard count > 0 else { return }
        var hasSignal = false
        for index in 0..<count {
            let start = index * input.count / count
            let end = (index + 1) * input.count / count
            var minimum = input[start]
            var maximum = minimum
            for sample in input[(start + 1)..<end] {
                minimum = min(minimum, sample)
                maximum = max(maximum, sample)
            }
            hasSignal = hasSignal || minimum != 0 || maximum != 0
            columns.append(Column(minimum: minimum, maximum: maximum))
        }
        if !hasSignal { reset() }
    }
}

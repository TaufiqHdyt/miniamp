import AudioToolbox
import AVFoundation

/// Helpers for the engine's output node and channel routing.
///
/// In manual rendering mode the engine's output node doesn't touch hardware (HALOutput does),
/// but it still converts sample rate when the file's rate differs from the device's.
enum OutputUnit {
    /// Runs `body` with the output node's audio unit (the unit is only lent out for the call).
    static func withUnit<R>(_ engine: AVAudioEngine, _ body: (AudioUnit) throws -> R) throws -> R {
        try engine.outputNode.withAudioUnit { (unit: borrowing AudioUnit?) throws(any Error) -> R in
            guard let unit = copy unit else {
                throw CoreAudioError(status: kAudioUnitErr_Uninitialized, operation: "Get output unit")
            }
            return try body(unit)
        }
    }

    /// Sets a fixed-size property on the engine's output unit.
    static func set<T>(_ engine: AVAudioEngine, _ property: AudioUnitPropertyID, _ value: T,
                       scope: AudioUnitScope = kAudioUnitScope_Global, _ operation: @autoclosure () -> String) throws {
        try withUnit(engine) { unit in
            let status = withUnsafeBytes(of: value) {
                AudioUnitSetProperty(unit, property, scope, 0, $0.baseAddress, UInt32($0.count))
            }
            try check(status, operation())
        }
    }

    /// One entry per device channel: the source channel it plays, or -1 for silence.
    /// A mono source goes to the first two device channels (left and right) unchanged;
    /// other sources map one-to-one.
    static func channelMap(sourceChannels: Int, deviceChannels: Int) -> [Int32] {
        (0..<max(deviceChannels, 1)).map { ch in
            if sourceChannels == 1 { return ch < 2 ? 0 : -1 }
            return ch < sourceChannels ? Int32(ch) : -1
        }
    }

    /// Asks the engine output node's converter for its best sample-rate conversion. It only
    /// does work when the file's rate differs from the render (device) rate: the fallback path.
    static func setMaximumResamplingQuality(on engine: AVAudioEngine) throws {
        try setResamplerComplexity(kAudioUnitSampleRateConverterComplexity_Mastering, on: engine)
        try set(engine, kAudioUnitProperty_RenderQuality, UInt32(kRenderQuality_Max), "Set render quality")
    }

    static func setResamplerComplexity(_ complexity: UInt32, on engine: AVAudioEngine) throws {
        try set(engine, kAudioUnitProperty_SampleRateConverterComplexity, complexity, "Set resampler complexity")
    }
}

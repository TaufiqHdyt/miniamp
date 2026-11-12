import AVFoundation

// macOS 27 renamed these to throwing versions: `playAudio()` for `play()`, `connectNode` for
// `connect`. These pick whichever the running system has.

extension AVAudioPlayerNode {
    /// Starts playback (or resumes it, after a pause).
    func startPlayback() throws {
        if #available(macOS 27, *) {
            try playAudio()
        } else {
            play()
        }
    }
}

extension AVAudioEngine {
    /// Connects `source`'s output to `destination`'s input in `format`.
    func link(_ source: AVAudioNode, to destination: AVAudioNode, format: AVAudioFormat?) throws {
        if #available(macOS 27, *) {
            try connectNode(source, to: destination, format: format)
        } else {
            connect(source, to: destination, format: format)
        }
    }
}

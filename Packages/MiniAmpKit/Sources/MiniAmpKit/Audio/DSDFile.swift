import CDSD
import Foundation

/// A DSD file, DSF or DSDIFF (.dff), memory-mapped, with access to each channel's bytes.
///
/// DSD is one bit per sample at 64 or more times 44.1 kHz (DSD64 is 2.8224 MHz). Bytes come back
/// MSB-first, the earliest bit in the top bit, whatever order the file stores them in.
/// DST-compressed DSDIFF isn't supported.
public final class DSDFile: Sendable {
    public enum Container: Sendable { case dsf, dff }

    public enum FileError: Error, CustomStringConvertible {
        case notDSD
        case unsupported(String)
        case truncated

        public var description: String {
            switch self {
            case .notDSD: "not a DSF or DSDIFF file"
            case .unsupported(let what): "unsupported DSD file: \(what)"
            case .truncated: "the DSD file is cut short"
            }
        }
    }

    public static let fileExtensions: Set<String> = ["dsf", "dff"]

    public static func isDSD(_ url: URL) -> Bool { fileExtensions.contains(url.pathExtension.lowercased()) }

    /// What DSD silence is made of: alternating bits average to nothing.
    static let silence: UInt8 = 0x69

    public let url: URL
    public let container: Container
    public let channels: Int
    /// One-bit samples per second, per channel: 2,822,400 for DSD64.
    public let sampleRate: Int
    /// Samples (bits) per channel.
    public let sampleCount: Int64
    private let data: Data
    private let dataOffset: Int
    /// DSF stores each channel in blocks of this many bytes, in turn. DSDIFF interleaves bytes (0).
    private let blockSize: Int
    private let lsbFirst: Bool

    /// Bytes per channel.
    public var byteCount: Int64 { sampleCount / 8 }

    /// The rate family: 44.1 kHz (DSD64 = 64 × 44.1 kHz) or 48 kHz.
    public var baseRate: Int { sampleRate % 44_100 == 0 ? 44_100 : 48_000 }

    /// 64 for DSD64, 128 for DSD128, and so on.
    public var multiple: Int { sampleRate / baseRate }

    public var name: String { "DSD\(multiple)" }

    public init(url: URL) throws {
        self.url = url
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        self.data = data
        guard data.count >= 16 else { throw FileError.notDSD }
        switch data.fourCC(at: 0) {
        case "DSD ":
            container = .dsf
            (channels, sampleRate, sampleCount, dataOffset, blockSize, lsbFirst) = try Self.parseDSF(data)
        case "FRM8":
            container = .dff
            (channels, sampleRate, sampleCount, dataOffset) = try Self.parseDFF(data)
            blockSize = 0
            lsbFirst = false
        default:
            throw FileError.notDSD
        }
        guard channels > 0, sampleRate > 0, sampleRate % 44_100 == 0 || sampleRate % 48_000 == 0,
              sampleRate / (sampleRate % 44_100 == 0 ? 44_100 : 48_000) >= 64
        else { throw FileError.unsupported("\(channels) channels at \(sampleRate) Hz") }
    }

    /// Copies `count` bytes of `channel`, starting at byte `start`, into `out`. Bytes before the
    /// start or past the end of the file are DSD silence.
    func copyBytes(channel: Int, from start: Int64, count: Int, into out: UnsafeMutablePointer<UInt8>) {
        // Silence before the start and past the end; the file's bytes in between.
        let lead = Int(min(max(-start, 0), Int64(count)))
        let first = start + Int64(lead)
        let available = Int(min(max(byteCount - first, 0), Int64(count - lead)))
        if lead > 0 { memset(out, Int32(Self.silence), lead) }
        if lead + available < count { memset(out + lead + available, Int32(Self.silence), count - lead - available) }
        guard available > 0 else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self).baseAddress!
            var i = 0
            while i < available {
                let index = first + Int64(i)
                let destination = out + lead + i
                if blockSize > 0 {
                    // DSF: a run within one block is contiguous.
                    let block = Int(index / Int64(blockSize)), within = Int(index % Int64(blockSize))
                    let run = min(blockSize - within, available - i)
                    let offset = dataOffset + (block * channels + channel) * blockSize + within
                    guard offset + run <= raw.count else {
                        memset(destination, Int32(Self.silence), available - i)
                        return
                    }
                    dsd_gather(bytes + offset, 1, run, lsbFirst ? 1 : 0, destination)
                    i += run
                } else {
                    // DSDIFF: channels interleaved a byte at a time.
                    let offset = dataOffset + Int(index) * channels + channel
                    let run = min(available - i, (raw.count - offset + channels - 1) / channels)
                    guard run > 0 else {
                        memset(destination, Int32(Self.silence), available - i)
                        return
                    }
                    dsd_gather(bytes + offset, channels, run, 0, destination)
                    i += run
                }
            }
        }
    }

    /// Each byte with its bits in the opposite order (DSF's LSB-first to MSB-first).
    static let reversed: [UInt8] = (0..<256).map { v in
        var r: UInt8 = 0
        for bit in 0..<8 where v & (1 << bit) != 0 { r |= UInt8(0x80) >> UInt8(bit) }
        return r
    }

    // MARK: Parsing

    /// DSF: little-endian "DSD " and "fmt " chunks, then "data".
    private static func parseDSF(_ d: Data) throws
        -> (channels: Int, rate: Int, samples: Int64, offset: Int, block: Int, lsbFirst: Bool) {
        let dsdSize = Int(d.uint64LE(at: 4))
        guard dsdSize >= 28, d.count >= dsdSize + 12, d.fourCC(at: dsdSize) == "fmt " else { throw FileError.notDSD }
        let fmt = dsdSize
        let fmtSize = Int(d.uint64LE(at: fmt + 4))
        guard fmtSize >= 52, d.count >= fmt + fmtSize + 12 else { throw FileError.truncated }
        guard d.uint32LE(at: fmt + 16) == 0 else { throw FileError.unsupported("format \(d.uint32LE(at: fmt + 16))") }
        let channels = Int(d.uint32LE(at: fmt + 24))
        let rate = Int(d.uint32LE(at: fmt + 28))
        let bits = d.uint32LE(at: fmt + 32)
        let samples = Int64(d.uint64LE(at: fmt + 36))
        let block = Int(d.uint32LE(at: fmt + 44))
        guard bits == 1 || bits == 8 else { throw FileError.unsupported("\(bits) bits per sample") }
        guard block > 0 else { throw FileError.unsupported("block size 0") }
        let dataChunk = fmt + fmtSize
        guard d.fourCC(at: dataChunk) == "data" else { throw FileError.notDSD }
        return (channels, rate, samples, dataChunk + 12, block, bits == 1)
    }

    /// DSDIFF: a big-endian "FRM8" form of chunks; the format is in "PROP", the bits in "DSD ".
    private static func parseDFF(_ d: Data) throws -> (channels: Int, rate: Int, samples: Int64, offset: Int) {
        guard d.fourCC(at: 12) == "DSD " else { throw FileError.notDSD }
        var channels = 0, rate = 0
        var position = 16
        while position + 12 <= d.count {
            let id = d.fourCC(at: position)
            let size = Int(d.uint64BE(at: position + 4))
            let body = position + 12
            switch id {
            case "PROP":
                guard d.fourCC(at: body) == "SND " else { break }
                var sub = body + 4
                while sub + 12 <= min(body + size, d.count) {
                    let subID = d.fourCC(at: sub)
                    let subSize = Int(d.uint64BE(at: sub + 4))
                    let subBody = sub + 12
                    switch subID {
                    case "FS  ": rate = Int(d.uint32BE(at: subBody))
                    case "CHNL": channels = Int(d.uint16BE(at: subBody))
                    case "CMPR":
                        let type = d.fourCC(at: subBody)
                        guard type == "DSD " else { throw FileError.unsupported("\(type.trimmingCharacters(in: .whitespaces)) compression") }
                    default: break
                    }
                    sub = subBody + subSize + (subSize & 1)
                }
            case "DST ":
                throw FileError.unsupported("DST compression")
            case "DSD ":
                guard channels > 0, rate > 0 else { throw FileError.notDSD }
                let available = min(size, d.count - body)
                return (channels, rate, Int64(available / channels) * 8, body)
            default:
                break
            }
            position = body + size + (size & 1)
        }
        throw FileError.truncated
    }
}

extension Data {
    fileprivate func fourCC(at offset: Int) -> String {
        guard offset + 4 <= count else { return "" }
        return String(decoding: self[startIndex + offset ..< startIndex + offset + 4], as: UTF8.self)
    }

    fileprivate func integer<T: FixedWidthInteger>(at offset: Int, _: T.Type) -> T {
        guard offset + MemoryLayout<T>.size <= count else { return 0 }
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) {
            copyBytes(to: $0, from: startIndex + offset ..< startIndex + offset + MemoryLayout<T>.size)
        }
        return value
    }

    fileprivate func uint16BE(at offset: Int) -> UInt16 { UInt16(bigEndian: integer(at: offset, UInt16.self)) }
    fileprivate func uint32BE(at offset: Int) -> UInt32 { UInt32(bigEndian: integer(at: offset, UInt32.self)) }
    fileprivate func uint64BE(at offset: Int) -> UInt64 { UInt64(bigEndian: integer(at: offset, UInt64.self)) }
    fileprivate func uint32LE(at offset: Int) -> UInt32 { UInt32(littleEndian: integer(at: offset, UInt32.self)) }
    fileprivate func uint64LE(at offset: Int) -> UInt64 { UInt64(littleEndian: integer(at: offset, UInt64.self)) }
}

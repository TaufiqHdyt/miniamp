import CoreGraphics
import Foundation

/// A colour taken from a cover, for tinting what's around it: the cover's most prominent hue,
/// toned so it works as a wash behind text in light and dark mode alike. sRGB, 0 to 1.
public struct ArtworkTint: Sendable, Equatable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Covers are scaled to this many pixels a side first: plenty for a dominant colour.
    static let sampleSize = 24
    /// Below this share of colourful pixels a cover counts as black and white: no tint.
    static let minimumColourfulShare = 0.06
    static let hueBins = 12

    /// The cover's dominant hue, or nil for a cover with too little colour to take one from.
    ///
    /// Each pixel votes for its hue with its saturation times its brightness, so vivid areas
    /// count and greys, near-blacks, and near-whites don't. The winning hue's pixels are
    /// averaged, then brought into a range that reads as a tint.
    public static func of(_ image: CGImage) -> ArtworkTint? {
        let n = sampleSize
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return nil }

        var weight = [Double](repeating: 0, count: hueBins)
        var sums = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: hueBins)
        var colourful = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[i + 3]) / 255
            guard alpha > 0.5 else { continue }
            let (r, g, b) = (Double(pixels[i]) / 255 / alpha, Double(pixels[i + 1]) / 255 / alpha, Double(pixels[i + 2]) / 255 / alpha)
            let (h, s, v) = hsb(r, g, b)
            guard s > 0.15, v > 0.15 else { continue }
            colourful += 1
            let bin = min(Int(h * Double(hueBins)), hueBins - 1)
            let w = s * v
            weight[bin] += w
            sums[bin].r += r * w
            sums[bin].g += g * w
            sums[bin].b += b * w
        }
        guard Double(colourful) / Double(n * n) >= minimumColourfulShare,
              let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 0 else { return nil }
        let w = weight[best]
        let (h, s, v) = hsb(sums[best].r / w, sums[best].g / w, sums[best].b / w)
        let (r, g, b) = rgb(h, min(max(s, 0.35), 0.8), min(max(v, 0.55), 0.85))
        return ArtworkTint(red: r, green: g, blue: b)
    }

    /// Hue, saturation, and brightness, each 0 to 1.
    static func hsb(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        guard delta > 0 else { return (0, 0, maxC) }
        var h: Double
        if maxC == r { h = (g - b) / delta } else if maxC == g { h = (b - r) / delta + 2 } else { h = (r - g) / delta + 4 }
        h /= 6
        if h < 0 { h += 1 }
        return (h, delta / maxC, maxC)
    }

    static func rgb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let sector = h * 6, i = Int(sector) % 6, f = sector - Double(Int(sector))
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}

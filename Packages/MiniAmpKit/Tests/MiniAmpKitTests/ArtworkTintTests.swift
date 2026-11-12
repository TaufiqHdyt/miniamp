import CoreGraphics
import Testing
@testable import MiniAmpKit

/// Issue #46: the colour a cover tints its surroundings with.
@Suite struct ArtworkTintTests {
    /// An image in horizontal stripes: each (colour, share of the height).
    func image(_ stripes: [((Double, Double, Double), Double)], size: Int = 64) -> CGImage {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var y = 0.0
        for ((r, g, b), share) in stripes {
            context.setFillColor(red: r, green: g, blue: b, alpha: 1)
            context.fill(CGRect(x: 0, y: y, width: Double(size), height: share * Double(size)))
            y += share * Double(size)
        }
        return context.makeImage()!
    }

    func hue(_ tint: ArtworkTint?) -> Double? {
        tint.map { ArtworkTint.hsb($0.red, $0.green, $0.blue).0 }
    }

    @Test func takesTheHueOfASolidCover() throws {
        let red = try #require(ArtworkTint.of(image([((0.9, 0.1, 0.1), 1)])))
        #expect(red.red > red.green && red.red > red.blue)
        let blueHue = try #require(hue(ArtworkTint.of(image([((0.1, 0.2, 0.9), 1)]))))
        #expect(abs(blueHue - 0.635) < 0.03)
    }

    @Test func blackAndWhiteCoversHaveNoTint() {
        #expect(ArtworkTint.of(image([((0.5, 0.5, 0.5), 0.5), ((0.05, 0.05, 0.05), 0.3), ((1, 1, 1), 0.2)])) == nil)
        // A speck of colour isn't enough.
        #expect(ArtworkTint.of(image([((0.5, 0.5, 0.5), 0.97), ((1, 0, 0), 0.03)])) == nil)
    }

    @Test func vividAreasOutvoteDullOnes() throws {
        // Mostly grey with a band of blue: blue.
        let blue = try #require(hue(ArtworkTint.of(image([((0.6, 0.6, 0.6), 0.7), ((0.1, 0.3, 0.95), 0.3)]))))
        #expect(blue > 0.55 && blue < 0.7)
        // More yellow than purple: yellow.
        let yellow = try #require(hue(ArtworkTint.of(image([((0.95, 0.85, 0.1), 0.6), ((0.5, 0.1, 0.7), 0.4)]))))
        #expect(yellow > 0.1 && yellow < 0.2)
    }

    @Test func tonesTheColourForATint() throws {
        // Near-black red and pale pink both come out at a usable strength.
        for colour in [(0.3, 0.05, 0.05), (1.0, 0.8, 0.8)] {
            let tint = try #require(ArtworkTint.of(image([(colour, 1)])))
            let (_, s, v) = ArtworkTint.hsb(tint.red, tint.green, tint.blue)
            #expect(s >= 0.34 && s <= 0.81)
            #expect(v >= 0.54 && v <= 0.86)
        }
    }

    @Test func hsbRoundTrips() {
        for (r, g, b) in [(0.2, 0.4, 0.6), (0.9, 0.1, 0.5), (0.3, 0.8, 0.2)] {
            let (h, s, v) = ArtworkTint.hsb(r, g, b)
            let back = ArtworkTint.rgb(h, s, v)
            #expect(abs(back.0 - r) < 1e-9 && abs(back.1 - g) < 1e-9 && abs(back.2 - b) < 1e-9)
        }
    }
}

import AppKit
import ImageIO
import MiniAmpKit
import SwiftUI

/// Decoded cover thumbnails, shared by every view. Decoding happens off the main actor.
@MainActor
final class ArtworkImages {
    static let shared = ArtworkImages()
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 600 }

    func cached(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }

    func image(for key: String, in artwork: ArtworkCache) async -> NSImage? {
        if let image = cached(key) { return image }
        let url = artwork.thumbnailURL(for: key)
        let cgImage = await Task.detached(priority: .userInitiated) { Self.decode(url) }.value
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    /// Covers of files outside the library, read from their tags. Keyed by path.
    func image(embeddedIn url: URL) async -> NSImage? {
        let key = "file:" + url.path
        if let image = cached(key) { return image }
        let cgImage = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let data = TagReader.read(url, includeArtwork: true)?.artwork,
                  let source = CGImageSourceCreateWithData(data as CFData, nil)
            else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 600,
            ] as CFDictionary)
        }.value
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    nonisolated private static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

/// A square cover, or a placeholder note when there's none.
struct ArtworkView: View {
    let key: String?
    let artwork: ArtworkCache?
    /// For files outside the library: read the cover from the file's tags.
    var fileURL: URL? = nil
    var cornerRadius: CGFloat = 4

    @State private var image: NSImage?

    var body: some View {
        // A square that the image fills; a non-square cover is cropped, never stretched.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay {
                            Image(systemName: "music.note")
                                .resizable()
                                .scaledToFit()
                                .scaleEffect(0.4)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: "\(key ?? "")|\(fileURL?.path ?? "")") {
            image = key.flatMap { ArtworkImages.shared.cached($0) }
            if image == nil, let key, let artwork {
                image = await ArtworkImages.shared.image(for: key, in: artwork)
            }
            if image == nil, key == nil, let fileURL {
                image = await ArtworkImages.shared.image(embeddedIn: fileURL)
            }
        }
        .accessibilityHidden(true)
    }
}

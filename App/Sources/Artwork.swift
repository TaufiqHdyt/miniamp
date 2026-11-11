import AppKit
import ImageIO
import MiniAmpKit
import SwiftUI

/// How big a cover is drawn. Each size decodes the thumbnail at no more pixels than it shows.
enum ArtworkSize: Int {
    /// Player bar, up to 64 pt.
    case small = 128
    /// Album grid and album header, up to 220 pt.
    case medium = 440
    /// Now playing: the whole 600 px thumbnail.
    case large = 600

    var maxPixels: Int { rawValue }
}

/// Decoded covers, shared by every view, held to a memory budget. Decoding happens off the main actor.
///
/// Every cover used to be decoded at the thumbnail's full 600 px (1.4 MB each) and kept by count,
/// so scrolling a big album grid could hold close to a gigabyte. Decoding at the displayed
/// size makes a grid tile about a fifth of that, and the cache evicts by bytes.
@MainActor
final class ArtworkImages {
    static let shared = ArtworkImages()
    private let cache = NSCache<NSString, NSImage>()
    /// Decodes in progress, so tiles showing the same cover share one.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init() { cache.totalCostLimit = 96 * 1024 * 1024 }

    func cached(_ key: String, _ size: ArtworkSize) -> NSImage? {
        cache.object(forKey: Self.cacheKey(key, size) as NSString)
    }

    func image(for key: String, size: ArtworkSize, in artwork: ArtworkCache) async -> NSImage? {
        let url = artwork.thumbnailURL(for: key)
        return await load(Self.cacheKey(key, size)) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return Self.thumbnail(source, maxPixels: size.maxPixels)
        }
    }

    /// Covers of files outside the library, read from their tags.
    func image(embeddedIn url: URL, size: ArtworkSize) async -> NSImage? {
        await load(Self.cacheKey("file:" + url.path, size)) {
            guard let data = TagReader.read(url, includeArtwork: true)?.artwork,
                  let source = CGImageSourceCreateWithData(data as CFData, nil)
            else { return nil }
            return Self.thumbnail(source, maxPixels: size.maxPixels)
        }
    }

    private func load(_ cacheKey: String, _ decode: @escaping @Sendable () -> CGImage?) async -> NSImage? {
        if let image = cache.object(forKey: cacheKey as NSString) { return image }
        if let task = inFlight[cacheKey] { return await task.value }
        let task = Task<NSImage?, Never> {
            let cgImage = await Task.detached(priority: .userInitiated) { decode() }.value
            guard let cgImage else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        inFlight[cacheKey] = task
        let image = await task.value
        inFlight[cacheKey] = nil
        if let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            cache.setObject(image, forKey: cacheKey as NSString, cost: cg.bytesPerRow * cg.height)
        }
        return image
    }

    private static func cacheKey(_ key: String, _ size: ArtworkSize) -> String { "\(key)@\(size.rawValue)" }

    /// Decoded now (not lazily at first draw, which would land on the main thread).
    nonisolated private static func thumbnail(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}

/// A square cover, or a placeholder note when there's none.
struct ArtworkView: View {
    let key: String?
    let artwork: ArtworkCache?
    /// For files outside the library: read the cover from the file's tags.
    var fileURL: URL? = nil
    var size: ArtworkSize = .medium
    var cornerRadius: CGFloat = 4

    @State private var loaded: NSImage?
    @State private var loadedID = ""

    private var id: String { "\(key ?? "")|\(fileURL?.path ?? "")|\(size.rawValue)" }

    var body: some View {
        // Already decoded: show it in this frame, without a placeholder flash.
        let image = loadedID == id ? loaded : key.flatMap { ArtworkImages.shared.cached($0, size) }
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
            .task(id: id) {
                let id = id
                var found: NSImage?
                if let key, let artwork {
                    found = await ArtworkImages.shared.image(for: key, size: size, in: artwork)
                } else if let fileURL {
                    found = await ArtworkImages.shared.image(embeddedIn: fileURL, size: size)
                }
                guard !Task.isCancelled else { return }
                loaded = found
                loadedID = id
            }
            .accessibilityHidden(true)
    }
}

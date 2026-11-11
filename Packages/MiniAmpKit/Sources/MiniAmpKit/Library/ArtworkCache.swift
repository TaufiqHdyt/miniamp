import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// On-disk thumbnails of cover art, keyed by a hash of the original image's bytes, so every
/// track of an album with the same embedded cover shares one file.
///
/// Thumbnails are JPEGs no larger than `maxPixelSize` on their longer side. The original
/// stays in the audio file (or the folder's cover image) and is read again when full size is needed.
public struct ArtworkCache: Sendable {
    public let directory: URL
    public let maxPixelSize: Int

    /// Names checked, in order, for a folder's cover when a file has no embedded picture.
    static let folderImageNames = ["cover", "folder", "front", "album", "artwork"]
    static let folderImageExtensions = ["jpg", "jpeg", "png", "webp", "heic"]

    public init(directory: URL, maxPixelSize: Int = 600) throws {
        self.directory = directory
        self.maxPixelSize = maxPixelSize
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// `~/Library/Caches/miniamp/artwork` (inside the container when sandboxed).
    public static func standard() throws -> ArtworkCache {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try ArtworkCache(directory: caches.appendingPathComponent("miniamp/artwork", isDirectory: true))
    }

    public static func key(for data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public func thumbnailURL(for key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("jpg")
    }

    /// Stores a thumbnail of `imageData` unless one exists. Returns its key, or nil if the
    /// bytes aren't a decodable image.
    @discardableResult
    public func store(_ imageData: Data) -> String? {
        let key = Self.key(for: imageData)
        let url = thumbnailURL(for: key)
        if FileManager.default.fileExists(atPath: url.path) { return key }
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary)
        else { return nil }

        // Write to a temporary name and move into place, so a reader never sees half a file.
        let temporary = directory.appendingPathComponent(".\(key)-\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporary)
            return nil
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
            // Another scan task stored the same image first.
            try? FileManager.default.removeItem(at: temporary)
        }
        return key
    }

    /// The cover image file in `directory` (cover.jpg, folder.png, …), if any. Case-insensitive.
    static func folderImage(in directory: URL) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        var byLowercased: [String: String] = [:]
        for name in names { byLowercased[name.lowercased()] = name }
        for base in folderImageNames {
            for ext in folderImageExtensions {
                if let name = byLowercased["\(base).\(ext)"] { return directory.appendingPathComponent(name) }
            }
        }
        return nil
    }

    /// Removes thumbnails no track or album refers to.
    public func prune(keeping keys: Set<String>) throws -> Int {
        var removed = 0
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let key = url.deletingPathExtension().lastPathComponent
            if url.pathExtension == "jpg", !keys.contains(key) {
                try FileManager.default.removeItem(at: url)
                removed += 1
            }
        }
        return removed
    }
}

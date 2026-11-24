import Foundation

/// How the library spells paths, so the database, directory listings, and FSEvents agree.
public enum LibraryPaths {
    /// Symlinks resolved (`/tmp` as `/private/tmp`, as FSEvents reports it; `URL.resolvingSymlinksInPath`
    /// strips `/private`), then normalized.
    public static func canonical(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard let resolved = realpath(path, nil) else { return normalized(path) }
        defer { free(resolved) }
        return normalized(String(cString: resolved))
    }

    /// The path within iCloud Drive, independent of the Mac's home directory.
    static func iCloudRelativePath(_ path: String) -> String? {
        let marker = "/Library/Mobile Documents/com~apple~CloudDocs"
        guard let range = path.range(of: marker) else { return nil }
        let relative = path[range.upperBound...]
        guard relative.isEmpty || relative.first == "/" else { return nil }
        return String(relative)
    }

    /// Precomposed (NFC). Directory listings hand back decomposed names, FSEvents precomposed
    /// ones, and SQLite compares bytes, so everything is stored one way.
    public static func normalized(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
    }
}

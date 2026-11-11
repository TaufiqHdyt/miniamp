import Foundation

extension Optional where Wrapped == String {
    /// The trimmed string, or nil if it's missing or blank.
    var nonBlank: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

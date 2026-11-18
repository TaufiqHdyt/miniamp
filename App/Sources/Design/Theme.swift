import MiniAmpKit
import SwiftUI

/// The design's values in one place: spacing, corner radii, shadows, and how strongly each
/// surface takes the playing song's cover colour. Views use these rather than numbers of
/// their own, so the look can change here. See DESIGN.md.
enum Theme {
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 20
        static let xl: CGFloat = 32
        /// Between the edge of a page and its content.
        static let page: CGFloat = 20
    }

    enum Radius {
        /// Covers in rows and the player bar.
        static let small: CGFloat = 4
        /// Album covers, text fields, tooltips.
        static let medium: CGFloat = 6
        /// Cards.
        static let large: CGFloat = 8
        /// Panels set into a page (the visualizer).
        static let panel: CGFloat = 10
    }

    /// How far a thing sits above the page.
    enum Elevation {
        /// A small cover in a bar.
        case hairline
        /// A cover in a grid; `lifted` while the pointer is on it.
        case tile, lifted
        /// A cover in a header, a tooltip.
        case card
        /// A cover over the coloured wash.
        case floating
        /// A panel over the wash, a preview.
        case panel

        var opacity: Double {
            switch self {
            case .hairline, .tile: 0.15
            case .card: 0.2
            case .lifted: 0.25
            case .floating: 0.3
            case .panel: 0.35
            }
        }

        var radius: CGFloat {
            switch self {
            case .hairline: 1.5
            case .tile: 2
            case .card: 3
            case .lifted, .floating: 4
            case .panel: 12
            }
        }

        var y: CGFloat {
            switch self {
            case .hairline: 0.5
            case .tile, .lifted, .card: 1
            case .floating: 2
            case .panel: 4
            }
        }
    }

    /// How strongly surfaces take the playing song's cover colour, as gradient ends.
    enum Tint {
        static let playerBar = (leading: 0.28, trailing: 0.08)
        static let inspector = (top: 0.22, bottom: 0.04)
    }

    /// The black laid over the blurred cover behind full lyrics and the visualizer, so white
    /// text reads on it. A cover with little colour (no tint) can be light grey or white
    /// blurred, so it gets more; so does a light tint.
    static func washDarkness(for tint: ArtworkTint?) -> Double {
        guard let tint else { return 0.6 }
        let luminance = 0.2126 * tint.red + 0.7152 * tint.green + 0.0722 * tint.blue
        return 0.35 + max(0, luminance - 0.5) * 0.5
    }
}

extension View {
    func elevation(_ level: Theme.Elevation) -> some View {
        shadow(color: .black.opacity(level.opacity), radius: level.radius, y: level.y)
    }

    /// Liquid Glass on macOS 26 and later; the material it replaces before that.
    @ViewBuilder
    func glassBackground(in shape: some Shape, fallback: Material = .regularMaterial) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(fallback, in: shape)
        }
    }
}

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
        static let page: CGFloat = 24
    }

    enum Radius {
        /// Covers in rows and the player bar.
        static let small: CGFloat = 4
        /// Album covers, text fields, tooltips.
        static let medium: CGFloat = 8
        /// Cards.
        static let large: CGFloat = 12
        /// The big panels, all alike: the player bar (glass, macOS 26 and later), Up Next
        /// (floating like the sidebar), the visualizer. Continuous corners.
        static let floatingPanel: CGFloat = 20
        static let bar: CGFloat = floatingPanel
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
    /// text reads on it, the dimmed lines included: more the lighter the cover is overall
    /// (a white cover gets 80%), whatever its tint.
    static func washDarkness(brightness: Double?) -> Double {
        guard let brightness else { return 0.35 }
        return min(0.35 + max(0, brightness - 0.3) * 0.75, 0.8)
    }
}

extension View {
    /// Room after a List's last row for the floating player bar. Lists on macOS are AppKit
    /// tables and ignore contentMargins, but leave room for a bottom safe-area inset.
    func clearsPlayerBar(_ app: AppState) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: app.playerBarInset).allowsHitTesting(false)
        }
    }

    func elevation(_ level: Theme.Elevation) -> some View {
        shadow(color: .black.opacity(level.opacity), radius: level.radius, y: level.y)
    }

    func panelSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
        return background(.primary.opacity(0.035), in: shape)
            .overlay { shape.strokeBorder(.primary.opacity(0.09)).allowsHitTesting(false) }
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

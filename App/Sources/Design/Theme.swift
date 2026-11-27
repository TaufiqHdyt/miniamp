import MiniAmpKit
import SwiftUI

/// Shared spacing, corner radii, and shadows.
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
    }

    /// How far a thing sits above the page.
    enum Elevation {
        /// A small cover in a bar.
        case hairline
        /// A cover in a grid; `lifted` while the pointer is on it.
        case tile, lifted
        /// A cover in a header, a tooltip.
        case card
        /// A panel over the wash, a preview.
        case panel

        var opacity: Double {
            switch self {
            case .hairline, .tile: 0.15
            case .card: 0.2
            case .lifted: 0.25
            case .panel: 0.35
            }
        }

        var radius: CGFloat {
            switch self {
            case .hairline: 1.5
            case .tile: 2
            case .card: 3
            case .lifted: 4
            case .panel: 12
            }
        }

        var y: CGFloat {
            switch self {
            case .hairline: 0.5
            case .tile, .lifted, .card: 1
            case .panel: 4
            }
        }
    }
}

extension View {
    func elevation(_ level: Theme.Elevation) -> some View {
        shadow(color: .black.opacity(level.opacity), radius: level.radius, y: level.y)
    }

    func panelSurface() -> some View { modifier(PanelSurface()) }
}

private struct PanelSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
        return content.background(.primary.opacity(contrast == .increased ? 0.08 : 0.035), in: shape)
            .overlay {
                shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.4 : 0.09))
                    .allowsHitTesting(false)
            }
    }
}

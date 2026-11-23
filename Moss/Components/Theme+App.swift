import SwiftUI

/// Moss-only design tokens layered on the shared `Theme`.
extension Theme {
    /// Lottie animation shown by `LoadingView`.
    static let loadingAnimation = "moss_spinner.lottie"

    /// `Card`: roomy, full width, without a border.
    enum CardStyle {
        static let padding = Theme.Spacing.lg
        static let cornerRadius = Theme.Radius.lg
        static let fillsWidth = true
        static let showsBorder = false
    }
}

extension Theme.Colors {
    /// The moss-ball green used by the app icon and site.
    static let moss = Color(red: 0.18, green: 0.41, blue: 0.24)
    static let lichen = Color(red: 0.77, green: 0.84, blue: 0.70)
}

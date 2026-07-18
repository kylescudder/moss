import SwiftUI

struct LoadingView: View {
    let message: String

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            ProgressView()
            Text(message)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.background)
    }
}


import SwiftUI

struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)
            .padding(.horizontal, Theme.Spacing.lg)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: Theme.Radius.md))
        .disabled(isLoading)
    }
}

struct SecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    var assetImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.md) {
                if let assetImage {
                    Image(assetImage)
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }

                Text(title)
                    .font(.body.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)
            .padding(.horizontal, Theme.Spacing.lg)
            .background(Theme.Colors.surface)
            .foregroundStyle(Theme.Colors.textPrimary)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .stroke(Theme.Colors.separator, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
        .buttonStyle(.plain)
    }
}

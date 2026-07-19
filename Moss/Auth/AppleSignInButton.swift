import AuthenticationServices
import SwiftUI

struct AppleSignInButton: View {
    @EnvironmentObject private var services: AppServices

    var body: some View {
        SignInWithAppleButton(
            .continue,
            onRequest: { request in
                services.auth.beginAppleSignIn(request: request)
            },
            onCompletion: { result in
                Task { await services.auth.completeAppleSignIn(result: result) }
            }
        )
        .signInWithAppleButtonStyle(.black)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }
}

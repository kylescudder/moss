import SwiftUI

@main
struct MossApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var services = AppServices()
    @AppStorage("appearance") private var appearance: Appearance = .system

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(services)
                .preferredColorScheme(appearance.colorScheme)
                .task {
                    await services.auth.bootstrap()
                }
                .onOpenURL { url in
                    Task { await services.auth.handle(callbackURL: url) }
                }
        }
    }
}

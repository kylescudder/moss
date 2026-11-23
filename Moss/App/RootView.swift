import SwiftUI

struct RootView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch services.auth.state {
            case .unknown:
                LoadingView(message: "Packing up...")
            case .signedOut:
                NavigationStack { SignInView() }
            case .signedIn:
                if !services.auth.canAccessMainApp {
                    NavigationStack { SignInView() }
                } else {
                    MainTabView()
                        .id(services.auth.currentUserID)
                }
            }
        }
        .task { await services.auth.bootstrap(offlineAccount: services.sync.offlineAccount) }
        .onOpenURL { url in handle(url: url) }
        .onAppear { QuickActionRouter.activate() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                QuickActionRouter.activate()
                if case .signedIn = services.auth.state {
                    Task { await services.push.refreshRegistration() }
                }
                Task { await services.sync.retryConnection() }
            }
        }
        .sheet(isPresented: Binding(
            get: { services.auth.isPasswordRecovery },
            set: { services.auth.isPasswordRecovery = $0 }
        )) {
            ResetPasswordSheet()
                .presentationDetents([.medium, .large])
        }
        .alert(item: Binding(
            get: { services.syncIssues.current },
            set: { services.syncIssues.current = $0 }
        )) { issue in
            Alert(
                title: Text(issue.title),
                message: Text(issue.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func handle(url: URL) {
        QuickActionRouter.handle(url: url, auth: services.auth)
    }
}

struct MainTabView: View {
    @State private var selection: MainTab = .today
    @State private var newTripRequest = 0

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { TodayView() }
                .tabItem { Label("Today", systemImage: "sun.max") }
                .tag(MainTab.today)
            NavigationStack { TripsListView(newTripRequest: newTripRequest) }
                .tabItem { Label("Trips", systemImage: "suitcase") }
                .tag(MainTab.trips)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(MainTab.settings)
        }
        .tint(Theme.Colors.accent)
        .onReceive(NotificationCenter.default.publisher(for: .openNewTrip)) { _ in
            selection = .trips
            newTripRequest += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .openToday)) { _ in
            selection = .today
        }
    }
}

private enum MainTab: Hashable {
    case today, trips, settings
}

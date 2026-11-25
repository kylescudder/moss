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
                if services.auth.canAccessMainApp {
                    Task { await services.sharingInbox.refresh() }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { services.auth.canAccessMainApp && services.showsInvites },
            set: { services.showsInvites = $0 }
        )) {
            ShareInvitesView(inbox: services.sharingInbox, signedInEmail: services.signedInEmail)
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
        // Invite emails link to https://growmoss.app/invites.
        if url.scheme == "https", url.path == "/invites" {
            services.showsInvites = true
            return
        }
        QuickActionRouter.handle(url: url, auth: services.auth)
    }
}

struct MainTabView: View {
    @State private var selection: MainTab = .today
    @State private var showNewTrip = false

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { TodayView() }
                .tabItem { Label("Today", systemImage: "sun.max") }
                .tag(MainTab.today)
            NavigationStack { TripsListView() }
                .tabItem { Label("Trips", systemImage: "suitcase") }
                .tag(MainTab.trips)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(MainTab.settings)
        }
        .tint(Theme.Colors.accent)
        .sheet(isPresented: $showNewTrip) {
            TripEditorView()
        }
        // Fires on appear with any action that arrived before the tabs existed.
        .onReceive(QuickActionInbox.shared.actions) { action in
            switch action {
            case .newTrip:
                selection = .trips
                showNewTrip = true
            case .today:
                selection = .today
            }
        }
    }
}

private enum MainTab: Hashable {
    case today, trips, settings
}

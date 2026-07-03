import SwiftUI

struct RootView: View {
    @EnvironmentObject private var services: AppServices

    var body: some View {
        Group {
            switch services.auth.state {
            case .unknown:
                LoadingView(message: "Loading roam")
            case .signedOut:
                NavigationStack {
                    SignInView()
                }
            case .signedIn:
                AppTabView()
            }
        }
    }
}

private struct AppTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                TripsListView()
            }
            .tabItem {
                Label("Trips", systemImage: "suitcase.fill")
            }

            NavigationStack {
                TodayView()
            }
            .tabItem {
                Label("Today", systemImage: "calendar")
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
        }
    }
}


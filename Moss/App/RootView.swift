import SwiftUI

struct RootView: View {
    @EnvironmentObject private var services: AppServices

    var body: some View {
        Group {
            switch services.auth.state {
            case .unknown:
                LoadingView(message: "Loading Moss")
            case .signedOut:
                NavigationStack {
                    SignInView()
                }
            case .signedIn:
                if services.auth.isPasswordRecovery {
                    NavigationStack {
                        SignInView()
                    }
                } else {
                    AppTabView()
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { services.auth.isPasswordRecovery },
            set: { services.auth.isPasswordRecovery = $0 }
        )) {
            ResetPasswordSheet()
                .presentationDetents([.medium, .large])
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

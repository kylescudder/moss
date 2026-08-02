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

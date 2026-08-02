import Foundation

enum AppSecrets {
    static var supabaseURL: URL {
        URL(string: raw("SUPABASE_URL")) ?? URL(string: "https://example.supabase.co")!
    }

    static var supabaseAnonKey: String {
        raw("SUPABASE_ANON_KEY")
    }

    static var authRedirectURL: URL {
        URL(string: "moss://auth-callback")!
    }

    static var powerSyncURL: URL? { URL(string: raw("POWERSYNC_URL")) }

    static var powerSyncConfigurationError: String? {
        powerSyncURL == nil ? "Missing or invalid POWERSYNC_URL in Config/Secrets.xcconfig." : nil
    }

    static var supabaseConfigurationError: String? {
        let url = raw("SUPABASE_URL")
        let key = raw("SUPABASE_ANON_KEY")
        if url.isEmpty || key.isEmpty {
            return "Missing SUPABASE_URL or SUPABASE_ANON_KEY in Config/Secrets.xcconfig."
        }
        return nil
    }

    private static func raw(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
    }
}

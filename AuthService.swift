import Foundation
import Security

/// Real account system backed by Supabase Auth (GoTrue).
///
/// Sign-up and sign-in hit the project's `/auth/v1` endpoints with the
/// publishable key — the same flow any Supabase client app uses. The password is
/// sent once over HTTPS to Supabase and is never stored by the app; only the
/// returned session tokens are kept, in the Keychain.
@MainActor
final class AuthService: ObservableObject {
    static let shared = AuthService()

    struct User: Codable, Equatable {
        var id: String
        var email: String?
    }

    struct Session: Codable, Equatable {
        var accessToken: String
        var refreshToken: String
        var user: User
    }

    @Published private(set) var session: Session?
    @Published var isWorking = false
    @Published var errorMessage: String?
    /// Set after a sign-up that needs email confirmation before a session exists.
    @Published var pendingConfirmation = false

    private var base: String { Analytics.supabaseURL }
    private var apiKey: String { Analytics.supabaseAnonKey }
    private var configured: Bool { !base.isEmpty && !apiKey.isEmpty }

    private init() {
        // Keychain can pause for a long time while macOS unlocks or migrates it.
        // Never hold the app's main thread (and its entire window) during that read.
        session = nil
        Task { [weak self] in
            let restored = await Task.detached(priority: .utility) {
                Keychain.loadSession()
            }.value
            self?.session = restored
        }
    }

    var isSignedIn: Bool { session != nil }

    // MARK: Actions

    func signUp(email: String, password: String) async {
        await perform(path: "/auth/v1/signup", email: email, password: password, isSignUp: true)
    }

    func signIn(email: String, password: String) async {
        await perform(path: "/auth/v1/token?grant_type=password", email: email, password: password, isSignUp: false)
    }

    func signOut() {
        // Best-effort server revoke; the local session is cleared regardless.
        if let token = session?.accessToken, let url = URL(string: "\(base)/auth/v1/logout") {
            var r = URLRequest(url: url)
            r.httpMethod = "POST"
            r.setValue(apiKey, forHTTPHeaderField: "apikey")
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: r).resume()
        }
        session = nil
        Keychain.clearSession()
    }

    // MARK: Networking

    private func perform(path: String, email: String, password: String, isSignUp: Bool) async {
        errorMessage = nil
        pendingConfirmation = false

        guard configured else {
            errorMessage = "Accounts aren’t configured yet."
            return
        }
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("@"), password.count >= 6 else {
            errorMessage = "Enter a valid email and a password of at least 6 characters."
            return
        }
        guard let url = URL(string: "\(base)\(path)") else { return }

        isWorking = true
        defer { isWorking = false }

        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 20
        r.setValue(apiKey, forHTTPHeaderField: "apikey")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmed, "password": password])

        do {
            let (data, response) = try await URLSession.shared.data(for: r)
            guard let http = response as? HTTPURLResponse else { errorMessage = "No response from server."; return }

            if http.statusCode == 200 || http.statusCode == 201 {
                if let session = parseSession(data) {
                    self.session = session
                    Keychain.saveSession(session)
                } else if isSignUp {
                    // Signup succeeded but no session came back → email
                    // confirmation is turned on for this project.
                    pendingConfirmation = true
                } else {
                    errorMessage = "Signed in, but no session was returned."
                }
            } else {
                errorMessage = parseError(data) ?? "That didn’t work (\(http.statusCode))."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func parseSession(_ data: Data) -> Session? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else { return nil }
        let userJSON = json["user"] as? [String: Any]
        let user = User(id: userJSON?["id"] as? String ?? "",
                        email: userJSON?["email"] as? String)
        return Session(accessToken: access, refreshToken: refresh, user: user)
    }

    private func parseError(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // GoTrue uses a few different error shapes.
        return (json["msg"] as? String)
            ?? (json["error_description"] as? String)
            ?? (json["message"] as? String)
            ?? (json["error"] as? String)
    }
}

// MARK: - Keychain

/// Minimal Keychain wrapper. Session tokens live here rather than UserDefaults so
/// they aren't sitting in a world-readable plist.
private enum Keychain {
    private static let account = "com.livewall.session"
    private static let service = "com.livewall.app"

    static func saveSession(_ session: AuthService.Session) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func loadSession() -> AuthService.Session? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(AuthService.Session.self, from: data)
    }

    static func clearSession() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

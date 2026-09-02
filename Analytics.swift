import AppKit
import Foundation

/// Anonymous install counter.
///
/// Writes one row per installation to a Supabase table so you can see how many
/// people are actually running LiveWall. Deliberately minimal:
///
/// * a random UUID generated on this Mac — it identifies an *install*, never a
///   person, and cannot be traced back to anyone
/// * the app version and the macOS version
///
/// No name, no email, no file paths, no wallpaper titles, no IP logging beyond
/// whatever Supabase does at the network layer. Users can switch it off in
/// Settings. Every failure is silent: analytics must never delay launch or
/// surface an error to someone who just wanted a wallpaper.
enum Analytics {

    // MARK: Configuration

    /// Your Supabase project URL, e.g. "https://abcdefgh.supabase.co".
    /// Leave empty to disable analytics entirely.
    static let supabaseURL = "https://hjaokquzjptekfuecduh.supabase.co"

    /// The project's **anon/public** key. This is safe to ship — it is designed
    /// to be public, and the table's row-level security policy (see the SQL in
    /// docs/analytics-setup.md) allows inserts but not reads.
    static let supabaseAnonKey = "sb_publishable_a-MPJFGu-quTb37HWMNpLA_jJK7h_T6"

    private static let table = "installs"

    // MARK: Settings

    static let optOutKey = "shareAnonymousStats"

    static var isEnabled: Bool {
        guard !supabaseURL.isEmpty, !supabaseAnonKey.isEmpty else { return false }
        return UserDefaults.standard.object(forKey: optOutKey) as? Bool ?? true
    }

    /// Stable random id for this installation, created once.
    static var installID: String {
        let key = "liveWallInstallID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    // MARK: Reporting

    /// True once the server has told us this install is banned. Checked at
    /// launch; the app disables its wallpaper features rather than pretending
    /// to work.
    @MainActor static var isBanned = false

    /// Asks the server whether this install is banned, and what wallpaper is
    /// currently featured. Uses the publishable key, so it can only read the
    /// single row belonging to this install (see the RLS policy in the docs).
    static func checkStatus(_ done: @escaping @Sendable (Bool) -> Void) {
        guard isEnabled,
              let url = URL(string: "\(supabaseURL)/rest/v1/\(table)?select=banned&install_id=eq.\(installID)")
        else { return }
        var r = URLRequest(url: url)
        r.timeoutInterval = 10
        r.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        r.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: r) { data, _, _ in
            guard let data,
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let banned = rows.first?["banned"] as? Bool else { return }
            done(banned)
        }.resume()
    }

    /// Records that this install launched. Call once at startup.
    ///
    /// Upserts on `install_id`, so the row count is the number of installs and
    /// `last_seen` gives you active users over any window you like.
    static func recordLaunch() {
        guard isEnabled,
              let url = URL(string: "\(supabaseURL)/rest/v1/\(table)?on_conflict=install_id")
        else { return }

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let payload: [String: Any] = [
            "install_id": installID,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "os_version": "\(os.majorVersion).\(os.minorVersion)",
            "last_seen": ISO8601DateFormatter().string(from: Date())
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        // merge-duplicates turns the insert into an upsert on install_id.
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = body

        // Fire and forget. A failure here is never worth telling the user about.
        URLSession.shared.dataTask(with: request).resume()
    }

    // MARK: Presence

    private static var heartbeatTimer: Timer?

    /// Refreshes `last_seen` every minute while LiveWall is open, so the admin
    /// console can tell who is actually online right now rather than who last
    /// launched the app. Same single row, same publishable key, no new data.
    @MainActor static func startHeartbeat() {
        guard isEnabled, heartbeatTimer == nil else { return }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            recordLaunch()
        }
    }

    @MainActor static func stopHeartbeat() {
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
    }

    /// Reads any directives the admin has set for *this* install: a wallpaper to
    /// apply, and whether Games has been granted. The app decides what to do
    /// with them — nothing is applied without the normal wallpaper pipeline.
    static func fetchDirectives(_ done: @escaping @Sendable (String?, Bool) -> Void) {
        guard isEnabled,
              let url = URL(string: "\(supabaseURL)/rest/v1/\(table)?select=push_wallpaper,games_granted&install_id=eq.\(installID)")
        else { return }
        var r = URLRequest(url: url)
        r.timeoutInterval = 10
        r.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        r.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: r) { data, _, _ in
            guard let data,
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let row = rows.first else { return }
            done(row["push_wallpaper"] as? String, (row["games_granted"] as? Bool) ?? false)
        }.resume()
    }
}

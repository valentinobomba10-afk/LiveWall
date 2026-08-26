import SwiftUI

/// Admin console — visible only to you.
///
/// The stats/ban/broadcast features need Supabase's **secret** key, which must
/// never ship inside an app handed to strangers. So the admin credentials are
/// NOT compiled in: they are read from a file that lives only on your Mac,
/// `~/.livewall-admin/config.json`:
///
/// ```json
/// { "url": "https://YOURPROJECT.supabase.co",
///   "secret": "sb_secret_..." }
/// ```
///
/// On your laptop the file exists, so typing the code word opens a working
/// console. On anyone else's Mac the file is absent, so the same code word opens
/// a panel that can do nothing — no data, no power, nothing to steal. This is
/// what makes it safe to leave the admin UI in the public build.
@MainActor
final class AdminConfig {
    let url: String
    let secret: String

    static let shared: AdminConfig? = load()

    private init(url: String, secret: String) { self.url = url; self.secret = secret }

    private static func load() -> AdminConfig? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".livewall-admin/config.json")
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let url = json["url"], let secret = json["secret"],
              !url.isEmpty, !secret.isEmpty else { return nil }
        return AdminConfig(url: url, secret: secret)
    }
}

/// One install row as returned by Supabase.
struct InstallRow: Codable, Identifiable {
    var install_id: String
    var app_version: String?
    var os_version: String?
    var first_seen: String?
    var last_seen: String?
    var banned: Bool?
    var id: String { install_id }
}

/// Talks to Supabase with the admin secret. Only ever instantiated when
/// `AdminConfig.shared` is non-nil, i.e. on your machine.
@MainActor
final class AdminService: ObservableObject {
    @Published var installs: [InstallRow] = []
    @Published var pending: [Submission] = []
    @Published var status = ""
    @Published var loading = false

    private let config: AdminConfig

    init(config: AdminConfig) { self.config = config }

    // MARK: Submission review

    /// Pending community submissions waiting for approval.
    func loadPending() {
        guard let req = request("submissions?status=eq.pending&order=created_at.desc") else { return }
        Task {
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let rows = try? JSONDecoder().decode([Submission].self, from: data) {
                pending = rows
            }
        }
    }

    /// Approve or reject a submission. Approved ones become visible to everyone.
    func review(_ id: String, approve: Bool) {
        let payload: [String: Any] = ["status": approve ? "approved" : "rejected",
                                      "reviewed_at": ISO8601DateFormatter().string(from: Date())]
        let body = try? JSONSerialization.data(withJSONObject: payload)
        guard let req = request("submissions?id=eq.\(id)", method: "PATCH", body: body) else { return }
        Task {
            _ = try? await URLSession.shared.data(for: req)
            loadPending()
        }
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest? {
        guard let url = URL(string: "\(config.url)/rest/v1/\(path)") else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 15
        r.setValue(config.secret, forHTTPHeaderField: "apikey")
        r.setValue("Bearer \(config.secret)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if method != "GET" { r.setValue("return=minimal", forHTTPHeaderField: "Prefer") }
        r.httpBody = body
        return r
    }

    func refresh() {
        guard let req = request("installs?select=*&order=last_seen.desc") else { return }
        loading = true
        Task {
            defer { loading = false }
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                let rows = try JSONDecoder().decode([InstallRow].self, from: data)
                installs = rows
                status = "\(rows.count) installs"
            } catch {
                status = "Could not load: \(error.localizedDescription)"
            }
        }
    }

    /// Total, and active in the last 30 days.
    var activeCount: Int {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let iso = ISO8601DateFormatter()
        return installs.filter {
            guard let s = $0.last_seen, let d = iso.date(from: s) else { return false }
            return d > cutoff
        }.count
    }

    var byVersion: [(String, Int)] {
        Dictionary(grouping: installs, by: { $0.app_version ?? "?" })
            .map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
    }

    func setBanned(_ id: String, _ banned: Bool) {
        let body = try? JSONSerialization.data(withJSONObject: ["banned": banned])
        guard let req = request("installs?install_id=eq.\(id)", method: "PATCH", body: body) else { return }
        Task {
            _ = try? await URLSession.shared.data(for: req)
            refresh()
        }
    }

    /// Broadcasts a featured wallpaper URL that installs pick up on next launch.
    /// This is a suggestion the app shows/applies — not covert control of one
    /// person's screen.
    func setFeaturedWallpaper(_ url: String) {
        let payload: [String: Any] = ["id": 1, "wallpaper_url": url, "updated_at": ISO8601DateFormatter().string(from: Date())]
        let body = try? JSONSerialization.data(withJSONObject: payload)
        guard let req = request("broadcast?on_conflict=id", method: "POST", body: body) else { return }
        var r = req
        r.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        Task {
            _ = try? await URLSession.shared.data(for: r)
            status = "Featured wallpaper broadcast."
        }
    }
}

/// The console UI, revealed by the code word in the search field.
struct AdminPanelView: View {
    let onClose: () -> Void
    @StateObject private var service: AdminService
    @State private var featuredURL = ""

    init?(onClose: @escaping () -> Void) {
        guard let config = AdminConfig.shared else { return nil }
        self.onClose = onClose
        _service = StateObject(wrappedValue: AdminService(config: config))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Admin").font(.system(size: 34, weight: .bold)).foregroundStyle(Palette.text)
                    Spacer()
                    Button("Refresh") { service.refresh() }.disabled(service.loading)
                    Button("Close") { onClose() }
                }
                .padding(.top, 60)

                HStack(spacing: 14) {
                    statCard("Total installs", "\(service.installs.count)")
                    statCard("Active (30d)", "\(service.activeCount)")
                    statCard("Banned", "\(service.installs.filter { $0.banned == true }.count)")
                }

                if !service.byVersion.isEmpty {
                    Text("By version").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.text)
                    ForEach(service.byVersion, id: \.0) { v, n in
                        HStack { Text(v).foregroundStyle(Palette.text); Spacer(); Text("\(n)").foregroundStyle(Palette.secondary) }
                            .font(.system(size: 13))
                    }
                }

                // Submission review queue
                HStack {
                    Text("Pending submissions").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.text)
                    if !service.pending.isEmpty {
                        Text("\(service.pending.count)").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Palette.text).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.orange, in: Capsule())
                    }
                }
                if service.pending.isEmpty {
                    Text("Nothing waiting for review.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                } else {
                    ForEach(service.pending) { s in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                                Text("\(s.user_email ?? "?") · \(s.wallpaper_url)")
                                    .font(.system(size: 10)).foregroundStyle(Palette.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("Approve") { service.review(s.id, approve: true) }.foregroundStyle(.green)
                            Button("Reject") { service.review(s.id, approve: false) }.foregroundStyle(.red)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Palette.chip, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }

                Text("Featured wallpaper (broadcast)").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.text)
                HStack {
                    TextField("Video URL to feature on all installs", text: $featuredURL)
                        .textFieldStyle(.roundedBorder)
                    Button("Broadcast") { service.setFeaturedWallpaper(featuredURL) }
                        .disabled(featuredURL.isEmpty)
                }

                Text("Installs").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.text)
                ForEach(service.installs) { row in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.install_id.prefix(8) + "…").font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.text)
                            Text("\(row.app_version ?? "?") · macOS \(row.os_version ?? "?") · seen \(shortDate(row.last_seen))")
                                .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                        }
                        Spacer()
                        if row.banned == true {
                            Text("BANNED").font(.system(size: 10, weight: .bold)).foregroundStyle(.orange)
                            Button("Unban") { service.setBanned(row.install_id, false) }
                        } else {
                            Button("Ban") { service.setBanned(row.install_id, true) }.foregroundStyle(.red)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Palette.chip, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                Text(service.status).font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, 28).padding(.bottom, 40)
        }
        .onAppear { service.refresh(); service.loadPending() }
    }

    private func statCard(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 30, weight: .bold)).foregroundStyle(Palette.text)
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Palette.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func shortDate(_ iso: String?) -> String {
        guard let iso, iso.count >= 10 else { return "?" }
        return String(iso.prefix(10))
    }
}

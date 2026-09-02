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
    var games_granted: Bool?
    var push_wallpaper: String?
    var id: String { install_id }

    /// Online = seen in the last three minutes (the app heartbeats every 60s).
    var isOnline: Bool {
        guard let s = last_seen, let d = ISO8601DateFormatter().date(from: s) else { return false }
        return Date().timeIntervalSince(d) < 180
    }
    var shortID: String { String(install_id.prefix(8)) }
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

    /// Number of installs heartbeating right now.
    var onlineCount: Int { installs.filter(\.isOnline).count }
    var bannedCount: Int { installs.filter { $0.banned == true }.count }

    /// Grants (or revokes) the Games section for one install.
    func setGamesGranted(_ id: String, _ granted: Bool) {
        let body = try? JSONSerialization.data(withJSONObject: ["games_granted": granted])
        guard let req = request("installs?install_id=eq.\(id)", method: "PATCH", body: body) else { return }
        Task {
            _ = try? await URLSession.shared.data(for: req)
            status = granted ? "Games granted to \(id.prefix(8))" : "Games revoked for \(id.prefix(8))"
            refresh()
        }
    }

    /// Suggests a wallpaper to one install. The app applies it through the same
    /// pipeline the user's own clicks use, and only while sharing is enabled.
    func pushWallpaper(_ id: String, url: String) {
        let body = try? JSONSerialization.data(withJSONObject: ["push_wallpaper": url])
        guard let req = request("installs?install_id=eq.\(id)", method: "PATCH", body: body) else { return }
        Task {
            _ = try? await URLSession.shared.data(for: req)
            status = "Wallpaper pushed to \(id.prefix(8))"
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
    @State private var tab = "Overview"
    @State private var userSearch = ""
    @State private var selected: InstallRow?
    @State private var pushURL = ""
    @State private var command = ""
    @State private var log: [String] = ["LiveWall admin terminal. Type `help` for commands."]

    private let tabs = ["Overview", "Users", "Submissions", "Terminal"]

    init?(onClose: @escaping () -> Void) {
        guard let config = AdminConfig.shared else { return nil }
        self.onClose = onClose
        _service = StateObject(wrappedValue: AdminService(config: config))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Picker("", selection: $tab) {
                ForEach(tabs, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 18).padding(.bottom, 12)

            Group {
                switch tab {
                case "Users":       usersTab
                case "Submissions": submissionsTab
                case "Terminal":    terminalTab
                default:            overviewTab
                }
            }
        }
        .onAppear { service.refresh(); service.loadPending() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Admin").font(.system(size: 26, weight: .bold)).foregroundStyle(DS.ink)
                Text(service.status.isEmpty ? "Connected to Supabase" : service.status)
                    .font(.system(size: 12)).foregroundStyle(DS.ink2)
            }
            Spacer()
            if service.loading { ProgressView().scaleEffect(0.6) }
            Button("Refresh") { service.refresh(); service.loadPending() }.buttonStyle(DSGlassButton())
            Button("Close", action: onClose).buttonStyle(DSGlassButton())
        }
        .padding(18)
    }

    // MARK: Overview

    private var overviewTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    stat("Online now", "\(service.onlineCount)", "dot.radiowaves.left.and.right", DS.live)
                    stat("Installs", "\(service.installs.count)", "desktopcomputer", DS.blue)
                    stat("Active 30d", "\(service.activeCount)", "chart.line.uptrend.xyaxis", DS.purple)
                    stat("Banned", "\(service.bannedCount)", "nosign", Color(red: 0.86, green: 0.25, blue: 0.3))
                }

                if !service.byVersion.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Versions").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.ink)
                        ForEach(service.byVersion, id: \.0) { v, n in
                            HStack {
                                Text(v).font(.system(size: 12.5)).foregroundStyle(DS.ink)
                                Spacer()
                                GeometryReader { g in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(DS.divider)
                                        Capsule().fill(DS.accent)
                                            .frame(width: g.size.width * CGFloat(n) / CGFloat(max(service.installs.count, 1)))
                                    }
                                }.frame(height: 7).frame(maxWidth: 260)
                                Text("\(n)").font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(DS.ink2).frame(width: 34, alignment: .trailing)
                            }
                        }
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading).glass()
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text("Broadcast a featured wallpaper").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.ink)
                    Text("Every install picks this up on next launch as a suggestion.")
                        .font(.system(size: 11.5)).foregroundStyle(DS.ink2)
                    HStack(spacing: 9) {
                        TextField("https://…mp4", text: $pushURL)
                            .textFieldStyle(.plain).font(.system(size: 12))
                            .padding(.horizontal, 11).frame(height: 30).glass(DS.rCtl, strong: true)
                        Button("Broadcast") { service.setFeaturedWallpaper(pushURL) }
                            .buttonStyle(DSPrimaryButton()).disabled(pushURL.isEmpty)
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading).glass()
            }
            .padding(18).padding(.top, 0)
        }
    }

    private func stat(_ label: String, _ value: String, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(tint)
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(DS.ink)
            Text(label).font(.system(size: 11)).foregroundStyle(DS.ink2)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).glass(DS.rTile)
    }

    // MARK: Users

    private var filteredUsers: [InstallRow] {
        let q = userSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return service.installs }
        return service.installs.filter {
            $0.install_id.lowercased().contains(q) || ($0.app_version ?? "").contains(q)
        }
    }

    private var usersTab: some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(DS.ink3)
                TextField("Search by install id or version", text: $userSearch)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 11).frame(height: 30).glass(DS.rCtl, strong: true)
            .padding(.horizontal, 18)

            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(filteredUsers) { row in userRow(row) }
                    if filteredUsers.isEmpty {
                        Text("No installs yet.").font(.system(size: 12.5))
                            .foregroundStyle(DS.ink2).padding(.top, 40)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 18)
            }
        }
    }

    private func userRow(_ row: InstallRow) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Circle().fill(row.isOnline ? DS.live : DS.ink3.opacity(0.45))
                    .frame(width: 8, height: 8)
                    .shadow(color: row.isOnline ? DS.live : .clear, radius: 4)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(row.shortID).font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DS.ink)
                        if row.banned == true {
                            Text("BANNED").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Capsule().fill(Color(red: 0.86, green: 0.25, blue: 0.3)))
                        }
                        if row.games_granted == true {
                            Text("GAMES").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Capsule().fill(DS.purple))
                        }
                    }
                    Text("v\(row.app_version ?? "?") · macOS \(row.os_version ?? "?") · \(row.isOnline ? "online" : "last seen \(shortDate(row.last_seen))")")
                        .font(.system(size: 11)).foregroundStyle(DS.ink2)
                }
                Spacer(minLength: 0)
                Button(row.banned == true ? "Unban" : "Ban") {
                    service.setBanned(row.install_id, !(row.banned ?? false))
                }.buttonStyle(DSGlassButton())
                Button(row.games_granted == true ? "Revoke Games" : "Give Games") {
                    service.setGamesGranted(row.install_id, !(row.games_granted ?? false))
                }.buttonStyle(DSGlassButton())
                Button(selected?.id == row.id ? "Hide" : "Wallpaper") {
                    selected = selected?.id == row.id ? nil : row
                }.buttonStyle(DSGlassButton())
            }

            if selected?.id == row.id {
                HStack(spacing: 9) {
                    TextField("Wallpaper URL to push to this install", text: $pushURL)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .padding(.horizontal, 11).frame(height: 28).glass(DS.rCtl, strong: true)
                    Button("Push") {
                        service.pushWallpaper(row.install_id, url: pushURL)
                        pushURL = ""; selected = nil
                    }.buttonStyle(DSPrimaryButton()).disabled(pushURL.isEmpty)
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).glass(DS.rTile)
    }

    private func shortDate(_ iso: String?) -> String {
        guard let iso, let d = ISO8601DateFormatter().date(from: iso) else { return "never" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    // MARK: Submissions

    private var submissionsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if service.pending.isEmpty {
                    Text("No submissions waiting for review.")
                        .font(.system(size: 12.5)).foregroundStyle(DS.ink2)
                        .frame(maxWidth: .infinity).padding(.top, 50)
                }
                ForEach(service.pending, id: \.id) { sub in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(sub.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.ink)
                            Text(sub.wallpaper_url).font(.system(size: 11)).foregroundStyle(DS.ink2).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Button("Approve") { service.review(sub.id, approve: true) }.buttonStyle(DSPrimaryButton())
                        Button("Reject") { service.review(sub.id, approve: false) }.buttonStyle(DSGlassButton())
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).glass(DS.rTile)
                }
            }
            .padding(18).padding(.top, 0)
        }
    }

    // MARK: Terminal

    private var terminalTab: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(log.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(line.hasPrefix(">") ? DS.blue : DS.ink)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: log.count) { _ in
                    withAnimation { proxy.scrollTo(log.count - 1, anchor: .bottom) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(DS.raised, in: RoundedRectangle(cornerRadius: DS.rTile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.rTile, style: .continuous).strokeBorder(DS.hairline))
            .padding(.horizontal, 18)

            HStack(spacing: 8) {
                Text(">").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(DS.blue)
                TextField("command", text: $command)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .onSubmit(run)
                Button("Run", action: run).buttonStyle(DSPrimaryButton()).disabled(command.isEmpty)
            }
            .padding(.horizontal, 11).frame(height: 34)
            .glass(DS.rCtl, strong: true)
            .padding(18)
        }
    }

    private func out(_ s: String) { log.append(s) }

    private func run() {
        let raw = command.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        command = ""
        out("> \(raw)")
        let parts = raw.split(separator: " ").map(String.init)
        let cmd = parts[0].lowercased()
        let args = Array(parts.dropFirst())

        // Resolves a short id prefix to a full install id.
        func resolve(_ prefix: String) -> InstallRow? {
            service.installs.first { $0.install_id.hasPrefix(prefix) }
        }

        switch cmd {
        case "help":
            out("""
            Commands:
              help                        this list
              stats                       totals, online, banned
              users [n]                   list installs (default 20)
              online                      only installs online right now
              find <text>                 search installs
              info <id>                   details for one install
              ban <id> / unban <id>       ban control
              games <id> on|off           grant or revoke the Games section
              wallpaper <id> <url>        push a wallpaper to one install
              broadcast <url>             feature a wallpaper for everyone
              pending                     submissions awaiting review
              approve <id> / reject <id>  review a submission
              refresh                     reload from Supabase
              clear                       clear this log
            """)
        case "clear":
            log = []
        case "refresh":
            service.refresh(); service.loadPending(); out("refreshing…")
        case "stats":
            out("installs=\(service.installs.count) online=\(service.onlineCount) active30d=\(service.activeCount) banned=\(service.bannedCount)")
        case "users":
            let n = args.first.flatMap(Int.init) ?? 20
            if service.installs.isEmpty { out("no installs") }
            for r in service.installs.prefix(n) {
                out("  \(r.shortID)  v\(r.app_version ?? "?")  \(r.isOnline ? "ONLINE " : "offline")\(r.banned == true ? " BANNED" : "")\(r.games_granted == true ? " GAMES" : "")")
            }
        case "online":
            let on = service.installs.filter(\.isOnline)
            out("\(on.count) online")
            for r in on { out("  \(r.shortID)  v\(r.app_version ?? "?")") }
        case "find":
            guard let q = args.first?.lowercased() else { out("usage: find <text>"); break }
            let hits = service.installs.filter { $0.install_id.lowercased().contains(q) || ($0.app_version ?? "").contains(q) }
            out("\(hits.count) match")
            for r in hits.prefix(30) { out("  \(r.shortID)  v\(r.app_version ?? "?")") }
        case "info":
            guard let id = args.first, let r = resolve(id) else { out("no install matching \(args.first ?? "")"); break }
            out("  id        \(r.install_id)")
            out("  version   \(r.app_version ?? "?")")
            out("  macOS     \(r.os_version ?? "?")")
            out("  first     \(r.first_seen ?? "?")")
            out("  last      \(r.last_seen ?? "?")")
            out("  online    \(r.isOnline)")
            out("  banned    \(r.banned ?? false)")
            out("  games     \(r.games_granted ?? false)")
        case "ban", "unban":
            guard let id = args.first, let r = resolve(id) else { out("no install matching \(args.first ?? "")"); break }
            service.setBanned(r.install_id, cmd == "ban")
            out("\(cmd)ned \(r.shortID)")
        case "games":
            guard let id = args.first, let r = resolve(id), args.count > 1 else { out("usage: games <id> on|off"); break }
            let on = args[1].lowercased() == "on"
            service.setGamesGranted(r.install_id, on)
            out("games \(on ? "granted to" : "revoked for") \(r.shortID)")
        case "wallpaper":
            guard args.count >= 2, let r = resolve(args[0]) else { out("usage: wallpaper <id> <url>"); break }
            service.pushWallpaper(r.install_id, url: args[1])
            out("pushed to \(r.shortID)")
        case "broadcast":
            guard let url = args.first else { out("usage: broadcast <url>"); break }
            service.setFeaturedWallpaper(url)
            out("broadcast set")
        case "pending":
            out("\(service.pending.count) pending")
            for s in service.pending { out("  \(s.id.prefix(8))  \(s.title)") }
        case "approve", "reject":
            guard let id = args.first,
                  let sub = service.pending.first(where: { $0.id.hasPrefix(id) }) else { out("no submission matching \(args.first ?? "")"); break }
            service.review(sub.id, approve: cmd == "approve")
            out("\(cmd)ed \(sub.title)")
        default:
            out("unknown command: \(cmd) — type `help`")
        }
    }
}

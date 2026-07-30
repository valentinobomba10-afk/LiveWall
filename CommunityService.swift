import Foundation
import AppKit
import UniformTypeIdentifiers

struct CommunityWallpaper: Codable, Identifiable {
    let id: Int
    let title: String
    let category: String
    let videoURL: String
    let author: String
    let creatorID: Int
    let downloads: Int
    let applies: Int

    func asLibraryItem() -> LibraryItem {
        LibraryItem(title: title, kind: .directURL, urlString: videoURL)
    }
}

struct CommunityNotification: Codable, Identifiable {
    let id: Int
    let type: String
    let title: String
    let body: String
    let readAt: String?

    enum CodingKeys: String, CodingKey { case id, type, title, body; case readAt = "read_at" }
}

@MainActor final class CommunityService: ObservableObject {
    @Published private(set) var wallpapers: [CommunityWallpaper] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isUploading = false
    @Published private(set) var notifications: [CommunityNotification] = []
    @Published var message = "Enter your Community server address to explore shared wallpapers."
    @Published var isError = false
    @Published private(set) var username = UserDefaults.standard.string(forKey: "communityUsername") ?? ""

    private var token: String { UserDefaults.standard.string(forKey: "communityToken") ?? "" }
    var unreadNotificationCount: Int { notifications.filter { $0.readAt == nil }.count }

    func load(from endpoint: String) async {
        guard let url = apiURL(endpoint, action: "wallpapers") else { status("Enter a valid Community server address.", error: true); return }
        isLoading = true; defer { isLoading = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            try validate(response)
            wallpapers = try JSONDecoder().decode(WallpaperList.self, from: data).wallpapers
            if !token.isEmpty { await loadNotifications(from: endpoint) }
            status(wallpapers.isEmpty ? "No community wallpapers have been approved yet." : "Loaded \(wallpapers.count) community wallpapers.", error: false)
        } catch { status(error.localizedDescription, error: true) }
    }

    func register(endpoint: String, username: String, email: String, password: String) async {
        await authenticate(endpoint: endpoint, action: "register", body: ["username": username, "email": email, "password": password])
    }

    func login(endpoint: String, identity: String, password: String) async {
        await authenticate(endpoint: endpoint, action: "login", body: ["identity": identity, "password": password])
    }

    func chooseAndUpload(endpoint: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.prompt = "Upload Video"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let title = url.deletingPathExtension().lastPathComponent
        Task { await upload(source: url, title: title, category: "Other", endpoint: endpoint) }
    }

    func upload(source: URL, title: String, category: String, endpoint: String) async {
        guard !token.isEmpty else { status("Create an account or sign in before uploading.", error: true); return }
        guard let url = apiURL(endpoint, action: "upload") else { status("Enter a valid Community server address.", error: true); return }
        isUploading = true; defer { isUploading = false }
        let boundary = "LiveWall-\(UUID().uuidString)"
        do {
            let video = try Data(contentsOf: source)
            var body = Data()
            body.appendFormField("title", value: title, boundary: boundary)
            body.appendFormField("category", value: category, boundary: boundary)
            body.appendFile("video", filename: source.lastPathComponent, mimeType: mimeType(for: source), data: video, boundary: boundary)
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response)
            let result = try JSONDecoder().decode(APIMessage.self, from: data)
            status(result.message ?? "Uploaded for review.", error: false)
        } catch { status(error.localizedDescription, error: true) }
    }

    func report(wallpaperID: Int, endpoint: String) async {
        await post(endpoint: endpoint, action: "report", body: ["wallpaperID": wallpaperID, "reason": "Inappropriate content"], success: "Thanks. Your report was sent to the moderation queue.")
    }

    func follow(creatorID: Int, endpoint: String) async {
        await post(endpoint: endpoint, action: "follow", body: ["creatorID": creatorID], success: "Creator followed. You will be notified about approved uploads.")
    }

    func track(wallpaperID: Int, event: String, endpoint: String) async {
        guard let url = apiURL(endpoint, action: "track") else { return }
        do {
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            request.httpBody = try JSONSerialization.data(withJSONObject: ["wallpaperID": wallpaperID, "event": event])
            let (_, response) = try await URLSession.shared.data(for: request); try validate(response)
        } catch { }
    }

    func loadNotifications(from endpoint: String) async {
        guard !token.isEmpty, let url = apiURL(endpoint, action: "notifications") else { return }
        do {
            var request = URLRequest(url: url); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request); try validate(response)
            notifications = try JSONDecoder().decode(NotificationList.self, from: data).notifications
        } catch { }
    }

    func markNotificationsRead(endpoint: String) async {
        await post(endpoint: endpoint, action: "read_notifications", body: [:], success: "Notifications marked read.")
        await loadNotifications(from: endpoint)
    }

    private func authenticate(endpoint: String, action: String, body: [String: String]) async {
        guard let url = apiURL(endpoint, action: action) else { status("Enter a valid Community server address.", error: true); return }
        do {
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response)
            let account = try JSONDecoder().decode(Account.self, from: data)
            UserDefaults.standard.set(account.token, forKey: "communityToken")
            UserDefaults.standard.set(account.username, forKey: "communityUsername")
            username = account.username; status("Signed in as \(account.username).", error: false)
        } catch { status(error.localizedDescription, error: true) }
    }

    private func post(endpoint: String, action: String, body: [String: Any], success: String) async {
        guard !token.isEmpty else { status("Create an account or sign in first.", error: true); return }
        guard let url = apiURL(endpoint, action: action) else { status("Enter a valid Community server address.", error: true); return }
        do {
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request); try validate(response)
            status((try? JSONDecoder().decode(APIMessage.self, from: data).message) ?? success, error: false)
        } catch { status(error.localizedDescription, error: true) }
    }

    private func apiURL(_ endpoint: String, action: String) -> URL? {
        guard var components = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "https", components.host != nil else { return nil }
        var items = components.queryItems ?? []; items.append(URLQueryItem(name: "action", value: action)); components.queryItems = items
        return components.url
    }
    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else { throw NSError(domain: "LiveWall Community", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Community server returned error \(http.statusCode)."] ) }
    }
    private func status(_ value: String, error: Bool) { message = value; isError = error }
    private func mimeType(for url: URL) -> String { ["mp4": "video/mp4", "mov": "video/quicktime", "webm": "video/webm"][url.pathExtension.lowercased()] ?? "application/octet-stream" }

    private struct WallpaperList: Codable { let wallpapers: [CommunityWallpaper] }
    private struct NotificationList: Codable { let notifications: [CommunityNotification] }
    private struct Account: Codable { let token: String; let username: String }
    private struct APIMessage: Codable { let message: String? }
}

private extension Data {
    mutating func appendFormField(_ name: String, value: String, boundary: String) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
    }
    mutating func appendFile(_ name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data); append("\r\n".data(using: .utf8)!)
    }
}

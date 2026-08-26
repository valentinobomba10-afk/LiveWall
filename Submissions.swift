import SwiftUI

/// A community wallpaper someone submitted for review.
struct Submission: Codable, Identifiable, Hashable {
    var id: String
    var user_email: String?
    var title: String
    var wallpaper_url: String
    var thumbnail_url: String?
    var status: String          // pending | approved | rejected
    var created_at: String?
}

/// User-facing side of the submission system: submit a wallpaper for review,
/// see your own submissions, and browse the approved community wallpapers.
///
/// Submissions go in as `pending`; nothing is public until you approve it in the
/// Admin tab. Uploads use the signed-in user's token so the database can enforce
/// "you may only submit as yourself" (see the RLS policy in the setup doc).
@MainActor
final class SubmissionService: ObservableObject {
    static let shared = SubmissionService()

    @Published var mine: [Submission] = []
    @Published var approved: [Submission] = []
    @Published var message: String?
    @Published var working = false

    private var base: String { Analytics.supabaseURL }
    private var key: String { Analytics.supabaseAnonKey }

    func submit(title: String, url: String, thumbnail: String) async {
        message = nil
        guard let session = AuthService.shared.session else { message = "Sign in to submit a wallpaper."; return }
        let t = title.trimmingCharacters(in: .whitespaces)
        var u = url.trimmingCharacters(in: .whitespaces)
        if RemoteLink.isGoogleDriveFolder(u) {
            message = "That's a Google Drive folder. Paste a single video's share link instead."; return
        }
        u = RemoteLink.normalized(u)   // Google Drive file link → streamable URL
        guard !t.isEmpty, u.contains("://") else { message = "Enter a title and a full video URL (https://…)."; return }
        guard let endpoint = URL(string: "\(base)/rest/v1/submissions") else { return }

        working = true; defer { working = false }
        var r = URLRequest(url: endpoint)
        r.httpMethod = "POST"
        r.timeoutInterval = 20
        r.setValue(key, forHTTPHeaderField: "apikey")
        r.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        let payload: [String: Any] = [
            "user_id": session.user.id,
            "user_email": session.user.email ?? "",
            "title": t, "wallpaper_url": u,
            "thumbnail_url": thumbnail.trimmingCharacters(in: .whitespaces),
            "status": "pending"
        ]
        r.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (_, resp) = try await URLSession.shared.data(for: r)
            if let h = resp as? HTTPURLResponse, (200..<300).contains(h.statusCode) {
                message = "Submitted! It’ll appear once it’s approved."
                await loadMine()
            } else {
                message = "Submission failed. Make sure the submissions table exists."
            }
        } catch { message = error.localizedDescription }
    }

    /// Uploads a local video/audio file to the `wallpapers` Storage bucket, then
    /// submits its public URL for review. Needs a public bucket named
    /// `wallpapers` with an authenticated-insert policy (see the setup doc).
    func uploadAndSubmit(fileURL: URL, title: String) async {
        message = nil
        guard let session = AuthService.shared.session else { message = "Sign in to submit a wallpaper."; return }
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { message = "Give it a title."; return }
        guard let data = try? Data(contentsOf: fileURL) else { message = "Couldn’t read that file."; return }

        // Supabase free tier caps upload size; keep big 4K files off it.
        let mb = Double(data.count) / 1_048_576
        guard mb <= 50 else { message = "That file is \(Int(mb)) MB. Please keep uploads under 50 MB."; return }

        let ext = fileURL.pathExtension.lowercased()
        let object = "\(session.user.id)/\(UUID().uuidString).\(ext)"
        guard let up = URL(string: "\(base)/storage/v1/object/wallpapers/\(object)") else { return }

        working = true; defer { working = false }
        var r = URLRequest(url: up)
        r.httpMethod = "POST"
        r.timeoutInterval = 120
        r.setValue(key, forHTTPHeaderField: "apikey")
        r.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        r.setValue(Self.mime(ext), forHTTPHeaderField: "Content-Type")
        r.httpBody = data
        do {
            let (_, resp) = try await URLSession.shared.data(for: r)
            guard let h = resp as? HTTPURLResponse, (200..<300).contains(h.statusCode) else {
                message = "Upload failed. Make sure a public 'wallpapers' Storage bucket exists."
                return
            }
            let publicURL = "\(base)/storage/v1/object/public/wallpapers/\(object)"
            await submit(title: t, url: publicURL, thumbnail: "")
        } catch { message = error.localizedDescription }
    }

    private static func mime(_ ext: String) -> String {
        switch ext {
        case "mp4":  return "video/mp4"
        case "mov":  return "video/quicktime"
        case "m4v":  return "video/x-m4v"
        case "webm": return "video/webm"
        case "mp3":  return "audio/mpeg"
        default:     return "application/octet-stream"
        }
    }

    func loadMine() async {
        guard let session = AuthService.shared.session,
              let url = URL(string: "\(base)/rest/v1/submissions?user_id=eq.\(session.user.id)&order=created_at.desc")
        else { mine = []; return }
        var r = URLRequest(url: url)
        r.setValue(key, forHTTPHeaderField: "apikey")
        r.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        if let (data, _) = try? await URLSession.shared.data(for: r),
           let rows = try? JSONDecoder().decode([Submission].self, from: data) { mine = rows }
    }

    func loadApproved() async {
        guard let url = URL(string: "\(base)/rest/v1/submissions?status=eq.approved&order=created_at.desc") else { return }
        var r = URLRequest(url: url)
        r.setValue(key, forHTTPHeaderField: "apikey")
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let (data, _) = try? await URLSession.shared.data(for: r),
           let rows = try? JSONDecoder().decode([Submission].self, from: data) { approved = rows }
    }
}

// MARK: - Profile screen

/// Backdrop-style profile: avatar, identity, stat tiles, and three tabs
/// (Submissions / Favorites / My Uploads).
struct ProfileScreen: View {
    @ObservedObject private var auth = AuthService.shared
    @ObservedObject private var subs = SubmissionService.shared
    @State private var tab = 0
    @State private var showSubmit = false

    private var favoritesCount: Int {
        (UserDefaults.standard.stringArray(forKey: "favorites") ?? []).count
    }
    private var approvedMine: [Submission] { subs.mine.filter { $0.status == "approved" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                stats
                tabBar

                switch tab {
                case 1: favoritesTab
                case 2: uploadsTab
                default: submissionsTab
                }
            }
            .padding(.horizontal, 28).padding(.top, 72).padding(.bottom, 50)
        }
        .sheet(isPresented: $showSubmit) { SubmitSheet() }
        .task { await subs.loadMine() }
    }

    private var header: some View {
        HStack(spacing: 18) {
            Circle()
                .fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 76, height: 76)
                .overlay(Image(systemName: "person.fill").font(.system(size: 32)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 4) {
                Text(auth.session?.user.email ?? "Guest")
                    .font(.system(size: 26, weight: .bold)).foregroundStyle(Palette.text)
                Text(auth.isSignedIn ? "Signed in" : "Not signed in — sign in to submit")
                    .font(.system(size: 13)).foregroundStyle(Palette.secondary)
            }
            Spacer()
            Button {
                if auth.isSignedIn { showSubmit = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    Text("Submit Wallpaper").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .opacity(auth.isSignedIn ? 1 : 0.4)
        }
    }

    private var stats: some View {
        HStack(spacing: 14) {
            statTile("\(subs.mine.count)", "Submissions")
            statTile("\(approvedMine.count)", "Approved")
            statTile("\(favoritesCount)", "Favorites")
        }
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 26, weight: .bold)).foregroundStyle(Palette.text)
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 16)
        .background(Palette.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("Submissions", 0)
            tabButton("Favorites", 1)
            tabButton("My Uploads", 2)
        }
        .padding(3)
        .background(Palette.chip, in: Capsule())
    }

    private func tabButton(_ title: String, _ i: Int) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { tab = i } } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tab == i ? .white : Palette.secondary)
                .frame(maxWidth: .infinity).frame(height: 32)
                .background { if tab == i { Capsule().fill(Color.accentColor) } }
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var submissionsTab: some View {
        if !auth.isSignedIn {
            empty("Sign in to submit wallpapers", "person.crop.circle.badge.questionmark")
        } else if subs.mine.isEmpty {
            empty("No submissions yet", "tray")
        } else {
            ForEach(subs.mine) { submissionRow($0) }
        }
    }

    @ViewBuilder private var uploadsTab: some View {
        if approvedMine.isEmpty { empty("Nothing approved yet", "checkmark.seal") }
        else { ForEach(approvedMine) { submissionRow($0) } }
    }

    private var favoritesTab: some View {
        empty("Your favourites live on the Favorites tab", "heart")
    }

    private func submissionRow(_ s: Submission) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "film").foregroundStyle(Palette.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                Text(s.wallpaper_url).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            Spacer()
            statusBadge(s.status)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Palette.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func statusBadge(_ status: String) -> some View {
        let (color, label): (Color, String) = {
            switch status {
            case "approved": return (.green, "Approved")
            case "rejected": return (.red, "Rejected")
            default:         return (.orange, "Pending")
            }
        }()
        return Text(label)
            .font(.system(size: 10, weight: .bold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }

    private func empty(_ text: String, _ icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(Palette.tertiary)
            Text(text).font(.system(size: 13)).foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 44)
    }
}

/// Submit-a-wallpaper form. URL-based for now: paste a direct video URL and a
/// title. (Hosting uploaded video files would need Supabase Storage — a later
/// step.)
struct SubmitSheet: View {
    @ObservedObject private var subs = SubmissionService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var url = ""
    @State private var pickedFile: URL?
    private enum Mode { case file, link }
    @State private var mode: Mode = .file

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Submit a Wallpaper").font(.system(size: 20, weight: .bold))
            Text("Upload a video file or paste a link. Your submission is reviewed before it goes public.")
                .font(.system(size: 12)).foregroundStyle(.secondary)

            TextField("Title", text: $title).textFieldStyle(.roundedBorder)

            Picker("", selection: $mode) {
                Text("Upload File").tag(Mode.file)
                Text("Paste Link").tag(Mode.link)
            }.pickerStyle(.segmented).labelsHidden()

            if mode == .file {
                HStack(spacing: 10) {
                    Button {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.allowsMultipleSelection = false
                        panel.allowedFileTypes = ["mp4", "mov", "m4v", "webm", "mp3"]
                        if panel.runModal() == .OK { pickedFile = panel.url }
                    } label: {
                        Label(pickedFile == nil ? "Choose File…" : "Change File", systemImage: "film")
                    }
                    Text(pickedFile?.lastPathComponent ?? "mp4, mov, m4v, webm, mp3 · up to 50 MB")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                TextField("Video URL or Google Drive link", text: $url).textFieldStyle(.roundedBorder)
            }

            if let message = subs.message {
                Text(message).font(.system(size: 12))
                    .foregroundStyle(message.hasPrefix("Submitted") ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        if mode == .file, let file = pickedFile {
                            await subs.uploadAndSubmit(fileURL: file, title: title)
                        } else {
                            await subs.submit(title: title, url: url, thumbnail: "")
                        }
                        if subs.message?.hasPrefix("Submitted") == true { dismiss() }
                    }
                } label: {
                    if subs.working { ProgressView().controlSize(.small) }
                    else { Text(mode == .file ? "Upload & Submit" : "Submit") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(subs.working || (mode == .file && pickedFile == nil))
            }
        }
        .padding(22).frame(width: 480)
    }
}

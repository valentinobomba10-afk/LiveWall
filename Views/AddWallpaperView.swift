import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AddWallpaperView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @State private var urlText = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add wallpaper").font(.title.bold())
            Button("Choose Local Video…", systemImage: "folder") { chooseFile() }
            Divider()
            TextField("YouTube or direct video URL", text: $urlText).textFieldStyle(.roundedBorder)
            Button("Add URL", systemImage: "play.rectangle") { addURL() }.buttonStyle(.borderedProminent)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() } }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            let item = WallpaperItem(id: UUID(), name: url.deletingPathExtension().lastPathComponent, sourceType: .localVideo, url: url, bookmark: bookmark)
            library.add(item)
            dismiss()
        }
    }

    private func addURL() {
        guard let url = URL(string: urlText), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            errorMessage = "Enter a valid YouTube or direct video URL."
            return
        }
        let isYouTube = YouTubeURLParser.videoID(from: urlText) != nil
        let kind: WallpaperSourceType = isYouTube ? .youtube : .directVideoURL
        let name = isYouTube ? "YouTube wallpaper" : (url.lastPathComponent.isEmpty ? "Remote video" : url.lastPathComponent)
        library.add(WallpaperItem(id: UUID(), name: name, sourceType: kind, url: url))
        dismiss()
    }
}

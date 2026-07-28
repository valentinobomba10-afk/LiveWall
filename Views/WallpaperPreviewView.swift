import SwiftUI
import AVKit
import WebKit

struct WallpaperPreviewView: View {
    let item: WallpaperItem
    var isWallpaper = false
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: isWallpaper ? 0 : 14))
    }

    @ViewBuilder private var content: some View {
        if [.localVideo, .directVideoURL].contains(item.sourceType), let url = item.resolvedURL {
            VideoPlayer(player: player)
                .onAppear { startVideo(url) }
                .onDisappear { player?.pause() }
        } else if item.sourceType == .youtube, let url = item.url, let id = YouTubeURLParser.videoID(from: url.absoluteString) {
            YouTubePreview(videoID: id)
        } else {
            VStack(spacing: 8) { Image(systemName: "play.rectangle").font(.system(size: 34)); Text("Preview unavailable") }.foregroundStyle(.secondary)
        }
    }

    private func startVideo(_ url: URL) {
        let next = AVPlayer(url: url)
        next.isMuted = item.muted
        next.volume = item.volume
        player = next
        next.play()
    }

    func play() { player?.play() }
    func pause() { player?.pause() }
}

struct YouTubePreview: NSViewRepresentable {
    let videoID: String
    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        let html = "<html><body style='margin:0;background:#000'><iframe width='100%' height='100%' src='https://www.youtube.com/embed/\(videoID)?autoplay=1&controls=0&loop=1&playlist=\(videoID)' frameborder='0' allow='autoplay'></iframe></body></html>"
        view.loadHTMLString(html, baseURL: nil)
        return view
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

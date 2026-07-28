import WebKit

final class YouTubeRenderer: NSObject, WallpaperRenderer {
    let webView = WKWebView(frame: .zero)
    private var videoID = ""
    func load(source: WallpaperSource) async throws { guard let source = source as? YouTubeSource else { throw NSError(domain: "LiveWall", code: 3) }; videoID = source.videoID; webView.loadHTMLString("""
    <!doctype html><html><body style='margin:0;background:#000;overflow:hidden'><iframe width='100%' height='100%' src='https://www.youtube.com/embed/\(videoID)?autoplay=1&controls=0&loop=1&playlist=\(videoID)&playsinline=1' frameborder='0' allow='autoplay; encrypted-media'></iframe></body></html>
    """, baseURL: nil) }
    func play() { webView.evaluateJavaScript(#"document.querySelector('iframe')?.contentWindow.postMessage('{"event":"command","func":"playVideo","args":[]}', '*')"#) }
    func pause() { webView.evaluateJavaScript(#"document.querySelector('iframe')?.contentWindow.postMessage('{"event":"command","func":"pauseVideo","args":[]}', '*')"#) }
    func stop() { webView.stopLoading() }; func setMuted(_ muted: Bool) {}; func setVolume(_ volume: Float) {}
}

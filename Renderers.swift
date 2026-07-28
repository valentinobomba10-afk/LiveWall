import AppKit
import AVFoundation
import WebKit

/// Draws one wallpaper item into one window's content view.
protocol WallpaperRenderer: AnyObject {
    var view: NSView { get }
    func start()
    func play()
    func pause()
    func setMuted(_ muted: Bool)
    func setVolume(_ volume: Float)
    func setScaling(_ mode: ScalingMode)
    func teardown()
}

// MARK: - Local / direct-URL video (AVQueuePlayer + AVPlayerLooper for gapless looping)

/// A layer-backed view hosting an AVPlayerLayer. Click-through (hitTest returns nil).
final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let base = CALayer()
        base.backgroundColor = NSColor.black.cgColor
        layer = base
        playerLayer.frame = bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        base.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); playerLayer.frame = bounds }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // Render at the *actual* display's pixel density (e.g. 2x Retina, or a 5K panel),
    // not a fixed guess — keeps the wallpaper at full native resolution on every screen.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? layer?.contentsScale ?? 2
        layer?.contentsScale = scale
        playerLayer.contentsScale = scale
    }
}

final class VideoWallpaperRenderer: WallpaperRenderer {
    let view: NSView
    private let layerView: PlayerLayerView
    private let queuePlayer = AVQueuePlayer()
    private var looper: AVPlayerLooper?          // MUST be retained or looping stops
    private let url: URL
    private var muted: Bool
    private var volume: Float
    private let loops: Bool

    init(url: URL, muted: Bool, volume: Float, loops: Bool, scaling: ScalingMode) {
        self.url = url
        self.muted = muted
        self.volume = volume
        self.loops = loops
        layerView = PlayerLayerView(frame: .zero)
        view = layerView
        layerView.playerLayer.player = queuePlayer
        layerView.playerLayer.videoGravity = scaling.gravity
        // Preserve the full-resolution source on Retina displays instead of
        // allowing an underscaled backing layer to soften the image.
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        layerView.layer?.contentsScale = scale
        layerView.playerLayer.contentsScale = scale
        layerView.playerLayer.magnificationFilter = .trilinear   // smoother when upscaled
        layerView.playerLayer.minificationFilter = .trilinear    // crisper 4K → display downscale
    }

    func start() {
        let item = AVPlayerItem(url: url)
        item.preferredPeakBitRate = .greatestFiniteMagnitude
        if loops {
            looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        } else {
            queuePlayer.insert(item, after: nil)
        }
        queuePlayer.isMuted = muted
        queuePlayer.volume = volume
        queuePlayer.play()
    }

    func play() { queuePlayer.play() }
    func pause() { queuePlayer.pause() }
    func setMuted(_ m: Bool) { muted = m; queuePlayer.isMuted = m }
    func setVolume(_ v: Float) { volume = v; queuePlayer.volume = v }
    func setScaling(_ mode: ScalingMode) { layerView.playerLayer.videoGravity = mode.gravity }

    func teardown() {
        queuePlayer.pause()
        looper?.disableLooping()
        looper = nil
        queuePlayer.removeAllItems()
        layerView.playerLayer.player = nil
        layerView.removeFromSuperview()
    }
}

// MARK: - YouTube (official IFrame Player API only — no downloading / ad-block / DRM bypass)

final class YouTubeWallpaperRenderer: NSObject, WallpaperRenderer, WKNavigationDelegate, WKScriptMessageHandler {
    let view: NSView
    private let webView: WKWebView
    private let videoID: String
    private var muted: Bool

    init(videoID: String, muted: Bool) {
        self.videoID = videoID
        self.muted = muted
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []      // allow muted autoplay
        let ucc = WKUserContentController()
        config.userContentController = ucc
        webView = WKWebView(frame: .zero, configuration: config)
        view = webView
        super.init()
        ucc.add(self, name: "lw")
        webView.navigationDelegate = self
        // Present as Safari; a bare WKWebView UA is more likely to be refused by YouTube.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
    }

    func start() {
        let html = """
        <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
        #p{position:absolute;inset:0}iframe{width:100%;height:100%;border:0;pointer-events:none}</style>
        </head><body><div id="p"><iframe
          src="https://www.youtube.com/embed/\(videoID)?autoplay=1&mute=\(muted ? 1 : 0)&controls=0&loop=1&playlist=\(videoID)&playsinline=1&enablejsapi=1&origin=https%3A%2F%2Fwww.youtube.com"
          allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen></iframe></div></body></html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com"))
    }

    private func sendCommand(_ function: String, args: String = "[]") {
        let script = "(function(){var f=document.querySelector('iframe');if(f&&f.contentWindow){f.contentWindow.postMessage(JSON.stringify({event:'command',func:'\(function)',args:\(args)}),'https://www.youtube.com');}})();"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func play()  { sendCommand("playVideo") }
    func pause() { sendCommand("pauseVideo") }
    func setMuted(_ m: Bool) {
        muted = m
        let command = m ? "mute" : "unMute"
        sendCommand(command)
    }
    func setVolume(_ v: Float) {
        sendCommand("setVolume", args: "[\(Int(v * 100))]")
    }
    func setScaling(_ mode: ScalingMode) { /* YouTube manages its own layout */ }

    func teardown() {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "lw")
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
    }

    // Surface a clean LiveWall message instead of YouTube's raw error on the desktop.
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let s = m.body as? String else { return }
        if s.hasPrefix("error:") {
            let code = Int(s.dropFirst(6)) ?? -1
            NSLog("[LiveWall/YT] embed error \(code) for \(videoID)")
            showUnavailable(code)
        }
    }

    private func showUnavailable(_ code: Int) {
        let reason: String
        switch code {
        case 2:          reason = "The video link looks invalid."
        case 5:          reason = "A playback error occurred."
        case 100:        reason = "This video is private or has been removed."
        case 101, 150:   reason = "The owner has disabled playback on other sites."
        case 152, 153:   reason = "YouTube blocked embedded playback here (network, region, or embedding restriction)."
        default:         reason = "YouTube can’t play this video here."
        }
        let html = """
        <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#0b0b0d;display:flex;align-items:center;justify-content:center;
        font-family:-apple-system,Helvetica,Arial,sans-serif;color:#fff}
        .box{max-width:640px;text-align:center;padding:24px}
        .icon{font-size:52px;opacity:.5}
        h1{font-size:26px;margin:14px 0 6px} p{color:#b7b7bd;font-size:16px;margin:6px 0}
        .small{color:#7d7d84;font-size:13px;margin-top:16px}</style></head>
        <body><div class="box"><div class="icon">▢</div>
        <h1>This YouTube video can’t be played here</h1>
        <p>\(reason)</p>
        <p class="small">LiveWall uses YouTube’s official player and never downloads videos or bypasses restrictions. Try a local video or a direct video URL.</p>
        </div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        NSLog("[LiveWall/YT] load failed: \(e.localizedDescription)")
        showUnavailable(-1)
    }

    func webView(_ w: WKWebView, didFail navigation: WKNavigation!, withError e: Error) {
        NSLog("[LiveWall/YT] playback page failed: \(e.localizedDescription)")
        showUnavailable(-1)
    }
}

// MARK: - Local interactive HTML / WebGL

final class InteractiveWebWallpaperRenderer: NSObject, WallpaperRenderer {
    let view: NSView
    private let webView: WKWebView
    private let url: URL

    init(url: URL) {
        self.url = url
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: config)
        view = webView
        super.init()
    }

    func start() {
        if url.isFileURL { webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        else { webView.load(URLRequest(url: url)) }
    }
    func play() { webView.evaluateJavaScript("window.liveWallResume && window.liveWallResume()", completionHandler: nil) }
    func pause() { webView.evaluateJavaScript("window.liveWallPause && window.liveWallPause()", completionHandler: nil) }
    func setMuted(_ muted: Bool) { }
    func setVolume(_ volume: Float) { }
    func setScaling(_ mode: ScalingMode) { }
    func teardown() { webView.stopLoading(); webView.loadHTMLString("", baseURL: nil); webView.removeFromSuperview() }
}

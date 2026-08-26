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
    func setPointer(_ point: CGPoint?)
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
    private var endObserver: NSObjectProtocol?
    private var remoteLoader: RemoteVideoAssetLoader?
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

    private var timeObserver: Any?
    private var readyObs: NSKeyValueObservation?

    // Resume position, remembered per video file. Re-applying a wallpaper picks
    // up where it left off instead of restarting from zero.
    private var resumeKey: String { "liveWallResume:\(url.absoluteString)" }

    func start() {
        let item: AVPlayerItem
        if url.isFileURL {
            item = AVPlayerItem(url: url)
        } else {
            let loader = RemoteVideoAssetLoader(url: url)
            remoteLoader = loader
            item = AVPlayerItem(asset: loader.asset)
        }
        item.preferredPeakBitRate = .greatestFiniteMagnitude
        // Remote movie files need a useful buffer before playback. This avoids
        // the repeated play/freeze cycle seen when a multi-gigabyte Drive MP4 is
        // rendered directly onto the desktop.
        item.preferredForwardBufferDuration = url.isFileURL ? 0 : 8
        queuePlayer.automaticallyWaitsToMinimizeStalling = true
        if loops && url.isFileURL {
            looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        } else {
            queuePlayer.insert(item, after: nil)
            if loops {
                // AVPlayerLooper can remain permanently stuck at time zero for
                // very large HTTP MP4s (notably Google Drive files). A normal
                // queued item streams correctly, so loop remote videos by
                // seeking that item when it reaches the end.
                endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: item,
                    queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    self.queuePlayer.seek(to: .zero)
                    self.queuePlayer.play()
                }
            }
        }
        queuePlayer.isMuted = muted
        queuePlayer.volume = volume

        // Seek to the last remembered position — but only once the item is
        // actually ready. Seeking a not-yet-loaded item is silently ignored,
        // which is why resume appeared to do nothing before.
        let resume = UserDefaults.standard.double(forKey: resumeKey)
        if resume > 1 {
            readyObs = queuePlayer.observe(\.currentItem?.status, options: [.new, .initial]) { [weak self] player, _ in
                guard let self, player.currentItem?.status == .readyToPlay else { return }
                player.seek(to: CMTime(seconds: resume, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
                self.readyObs?.invalidate(); self.readyObs = nil
            }
        }
        queuePlayer.play()

        // Persist the position every couple of seconds so it survives quit/stop.
        timeObserver = queuePlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 2, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self, time.seconds.isFinite, time.seconds > 1 else { return }
            UserDefaults.standard.set(time.seconds, forKey: self.resumeKey)
        }
    }

    func play() { queuePlayer.play() }
    func pause() { queuePlayer.pause() }
    func setMuted(_ m: Bool) { muted = m; queuePlayer.isMuted = m }
    func setVolume(_ v: Float) { volume = v; queuePlayer.volume = v }
    func setScaling(_ mode: ScalingMode) { layerView.playerLayer.videoGravity = mode.gravity }
    func setPointer(_ point: CGPoint?) { }

    private func saveResume() {
        let t = queuePlayer.currentTime().seconds
        if t.isFinite, t > 1 { UserDefaults.standard.set(t, forKey: resumeKey) }
    }

    func teardown() {
        saveResume()   // remember where we stopped
        readyObs?.invalidate(); readyObs = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        if let timeObserver { queuePlayer.removeTimeObserver(timeObserver); self.timeObserver = nil }
        queuePlayer.pause()
        looper?.disableLooping()
        looper = nil
        queuePlayer.removeAllItems()
        remoteLoader?.invalidate()
        remoteLoader = nil
        layerView.playerLayer.player = nil
        layerView.removeFromSuperview()
    }
}

// MARK: - Remote HTTP video via WebKit

/// Google Drive's download host sometimes refuses to start inside AVPlayer even
/// though the same H.264/AAC asset is playable. WebKit's media loader handles
/// that HTTP response correctly. This renders only a native HTML5 video element,
/// not Drive's preview webpage, so there are no controls or low-quality overlays.
final class HTML5VideoWallpaperRenderer: NSObject, WallpaperRenderer {
    let view: NSView
    private let webView: WKWebView
    private let url: URL
    private var muted: Bool
    private var volume: Float
    private let loops: Bool
    private var scaling: ScalingMode

    init(url: URL, muted: Bool, volume: Float, loops: Bool, scaling: ScalingMode) {
        self.url = url
        self.muted = muted
        self.volume = volume
        self.loops = loops
        self.scaling = scaling
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = false
        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        view = webView
        super.init()
    }

    func start() {
        let escaped = url.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let fit = cssObjectFit(scaling)
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#000}
        video{width:100%;height:100%;object-fit:\(fit);background:#000}</style></head>
        <body><video id="v" src="\(escaped)" autoplay playsinline \(loops ? "loop" : "") \(muted ? "muted" : "")></video>
        <script>
        const v=document.getElementById('v');
        v.volume=\(volume);
        v.muted=\(muted);
        const play=()=>v.play().catch(()=>{});
        ['loadedmetadata','canplay','canplaythrough'].forEach(e=>v.addEventListener(e,play));
        document.addEventListener('visibilitychange',()=>{if(!document.hidden)play();});
        setInterval(()=>{if(v.paused&&!v.ended)play();},1500);
        play();
        </script></body></html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://drive.usercontent.google.com/"))
    }

    func play() { webView.evaluateJavaScript("document.getElementById('v')?.play()", completionHandler: nil) }
    func pause() { webView.evaluateJavaScript("document.getElementById('v')?.pause()", completionHandler: nil) }
    func setMuted(_ value: Bool) {
        muted = value
        webView.evaluateJavaScript("document.getElementById('v').muted=\(value)", completionHandler: nil)
    }
    func setVolume(_ value: Float) {
        volume = value
        webView.evaluateJavaScript("document.getElementById('v').volume=\(value)", completionHandler: nil)
    }
    func setScaling(_ mode: ScalingMode) {
        scaling = mode
        webView.evaluateJavaScript("document.getElementById('v').style.objectFit='\(cssObjectFit(mode))'", completionHandler: nil)
    }
    func setPointer(_ point: CGPoint?) { }
    func teardown() { webView.stopLoading(); webView.loadHTMLString("", baseURL: nil); webView.removeFromSuperview() }

    private func cssObjectFit(_ mode: ScalingMode) -> String {
        switch mode {
        case .fill: return "cover"
        case .fit: return "contain"
        case .stretch: return "fill"
        case .center: return "none"
        }
    }
}

// MARK: - Google Drive video preview

/// Drive's `usercontent` download URLs are not stable playback URLs. When a
/// popular file reaches its download quota they return a small HTML error page
/// with HTTP 200, which looks like a silent black wallpaper to a `<video>` tag.
/// Drive's preview player uses its streaming service instead, so use that for
/// Drive-hosted movies and continuously nudge its media element into autoplay.
final class GoogleDriveWallpaperRenderer: NSObject, WallpaperRenderer {
    let view: NSView
    private let webView: WKWebView
    private let previewURL: URL
    private var muted: Bool
    private var volume: Float
    private let loops: Bool
    private var scaling: ScalingMode
    private var delayedStart: DispatchWorkItem?

    init?(downloadURL: URL, muted: Bool, volume: Float, loops: Bool, scaling: ScalingMode) {
        guard let fileID = Self.fileID(from: downloadURL),
              let previewURL = URL(string: "https://drive.google.com/file/d/\(fileID)/preview") else { return nil }
        self.previewURL = previewURL
        self.muted = muted
        self.volume = volume
        self.loops = loops
        self.scaling = scaling

        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = false

        // This script is injected into every frame. Drive may place the actual
        // player in a child frame, and a main-frame-only script cannot reach it.
        let bootstrap = """
        (() => {
          window.__liveWallMuted = \(muted ? "true" : "false");
          window.__liveWallVolume = \(volume);
          window.__liveWallLoop = \(loops ? "true" : "false");
          window.__liveWallFit = '\(Self.cssObjectFit(scaling))';
          const style = document.createElement('style');
          style.textContent = `
            html,body{margin:0!important;width:100%!important;height:100%!important;overflow:hidden!important;background:#000!important}
            video{width:100%!important;height:100%!important;object-fit:${window.__liveWallFit}!important;background:#000!important}
            [role=toolbar],header,.ndfHFb-c4YZDc-Wrql6b,.ndfHFb-c4YZDc-GSQQnc-LgbsSe{opacity:0!important;pointer-events:none!important}
          `;
          (document.head || document.documentElement).appendChild(style);
          const resume = () => {
            document.querySelectorAll('video,audio').forEach(media => {
              media.muted = window.__liveWallMuted;
              media.volume = window.__liveWallVolume;
              media.loop = window.__liveWallLoop;
              media.playsInline = true;
              media.style.objectFit = window.__liveWallFit;
              if (media.paused && !media.ended) media.play().catch(() => {});
              if (window.__liveWallLoop && media.ended) { media.currentTime = 0; media.play().catch(() => {}); }
            });
            document.querySelectorAll('[aria-label]').forEach(button => {
              const label = (button.getAttribute('aria-label') || '').toLowerCase();
              if ((label === 'play' || label.startsWith('play ')) && button.offsetParent !== null) button.click();
            });
          };
          const forceStart = () => {
            resume();
            document.querySelectorAll('[aria-label],button').forEach(button => {
              const label = ((button.getAttribute('aria-label') || '') + ' ' + (button.textContent || '')).toLowerCase();
              if (label.includes('play')) button.click();
            });
            document.querySelectorAll('iframe').forEach(frame =>
              frame.contentWindow?.postMessage({type:'LIVEWALL_FORCE_PLAY'}, '*')
            );
          };
          window.liveWallResume = resume;
          window.liveWallForceStart = forceStart;
          window.liveWallPause = () => document.querySelectorAll('video,audio').forEach(media => media.pause());
          window.liveWallMedia = (isMuted, mediaVolume, fit) => {
            window.__liveWallMuted = isMuted;
            window.__liveWallVolume = mediaVolume;
            window.__liveWallFit = fit;
            resume();
          };
          new MutationObserver(resume).observe(document.documentElement, {subtree:true,childList:true});
          addEventListener('message', event => {
            if (event.data?.type === 'LIVEWALL_FORCE_PLAY') forceStart();
          });
          addEventListener('load', resume);
          setInterval(resume, 1000);
          setTimeout(forceStart, 10000);
          resume();
        })();
        """
        config.userContentController.addUserScript(
            WKUserScript(source: bootstrap, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        )
        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        view = webView
        super.init()
    }

    func start() {
        webView.load(URLRequest(url: previewURL))
        let task = DispatchWorkItem { [weak self] in self?.forceStart() }
        delayedStart = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: task)
    }
    func play() { forceStart() }
    func pause() { webView.evaluateJavaScript("window.liveWallPause && window.liveWallPause()", completionHandler: nil) }
    func setMuted(_ value: Bool) { muted = value; updateMedia() }
    func setVolume(_ value: Float) { volume = value; updateMedia() }
    func setScaling(_ mode: ScalingMode) { scaling = mode; updateMedia() }
    func setPointer(_ point: CGPoint?) { }
    func teardown() {
        delayedStart?.cancel()
        delayedStart = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
    }

    private func forceStart() {
        webView.evaluateJavaScript("window.liveWallForceStart && window.liveWallForceStart()", completionHandler: nil)
    }

    private func updateMedia() {
        webView.evaluateJavaScript(
            "window.liveWallMedia && window.liveWallMedia(\(muted), \(volume), '\(Self.cssObjectFit(scaling))')",
            completionHandler: nil
        )
    }

    private static func fileID(from url: URL) -> String? {
        if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty { return id }
        let parts = url.pathComponents
        if let index = parts.firstIndex(of: "d"), parts.index(after: index) < parts.endIndex {
            return parts[parts.index(after: index)]
        }
        return nil
    }

    private static func cssObjectFit(_ mode: ScalingMode) -> String {
        switch mode {
        case .fill: return "cover"
        case .fit: return "contain"
        case .stretch: return "fill"
        case .center: return "none"
        }
    }
}

// MARK: - Google Drive native autoplay stream

/// Resolves Drive's public preview metadata to the signed MP4 rendition used by
/// its own player. Unlike a preview-page button, this URL can be handed directly
/// to AVPlayer and therefore autoplays without a synthetic/user click. It also
/// turns MKV originals into a macOS-playable MP4 rendition without downloading
/// the complete source file first.
final class GoogleDriveStreamWallpaperRenderer: WallpaperRenderer {
    let view: NSView
    private let container: NSView
    private let downloadURL: URL
    private var muted: Bool
    private var volume: Float
    private let loops: Bool
    private var scaling: ScalingMode
    private var child: WallpaperRenderer?
    private var resolveTask: URLSessionDataTask?
    private var shouldPlay = true
    private var isTornDown = false

    init(downloadURL: URL, muted: Bool, volume: Float, loops: Bool, scaling: ScalingMode) {
        self.downloadURL = downloadURL
        self.muted = muted
        self.volume = volume
        self.loops = loops
        self.scaling = scaling
        container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        view = container
    }

    func start() {
        guard let fileID = Self.fileID(from: downloadURL),
              let infoURL = URL(string: "https://drive.google.com/get_video_info?docid=\(fileID)") else {
            installFallback()
            return
        }
        var request = URLRequest(url: infoURL)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        resolveTask = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let streamURL = data.flatMap(Self.streamURL(from:))
            DispatchQueue.main.async {
                guard let self, !self.isTornDown else { return }
                if let streamURL { self.installNativePlayer(streamURL) }
                else { self.installFallback() }
            }
        }
        resolveTask?.resume()
    }

    func play() { shouldPlay = true; child?.play() }
    func pause() { shouldPlay = false; child?.pause() }
    func setMuted(_ value: Bool) { muted = value; child?.setMuted(value) }
    func setVolume(_ value: Float) { volume = value; child?.setVolume(value) }
    func setScaling(_ mode: ScalingMode) { scaling = mode; child?.setScaling(mode) }
    func setPointer(_ point: CGPoint?) { child?.setPointer(point) }

    func teardown() {
        isTornDown = true
        resolveTask?.cancel()
        resolveTask = nil
        child?.teardown()
        child = nil
        container.removeFromSuperview()
    }

    private func installNativePlayer(_ streamURL: URL) {
        let renderer = VideoWallpaperRenderer(url: streamURL, muted: muted, volume: volume,
                                              loops: loops, scaling: scaling)
        install(renderer)
    }

    private func installFallback() {
        guard let renderer = GoogleDriveWallpaperRenderer(downloadURL: downloadURL, muted: muted,
                                                           volume: volume, loops: loops,
                                                           scaling: scaling) else { return }
        install(renderer)
    }

    private func install(_ renderer: WallpaperRenderer) {
        guard !isTornDown else { return }
        child?.teardown()
        child = renderer
        renderer.view.frame = container.bounds
        renderer.view.autoresizingMask = [.width, .height]
        container.addSubview(renderer.view)
        renderer.start()
        if !shouldPlay { renderer.pause() }
    }

    private static func fileID(from url: URL) -> String? {
        if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty { return id }
        let parts = url.pathComponents
        if let index = parts.firstIndex(of: "d"), parts.index(after: index) < parts.endIndex {
            return parts[parts.index(after: index)]
        }
        return nil
    }

    private static func streamURL(from data: Data) -> URL? {
        guard let body = String(data: data, encoding: .utf8) else { return nil }
        var components = URLComponents()
        components.query = body
        let items = components.queryItems ?? []

        // Prefer a combined audio/video rendition. This is the same progressive
        // MP4 Drive uses for normal preview playback and is universally handled
        // by AVPlayer on supported macOS versions.
        if let response = items.first(where: { $0.name == "player_response" })?.value,
           let jsonData = response.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let streaming = json["streamingData"] as? [String: Any],
           let formats = streaming["formats"] as? [[String: Any]] {
            let playable = formats.compactMap { format -> (Int, URL)? in
                guard let value = format["url"] as? String, let url = URL(string: value) else { return nil }
                return (format["height"] as? Int ?? 0, url)
            }
            if let best = playable.max(by: { $0.0 < $1.0 }) { return best.1 }
        }

        if let map = items.first(where: { $0.name == "fmt_stream_map" })?.value {
            for entry in map.split(separator: ",") {
                let pair = entry.split(separator: "|", maxSplits: 1).map(String.init)
                if pair.count == 2, let url = URL(string: pair[1]) { return url }
            }
        }
        return nil
    }
}

// MARK: - Static image

/// Used only if a restored request contains an image. Normal image uploads are
/// applied through NSWorkspace so they remain visible even after LiveWall quits.
final class ImageWallpaperRenderer: WallpaperRenderer {
    let view: NSView
    private let imageView: NSImageView

    init(url: URL, scaling: ScalingMode) {
        imageView = NSImageView(frame: .zero)
        imageView.image = NSImage(contentsOf: url)
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        view = imageView
        setScaling(scaling)
    }

    func start() { }
    func play() { }
    func pause() { }
    func setMuted(_ muted: Bool) { }
    func setVolume(_ volume: Float) { }
    func setScaling(_ mode: ScalingMode) {
        imageView.imageScaling = mode == .stretch ? .scaleAxesIndependently : .scaleProportionallyUpOrDown
    }
    func setPointer(_ point: CGPoint?) { }
    func teardown() { imageView.removeFromSuperview() }
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
    func setPointer(_ point: CGPoint?) { }

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
    private var muted: Bool
    private var volume: Float

    init(url: URL, muted: Bool = true, volume: Float = 0.5) {
        self.url = url
        self.muted = muted
        self.volume = volume
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        // Flux's controls contain its web-site navigation, creator links, and
        // purchase prompt. A live wallpaper should render only the artwork.
        let css = "var s=document.createElement('style');s.textContent='#controls{display:none!important}';document.documentElement.appendChild(s);"
        config.userContentController.addUserScript(WKUserScript(source: css, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        view = webView
        super.init()
    }

    func start() {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else { webView.load(URLRequest(url: url)) }
    }
    func play() { webView.evaluateJavaScript("window.liveWallResume && window.liveWallResume()", completionHandler: nil) }
    func pause() { webView.evaluateJavaScript("window.liveWallPause && window.liveWallPause()", completionHandler: nil) }
    func setMuted(_ muted: Bool) {
        self.muted = muted
        sendMediaSettings()
    }
    func setVolume(_ volume: Float) {
        self.volume = volume
        sendMediaSettings()
    }
    func setScaling(_ mode: ScalingMode) { }
    func setPointer(_ point: CGPoint?) {
        let script: String
        if let point { script = "window.liveWallPointer && window.liveWallPointer(\(point.x), \(point.y))" }
        else { script = "window.liveWallPointer && window.liveWallPointer(-2, -2)" }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
    func teardown() { webView.stopLoading(); webView.loadHTMLString("", baseURL: nil); webView.removeFromSuperview() }

    private func sendMediaSettings() {
        let script = """
        (() => {
          const data = {type:'LIVEWALL_MEDIA', muted:\(muted ? "true" : "false"), volume:\(volume)};
          window.postMessage(data, '*');
          document.querySelectorAll('iframe').forEach(frame => frame.contentWindow?.postMessage(data, '*'));
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}

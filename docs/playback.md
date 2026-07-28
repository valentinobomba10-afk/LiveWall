# Playback

Covers spec tasks 9 (local video via AVPlayer), 10 (YouTube via WKWebView), 11 (compliance warnings).

Two renderers implement `WallpaperRenderer`: `VideoWallpaperRenderer` (AVFoundation) and `WebWallpaperRenderer` (WebKit). A factory picks the right one.

---

## 1. Renderer factory

```swift
@MainActor
public final class WallpaperRendererFactory {
    private let settings: SettingsService
    public init(settings: SettingsService) { self.settings = settings }

    public func makeRenderer(for item: WallpaperItem) throws -> WallpaperRenderer {
        switch item.kind {
        case .localVideo, .directVideoURL:
            return try VideoWallpaperRenderer(item: item, settings: settings)
        case .youTube, .youTubeLive:
            return WebWallpaperRenderer(item: item, settings: settings)
        }
    }
}
```

---

## 2. Local & direct-URL video — `VideoWallpaperRenderer`

### 2.1 Design
- **`AVQueuePlayer` + `AVPlayerLooper`** for gapless looping (preferred over `AVPlayerItemDidPlayToEndTime` seeking, which stutters).
- **`AVPlayerLayer`** hosted in a layer-backed `NSView`.
- Muted by default per settings; volume 0–1.
- `videoGravity` maps to `FillMode` (Centre handled specially).
- Security-scoped bookmark resolution for sandboxed local files.

### 2.2 Implementation

```swift
import AVFoundation
import AppKit

@MainActor
public final class VideoWallpaperRenderer: NSObject, WallpaperRenderer {

    public let item: WallpaperItem
    public var onFailure: ((WallpaperError) -> Void)?
    public private(set) var isPlaying = false

    private let settings: SettingsService
    private let playerView = PlayerContainerView()      // layer-backed NSView hosting AVPlayerLayer
    private var queuePlayer: AVQueuePlayer?
    private var looper: AVPlayerLooper?                  // MUST be retained or looping stops
    private var playerLayer: AVPlayerLayer?
    private var securityScopedURL: URL?
    private var statusObs: NSKeyValueObservation?
    private var errorObs: NSObjectProtocol?
    private var currentMode: FillMode

    public var contentView: NSView { playerView }

    public init(item: WallpaperItem, settings: SettingsService) throws {
        self.item = item
        self.settings = settings
        self.currentMode = item.preferredFillMode ?? settings.settings.defaultFillMode
        super.init()
    }

    public func prepare() throws {
        let source: WallpaperSource = (item.kind == .localVideo)
            ? LocalFileSource(item: item) : DirectURLSource(item: item)
        let resolved = try source.resolve()
        guard case let .avURL(url, accessURL) = resolved else {
            throw WallpaperError.unsupportedSource
        }
        securityScopedURL = accessURL

        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false   // cheaper; we only loop
        ])
        let item = AVPlayerItem(asset: asset)
        let queue = AVQueuePlayer()
        queue.isMuted = settings.settings.muteByDefault
        queue.volume = settings.settings.defaultVolume
        queue.actionAtItemEnd = .none
        queue.automaticallyWaitsToMinimizeStalling = true

        let looper = AVPlayerLooper(player: queue, templateItem: item)   // retained below
        let layer = AVPlayerLayer(player: queue)
        layer.videoGravity = currentMode.videoGravity
        playerView.hostLayer(layer)

        self.queuePlayer = queue
        self.looper = looper
        self.playerLayer = layer

        observe(item: item, queue: queue)
        applyFrameRateLimit(settings.settings.frameRateLimit)
    }

    public func play()  { queuePlayer?.play(); isPlaying = true }
    public func pause() { queuePlayer?.pause(); isPlaying = false }
    public func setMuted(_ m: Bool)   { queuePlayer?.isMuted = m }
    public func setVolume(_ v: Float) { queuePlayer?.volume = max(0, min(1, v)) }
    public func setLooping(_ on: Bool) {
        // AVPlayerLooper always loops; to disable, swap to a non-looping queue player.
        // Simplest: keep looper but if !on, observe end and pause. See note below.
    }
    public func setFillMode(_ mode: FillMode) {
        currentMode = mode
        if mode == .center { applyCenterGravity() } else { playerLayer?.videoGravity = mode.videoGravity }
    }
    public func setFrameRateLimit(_ limit: FrameRateLimit) { applyFrameRateLimit(limit) }

    public func teardown() {
        statusObs?.invalidate(); statusObs = nil
        if let errorObs { NotificationCenter.default.removeObserver(errorObs); self.errorObs = nil }
        queuePlayer?.pause()
        queuePlayer?.removeAllItems()
        looper?.disableLooping()
        playerLayer?.player = nil
        playerLayer?.removeFromSuperlayer()
        looper = nil; queuePlayer = nil; playerLayer = nil
        isPlaying = false
        if let url = securityScopedURL { url.stopAccessingSecurityScopedResource(); securityScopedURL = nil }
    }
    deinit { /* teardown must have run on main actor already; do not touch AVKit here */ }

    // MARK: helpers
    private func observe(item: AVPlayerItem, queue: AVQueuePlayer) {
        statusObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                if item.status == .failed {
                    self.onFailure?(.playbackFailed(item.error))
                }
            }
        }
        errorObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
                let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self?.onFailure?(.playbackFailed(err))
        }
    }

    private func applyFrameRateLimit(_ limit: FrameRateLimit) {
        // Prefer capping the layer's max frame duration where supported; otherwise document as best-effort.
        // On displays, honour by choosing source assets/quality; hard fps cap on AVPlayerLayer is limited.
    }

    private func applyCenterGravity() {
        // Centre = 1:1, no scaling, centered. Use resizeAspect but constrain layer bounds to natural size.
        playerLayer?.videoGravity = .resizeAspect
        // Optionally compute natural size via asset track and set layer.frame centered in playerView.bounds.
    }
}

extension FillMode {
    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fill:    return .resizeAspectFill
        case .fit:     return .resizeAspect
        case .stretch: return .resize
        case .center:  return .resizeAspect   // refined by applyCenterGravity()
        }
    }
}
```

`PlayerContainerView`:

```swift
final class PlayerContainerView: NSView {
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func hostLayer(_ layer: AVPlayerLayer) {
        wantsLayer = true
        self.layer = CALayer()
        layer.frame = bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        self.layer?.addSublayer(layer)
    }
    override func layout() { super.layout(); layer?.sublayers?.forEach { $0.frame = bounds } }
}
```

### 2.3 Local file access (sandbox-safe)

```swift
public struct LocalFileSource: WallpaperSource {
    public let item: WallpaperItem
    private var startedURL: URL?
    public init(item: WallpaperItem) { self.item = item }

    public func resolve() throws -> ResolvedWallpaper {
        guard let bookmark = item.localBookmark else { throw WallpaperError.missingLocalFile }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark,
                          options: [.withSecurityScope],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.startAccessingSecurityScopedResource() else { throw WallpaperError.missingLocalFile }
        guard FileManager.default.fileExists(atPath: url.path) else {
            url.stopAccessingSecurityScopedResource(); throw WallpaperError.missingLocalFile
        }
        // If `stale`, caller should re-create the bookmark and persist it.
        return .avURL(url, accessURL: url)
    }
    public func endAccess() { startedURL?.stopAccessingSecurityScopedResource() }
}
```

- Create the bookmark **at pick time** with `NSOpenPanel` and `url.bookmarkData(options: [.withSecurityScope])`, store in `WallpaperItem.localBookmark`.
- Supported containers/codecs: whatever `AVFoundation` supports — `.mp4/.m4v/.mov` with H.264/HEVC, plus HLS `.m3u8` for remote. Reject unsupported files up front (see [error-handling.md](error-handling.md#unsupported-video)).

### 2.4 Loop toggle
`AVPlayerLooper` always loops. To honour a **loop = off** setting, either (a) don't use the looper — use a plain `AVPlayer`, observe `AVPlayerItemDidPlayToEndTime`, and pause on end; or (b) keep the looper and call `disableLooping()` when the user turns loop off. Recommended: build the player in loop mode by default (wallpapers loop), and swap to a non-looping `AVPlayer` only when the user disables loop.

---

## 3. YouTube — `WebWallpaperRenderer` (WKWebView + IFrame Player API)

### 3.1 Design & compliance (task 11 — READ THIS)

LiveWall embeds YouTube **only** through the official **IFrame Player API** served from YouTube's own origin. This is the sanctioned way to play YouTube content in third-party surfaces.

**Absolutely prohibited (do not implement, ever):**
- ❌ Downloading / caching / extracting video or audio streams (no yt-dlp behaviour, no `googlevideo.com` requests, no `player_response` parsing).
- ❌ Blocking, skipping, or hiding ads (no ad-selector CSS, no auto-clicking "Skip").
- ❌ Bypassing DRM (Widevine/FairPlay), login walls, age gates, private-video checks, or geo/region blocks.
- ❌ Injecting scripts that alter YouTube's player behaviour beyond the documented IFrame API calls (`playVideo`, `pauseVideo`, `mute`, `setVolume`, `setPlaybackQuality` hint).
- ❌ Spoofing referrers/user-agents to defeat embedding restrictions.

If the IFrame API reports the video is not embeddable / private / removed / age-restricted / region-blocked, the renderer emits a `WallpaperError` and stops. No fallback that circumvents the restriction is permitted. See [error-handling.md](error-handling.md#youtube-errors).

### 3.2 URL parsing → canonical video id (`YouTubeURLParser`, in Core, unit-tested)

```swift
public enum YouTubeURLParser {
    /// Extracts an 11-char video id from the common URL shapes, or nil.
    public static func videoID(from raw: String) -> String? {
        // Handle: youtube.com/watch?v=ID, youtu.be/ID, youtube.com/live/ID,
        //         youtube.com/embed/ID, youtube.com/shorts/ID, &t=, playlists ignored.
        // Validate against ^[A-Za-z0-9_-]{11}$ before returning.
    }
    public static func isLikelyLivePath(_ raw: String) -> Bool {
        raw.contains("/live/") || raw.contains("watch?") && raw.contains("live")
    }
}
```

Store only the canonical `youTubeVideoID` in `WallpaperItem`; rebuild the embed URL from it.

### 3.3 Embed HTML (`YouTubeEmbedHTML`)

Serve a tiny local HTML page that loads the IFrame API and hosts one player. `enablejsapi=1` lets us call `playVideo`/`pauseVideo`/`mute` via `evaluateJavaScript`. `playsinline`, `mute=1`, and `autoplay=1` are required so autoplay is allowed by the player.

```swift
public enum YouTubeEmbedHTML {
    public static func page(videoID: String, muted: Bool, isLive: Bool) -> String {
        let mute = muted ? 1 : 0
        return """
        <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html,body{margin:0;height:100%;background:#000;overflow:hidden}
          #p{position:absolute;inset:0}
          iframe{width:100%;height:100%;border:0;pointer-events:none} /* non-interactive wallpaper */
        </style></head>
        <body><div id="p"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
          var player;
          function onYouTubeIframeAPIReady(){
            player = new YT.Player('p', {
              videoId: '\(videoID)',
              host: 'https://www.youtube.com',
              playerVars: {
                autoplay: 1, controls: 0, disablekb: 1, fs: 0, modestbranding: 1,
                playsinline: 1, rel: 0, mute: \(mute), loop: 1, playlist: '\(videoID)',
                iv_load_policy: 3
              },
              events: {
                onReady: function(e){ e.target.\(muted ? "mute" : "unMute")(); e.target.playVideo(); },
                onError: function(e){ window.webkit.messageHandlers.yt.postMessage({error: e.data}); },
                onStateChange: function(e){ window.webkit.messageHandlers.yt.postMessage({state: e.data}); }
              }
            });
          }
          window.LiveWall = {
            play:   function(){ player && player.playVideo(); },
            pause:  function(){ player && player.pauseVideo(); },
            mute:   function(){ player && player.mute(); },
            unmute: function(){ player && player.unMute(); },
            volume: function(v){ player && player.setVolume(Math.round(v*100)); }
          };
        </script></body></html>
        """
    }
}
```

> **`loop:1` requires `playlist` set to the same id** — that's the documented IFrame trick for single-video looping. Livestreams ignore loop (they're continuous); that's fine.
>
> **`onError` codes**: `2` invalid param, `5` HTML5 error, `100` removed/private, `101`/`150` embedding disabled by owner. Map these in [error-handling.md](error-handling.md#youtube-errors).

### 3.4 `WebWallpaperRenderer`

```swift
import WebKit
import AppKit

@MainActor
public final class WebWallpaperRenderer: NSObject, WallpaperRenderer, WKNavigationDelegate, WKScriptMessageHandler {
    public let item: WallpaperItem
    public var onFailure: ((WallpaperError) -> Void)?
    public private(set) var isPlaying = false

    private let settings: SettingsService
    private var webView: WKWebView!
    private var reachabilityFailed = false

    public var contentView: NSView { webView }

    public init(item: WallpaperItem, settings: SettingsService) {
        self.item = item; self.settings = settings; super.init()
    }

    public func prepare() throws {
        guard let videoID = item.youTubeVideoID else { throw WallpaperError.invalidURL }

        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []       // allow autoplay (muted)
        config.allowsAirPlayForMediaPlayback = false
        config.suppressesIncrementalRendering = false
        config.websiteDataStore = .nonPersistent()                 // no on-disk cache of YouTube data
        let ucc = WKUserContentController()
        ucc.add(self, name: "yt")
        config.userContentController = ucc

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground")              // transparent under video
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = false
        wv.autoresizingMask = [.width, .height]
        self.webView = wv

        let html = YouTubeEmbedHTML.page(
            videoID: videoID,
            muted: settings.settings.muteByDefault,
            isLive: item.kind == .youTubeLive)
        wv.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com")!)
    }

    public func play()  { eval("window.LiveWall && LiveWall.play()");  isPlaying = true }
    public func pause() { eval("window.LiveWall && LiveWall.pause()"); isPlaying = false }
    public func setMuted(_ m: Bool)   { eval("window.LiveWall && LiveWall.\(m ? "mute" : "unmute")()") }
    public func setVolume(_ v: Float) { eval("window.LiveWall && LiveWall.volume(\(max(0,min(1,v))))") }
    public func setLooping(_ on: Bool) { /* controlled by playerVars.loop at load; reload to change */ }
    public func setFillMode(_ mode: FillMode) { /* CSS object-fit; see note */ }
    public func setFrameRateLimit(_ limit: FrameRateLimit) { /* not controllable via IFrame API */ }

    public func teardown() {
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "yt")
        webView?.navigationDelegate = nil
        webView?.loadHTMLString("", baseURL: nil)   // stop media, release decoders
        webView?.removeFromSuperview()
        webView = nil
        isPlaying = false
    }

    // MARK: WKScriptMessageHandler
    public func userContentController(_ ucc: WKUserContentController, didReceive msg: WKScriptMessage) {
        guard let body = msg.body as? [String: Any] else { return }
        if let code = body["error"] as? Int {
            onFailure?(WallpaperError.youTube(fromIFrameCode: code))
        }
    }

    // MARK: WKNavigationDelegate
    public func webView(_ wv: WKWebView, didFail nav: WKNavigation!, withError error: Error) {
        onFailure?(.webViewFailed(error))
    }
    public func webView(_ wv: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError error: Error) {
        onFailure?(.noInternetOrLoadFailed(error))
    }

    private func eval(_ js: String) { webView?.evaluateJavaScript(js, completionHandler: nil) }
}
```

**Notes**
- `FillMode` for web: apply CSS `object-fit` on the iframe (`cover`=fill, `contain`=fit, `fill`=stretch, `none`=centre) by injecting a style tweak; exact aspect control is limited because YouTube manages its own layout. Document as best-effort.
- Audio-enabled autoplay: browsers/YouTube block **unmuted** autoplay without a user gesture. LiveWall starts muted; if the user enables sound, call `unMute()` — it may require the app window to be key at least once. Document this limitation in the README.
- `.nonPersistent()` data store + `loadHTMLString("")` on teardown ensures nothing is cached to disk and decoders are released.

---

## 4. Shared renderer rules (both types)

- `prepare()` builds resources but does **not** auto-play; `WallpaperManager` calls `play()` after policy check.
- `teardown()` is idempotent and always releases the heavy object (`AVQueuePlayer`/`WKWebView`). After teardown the renderer is inert.
- Failures never crash — they go through `onFailure` to the manager → UI.
- No renderer is shared between windows/displays.

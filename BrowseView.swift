import SwiftUI
import AVKit
import AVFoundation
import AppKit
import WebKit
import QuickLookThumbnailing

// MARK: - Looping muted video (hero background)

final class PlayerHostView: NSView {
    let playerLayer = AVPlayerLayer()
    /// Called when the host becomes visible/hidden, so the player can stop
    /// decoding video the user can't see (window behind others, minimized, or
    /// the app not active). In-app preview video was decoding non-stop even when
    /// the control window was hidden — a major, needless CPU cost.
    var onVisibilityChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); playerLayer.frame = bounds }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var isVisibleNow = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { updateVisibility(); return }
        let nc = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            nc.addObserver(self, selector: #selector(visibilityMayHaveChanged), name: name, object: window)
        }
        updateVisibility()
    }
    @objc private func visibilityMayHaveChanged() { updateVisibility() }
    private func updateVisibility() {
        let visible = (window?.occlusionState.contains(.visible) ?? false) && !(window?.isMiniaturized ?? true)
        guard visible != isVisibleNow else { return }
        isVisibleNow = visible
        onVisibilityChange?(visible)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}

struct LoopingVideoView: NSViewRepresentable {
    let url: URL?
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PlayerHostView {
        let v = PlayerHostView()
        context.coordinator.host = v
        v.onVisibilityChange = { [weak coord = context.coordinator] visible in coord?.setVisible(visible) }
        context.coordinator.load(url)
        return v
    }
    func updateNSView(_ nsView: PlayerHostView, context: Context) { context.coordinator.load(url) }
    static func dismantleNSView(_ nsView: PlayerHostView, coordinator: Coordinator) { coordinator.teardown() }

    final class Coordinator {
        weak var host: PlayerHostView?
        private var currentURL: URL?
        private let queue = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private var visible = true
        func load(_ url: URL?) {
            guard url != currentURL else { return }
            currentURL = url
            looper?.disableLooping(); looper = nil; queue.removeAllItems()
            guard let url else { host?.playerLayer.player = nil; return }
            let item = AVPlayerItem(url: url)
            looper = AVPlayerLooper(player: queue, templateItem: item)
            queue.isMuted = true
            host?.playerLayer.player = queue
            if visible { queue.play() }
        }
        /// Pause decoding while the window is hidden; resume when shown.
        func setVisible(_ shown: Bool) {
            visible = shown
            if shown { queue.play() } else { queue.pause() }
        }
        func teardown() { queue.pause(); looper?.disableLooping(); looper = nil; queue.removeAllItems() }
    }
}

/// Runs bundled HTML games inside LiveWall without opening a separate browser.
/// Toggles the app's real window into and out of native macOS full-screen.
///
/// The game plays inside a SwiftUI `.sheet`, which is a child window attached to
/// the main window. Full-screen belongs to the parent, so we target the titled,
/// visible window (the sheet rides along and grows to fill the space).
@MainActor
enum GameWindow {
    static func toggleFullscreen() {
        let window = NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) }
        window?.toggleFullScreen(nil)
    }

    static var isFullscreen: Bool {
        let window = NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) }
        return window?.styleMask.contains(.fullScreen) ?? false
    }
}

struct BundledGameView: NSViewRepresentable {
    let resourceName: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        // Redirect pop-ups open as new windows; refusing them stops the ad tabs.
        view.uiDelegate = context.coordinator
        let url = Bundle.main.url(forResource: resourceName, withExtension: "html", subdirectory: "Games")
            ?? Bundle.main.url(forResource: resourceName, withExtension: nil, subdirectory: "Games")
        // Turn on the ad blocker first, then load the game.
        AdBlocker.apply(to: configuration) {
            if let url {
                view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        }
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) { }

    /// Blocks pop-ups: `window.open` / target=_blank ad windows never spawn.
    final class Coordinator: NSObject, WKUIDelegate {
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            nil
        }
    }
}

/// Displays a locally imported MP4 in the Movies tab.
struct MoviePlayerView: NSViewRepresentable {
    let url: URL
    final class Coordinator {
        var player: AVPlayer?
        var remoteLoader: RemoteVideoAssetLoader?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        let item: AVPlayerItem
        if url.isFileURL {
            item = AVPlayerItem(url: url)
        } else {
            let loader = RemoteVideoAssetLoader(url: url)
            context.coordinator.remoteLoader = loader
            item = AVPlayerItem(asset: loader.asset)
        }
        item.preferredForwardBufferDuration = url.isFileURL ? 0 : 8
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        view.player = player
        context.coordinator.player = player
        player.play()
        return view
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) { }
    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        nsView.player?.pause()
        nsView.player = nil
        coordinator.remoteLoader?.invalidate()
        coordinator.remoteLoader = nil
        coordinator.player = nil
    }
}

/// Streams a remote MP4 with WebKit. Google Drive's video host serves some
/// large files in a form AVPlayerView reports as unsupported, while Safari's
/// media pipeline can play the same H.264 stream normally.
struct RemoteMoviePlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.isElementFullscreenEnabled = true
        if Self.driveFileID(from: url) != nil {
            let autoplay = """
            (() => {
              const play = () => {
                document.querySelectorAll('video').forEach(video => {
                  video.playsInline = true;
                  if (video.paused && !video.ended) video.play().catch(() => {});
                });
                document.querySelectorAll('[aria-label]').forEach(button => {
                  const label = (button.getAttribute('aria-label') || '').toLowerCase();
                  if ((label === 'play' || label.startsWith('play ')) && button.offsetParent !== null) button.click();
                });
              };
              new MutationObserver(play).observe(document.documentElement, {subtree:true,childList:true});
              setInterval(play, 1000);
              play();
            })();
            """
            configuration.userContentController.addUserScript(
                WKUserScript(source: autoplay, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
            )
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        if let fileID = Self.driveFileID(from: url),
           let preview = URL(string: "https://drive.google.com/file/d/\(fileID)/preview") {
            view.load(URLRequest(url: preview))
            return view
        }
        let escaped = url.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#000}
        video{width:100%;height:100%;object-fit:contain;background:#000}</style></head>
        <body><video id="movie" src="\(escaped)" controls autoplay playsinline></video>
        <script>document.getElementById('movie').play().catch(()=>{});</script></body></html>
        """
        view.loadHTMLString(html, baseURL: URL(string: "https://drive.usercontent.google.com/"))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) { }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) {
        nsView.stopLoading()
        nsView.loadHTMLString("", baseURL: nil)
    }

    private static func driveFileID(from url: URL) -> String? {
        if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty { return id }
        let parts = url.pathComponents
        if let index = parts.firstIndex(of: "d"), parts.index(after: index) < parts.endIndex {
            return parts[parts.index(after: index)]
        }
        return nil
    }
}

/// Displays a movie website in the app. The website remains isolated from the
/// wallpaper renderer and can use normal HTML5 video controls.
struct MovieWebView: NSViewRepresentable {
    let url: URL
    @Binding var currentURL: URL?

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MovieWebView

        init(parent: MovieWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            updateURL(webView.url)
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "liveWallURL", let value = message.body as? String else { return }
            updateURL(URL(string: value))
        }

        private func updateURL(_ url: URL?) {
            guard let url else { return }
            DispatchQueue.main.async { self.parent.currentURL = url }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.isElementFullscreenEnabled = true
        let reportURL = """
        (() => {
          const report = () => window.webkit.messageHandlers.liveWallURL.postMessage(location.href);
          const push = history.pushState.bind(history);
          const replace = history.replaceState.bind(history);
          history.pushState = (...args) => { push(...args); report(); };
          history.replaceState = (...args) => { replace(...args); report(); };
          addEventListener('popstate', report);
          setInterval(report, 750);
          report();
        })();
        """
        configuration.userContentController.addUserScript(
            WKUserScript(source: reportURL, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        configuration.userContentController.add(context.coordinator, name: "liveWallURL")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        DispatchQueue.main.async { currentURL = url }
        return view
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.stopLoading()
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "liveWallURL")
        nsView.navigationDelegate = nil
    }
}

/// Shows a real frame for local movies and an optional poster image for movie websites.
private struct MoviePosterView: View {
    let item: MovieItem
    @State private var localThumbnail: NSImage?

    private var posterURL: URL? {
        guard let value = item.posterURLString else { return nil }
        return URL(string: value)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.purple.opacity(0.55), Color.blue.opacity(0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let localThumbnail {
                Image(nsImage: localThumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let posterURL {
                AsyncImage(url: posterURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if phase.error != nil {
                        fallbackIcon
                    } else {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                }
            } else {
                fallbackIcon
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: item.urlString) { loadLocalThumbnail() }
    }

    private var fallbackIcon: some View {
        Image(systemName: item.kind == .website ? "globe" : "film.fill")
            .font(.system(size: 36))
            .foregroundStyle(.white.opacity(0.9))
    }

    private func loadLocalThumbnail() {
        guard item.kind == .localMP4 else { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: item.urlString),
            size: CGSize(width: 640, height: 360),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async { localThumbnail = image }
        }
    }
}

private struct BundledGameEntry: Identifiable, Hashable {
    let resourceName: String
    let title: String
    var id: String { resourceName }
}


// MARK: - Poster image for a library item

struct PosterView: View {
    let item: LibraryItem
    var contentMode: ContentMode = .fill
    @State private var generated: NSImage?
    @State private var posterIndex = 0

    private var posterURLs: [URL] {
        if item.kind == .youTube { return item.youTubeThumbnailURL.map { [$0] } ?? [] }
        return item.remoteThumbnailURLs
    }

    var body: some View {
        Group {
            if item.kind == .localImage,
                      let kind = item.wallpaperKind(),
                      case let .localImage(url) = kind,
                      let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else if let generated {
                Image(nsImage: generated).resizable().aspectRatio(contentMode: contentMode)
            } else if !posterURLs.isEmpty {
                AsyncImage(url: posterURLs[min(posterIndex, posterURLs.count - 1)]) { phase in
                    switch phase {
                    case .success(let image): image.resizable().aspectRatio(contentMode: contentMode)
                    case .failure:
                        if posterIndex + 1 < posterURLs.count {
                            Color.clear.onAppear { posterIndex += 1 }
                        } else {
                            fallback.task { await generatePreviewFrameIfNeeded() }
                        }
                    case .empty:              fallback
                    @unknown default:         fallback
                    }
                }
            } else {
                fallback.task { if item.kind == .localVideo { await generateFrame() } }
            }
        }
    }

    private var fallback: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.05)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: item.kind.badgeIcon).font(.system(size: 30)).foregroundStyle(.white.opacity(0.3))
        }
    }

    private func generateFrame() async {
        guard generated == nil, item.kind == .localVideo, let kind = item.wallpaperKind() else { return }
        let url: URL?
        switch kind { case .localVideo(let u): url = u; case .localImage, .directURL, .youTube, .web: url = nil }
        if let url { generated = await ThumbnailGenerator.frame(url: url) }
    }

    private func generatePreviewFrameIfNeeded() async {
        guard generated == nil, let source = item.thumbnailURLString,
              let url = URL(string: source), source.lowercased().contains("-preview.mp4") else { return }
        generated = await ThumbnailGenerator.frame(url: url)
    }
}

// MARK: - Helpers

/// What to play on the wallpaper's own detail page.
///
/// Unlike the grid — where opening remote video for every tile would be wasteful —
/// a detail page is showing exactly one wallpaper, so streaming is worth it.
/// MotionBGS ships a small `-preview.mp4` next to each 4K asset; prefer that over
/// pulling the full-size file just to show motion.
private func detailPlayableURL(_ item: LibraryItem) -> URL? {
    if let preview = item.thumbnailURLString, preview.lowercased().contains("-preview.mp4"),
       let url = URL(string: preview) {
        return url
    }
    switch item.kind {
    case .localVideo:
        if case let .localVideo(u)? = item.wallpaperKind() { return u }
        return nil
    case .directURL:
        return item.urlString.flatMap(URL.init(string:))
    case .localImage:
        return nil            // stills have nothing to animate
    case .youTube:
        return nil            // YouTube can't stream into AVPlayer; poster only
    case .web:
        return nil            // interactive wallpapers render in the desktop overlay only
    }
}

/// A URL suitable for a lightweight grid hover-preview: only ever a **local**
/// file. Streaming a remote video on hover made sweeping the grid lag badly, so
/// remote items just show their poster.
private func hoverPreviewURL(_ item: LibraryItem) -> URL? {
    guard item.kind == .localVideo, case let .localVideo(u)? = item.wallpaperKind() else { return nil }
    return u
}

func heroPlayableURL(_ item: LibraryItem) -> URL? {
    switch item.kind {
    case .localVideo:
        if case let .localVideo(u)? = item.wallpaperKind() { return u }
        return nil
    case .localImage:
        return nil
    case .directURL:
        return nil   // never stream a remote 4K clip just to render a preview
    case .youTube:
        return nil            // YouTube can't stream into AVPlayer; poster only
    case .web:
        return nil            // interactive wallpapers render in the desktop overlay only
    }
}

func categoryLabel(_ item: LibraryItem) -> String {
    if let category = item.category, !category.isEmpty { return category }
    let t = item.title.lowercased()
    if item.kind == .web { return "Interactive" }
    func has(_ words: [String]) -> Bool { words.contains { t.contains($0) } }
    if has(["car", "ferrari", "porsche", "bmw", "toyota", "supra", "nissan", "mercedes", "audi", "lamborghini", "drive", "racing", "f1", "road"]) { return "Cars" }
    if has(["minecraft", "roblox", "game", "elden ring", "deltarune", "ghost of tsushima", "nfs", "star citizen"]) { return "Games" }
    if has(["spider", "iron man", "marvel", "batman", "superman", "hero", "avenger"]) { return "Superheroes" }
    if has(["space", "astronaut", "galaxy", "nebula", "moon", "cosmic", "planet", "universe", "saturn", "stellar"]) { return "Space" }
    if has(["forest", "mountain", "ocean", "lake", "rain", "snow", "flower", "meadow", "field", "tree", "sunset", "sunrise", "waterfall", "beach", "nature", "garden", "sky"]) { return "Nature" }
    if has(["cat", "animal", "wolf", "bird", "dog", "tiger", "lion", "fish", "wildlife"]) { return "Animals" }
    if has(["samurai", "knight", "dragon", "fantasy", "magic", "sword", "castle", "dune"]) { return "Fantasy" }
    if has(["anime", "waifu", "chainsaw", "demon slayer", "manga"]) { return "Anime" }
    if has(["magma", "abstract", "vortex", "neon", "rgb", "particle", "fluid"]) { return "Abstract" }
    if has(["city", "building", "street", "train", "tokyo", "night", "urban", "cafe"]) { return "Cities" }
    if has(["razer", "coding", "code", "matrix", "digital", "circuit", "technology", "computer"]) { return "Technology" }
    switch item.kind {
    case .localVideo: return "My Wallpapers"
    case .localImage: return "My Wallpapers"
    case .youTube: return "Online Video"
    case .directURL: return "Other"
    case .web: return "Interactive"
    }
}

func resolutionLabel(_ item: LibraryItem) -> String {
    if item.remoteThumbnailURL?.absoluteString.contains("motionbgs") == true { return "3840×2160" }
    switch item.kind { case .youTube: return "YouTube"; case .localVideo: return "Local video"; case .localImage: return "Picture"; case .directURL: return "Remote"; case .web: return "Interactive" }
}

// MARK: - Grid card

struct WallpaperCard: View {
    let item: LibraryItem
    let favorite: Bool
    let running: Bool
    @State private var hover = false
    @State private var previewURL: URL?
    @State private var previewWork: DispatchWorkItem?

    var body: some View {
        // Backdrop's grid is pure artwork — the title and metadata only surface
        // on hover, so a wall of cards reads as a wall of wallpapers.
        //
        // A transparent 16:9 rectangle fixes each cell to its column width, and
        // the artwork fills that box as an overlay (clipped). Putting the aspect
        // ratio on the poster itself let a `.fill` card overflow its cell and
        // overlap its neighbours — the layout bug this replaces.
        Color.clear
            .aspectRatio(16.0/9.0, contentMode: .fit)
            .overlay { cardContent }
            .clipShape(RoundedRectangle(cornerRadius: Palette.cardRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Palette.cardRadius, style: .continuous))
            .animation(.easeOut(duration: 0.15), value: hover)
            .onHover { hovering in
                hover = hovering
                previewWork?.cancel()
                guard hovering, let url = hoverPreviewURL(item) else { previewURL = nil; return }
                let work = DispatchWorkItem { previewURL = url }
                previewWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
            }
    }

    private var cardContent: some View {
        ZStack(alignment: .bottomLeading) {
            PosterView(item: item)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Hovering previews motion — but only for local files, and only once
            // the pointer has rested a moment, so sweeping the grid stays smooth.
            if let previewURL {
                LoopingVideoView(url: previewURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }

            if hover {
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white).lineLimit(1)
                        Text("\(categoryLabel(item)) · \(resolutionLabel(item))")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: favorite ? "heart.fill" : "heart")
                        .font(.system(size: 12)).foregroundStyle(favorite ? .red : .white.opacity(0.75))
                }
                .padding(10)
            }

            if running {
                HStack(spacing: 4) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("LIVE").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if favorite && !hover {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11)).foregroundStyle(.red)
                    .padding(7).background(.black.opacity(0.45), in: Circle())
                    .padding(6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }
}

struct HeroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.black)
            .padding(.horizontal, 20).padding(.vertical, 11)
            .background(.white, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

// MARK: - Settings sheet

struct SettingsSheet: View {
    @ObservedObject var vm: WallpaperViewModel
    var showsDone = true
    @Environment(\.dismiss) private var dismiss

    private func udBinding(_ key: String, _ def: Bool) -> Binding<Bool> {
        Binding(get: { UserDefaults.standard.object(forKey: key) as? Bool ?? def },
                set: {
                    UserDefaults.standard.set($0, forKey: key)
                    NotificationCenter.default.post(name: .liveWallPowerSettingsChanged, object: nil)
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings").font(.system(size: 22, weight: .bold, design: .serif))

            section("Account") {
                accountRow
            }

            section("Shortcut") {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Turn off wallpaper").font(.system(size: 13)).foregroundStyle(Palette.text)
                        Text("Restores your normal desktop from anywhere")
                            .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    HotKeyRecorder()
                }
            }

            section("Displays") {
                Text("Tick the screens a wallpaper should appear on.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(vm.displays) { d in
                    Toggle(isOn: Binding(get: { vm.selectedDisplayIDs.contains(d.id) }, set: { _ in vm.toggleDisplay(d.id) })) {
                        Text("\(d.name)\(d.isMain ? " • Main" : "")")
                    }.toggleStyle(.checkbox)
                }
            }

            section("Playback") {
                Toggle("Loop", isOn: Binding(get: { vm.loops }, set: { vm.loops = $0 })).toggleStyle(.switch)
                Toggle("Muted", isOn: Binding(get: { vm.muted }, set: { vm.setMuted($0) })).toggleStyle(.switch)
                Picker("Scaling", selection: Binding(get: { vm.scaling }, set: { vm.setScaling($0) })) {
                    ForEach(ScalingMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                HStack { Text("Brightness"); Slider(value: Binding(get: { vm.brightness }, set: { vm.setBrightness($0) }), in: 0...1); Text("\(Int(vm.brightness * 100))%") }.font(.system(size: 12))
                HStack { Text("Color"); Slider(value: Binding(get: { vm.saturation }, set: { vm.setSaturation($0) }), in: 0...2); Text("\(Int(vm.saturation * 100))%") }.font(.system(size: 12))
            }

            section("Wallpaper rotation") {
                Toggle("Rotate wallpapers automatically", isOn: Binding(get: { vm.rotationEnabled }, set: { vm.rotationEnabled = $0; UserDefaults.standard.set($0, forKey: "rotationEnabled") })).toggleStyle(.switch)
                HStack { Text("Every"); Stepper(value: Binding(get: { vm.rotationMinutes }, set: { vm.rotationMinutes = $0; UserDefaults.standard.set($0, forKey: "rotationMinutes") }), in: 1...120, step: 1) { Text("\(Int(vm.rotationMinutes)) minutes") } }
            }

            section("Downloads") {
                Toggle("Offline mode", isOn: Binding(get: { vm.offlineMode }, set: { vm.offlineMode = $0; UserDefaults.standard.set($0, forKey: "offlineMode") })).toggleStyle(.switch)
                if vm.isDownloading {
                    HStack {
                        Text(vm.isDownloadPaused ? "Download paused" : "Downloading: \(vm.downloadTitle)")
                        Spacer()
                        Button(vm.isDownloadPaused ? "Resume" : "Pause") { vm.isDownloadPaused ? vm.resumeDownload() : vm.pauseDownload() }
                    }
                }
                if !vm.queuedDownloads.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Queued downloads").font(.system(size: 12, weight: .semibold))
                        ForEach(vm.queuedDownloads) { item in
                            HStack(spacing: 8) {
                                Text(item.title).lineLimit(1)
                                Spacer()
                                Button("Cancel") { vm.cancelQueuedDownload(item) }.buttonStyle(.borderless)
                            }
                            .font(.system(size: 11))
                        }
                    }
                }
                Text("Storage used: \(ByteCountFormatter.string(fromByteCount: vm.downloadStorageBytes, countStyle: .file))").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Clear downloaded wallpapers…") { vm.clearDownloadedWallpapers() }
            }

            section("Power & startup") {
                Toggle("Pause on battery", isOn: udBinding("pauseOnBattery", false))
                Toggle("Pause in Low Power Mode", isOn: udBinding("pauseOnLowPowerMode", false))
                Toggle("Pause when hidden by a fullscreen app", isOn: udBinding("pauseOnFullscreen", false))
                Toggle("Restore wallpaper on launch", isOn: udBinding("restoreLastWallpaper", true))
                Text("Screen lock and display sleep always pause playback.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            section("Backup") {
                HStack { Button("Export Backup…") { vm.exportBackup() }; Button("Import Backup…") { vm.importBackup() } }
            }

            section("App updates") {
                Text("LiveWall checks the shared GitHub release channel when you ask it to.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("Share anonymous usage stats", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: Analytics.optOutKey) as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: Analytics.optOutKey) }
                ))
                Text("A random ID, the app version and your macOS version. No personal data, ever.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)

                Toggle("Check for updates automatically at launch", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "updateNotificationsEnabled") as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: "updateNotificationsEnabled") }
                ))
                Text("When on, LiveWall quietly checks for a newer version each time it opens and pops up if one is ready.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Check for Updates…") { vm.checkForUpdates() }.buttonStyle(.borderedProminent)
            }

            if showsDone { HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) } }
        }
        .padding(24)
        .foregroundStyle(Palette.text)
    }

    @ViewBuilder private var accountRow: some View {
        // Sign out clears the Keychain session and the "continue without account"
        // skip flag, so the auth screen returns on the next visit.
        if let email = AuthService.shared.session?.user.email {
            HStack {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Signed in").font(.system(size: 13, weight: .semibold))
                    Text(email).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sign Out") {
                    AuthService.shared.signOut()
                    UserDefaults.standard.removeObject(forKey: "skippedSignIn")
                }.buttonStyle(.bordered)
            }
        } else {
            HStack {
                Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(.secondary)
                Text("Not signed in").font(.system(size: 13))
                Spacer()
                Button("Sign In") {
                    UserDefaults.standard.removeObject(forKey: "skippedSignIn")
                }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
            content()
        }
    }
}

/// A click-to-record control for the global "turn off wallpaper" shortcut.
/// Click it, then press the combination you want (at least one modifier).
struct HotKeyRecorder: View {
    @State private var recording = false
    @State private var display = HotKey.display
    @State private var monitor: Any?

    var body: some View {
        Button {
            if recording { stop() } else { start() }
        } label: {
            Text(recording ? "Press keys…" : display)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(recording ? Color.accentColor : Palette.text)
                .frame(minWidth: 96)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Palette.chip, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(recording ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // Require at least one modifier so a bare key can't hijack typing.
            guard !mods.isEmpty else { return nil }
            let char = (event.charactersIgnoringModifiers ?? "").uppercased()
            HotKey.save(keyCode: Int(event.keyCode), modifiers: mods, char: char.isEmpty ? "?" : char)
            display = HotKey.display
            stop()
            return nil   // swallow the event
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}

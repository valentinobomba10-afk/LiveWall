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

private func heroPlayableURL(_ item: LibraryItem) -> URL? {
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

private func categoryLabel(_ item: LibraryItem) -> String {
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

private func resolutionLabel(_ item: LibraryItem) -> String {
    if item.remoteThumbnailURL?.absoluteString.contains("motionbgs") == true { return "3840×2160" }
    switch item.kind { case .youTube: return "YouTube"; case .localVideo: return "Local video"; case .localImage: return "Picture"; case .directURL: return "Remote"; case .web: return "Interactive" }
}

// MARK: - Root browser

struct BrowseView: View {
    @ObservedObject var vm: WallpaperViewModel
    @ObservedObject var library: LibraryStore
    @ObservedObject var movies: MovieStore

    enum Tab: String, CaseIterable {
        case home = "Home", library = "Library", favorites = "Favorites", mine = "My Wallpapers",
             playlists = "Playlists", widgets = "Widgets", profile = "Profile",
             settings = "Settings", movies = "Movies", games = "Games", admin = "Admin"

        var icon: String {
            switch self {
            case .home:      return "star"
            case .library:   return "square.grid.2x2"
            case .favorites: return "heart"
            case .mine:      return "person.crop.square"
            case .playlists: return "rectangle.stack"
            case .widgets:   return "square.grid.2x2.fill"
            case .profile:   return "person.crop.circle"
            case .settings:  return "gearshape"
            case .movies:    return "film"
            case .games:     return "gamecontroller"
            case .admin:     return "lock.shield"
            }
        }
    }
    enum SortMode: String, CaseIterable { case mostLiked = "Most Liked", random = "Random", newest = "Newest" }
    @State private var tab: Tab = .home
    @State private var heroItem: LibraryItem?
    @State private var query = ""
    @State private var category = "All"
    @State private var resolution = "All"
    @State private var source = "All"
    @State private var sort: SortMode = .random
    @State private var favorites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
    @StateObject private var rotation = RotationEngine()
    @ObservedObject private var keys = KeyVault.shared
    private var gamesUnlocked: Bool { keys.isUnlocked }
    @State private var searchOpen = false
    @State private var showAllCategory: String?
    @State private var detailItem: LibraryItem?
    @State private var adminUnlocked = false
    @State private var lastLibraryCount = 0
    private var primaryDisplayID: UInt32 {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return 0 }
        return DisplayObserver.displayID(for: screen)
    }
    // Games open like browser tabs: several can be open at once, each kept alive
    // so switching tabs never reloads a game. No address bar is ever shown.
    @State private var openGames: [BundledGameEntry] = []
    @State private var activeGameID: BundledGameEntry.ID?
    @State private var showGames = false
    @State private var gameFullscreen = false
    @State private var gameSearch = ""
    @State private var gameSort = "Name"
    @State private var gameFilter = "All"
    @State private var gameAscending = true
    @State private var gameFavorites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "gameFavorites") ?? [])
    @State private var selectedMovie: MovieItem?
    @State private var movieDownloadTask: Task<Void, Never>?
    @State private var movieDownloadProgress = 0.0
    @State private var movieDownloadTitle = ""
    @State private var movieIsDownloading = false
    @State private var showMovieDownloadError = false
    @State private var movieError = ""
    @State private var movieSearch = ""
    @State private var movieCurrentURL: URL?

    private var allMovies: [MovieItem] {
        var seen = Set<String>()
        return (movies.items + MovieCatalog.driveMovies).filter {
            seen.insert($0.sourceURLString ?? $0.urlString).inserted
        }
    }

    private var featured: [LibraryItem] { vm.templates }
    private var rotationPool: [LibraryItem] { library.items.isEmpty ? vm.templates : library.items }
    private var favoriteItems: [LibraryItem] { (vm.templates + library.items).filter { favorites.contains($0.id.uuidString) } }

    private var bundledGames: [BundledGameEntry] {
        guard let gamesURL = Bundle.main.resourceURL?.appendingPathComponent("Games", isDirectory: true),
              let enumerator = FileManager.default.enumerator(at: gamesURL, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { item -> BundledGameEntry? in
            guard let url = item as? URL, url.pathExtension.lowercased() == "html" else { return nil }
            let relative = url.path.replacingOccurrences(of: gamesURL.path + "/", with: "")
            let resource = relative.replacingOccurrences(of: ".html", with: "")
            let title = relative
                .replacingOccurrences(of: ".html", with: "")
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "/index", with: "")
                .split(separator: "/")
                .joined(separator: " · ")
                .capitalized
            return BundledGameEntry(resourceName: resource, title: title)
        }
        .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    private var visibleGames: [BundledGameEntry] {
        var result = bundledGames.filter { game in
            (gameSearch.isEmpty || game.title.localizedCaseInsensitiveContains(gameSearch)) &&
            (gameFilter == "All" || gameCategory(game) == gameFilter) &&
            (gameFilter != "Favorites" || gameFavorites.contains(game.id))
        }
        if gameSort == "Category" {
            result.sort { gameCategory($0).localizedCompare(gameCategory($1)) == .orderedAscending }
        }
        if !gameAscending { result.reverse() }
        return result
    }

    private func gameCategory(_ game: BundledGameEntry) -> String {
        let title = game.title.lowercased()
        if title.contains("car") || title.contains("drive") || title.contains("racing") || title.contains("moto") || title.contains("bike") || title.contains("road") { return "Driving" }
        if title.contains("chess") || title.contains("puzzle") || title.contains("2048") || title.contains("clicker") || title.contains("fishing") || title.contains("word") { return "Casual" }
        if title.contains("shooter") || title.contains("fnaf") || title.contains("zombie") || title.contains("battle") || title.contains("war") || title.contains("mario") || title.contains("minecraft") { return "Action" }
        return "Strategy"
    }

    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()
            HStack(spacing: 0) {
                sidebar.frame(width: 216)
                ZStack {
                    if let item = detailItem {
                        detailScreen(item)
                        topBar
                    } else {
                    switch tab {
                    case .home:    homeScreen
                    case .library: gridScreen(items: sortedItems(filtered(vm.templates)), showCategories: true, showAdd: false)
                    case .favorites: gridScreen(items: favoriteItems, showCategories: false, showAdd: false)
                    case .mine:    gridScreen(items: searched(library.items), showCategories: false, showAdd: true)
                    case .playlists: playlistsScreen
                    case .widgets: WidgetsScreen(primaryDisplayID: primaryDisplayID)
                    case .settings: ScrollView { SettingsSheet(vm: vm, showsDone: false).frame(maxWidth: 620).padding(.top, 72) }
                    case .movies: moviesScreen
                    case .games: gamesScreen
                    case .profile: ProfileScreen()
                    case .admin: adminTab
                    }

                    topBar
                    }
                    keyOverlay
                    playerBar
                }
            }
            // The game browser is a full-window overlay (not a sheet), so the
            // Full Screen button — which toggles the real window — makes the game
            // genuinely fill the display instead of floating in a centred sheet.
            if showGames {
                gameBrowser
                    .transition(.opacity)
                    .zIndex(50)
            }
        }
        .animation(.easeOut(duration: 0.18), value: showGames)
        .onAppear {
            lastLibraryCount = library.items.count
            if heroItem == nil { heroItem = featured.first ?? library.items.first }
            rotation.apply = { vm.apply($0) }
            rotation.interval = max(vm.rotationMinutes, 1) * 60
            if vm.rotationEnabled { rotation.start(pool: rotationPool) }
        }
        .onChange(of: vm.rotationEnabled) { enabled in
            if enabled { rotation.interval = max(vm.rotationMinutes, 1) * 60; rotation.start(pool: rotationPool) }
            else { rotation.stop() }
        }
        .onChange(of: vm.rotationMinutes) { minutes in
            rotation.interval = max(minutes, 1) * 60
            if vm.rotationEnabled { rotation.start(pool: rotationPool) }
        }
        .sheet(isPresented: $vm.showAdd) { AddSheet(vm: vm) }
        .onChange(of: library.items.count) { count in
            // Adding a wallpaper should show it. Land on My Wallpapers with a
            // clean slate so no leftover filter or open detail page hides it.
            guard count > lastLibraryCount else { lastLibraryCount = count; return }
            lastLibraryCount = count
            query = ""
            showAllCategory = nil
            detailItem = nil
            withAnimation(.easeOut(duration: 0.15)) { tab = .mine }
        }
        .sheet(item: $selectedMovie) { item in
            moviePlayerSheet(item)
        }
        .alert("Movie download failed", isPresented: $showMovieDownloadError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(movieError)
        }
        .overlay { if vm.isDownloading { downloadOverlay } }
        .overlay { if movieIsDownloading { movieDownloadOverlay } }
        .overlay { KeyBannerOverlay() }
    }

    private func gameTitle(for resource: String) -> String {
        bundledGames.first(where: { $0.resourceName == resource })?.title ?? "LiveWall Game"
    }

    // MARK: Games — browser-style tabs

    /// Opens a game as a tab. If it's already open, just switches to it, so a
    /// game never loads twice. Presents the browser if it isn't showing yet.
    private func openGame(_ game: BundledGameEntry) {
        if !openGames.contains(where: { $0.id == game.id }) { openGames.append(game) }
        activeGameID = game.id
        showGames = true
    }

    /// Closes one tab. Picks a neighbour to keep active; closing the last tab
    /// dismisses the whole browser.
    private func closeGame(_ game: BundledGameEntry) {
        guard let idx = openGames.firstIndex(where: { $0.id == game.id }) else { return }
        openGames.remove(at: idx)
        if openGames.isEmpty {
            showGames = false
            activeGameID = nil
        } else if activeGameID == game.id {
            activeGameID = openGames[min(idx, openGames.count - 1)].id
        }
    }

    /// A Chrome-like game browser: a tab strip on top, one live web view per
    /// open game underneath. No address bar is ever shown — just the game.
    private var gameBrowser: some View {
        VStack(spacing: 0) {
            // Toolbar: exit, tab strip, full-screen.
            HStack(spacing: 10) {
                Button { exitGameBrowser() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                        Text("Back").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)   // Esc exits the browser

                // Scrollable tab strip.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(openGames) { game in gameTab(game) }
                    }
                }

                Spacer(minLength: 0)

                Button {
                    GameWindow.toggleFullscreen()
                    gameFullscreen = GameWindow.isFullscreen
                } label: {
                    Image(systemName: gameFullscreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 30)
                        .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: [.command, .control])
                .help("Toggle full screen")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color(red: 0.09, green: 0.09, blue: 0.11))

            // One web view per open game, kept alive; only the active one shows.
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.05)
                ForEach(openGames) { game in
                    BundledGameView(resourceName: game.resourceName)
                        .opacity(game.id == activeGameID ? 1 : 0)
                        .allowsHitTesting(game.id == activeGameID)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.04, green: 0.04, blue: 0.05).ignoresSafeArea())
        .onAppear { gameFullscreen = GameWindow.isFullscreen }
    }

    /// A single tab chip: title + close button, highlighted when active.
    private func gameTab(_ game: BundledGameEntry) -> some View {
        let active = game.id == activeGameID
        return HStack(spacing: 7) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(active ? 0.9 : 0.5))
            Text(game.title)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(.white.opacity(active ? 1 : 0.7))
                .lineLimit(1)
            Button { closeGame(game) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help("Close tab")
        }
        .padding(.leading, 11).padding(.trailing, 6).padding(.vertical, 6)
        .background(active ? Color.white.opacity(0.16) : Color.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(active ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1))
        .frame(maxWidth: 200)
        .contentShape(Rectangle())
        .onTapGesture { activeGameID = game.id }
    }

    /// Closes the whole browser and tears every game down.
    private func exitGameBrowser() {
        showGames = false
        openGames = []
        activeGameID = nil
    }

    // MARK: Top bar

    /// Backdrop keeps only Create and search up here — everything else lives in
    /// the sidebar, so the content area stays almost entirely artwork.
    private var topBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if detailItem != nil {
                    Button { withAnimation(.easeOut(duration: 0.18)) { detailItem = nil } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                            Text("Back").font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(Palette.text)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Palette.chip, in: Capsule())
                    }.buttonStyle(.plain)
                }
                Spacer()
                if searchOpen {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Palette.secondary).font(.system(size: 12))
                        TextField("Search", text: $query).textFieldStyle(.plain)
                            .onChange(of: query) { value in
                                if value == "valentino2027games" {
                                    query = ""; searchOpen = false; adminUnlocked = true; tab = .admin
                                } else if value == "LiveWall2013" {
                                    query = ""; searchOpen = false
                                    KeyVault.shared.unlockAll()
                                    tab = .games
                                }
                            }
                            .font(.system(size: 13)).frame(width: 150)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Palette.chip, in: Capsule())
                }
                Button { vm.showAdd = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                        Text("Create").font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Palette.chip, in: Capsule())
                }.buttonStyle(.plain)
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { searchOpen.toggle() }
                    if !searchOpen { query = "" }
                } label: {
                    Circle().fill(Palette.chip).frame(width: 32, height: 32)
                        .overlay(Image(systemName: "magnifyingglass")
                            .font(.system(size: 13)).foregroundStyle(Palette.secondary))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 26)
            .padding(.top, 16)
            Spacer()
        }
        // Keep scrolling content from bleeding through the fixed controls.
        .background(
            LinearGradient(colors: [Palette.canvas, Palette.canvas.opacity(0.95), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 96),
            alignment: .top
        )
    }

    private var myCategories: [String] { ["All"] + Set(vm.templates.map { categoryLabel($0) }).sorted() }

    // MARK: Playlists

    private var intervalLabel: String {
        switch Int(rotation.interval) {
        case 60:   return "1 minute"
        case 300:  return "5 minutes"
        case 900:  return "15 minutes"
        case 1800: return "30 minutes"
        case 3600: return "1 hour"
        default:   return "\(Int(rotation.interval / 60)) minutes"
        }
    }

    private var playlistsScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Playlists").font(.system(size: 40, weight: .semibold, design: .serif)).foregroundStyle(Palette.text)

                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.blue.opacity(0.22))
                        .frame(width: 46, height: 46)
                        .overlay(Image(systemName: "rectangle.stack.fill").font(.system(size: 20)).foregroundStyle(.blue))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Rotate your wallpapers").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.text)
                        Text("Cycle wallpapers on a timer. LiveWall switches through your library (or the gallery) automatically.")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08)))

                HStack(spacing: 12) {
                    Label(rotation.isRunning ? "Rotating" : "\(rotationPool.count) wallpapers", systemImage: "music.note.list")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    Text("Every").font(.system(size: 12)).foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { rotation.interval }, set: { rotation.interval = $0 })) {
                        Text("1 min").tag(60.0); Text("5 min").tag(300.0); Text("15 min").tag(900.0)
                        Text("30 min").tag(1800.0); Text("1 hour").tag(3600.0)
                    }.labelsHidden().frame(width: 92).disabled(rotation.isRunning)
                    if rotation.isRunning {
                        Button { rotation.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                            .buttonStyle(GlassButtonStyle(tint: .red)).fixedSize()
                    } else {
                        Button { rotation.start(pool: rotationPool) } label: { Label("Start Rotation", systemImage: "play.fill") }
                            .buttonStyle(PrimaryGlassButtonStyle()).fixedSize()
                    }
                }

                VStack(spacing: 12) {
                    Image(systemName: rotation.isRunning ? "arrow.triangle.2.circlepath" : "music.note.list")
                        .font(.system(size: 40, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 92, height: 92)
                        .background(LinearGradient(colors: [.blue.opacity(0.7), .purple.opacity(0.7)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    Text(rotation.isRunning ? "Rotation running" : "No rotation yet")
                        .font(.system(size: 19, weight: .semibold, design: .serif)).foregroundStyle(Palette.text)
                    Text(rotation.isRunning
                         ? "Switching \(rotationPool.count) wallpapers every \(intervalLabel)."
                         : "Start a rotation to cycle your wallpapers automatically on a timer.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if !rotation.isRunning {
                        Button { rotation.start(pool: rotationPool) } label: { Label("Create Playlist", systemImage: "plus") }
                            .buttonStyle(PrimaryGlassButtonStyle()).fixedSize().padding(.top, 4)
                            .disabled(rotationPool.isEmpty)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 300)
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.06)))
            }
            .padding(24).padding(.top, 76)
        }
    }

    /// Backdrop-style sidebar: navigation sits directly under the traffic lights,
    /// selection is a soft fill with an accent-tinted label, no wordmark.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Tab.allCases.filter { ![.settings, .profile, .admin].contains($0) && ($0 != .games || gamesUnlocked) }, id: \.self) { t in
                navRow(t)
            }
            Spacer(minLength: 0)

            // Once a hunter has found at least one key, show progress and a hint
            // so they know how many remain and roughly where to look. Hidden
            // before the first find (no spoiler) and after Games unlocks.
            if keys.count > 0 && !keys.isUnlocked {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text("🔑").font(.system(size: 13))
                        Text("\(keys.count)/\(KeyVault.total) keys found")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.text)
                    }
                    HStack(spacing: 4) {
                        ForEach(0..<KeyVault.total, id: \.self) { i in
                            Circle()
                                .fill(i < keys.count ? Color.yellow : Palette.hairline)
                                .frame(width: 6, height: 6)
                        }
                    }
                    Text("15 keys hidden on wallpaper pages. Ten glow bottom-right; the last five are dim and tucked in odd corners of busier wallpapers — sweep your cursor to find them.")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 12).padding(.bottom, 6)
            }

            // Bottom cluster: a filled primary row, then Profile / Feedback /
            // Settings — the shape Backdrop uses.
            VStack(spacing: 2) {
                Button { vm.showAdd = true } label: {
                    HStack(spacing: 11) {
                        Image(systemName: "plus").font(.system(size: 14)).frame(width: 18)
                        Text("Add Wallpaper").font(.system(size: 14, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.horizontal, 10)

                bottomRow("Profile", icon: "person.crop.circle") { tab = .profile }
                bottomRow("Feedback", icon: "megaphone") {
                    if let url = URL(string: "mailto:valentino.bomba@hotmail.com?subject=LiveWall%20Feedback") {
                        NSWorkspace.shared.open(url)
                    }
                }
                navRow(.settings)
                if AdminConfig.shared != nil || adminUnlocked { navRow(.admin) }
            }
            .padding(.bottom, 12)
        }
        .padding(.top, 52)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.sidebar.ignoresSafeArea())
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.hairline).frame(width: 1).ignoresSafeArea() }
    }

    /// The Admin tab. Renders the console when this Mac has admin credentials,
    /// otherwise a clear "unavailable" notice. It only reaches the sidebar for the
    /// admin (config present) or after the code word, so ordinary users never see
    /// it — and even if they did, without the local secret key it does nothing.
    @ViewBuilder private var adminTab: some View {
        if let panel = AdminPanelView(onClose: { tab = .home }) {
            panel
        } else {
            VStack(spacing: 10) {
                Image(systemName: "lock.shield").font(.system(size: 34)).foregroundStyle(Palette.tertiary)
                Text("Admin unavailable").font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.text)
                Text("No admin credentials on this Mac.").font(.system(size: 13)).foregroundStyle(Palette.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A quiet sidebar action row (Profile, Feedback) matching navRow's shape.
    private func bottomRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 18)
                    .foregroundStyle(Palette.secondary)
                Text(title).font(.system(size: 14)).foregroundStyle(Palette.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.horizontal, 10)
    }

    /// Small LiveWall branding mark, pinned to the bottom-right corner of the
    /// content area. Subtle so it never fights with the wallpaper grid.
    private var watermark: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 20, height: 20)
                .overlay(Image(systemName: "sparkles.tv.fill")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white))
            Text("LiveWall")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.secondary)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline))
        .opacity(0.7)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .allowsHitTesting(false)
    }

    private func navRow(_ t: Tab) -> some View {
        let active = tab == t
        return Button {
            // The Settings ten-click Easter egg is gone. Games now unlock only
            // once all ten hidden keys have been collected (see KeyVault).
            withAnimation(.easeOut(duration: 0.15)) {
                detailItem = nil          // leave the wallpaper page first
                tab = t
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: t.icon)
                    .font(.system(size: 14)).frame(width: 18)
                    .foregroundStyle(active ? Color.accentColor : Palette.secondary)
                Text(t.rawValue)
                    .font(.system(size: 14))
                    .foregroundStyle(active ? Color.accentColor : Palette.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background {
                if active { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.selected) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.horizontal, 10)
    }

    private var moviesScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Movies")
                        .font(.system(size: 30, weight: .bold, design: .serif))
                        .foregroundStyle(Palette.text)
                    Text("Click a movie to open it in your browser to download. Imported MP4s play inside LiveWall.")
                        .font(.system(size: 14)).foregroundStyle(Palette.secondary)
                }

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Palette.secondary)
                    TextField("Search movies", text: $movieSearch)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Palette.text)
                    if !movieSearch.isEmpty {
                        Button { movieSearch = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Palette.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear movie search")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.09)))

                Button {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.mpeg4Movie, .movie, .quickTimeMovie]
                    panel.allowsMultipleSelection = true
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK {
                        for url in panel.urls { _ = movies.importMP4(from: url) }
                    }
                } label: {
                    Label("Import MP4", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(PrimaryGlassButtonStyle())

                if searchedMovies(allMovies).isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: movieSearch.isEmpty ? "film.stack" : "magnifyingglass")
                            .font(.system(size: 36)).foregroundStyle(Palette.tertiary)
                        Text(movieSearch.isEmpty ? "No movies yet" : "No matching movies")
                            .font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.text)
                        Text(movieSearch.isEmpty ? "Import an MP4, or pick a movie from the catalog." : "Try another movie title.")
                            .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 300), spacing: 18)], spacing: 20) {
                        ForEach(searchedMovies(allMovies)) { item in
                            movieCard(item, canRemove: movies.items.contains(where: { $0.id == item.id }))
                        }
                    }
                }
            }
            .padding(.horizontal, 28).padding(.top, 76).padding(.bottom, 28)
        }
    }

    private func movieCard(_ item: MovieItem, canRemove: Bool) -> some View {
        Button {
            openMovie(item)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    MoviePosterView(item: item)
                    Text(movieSourceLabel(item))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(8)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

                HStack(alignment: .top, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if item.requiresSignIn == true {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .padding(.top, 3)
                    }
                }
                .frame(minHeight: 34, alignment: .top)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play") { openMovie(item) }
            if item.requiresSignIn != true {
                Button("Set as Background") { setMovieAsBackground(item) }
            }
            if item.googleDriveShareURL != nil {
                Divider()
                Button("Copy Google Drive Link") { copyMovieDriveLink(item) }
            }
            if canRemove { Button("Remove", role: .destructive) { movies.remove(item) } }
        }
    }

    private func searchedMovies(_ items: [MovieItem]) -> [MovieItem] {
        let term = movieSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(term) }
    }

    private func openMovie(_ item: MovieItem) {
        // Locally-imported movies play inside LiveWall.
        if item.kind == .localMP4 {
            movieCurrentURL = movies.url(for: item)
            selectedMovie = item
            return
        }
        // Catalog / remote movies open in the browser, which handles the site's
        // download challenge and saves the file. LiveWall can't play these
        // formats (mkv/AV1/HEVC-in-mkv) itself, so it hands them off.
        if let downloaded = movies.downloadedCopy(for: item) {
            movieCurrentURL = movies.url(for: downloaded)
            selectedMovie = downloaded
            return
        }
        if let url = URL(string: item.urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func downloadMovie(_ item: MovieItem, applyAfterDownload: Bool) {
        guard !movieIsDownloading else { return }
        if let downloaded = movies.downloadedCopy(for: item) {
            if applyAfterDownload { setMovieAsBackground(downloaded) }
            else {
                movieCurrentURL = movies.url(for: downloaded)
                selectedMovie = downloaded
            }
            return
        }

        selectedMovie = nil
        movieError = ""
        movieDownloadTitle = item.title
        movieDownloadProgress = 0
        movieIsDownloading = true
        movieDownloadTask = Task {
            do {
                let downloaded = try await MovieDownloadService.download(item) { progress in
                    Task { @MainActor in movieDownloadProgress = progress }
                }
                try Task.checkCancellation()
                movies.saveDownloaded(downloaded)
                movieIsDownloading = false
                movieDownloadTask = nil
                if applyAfterDownload {
                    setMovieAsBackground(downloaded)
                } else {
                    movieCurrentURL = movies.url(for: downloaded)
                    selectedMovie = downloaded
                }
            } catch is CancellationError {
                movieIsDownloading = false
                movieDownloadTask = nil
            } catch {
                movieIsDownloading = false
                movieDownloadTask = nil
                movieError = error.localizedDescription
                showMovieDownloadError = true
            }
        }
    }

    private func moviePlayerSheet(_ item: MovieItem) -> some View {
        ZStack {
            if let url = movies.url(for: item) {
                if item.kind != .website {
                    MoviePlayerView(url: url).background(Color.black)
                } else {
                    MovieWebView(url: url, currentURL: $movieCurrentURL).background(Color.black)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 30))
                    Text("Movie unavailable").font(.headline)
                    Text("The movie file could not be found.").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack {
                HStack {
                    if item.requiresSignIn != true {
                        Button { setMovieAsBackground(item) } label: {
                            Label("Set as Background", systemImage: "display")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(.white.opacity(0.22)))
                        }
                        .buttonStyle(.plain)
                        .help("Use this movie as your live wallpaper")
                    } else {
                        Label("Make this Drive file public to use it", systemImage: "lock.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                    }

                    if item.googleDriveShareURL != nil {
                        Button { copyMovieDriveLink(item) } label: {
                            Label("Copy Drive Link", systemImage: "link")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(.white.opacity(0.22)))
                        }
                        .buttonStyle(.plain)
                        .help("Copy the Google Drive movie link")
                    }

                    Spacer()

                    Button { selectedMovie = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .help("Close movie")
                }
                .padding(14)

                Spacer()
            }
        }
        .frame(minWidth: 900, minHeight: 580)
        .background(Color.black)
        .onExitCommand { selectedMovie = nil }
    }

    private func setMovieAsBackground(_ item: MovieItem) {
        guard item.requiresSignIn != true else {
            movieError = "This Google Drive movie is private. Change its sharing to Anyone with the link before using it as a background."
            selectedMovie = nil
            return
        }
        if item.kind == .remoteMP4 {
            downloadMovie(item, applyAfterDownload: true)
            return
        }
        guard let originalURL = movies.url(for: item) else {
            movieError = "The movie could not be opened."
            return
        }
        let url = item.kind == .website ? (movieCurrentURL ?? originalURL) : originalURL
        let wallpaper = LibraryItem(
            id: item.id,
            title: item.title,
            kind: item.kind == .localMP4 ? .localVideo : (item.kind == .remoteMP4 ? .directURL : .web),
            urlString: url.absoluteString,
            category: "Movies"
        )
        vm.apply(wallpaper)
        selectedMovie = nil
    }

    private func movieSourceLabel(_ item: MovieItem) -> String {
        switch item.kind {
        case .localMP4: return item.sourceURLString == nil ? "MP4" : "DOWNLOADED"
        case .remoteMP4: return "DOWNLOAD"
        case .website: return "WEB"
        }
    }

    private func copyMovieDriveLink(_ item: MovieItem) {
        guard let url = item.googleDriveShareURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }


    private var gamesScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Welcome to LiveWall Games!")
                        .font(.system(size: 30, weight: .bold, design: .serif))
                        .foregroundStyle(.white)
                    Text("Play local games while keeping your wallpapers and library in one place.")
                        .font(.system(size: 14)).foregroundStyle(.white.opacity(0.65))
                }

                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.65))
                        TextField("Search All Games", text: $gameSearch).textFieldStyle(.plain)
                        if !gameSearch.isEmpty { Button { gameSearch = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                    }
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .background(Color.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.12)))

                    Button {
                        if let game = visibleGames.randomElement() { openGame(game) }
                    } label: {
                        Text("🎲").font(.system(size: 21)).frame(width: 42, height: 42)
                            .background(Color.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }.buttonStyle(.plain).help("Random Game")
                }

                HStack(spacing: 9) {
                    Menu {
                        Button("Name") { gameSort = "Name" }
                        Button("Category") { gameSort = "Category" }
                    } label: {
                        gameControlLabel("Sort By: \(gameSort)", icon: "arrow.up.arrow.down")
                    }.menuStyle(.borderlessButton)
                    Menu {
                        ForEach(["All", "Favorites", "Featured", "Action", "Strategy", "Casual", "Driving"], id: \.self) { filter in
                            Button("\(filter)\(filter == "All" ? " (\(bundledGames.count))" : "")") { gameFilter = filter }
                        }
                    } label: {
                        gameControlLabel("Filter \(gameFilter) (\(visibleGames.count))", icon: "line.3.horizontal.decrease.circle")
                    }.menuStyle(.borderlessButton)
                    Button { gameAscending.toggle() } label: {
                        Image(systemName: gameAscending ? "arrow.down" : "arrow.up")
                            .frame(width: 38, height: 32).background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }.buttonStyle(.plain).help("Reverse order")
                    Spacer()
                    Text("\(visibleGames.count) games")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 13)], spacing: 15) {
                    ForEach(visibleGames) { game in gameCard(game) }
                }
            }
            .padding(.horizontal, 28).padding(.top, 78).padding(.bottom, 30)
        }
    }

    private func gameControlLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 11))
            Text(title).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.8))
        .padding(.horizontal, 12).frame(height: 32)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func gameCard(_ game: BundledGameEntry) -> some View {
        let favorite = gameFavorites.contains(game.id)
        let hue = Double(abs(game.title.hashValue % 360)) / 360.0
        return Button {
            openGame(game)
        } label: {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [Color(hue: hue, saturation: 0.58, brightness: 0.58), Color(hue: (hue + 0.16).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 42, weight: .medium)).foregroundStyle(.white.opacity(0.28))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 5) {
                    Text(gameCategory(game).uppercased()).font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.7))
                    Text(game.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                }.padding(12)
                Button { toggleGameFavorite(game) } label: {
                    Image(systemName: favorite ? "star.fill" : "star")
                        .foregroundStyle(favorite ? .yellow : .white.opacity(0.8)).padding(10)
                }.buttonStyle(.plain).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .frame(height: 132)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.13)))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }

    private func toggleGameFavorite(_ game: BundledGameEntry) {
        if gameFavorites.contains(game.id) { gameFavorites.remove(game.id) } else { gameFavorites.insert(game.id) }
        UserDefaults.standard.set(Array(gameFavorites), forKey: "gameFavorites")
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(myCategories, id: \.self) { c in
                    Button { category = c } label: {
                        Text(c).font(.system(size: 12, weight: category == c ? .semibold : .regular))
                            .foregroundStyle(category == c ? .white : Palette.secondary)
                            .padding(.horizontal, 13).padding(.vertical, 6)
                            .background(category == c ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Palette.chip), in: Capsule())
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: Home hero

    // Home = one vertical scroll: full-bleed hero on top, "Discover" grid below.
    private var homeScreen: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        heroSection(width: geo.size.width, height: max(geo.size.height, 440)).id("top")
                        discoverSection(proxy: proxy)
                    }
                }
            }
        }
    }

    private func heroSection(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            if let item = heroItem {
                PosterView(item: item).transition(.opacity)
                LoopingVideoView(url: heroPlayableURL(item))
                LinearGradient(colors: [.black.opacity(0.45), .clear, .clear, .black.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
                heroArrows
                heroInfo(item).frame(width: width)
                heroDots
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles.tv").font(.system(size: 48)).foregroundStyle(.white.opacity(0.4))
                    Text("No wallpapers yet").font(.system(size: 20, weight: .semibold, design: .serif)).foregroundStyle(.white)
                    Button("Add your own") { tab = .mine; vm.showAdd = true }.buttonStyle(HeroButtonStyle())
                }
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .animation(.easeInOut(duration: 0.35), value: heroItem?.id)
    }

    private func discoverSection(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("Discover").font(.system(size: 22, weight: .semibold, design: .serif)).foregroundStyle(Palette.text)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary).font(.system(size: 12))
                    TextField("Search…", text: $query).textFieldStyle(.plain).font(.system(size: 13)).frame(width: 130)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Palette.chip, in: Capsule())
                sortControl
                Button { vm.showAdd = true } label: {
                    Label("Upload", systemImage: "arrow.up.circle.fill").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.blue).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }.buttonStyle(.plain)
            }
            resolutionChips
            sourceChips
            categoryRow
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 14)], spacing: 14) {
                ForEach(sortedItems(filtered(vm.templates))) { item in
                    WallpaperCard(item: item, favorite: favorites.contains(item.id.uuidString), running: vm.runningItemID == item.id)
                        .onTapGesture {
                            vm.selectedID = item.id
                            heroItem = item
                            withAnimation(.easeInOut) { proxy.scrollTo("top", anchor: .top) }
                        }
                        .contextMenu {
                            Button { heroItem = item; tab = .home } label: { Label("Preview", systemImage: "eye") }
                            Button { vm.apply(item) } label: { Label("Set as Live Wallpaper", systemImage: "sparkles.tv") }
                            Button { toggleFavorite(item) } label: { Label(favorites.contains(item.id.uuidString) ? "Unfavorite" : "Favorite", systemImage: "heart") }
                        }
                }
                if !vm.motionBGSLoading {
                    Button { vm.loadMotionBGS() } label: {
                        Label("Load more MotionBGS wallpapers", systemImage: "arrow.down.circle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.text)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Palette.chip, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                } else {
                    ProgressView("Loading MotionBGS catalog…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }
            }
        }
        // The floating navigation and macOS traffic lights sit above this section.
        // Reserve space so Discover never scrolls underneath them.
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .padding(.top, 150)
        .foregroundStyle(Palette.text)
        .background(Palette.canvas)
    }

    private var sortControl: some View {
        HStack(spacing: 2) {
            ForEach(SortMode.allCases, id: \.self) { s in
                Text(s.rawValue).font(.system(size: 12, weight: sort == s ? .semibold : .regular))
                    .foregroundStyle(sort == s ? .white : Palette.secondary)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background { if sort == s { Capsule().fill(Color.accentColor) } }
                    .onTapGesture { sort = s }
            }
        }
        .padding(3).background(Palette.chip, in: Capsule())
    }

    private var resolutionChips: some View {
        HStack(spacing: 8) {
            ForEach(["All", "1080p", "1440p", "4K"], id: \.self) { r in
                Button { resolution = r } label: {
                    Text(r).font(.system(size: 11, weight: resolution == r ? .semibold : .regular))
                        .foregroundStyle(resolution == r ? .white : Palette.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(resolution == r ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Palette.chip), in: Capsule())
                }.buttonStyle(.plain)
            }
        }
    }

    private var sourceChips: some View {
        HStack(spacing: 8) {
            ForEach(["All", "MotionBGS", "WallpaperWaves", "Local", "Interactive"], id: \.self) { s in
                Button { source = s } label: {
                    Text(s).font(.system(size: 11, weight: source == s ? .semibold : .regular))
                        .foregroundStyle(source == s ? .white : Palette.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(source == s ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Palette.chip), in: Capsule())
                }.buttonStyle(.plain)
            }
        }
    }

    private var categoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(myCategories, id: \.self) { c in
                    Button { category = c } label: {
                        Text(c).font(.system(size: 12, weight: category == c ? .semibold : .regular))
                            .foregroundStyle(category == c ? .white : Palette.secondary)
                            .padding(.horizontal, 13).padding(.vertical, 6)
                            .background(category == c ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Palette.chip), in: Capsule())
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    /// Backdrop's detail layout: title and specs bottom-left, actions bottom-right,
    /// nothing else over the artwork.
    private func heroInfo(_ item: LibraryItem) -> some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 52, weight: .bold))
                        .foregroundStyle(.white).shadow(radius: 14)
                        .lineLimit(1).minimumScaleFactor(0.55)
                    Text(heroSpecs(item))
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
                // The title takes whatever is left after the actions have their
                // intrinsic width, so a narrow window truncates the text rather
                // than pushing the buttons off the edge.
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(0)
                .padding(.trailing, 20)
                // A long title must never push the actions off the window edge.
                HStack(spacing: 10) {
                    if item.kind == .directURL || item.kind == .youTube || item.kind == .web {
                        Button { openSource(item) } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "link").font(.system(size: 12, weight: .semibold))
                                Text("Link").font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 11)
                            .background(.white.opacity(0.18), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                    Button { toggleFavorite(item) } label: {
                        Image(systemName: favorites.contains(item.id.uuidString) ? "heart.fill" : "heart")
                            .font(.system(size: 15))
                            .foregroundStyle(favorites.contains(item.id.uuidString) ? .red : .white)
                            .frame(width: 42, height: 42)
                            .background(.white.opacity(0.18), in: Circle())
                    }.buttonStyle(.plain)
                    Button { vm.apply(item) } label: {
                        HStack(spacing: 7) {
                            Image(systemName: vm.runningItemID == item.id ? "checkmark" : "sparkles.tv.fill")
                                .font(.system(size: 13, weight: .semibold))
                            Text(vm.runningItemID == item.id ? "Live" : "Set Wallpaper")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20).padding(.vertical, 11)
                        .background(Color.accentColor, in: Capsule())
                    }.buttonStyle(.plain)
                }
                .fixedSize()
                .layoutPriority(1)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 30)
        }
    }

    /// "4K (3840 × 2160) · Local video" — the spec line under Backdrop's title.
    private func heroSpecs(_ item: LibraryItem) -> String {
        // Interactive wallpapers report the same word for resolution, category and
        // subtitle — show each distinct fact once rather than "Interactive ·
        // Interactive · Interactive".
        var seen = Set<String>()
        return [resolutionLabel(item), categoryLabel(item), item.subtitle]
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .joined(separator: "  ·  ")
    }

    private func openSource(_ item: LibraryItem) {
        guard let string = item.urlString, let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Backdrop's floating transport: what is playing, on which display.
    @ViewBuilder private var playerBar: some View {
        if vm.isRunning, let running = (vm.templates + library.items).first(where: { $0.id == vm.runningItemID }) {
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    Button { vm.togglePlay() } label: {
                        Image(systemName: vm.showAsPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15)).foregroundStyle(.white).frame(width: 24)
                    }.buttonStyle(.plain).disabled(!vm.canTogglePlay)
                    Button { vm.stop() } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).frame(width: 20)
                    }.buttonStyle(.plain)

                    // Sound on/off for the playing wallpaper.
                    Button { vm.setMuted(!vm.muted) } label: {
                        Image(systemName: vm.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(vm.muted ? .white.opacity(0.6) : Color.accentColor)
                            .frame(width: 22)
                    }
                    .buttonStyle(.plain)
                    .help(vm.muted ? "Unmute wallpaper" : "Mute wallpaper")

                    PosterView(item: running)
                        .frame(width: 46, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                    VStack(alignment: .leading, spacing: 0) {
                        Text(vm.selectedDisplayIDs.count == vm.displays.count ? "All Displays"
                             : (vm.displays.first { vm.selectedDisplayIDs.contains($0.id) }?.name ?? "Display"))
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        Text(running.title)
                            .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    .frame(minWidth: 120, alignment: .leading)

                    Image(systemName: "display.2").font(.system(size: 14)).foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color(red: 0.11, green: 0.10, blue: 0.14),
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                .padding(.bottom, 22)
            }
        }
    }

    private var heroArrows: some View {
        HStack {
            arrow("chevron.left") { step(-1) }
            Spacer()
            arrow("chevron.right") { step(1) }
        }
        .padding(.horizontal, 18)
    }

    private func arrow(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(.ultraThinMaterial).frame(width: 40, height: 40)
                .overlay(Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white))
                .overlay(Circle().strokeBorder(.white.opacity(0.15)))
        }.buttonStyle(.plain).opacity(featured.count > 1 ? 1 : 0)
    }

    private var heroDots: some View {
        VStack {
            Spacer()
            HStack(spacing: 7) {
                ForEach(Array(featured.prefix(9).enumerated()), id: \.offset) { idx, item in
                    Circle().fill(heroItem?.id == item.id ? Color.white : Color.white.opacity(0.4))
                        .frame(width: heroItem?.id == item.id ? 8 : 6, height: heroItem?.id == item.id ? 8 : 6)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 44)
        }
    }

    private func step(_ dir: Int) {
        guard !featured.isEmpty else { return }
        let idx = featured.firstIndex(where: { $0.id == heroItem?.id }) ?? 0
        let next = (idx + dir + featured.count) % featured.count
        withAnimation { heroItem = featured[next] }
    }

    // MARK: Grid

    private func gridScreen(items: [LibraryItem], showCategories: Bool, showAdd: Bool) -> some View {
        // The Library reads like Backdrop's Discover: a big page title, then one
        // horizontally-scrolling row per category. Searching or "Show All"
        // collapses it back to a flat grid of just those wallpapers.
        let sectioned = showCategories && query.isEmpty && showAllCategory == nil
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                pageTitle(showAllCategory ?? tab.rawValue, showsBack: showAllCategory != nil)

                if sectioned {
                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(sectionCategories(items), id: \.self) { name in
                            categorySection(name, items: items.filter { categoryLabel($0) == name })
                        }
                    }
                    .padding(.bottom, 40)
                } else {
                    let shown = showAllCategory.map { name in items.filter { categoryLabel($0) == name } } ?? items
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 14)], spacing: 14) {
                        if showAdd { addCard }
                        ForEach(shown) { item in card(item, removable: !showCategories) }
                    }
                    .padding(.bottom, 40)
                }
            }
            .padding(.horizontal, 26)
        }
    }

    private func pageTitle(_ text: String, showsBack: Bool) -> some View {
        HStack(spacing: 10) {
            if showsBack {
                Button { withAnimation(.easeOut(duration: 0.15)) { showAllCategory = nil } } label: {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                }.buttonStyle(.plain)
            }
            Text(text).font(.system(size: 38, weight: .bold)).foregroundStyle(Palette.text)
        }
        .padding(.top, 72).padding(.bottom, 18)
    }

    /// Categories present in `items`, most populated first — Backdrop leads with
    /// its biggest collections rather than sorting alphabetically.
    private func sectionCategories(_ items: [LibraryItem]) -> [String] {
        Dictionary(grouping: items, by: { categoryLabel($0) })
            .sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
            .map(\.key)
    }

    private func categorySection(_ name: String, items: [LibraryItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(name).font(.system(size: 19, weight: .bold)).foregroundStyle(Palette.text)
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.15)) { showAllCategory = name } } label: {
                    HStack(spacing: 3) {
                        Text("Show All").font(.system(size: 12.5))
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Palette.secondary)
                }.buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(items.prefix(14)) { item in
                        card(item, removable: false).frame(width: 248)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    /// The wallpaper's own page: the clip plays full-bleed with nothing over it
    /// but a back button and the title/actions — Backdrop's detail view.
    private func detailScreen(_ item: LibraryItem) -> some View {
        GeometryReader { geo in
        ZStack {
            Color.black
            PosterView(item: item)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            LoopingVideoView(url: detailPlayableURL(item))
            LinearGradient(colors: [.black.opacity(0.35), .clear, .clear, .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)

            Button { withAnimation(.easeOut(duration: 0.18)) { detailItem = nil } } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 20).padding(.top, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            heroInfo(item).frame(width: geo.size.width)
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .clipped()
        }
        .transition(.opacity)
    }

    /// Keys are drawn here, last in the content stack, because the hero's video
    /// layer is an AppKit view — anything placed inside that ZStack composites
    /// underneath it no matter what the SwiftUI ordering says.
    @ViewBuilder private var keyOverlay: some View {
        let shown = detailItem ?? (tab == .home ? heroItem : nil)
        if let item = shown, let slot = KeyVault.keyedWallpaperTitles.firstIndex(of: item.title) {
            let place = keyPlacement(slot: slot)
            SecretKeyLayer(id: KeyVault.wallpaperKeys[slot], size: place.size, subtle: place.subtle)
                .frame(width: max(place.size + 12, 22), height: max(place.size + 12, 22))
                .padding(.leading, place.left).padding(.trailing, place.right)
                .padding(.top, place.top).padding(.bottom, place.bottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: place.alignment)
        }
    }

    private struct KeyPlacement {
        var alignment: Alignment
        var left: CGFloat = 0, right: CGFloat = 0, top: CGFloat = 0, bottom: CGFloat = 0
        var size: CGFloat = 30
        var subtle = false
    }

    /// Easy keys (slots 0–9) glow bottom-right. The hard five (slots 10–14) are
    /// dim and tucked into spots nobody scans: hard against an edge, behind where
    /// the title sits, mid-edge, etc. Each hard slot gets its own hiding place.
    private func keyPlacement(slot: Int) -> KeyPlacement {
        guard KeyVault.isHardSlot(slot) else {
            return KeyPlacement(alignment: .bottomTrailing, right: 26, bottom: 200, size: 30)
        }
        switch slot {
        case 10: return KeyPlacement(alignment: .topLeading, left: 16, top: 16, size: 18, subtle: true)          // top-left corner
        case 11: return KeyPlacement(alignment: .top, top: 14, size: 17, subtle: true)                           // centre of the top edge
        case 12: return KeyPlacement(alignment: .bottomLeading, left: 16, bottom: 16, size: 17, subtle: true)    // bottom-left corner
        case 13: return KeyPlacement(alignment: .trailing, right: 14, size: 17, subtle: true)                    // mid-height, right edge
        default: return KeyPlacement(alignment: .topTrailing, right: 16, top: 60, size: 17, subtle: true)        // top-right, below the corner controls
        }
    }

    private func card(_ item: LibraryItem, removable: Bool) -> some View {
        WallpaperCard(item: item, favorite: favorites.contains(item.id.uuidString), running: vm.runningItemID == item.id)
            .onTapGesture {
                vm.selectedID = item.id
                withAnimation(.easeOut(duration: 0.18)) { detailItem = item }
            }
            .contextMenu {
                Button { withAnimation { detailItem = item } } label: { Label("Open", systemImage: "eye") }
                Button { vm.apply(item) } label: { Label("Set as Live Wallpaper", systemImage: "sparkles.tv") }
                Button { toggleFavorite(item) } label: { Label(favorites.contains(item.id.uuidString) ? "Unfavorite" : "Favorite", systemImage: "heart") }
                if removable { Button(role: .destructive) { vm.remove(item) } label: { Label("Remove", systemImage: "trash") } }
            }
    }

    private var addCard: some View {
        Button { vm.showAdd = true } label: {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8])).foregroundStyle(Palette.tertiary))
                .overlay(VStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 28, weight: .semibold))
                    Text("Add Wallpaper").font(.system(size: 14, weight: .medium))
                }.foregroundStyle(Palette.secondary))
                .aspectRatio(16.0/9.0, contentMode: .fit)
        }.buttonStyle(.plain)
    }

    private func favoriteButton(_ item: LibraryItem) -> some View {
        Button { toggleFavorite(item) } label: {
            HStack(spacing: 7) {
                Image(systemName: favorites.contains(item.id.uuidString) ? "heart.fill" : "heart")
                    .foregroundStyle(favorites.contains(item.id.uuidString) ? .red : .white)
                Text("Favorite").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            }
            .padding(.horizontal, 16).frame(height: 44)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        }.buttonStyle(.plain)
    }

    private func toggleFavorite(_ item: LibraryItem) {
        let key = item.id.uuidString
        if favorites.contains(key) { favorites.remove(key) } else { favorites.insert(key) }
        UserDefaults.standard.set(Array(favorites), forKey: "favorites")
    }

    /// My Wallpapers only honours the search box. The category, resolution and
    /// source chips belong to the Library — applying them here hid wallpapers the
    /// moment they were added.
    private func searched(_ items: [LibraryItem]) -> [LibraryItem] {
        items.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }

    private func filtered(_ items: [LibraryItem]) -> [LibraryItem] {
        items.filter { item in
            (query.isEmpty || item.title.localizedCaseInsensitiveContains(query)) &&
            (category == "All" || categoryLabel(item) == category) &&
            matchesResolution(item) && matchesSource(item)
        }
    }

    private func matchesResolution(_ item: LibraryItem) -> Bool {
        guard resolution != "All" else { return true }
        let text = (item.title + " " + (item.urlString ?? "")).lowercased()
        switch resolution {
        case "4K": return text.contains("4k") || item.remoteThumbnailURL?.host?.contains("motionbgs") == true
        case "1440p": return text.contains("1440")
        case "1080p": return text.contains("1080") || (item.kind == .localVideo && !text.contains("4k"))
        default: return true
        }
    }

    private func matchesSource(_ item: LibraryItem) -> Bool {
        guard source != "All" else { return true }
        switch source {
        case "MotionBGS": return item.urlString?.contains("motionbgs.com") == true
        case "WallpaperWaves": return item.urlString?.contains("wallpaperwaves.com") == true || item.thumbnailURLString?.contains("wallpaperwaves.com") == true
        case "Local": return item.kind == .localVideo || item.kind == .localImage
        case "Interactive": return item.kind == .web
        default: return true
        }
    }

    private func sortedItems(_ items: [LibraryItem]) -> [LibraryItem] {
        switch sort {
        case .newest:    return items.sorted { $0.dateAdded > $1.dateAdded }
        case .mostLiked: return items.sorted { favorites.contains($0.id.uuidString) && !favorites.contains($1.id.uuidString) }
        case .random:    return items
        }
    }

    private var downloadOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Downloading \(vm.downloadTitle)…").font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                ProgressView(value: vm.downloadProgress).frame(width: 220)
                Text("\(Int(vm.downloadProgress * 100))%")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(28).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var movieDownloadOverlay: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 13) {
                ProgressView().controlSize(.large)
                Text("Downloading \(movieDownloadTitle)…")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                ProgressView(value: movieDownloadProgress)
                    .frame(width: 260)
                Text("\(Int(movieDownloadProgress * 100))%")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                Text("Keep LiveWall open. The movie will start automatically when the download finishes.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(width: 300)
                Button("Cancel Download", role: .cancel) {
                    movieDownloadTask?.cancel()
                }
                .buttonStyle(.bordered)
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
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

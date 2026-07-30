import SwiftUI
import AVKit
import AVFoundation
import AppKit
import WebKit

// MARK: - Looping muted video (hero background)

final class PlayerHostView: NSView {
    let playerLayer = AVPlayerLayer()
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
}

struct LoopingVideoView: NSViewRepresentable {
    let url: URL?
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PlayerHostView {
        let v = PlayerHostView(); context.coordinator.host = v; context.coordinator.load(url); return v
    }
    func updateNSView(_ nsView: PlayerHostView, context: Context) { context.coordinator.load(url) }
    static func dismantleNSView(_ nsView: PlayerHostView, coordinator: Coordinator) { coordinator.teardown() }

    final class Coordinator {
        weak var host: PlayerHostView?
        private var currentURL: URL?
        private let queue = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        func load(_ url: URL?) {
            guard url != currentURL else { return }
            currentURL = url
            looper?.disableLooping(); looper = nil; queue.removeAllItems()
            guard let url else { host?.playerLayer.player = nil; return }
            let item = AVPlayerItem(url: url)
            looper = AVPlayerLooper(player: queue, templateItem: item)
            queue.isMuted = true
            host?.playerLayer.player = queue
            queue.play()
        }
        func teardown() { queue.pause(); looper?.disableLooping(); looper = nil; queue.removeAllItems() }
    }
}

/// Runs bundled HTML games inside LiveWall without opening a separate browser.
struct BundledGameView: NSViewRepresentable {
    let resourceName: String

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isElementFullscreenEnabled = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "html", subdirectory: "Games") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) { }
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

    enum Tab: String, CaseIterable { case home = "Home", community = "Community", library = "Library", favorites = "Favorites", mine = "My Wallpapers", playlists = "Playlists", settings = "Settings", games = "Games" }
    enum SortMode: String, CaseIterable { case mostLiked = "Most Liked", random = "Random", newest = "Newest" }
    @State private var tab: Tab = .home
    @State private var heroItem: LibraryItem?
    @State private var query = ""
    @State private var category = "All"
    @State private var sort: SortMode = .random
    @State private var favorites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
    @StateObject private var rotation = RotationEngine()
    @State private var settingsTapCount = 0
    @State private var gamesUnlocked = false
    @State private var selectedGameResource = "DriveMad"
    @StateObject private var community = CommunityService()
    @AppStorage("communityAPIURL") private var communityAPIURL = ""
    @State private var communityIdentity = ""
    @State private var communityEmail = ""
    @State private var communityPassword = ""

    private var featured: [LibraryItem] { vm.templates }
    private var rotationPool: [LibraryItem] { library.items.isEmpty ? vm.templates : library.items }
    private var favoriteItems: [LibraryItem] { (vm.templates + library.items).filter { favorites.contains($0.id.uuidString) } }

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.05).ignoresSafeArea()

            switch tab {
            case .home:    homeScreen
            case .community: communityScreen
            case .library: gridScreen(items: sortedItems(filtered(vm.templates)), showCategories: true, showAdd: false)
            case .favorites: gridScreen(items: favoriteItems, showCategories: false, showAdd: false)
            case .mine:    gridScreen(items: filtered(library.items), showCategories: false, showAdd: true)
            case .playlists: playlistsScreen
            case .settings: ScrollView { SettingsSheet(vm: vm, showsDone: false).frame(maxWidth: 620).padding(.top, 72) }
            case .games: gamesScreen
            }

            topBar
        }
        .onAppear {
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
        .overlay { if vm.isDownloading { downloadOverlay } }
    }

    // MARK: Top bar

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                if tab != .home {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.7)).font(.system(size: 12))
                        TextField("Search", text: $query).textFieldStyle(.plain)
                            .font(.system(size: 13)).frame(width: 150)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                } else {
                    Circle().fill(.ultraThinMaterial).frame(width: 34, height: 34)
                        .overlay(Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.white.opacity(0.8)))
                }
                Spacer()
                Circle().fill(.ultraThinMaterial).frame(width: 34, height: 34)
                    .overlay(Image(systemName: "questionmark").font(.system(size: 13)).foregroundStyle(.white.opacity(0.8)))
                Button { tab = .settings } label: {
                    Circle().fill(.ultraThinMaterial).frame(width: 34, height: 34)
                        .overlay(Image(systemName: "gearshape.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.85)))
                }.buttonStyle(.plain)
            }
            .overlay(navPill)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if tab == .library { categoryChips }
            Spacer()
        }
        // Keep scrolling content from visually bleeding through the fixed controls.
        .background(
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.04, blue: 0.05), Color(red: 0.04, green: 0.04, blue: 0.05).opacity(0.96), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: tab == .library ? 150 : 122),
            alignment: .top
        )
    }

    private var myCategories: [String] { ["All"] + Set(vm.templates.map { categoryLabel($0) }).sorted() }

    // MARK: Playlists

    private var communityScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Community").font(.system(size: 38, weight: .semibold, design: .serif)).foregroundStyle(.white)
                        Text("Share your own live wallpapers with other LiveWall users.").font(.system(size: 14)).foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer()
                    Button { Task { await community.load(from: communityAPIURL) } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }.buttonStyle(GlassButtonStyle(tint: .blue))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Community server").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    TextField("https://your-domain.com/livewall-api/api.php", text: $communityAPIURL)
                        .textFieldStyle(.roundedBorder)
                    Text("Your Hostinger server address. Uploads are reviewed before they appear for everyone.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(16).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                if community.username.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Create an account or sign in").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        HStack(spacing: 10) {
                            TextField("Username or email", text: $communityIdentity).textFieldStyle(.roundedBorder)
                            TextField("Email (for new account)", text: $communityEmail).textFieldStyle(.roundedBorder)
                            SecureField("Password", text: $communityPassword).textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Button("Sign In") { Task { await community.login(endpoint: communityAPIURL, identity: communityIdentity, password: communityPassword) } }
                            Button("Create Account") { Task { await community.register(endpoint: communityAPIURL, username: communityIdentity, email: communityEmail, password: communityPassword) } }
                            Spacer()
                        }.buttonStyle(GlassButtonStyle(tint: .purple))
                    }
                    .padding(16).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    HStack {
                        Label("Signed in as \(community.username)", systemImage: "person.crop.circle.fill").foregroundStyle(.white)
                        Spacer()
                        Button { community.chooseAndUpload(endpoint: communityAPIURL) } label: {
                            Label(community.isUploading ? "Uploading…" : "Upload a Video", systemImage: "arrow.up.circle.fill")
                        }.buttonStyle(PrimaryGlassButtonStyle()).disabled(community.isUploading)
                    }
                    .padding(16).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                Text(community.message).font(.system(size: 12)).foregroundStyle(community.isError ? .red : .secondary)

                if community.isLoading {
                    ProgressView("Loading community wallpapers…").tint(.white).frame(maxWidth: .infinity, minHeight: 220)
                } else if community.wallpapers.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.3.sequence").font(.system(size: 34)).foregroundStyle(.white.opacity(0.35))
                        Text("No community wallpapers yet").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        Text("Once approved uploads arrive, they will show here.").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 18)], spacing: 22) {
                        ForEach(community.wallpapers) { post in
                            let item = post.asLibraryItem()
                            WallpaperCard(item: item, favorite: favorites.contains(item.id.uuidString), running: vm.runningItemID == item.id)
                                .onTapGesture { vm.apply(item) }
                                .overlay(alignment: .bottomLeading) {
                                    Text("by \(post.author) · \(post.category)").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8)).padding(10)
                                }
                        }
                    }
                }
            }
            .padding(24).padding(.top, 92)
        }
        .task { await community.load(from: communityAPIURL) }
    }

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
                Text("Playlists").font(.system(size: 40, weight: .semibold, design: .serif)).foregroundStyle(.white)

                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.blue.opacity(0.22))
                        .frame(width: 46, height: 46)
                        .overlay(Image(systemName: "rectangle.stack.fill").font(.system(size: 20)).foregroundStyle(.blue))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Rotate your wallpapers").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
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
                        .font(.system(size: 19, weight: .semibold, design: .serif)).foregroundStyle(.white)
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

    private var navPill: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases.filter { $0 != .games }, id: \.self) { t in
                Button {
                    if t == .settings {
                        settingsTapCount += 1
                        if settingsTapCount >= 10 {
                            gamesUnlocked = true
                            settingsTapCount = 0
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { tab = .games }
                            return
                        }
                    }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { tab = t }
                } label: {
                    Text(t.rawValue)
                        .font(.system(size: 13, weight: tab == t ? .semibold : .regular))
                        .foregroundStyle(tab == t ? .white : .white.opacity(0.6))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background { if tab == t { Capsule().fill(.white.opacity(0.16)) } }
                }.buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }

    private var gamesScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Game Vault").font(.system(size: 34, weight: .bold, design: .serif)).foregroundStyle(.white)
                    Text("A hidden collection unlocked from Settings.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
                }
                Spacer()
                Button("Back to Settings") { tab = .settings }.buttonStyle(.bordered)
            }

            HStack(spacing: 12) {
                gamePicker(title: "Drive Mad", subtitle: "Obstacle car course", icon: "car.2.fill", resource: "DriveMad", number: 1)
                gamePicker(title: "Snow Rider", subtitle: "Downhill sled run", icon: "snowflake", resource: "SnowRider", number: 2)
                gamePicker(title: "Cluster Rush", subtitle: "Leap between moving trucks", icon: "figure.run", resource: "ClusterRush", number: 3)
                gamePicker(title: "UGS Collection", subtitle: "Search the full game collection", icon: "square.grid.3x3.fill", resource: "UGSCollection", number: 4)
                Spacer()
            }

            BundledGameView(resourceName: selectedGameResource)
                .id(selectedGameResource)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(28)
        .padding(.top, 70)
    }

    private func gamePicker(title: String, subtitle: String, icon: String, resource: String, number: Int) -> some View {
        Button { selectedGameResource = resource } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 20)).foregroundStyle(.blue).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
                Text("\(number)").font(.system(size: 11, weight: .bold)).foregroundStyle(.blue)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(selectedGameResource == resource ? Color.blue.opacity(0.28) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(myCategories, id: \.self) { c in
                    Button { category = c } label: {
                        Text(c).font(.system(size: 12, weight: category == c ? .semibold : .regular))
                            .foregroundStyle(category == c ? .black : .white.opacity(0.8))
                            .padding(.horizontal, 13).padding(.vertical, 6)
                            .background(category == c ? AnyShapeStyle(.white) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
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
                        heroSection(height: max(geo.size.height, 440)).id("top")
                        discoverSection(proxy: proxy)
                    }
                }
            }
        }
    }

    private func heroSection(height: CGFloat) -> some View {
        ZStack {
            if let item = heroItem {
                PosterView(item: item).transition(.opacity)
                LoopingVideoView(url: heroPlayableURL(item))
                LinearGradient(colors: [.black.opacity(0.45), .clear, .clear, .black.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
                heroArrows
                heroInfo(item)
                heroDots
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles.tv").font(.system(size: 48)).foregroundStyle(.white.opacity(0.4))
                    Text("No wallpapers yet").font(.system(size: 20, weight: .semibold, design: .serif)).foregroundStyle(.white)
                    Button("Add your own") { tab = .mine; vm.showAdd = true }.buttonStyle(HeroButtonStyle())
                }
            }
        }
        .frame(height: height)
        .clipped()
        .animation(.easeInOut(duration: 0.35), value: heroItem?.id)
    }

    private func discoverSection(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("Discover").font(.system(size: 22, weight: .semibold, design: .serif)).foregroundStyle(.white)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6)).font(.system(size: 12))
                    TextField("Search…", text: $query).textFieldStyle(.plain).font(.system(size: 13)).frame(width: 130)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                sortControl
                Button { vm.showAdd = true } label: {
                    Label("Upload", systemImage: "arrow.up.circle.fill").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.blue).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }.buttonStyle(.plain)
            }
            resolutionChips
            categoryRow
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 18)], spacing: 22) {
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
            }
        }
        // The floating navigation and macOS traffic lights sit above this section.
        // Reserve space so Discover never scrolls underneath them.
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .padding(.top, 150)
        .foregroundStyle(.white)
        .background(Color(red: 0.04, green: 0.04, blue: 0.05))
    }

    private var sortControl: some View {
        HStack(spacing: 2) {
            ForEach(SortMode.allCases, id: \.self) { s in
                Text(s.rawValue).font(.system(size: 12, weight: sort == s ? .semibold : .regular))
                    .foregroundStyle(sort == s ? .white : .white.opacity(0.6))
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background { if sort == s { Capsule().fill(.white.opacity(0.16)) } }
                    .onTapGesture { sort = s }
            }
        }
        .padding(3).background(.ultraThinMaterial, in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }

    private var resolutionChips: some View {
        HStack(spacing: 8) {
            ForEach(["1080p", "1440p", "4K", "Ultrawide", "Bitrate"], id: \.self) { r in
                Text(r).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    private var categoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(myCategories, id: \.self) { c in
                    Button { category = c } label: {
                        Text(c).font(.system(size: 12, weight: category == c ? .semibold : .regular))
                            .foregroundStyle(category == c ? .black : .white.opacity(0.8))
                            .padding(.horizontal, 13).padding(.vertical, 6)
                            .background(category == c ? AnyShapeStyle(.white) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func heroInfo(_ item: LibraryItem) -> some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(categoryLabel(item).uppercased())
                        .font(.system(size: 12, weight: .semibold)).tracking(1.5)
                        .foregroundStyle(.white.opacity(0.75))
                    Text(item.title)
                        .font(.system(size: 42, weight: .medium, design: .serif))
                        .foregroundStyle(.white).shadow(radius: 12).lineLimit(2)
                    Text(resolutionLabel(item) + "  ·  " + item.subtitle)
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                    HStack(spacing: 14) {
                        Button { vm.apply(item) } label: {
                            Image(systemName: vm.runningItemID == item.id ? "checkmark" : "play.fill")
                                .font(.system(size: 18, weight: .bold)).foregroundStyle(.black)
                                .frame(width: 54, height: 54).background(.white, in: Circle())
                        }.buttonStyle(.plain)
                        favoriteButton(item)
                    }
                    .padding(.top, 4)
                }
                Spacer()
            }
            .padding(28)
            .padding(.bottom, 40)
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
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 18)], spacing: 22) {
                if showAdd { addCard }
                ForEach(items) { item in
                    WallpaperCard(item: item, favorite: favorites.contains(item.id.uuidString), running: vm.runningItemID == item.id)
                        .onTapGesture { vm.selectedID = item.id; withAnimation { heroItem = item; tab = .home } }
                        .contextMenu {
                            Button { heroItem = item; tab = .home } label: { Label("Preview", systemImage: "eye") }
                            Button { vm.apply(item) } label: { Label("Set as Live Wallpaper", systemImage: "sparkles.tv") }
                            Button { toggleFavorite(item) } label: { Label(favorites.contains(item.id.uuidString) ? "Unfavorite" : "Favorite", systemImage: "heart") }
                            if !showCategories { Button(role: .destructive) { vm.remove(item) } label: { Label("Remove", systemImage: "trash") } }
                        }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, showCategories ? 108 : 76)
            .padding(.bottom, 30)
        }
    }

    private var addCard: some View {
        Button { vm.showAdd = true } label: {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8])).foregroundStyle(.white.opacity(0.3)))
                .overlay(VStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 28, weight: .semibold))
                    Text("Add Wallpaper").font(.system(size: 14, weight: .medium))
                }.foregroundStyle(.white.opacity(0.85)))
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

    private func filtered(_ items: [LibraryItem]) -> [LibraryItem] {
        items.filter { item in
            (query.isEmpty || item.title.localizedCaseInsensitiveContains(query)) &&
            (category == "All" || categoryLabel(item) == category)
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
}

// MARK: - Grid card

struct WallpaperCard: View {
    let item: LibraryItem
    let favorite: Bool
    let running: Bool
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                PosterView(item: item)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16.0/9.0, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(categoryLabel(item))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(9)
                if running {
                    HStack(spacing: 4) { Circle().fill(.green).frame(width: 6, height: 6); Text("LIVE").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
                        .padding(.horizontal, 7).padding(.vertical, 3).background(.ultraThinMaterial, in: Capsule())
                        .padding(9).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(hover ? 0.35 : 0.08)))
            .scaleEffect(hover ? 1.015 : 1)
            .shadow(color: .black.opacity(hover ? 0.4 : 0.2), radius: hover ? 14 : 7, y: 5)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    HStack(spacing: 6) {
                        Image(systemName: "globe").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                        Text(item.kind == .localVideo ? "Local" : "Discover").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                        Text(resolutionLabel(item)).font(.system(size: 11, weight: .medium)).foregroundStyle(.purple.opacity(0.9))
                    }
                }
                Spacer()
                Image(systemName: favorite ? "heart.fill" : "heart")
                    .font(.system(size: 13)).foregroundStyle(favorite ? .red : .white.opacity(0.5))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hover)
        .onHover { hover = $0 }
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
                set: { UserDefaults.standard.set($0, forKey: key) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings").font(.system(size: 22, weight: .bold, design: .serif))

            section("Displays") {
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
                if vm.isDownloading { HStack { Text("Downloading: \(vm.downloadTitle)"); Spacer(); Button(vm.isDownloadPaused ? "Resume" : "Pause") { vm.isDownloadPaused ? vm.resumeDownload() : vm.pauseDownload() } } }
                Text("Storage used: \(ByteCountFormatter.string(fromByteCount: vm.downloadStorageBytes, countStyle: .file))").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Clear downloaded wallpapers…") { vm.clearDownloadedWallpapers() }
            }

            section("Per-monitor wallpapers") {
                ForEach(vm.displays) { d in
                    HStack {
                        Text(d.name)
                        Spacer()
                        Button("Apply selected") { if let item = vm.selectedItem { vm.apply(item, to: d.id) } }
                            .buttonStyle(.bordered)
                    }
                }
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
                Toggle("Notify me when LiveWall starts", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "updateNotificationsEnabled") as? Bool ?? false },
                    set: { UserDefaults.standard.set($0, forKey: "updateNotificationsEnabled") }
                ))
                Button("Check for Updates…") { vm.checkForUpdates() }.buttonStyle(.borderedProminent)
            }

            if showsDone { HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) } }
        }
        .padding(24)
        .foregroundStyle(.white)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
            content()
        }
    }
}

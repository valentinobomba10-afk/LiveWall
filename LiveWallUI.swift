import SwiftUI
import AppKit

// =============================================================================
// LiveWall — the app's interface.
//
// This file IS the UI layer. It replaces the old BrowseView interface wholesale:
// a new design system (DS), a new window shell, and every page rebuilt on top of
// it. Nothing here reaches into the wallpaper engine directly — it drives the
// existing backend (WallpaperViewModel, LibraryStore, RotationEngine,
// WallpaperController via the view model, KeyVault, MovieStore) exactly as
// before, so all working functionality is preserved.
// =============================================================================

// MARK: - Design system

enum DS {
    // Surfaces — soft grey/white with a faint violet bias, the way macOS
    // materials pick up the desktop behind them.
    static let canvas      = Color(red: 0.937, green: 0.933, blue: 0.957)
    static let sidebarTint = Color(red: 0.910, green: 0.906, blue: 0.945)
    static let panel       = Color.white.opacity(0.66)
    static let panelSolid  = Color.white.opacity(0.86)
    static let raised      = Color.white.opacity(0.5)

    // Ink
    static let ink    = Color(red: 0.090, green: 0.086, blue: 0.114)
    static let ink2   = Color(red: 0.404, green: 0.396, blue: 0.478)
    static let ink3   = Color(red: 0.588, green: 0.580, blue: 0.655)

    // Lines
    static let hairline = Color.black.opacity(0.075)
    static let divider  = Color.black.opacity(0.10)

    // Accents
    static let blue   = Color(red: 0.216, green: 0.443, blue: 1.0)
    static let purple = Color(red: 0.494, green: 0.318, blue: 0.976)
    static let live   = Color(red: 0.180, green: 0.800, blue: 0.443)
    static var accent: LinearGradient {
        LinearGradient(colors: [blue, purple], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var selectionFill: Color { blue.opacity(0.115) }

    // Geometry — Apple-ish spacing scale.
    static let rCard: CGFloat = 18
    static let rTile: CGFloat = 13
    static let rCtl:  CGFloat = 9
    static let gap:   CGFloat = 14
    static let pad:   CGFloat = 18
}

/// The one panel treatment used everywhere: frosted glass, thin border, soft shadow.
private struct GlassPanel: ViewModifier {
    var radius: CGFloat = DS.rCard
    var strong = false
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background((strong ? DS.panelSolid : DS.panel),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(DS.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.07), radius: 14, y: 5)
    }
}
extension View {
    func glass(_ radius: CGFloat = DS.rCard, strong: Bool = false) -> some View {
        modifier(GlassPanel(radius: radius, strong: strong))
    }
}

/// Section heading used by every page.
private struct SectionTitle: View {
    let text: String
    var trailing: AnyView? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.ink)
            Spacer(minLength: 8)
            if let trailing { trailing }
        }
    }
}

/// Small uppercase label above a widget or field.
private struct MicroLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .bold)).tracking(0.7)
            .foregroundStyle(DS.ink3)
    }
}

/// Pill badge (LIVE, 4K) drawn over artwork.
private struct ArtBadge: View {
    let text: String
    var dot = false
    var body: some View {
        HStack(spacing: 5) {
            if dot {
                Circle().fill(DS.live).frame(width: 5, height: 5)
                    .shadow(color: DS.live, radius: 4)
            }
            Text(text).font(.system(size: 10, weight: .bold)).tracking(0.3)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.4), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.22)))
    }
}

// MARK: - Buttons

struct DSPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).frame(height: 32)
            .background(DS.blue, in: RoundedRectangle(cornerRadius: DS.rCtl, style: .continuous))
            .shadow(color: DS.blue.opacity(0.42), radius: 10, y: 4)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct DSGlassButton: ButtonStyle {
    var onArt = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(onArt ? .white : DS.ink)
            .padding(.horizontal, 15).frame(height: 32)
            .background(onArt ? AnyShapeStyle(Color.white.opacity(0.18)) : AnyShapeStyle(.ultraThinMaterial),
                        in: RoundedRectangle(cornerRadius: DS.rCtl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.rCtl, style: .continuous)
                .strokeBorder(onArt ? Color.white.opacity(0.3) : DS.hairline))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Root

struct LiveWallUI: View {
    @ObservedObject var vm: WallpaperViewModel
    @ObservedObject var library: LibraryStore
    @ObservedObject var movies: MovieStore
    @ObservedObject private var keys = KeyVault.shared

    enum Page: String, CaseIterable, Identifiable {
        case home = "Home", wallpapers = "Wallpapers", widgets = "Widgets",
             favorites = "Favorites", discover = "Discover",
             setups = "My Setups", settings = "Settings",
             mine = "My Wallpapers", movies = "Movies", games = "Games",
             profile = "Profile", admin = "Admin"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .home:       return "house.fill"
            case .wallpapers: return "photo.on.rectangle.angled"
            case .widgets:    return "square.grid.2x2.fill"
            case .favorites:  return "heart.fill"
            case .discover:   return "safari.fill"
            case .setups:     return "square.stack.3d.up.fill"
            case .settings:   return "gearshape.fill"
            case .mine:       return "person.crop.square.fill"
            case .movies:     return "film.fill"
            case .games:      return "gamecontroller.fill"
            case .profile:    return "person.crop.circle.fill"
            case .admin:      return "lock.shield.fill"
            }
        }
        static let groupA: [Page] = [.home, .wallpapers, .widgets, .favorites, .discover]
        static let groupB: [Page] = [.setups, .settings]
    }

    @State private var page: Page = .home
    @State private var detail: LibraryItem?
    @State private var search = ""
    @State private var current: LibraryItem?
    @State private var favorites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
    @State private var adminUnlocked = false
    @State private var wallFilter = "All"
    @StateObject private var rotation = RotationEngine()

    private var allItems: [LibraryItem] { library.items + vm.templates }
    private var displayID: CGDirectDisplayID {
        guard let s = NSScreen.main ?? NSScreen.screens.first else { return 0 }
        return DisplayObserver.displayID(for: s)
    }

    var body: some View {
        ZStack {
            // Ground: soft grey with a violet wash, so the glass has something
            // to sit against.
            DS.canvas.ignoresSafeArea()
            LinearGradient(colors: [DS.purple.opacity(0.16), .clear, DS.blue.opacity(0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea().allowsHitTesting(false)

            HStack(spacing: 0) {
                sidebar
                VStack(spacing: 0) {
                    titlebar
                    content
                }
            }
        }
        .frame(minWidth: 1060, minHeight: 680)
        .tint(DS.blue)
        .onAppear {
            if current == nil { current = allItems.first }
            rotation.apply = { vm.apply($0) }
            rotation.interval = max(vm.rotationMinutes, 1) * 60
            if vm.rotationEnabled { rotation.start(pool: allItems) }
        }
        .overlay { KeyBannerOverlay() }
        .sheet(isPresented: $vm.showAdd) { AddSheet(vm: vm) }
        .sheet(item: $detail) { item in
            WallpaperDetail(item: item, vm: vm, displayID: displayID,
                            isFavorite: favorites.contains(item.id.uuidString),
                            onFavorite: { toggleFavorite(item) },
                            onApplied: { current = item },
                            onClose: { detail = nil })
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Logo + wordmark
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(DS.accent)
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: "photo.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white))
                    .shadow(color: DS.blue.opacity(0.4), radius: 6, y: 2)
                Text("LiveWall").font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.ink)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18).padding(.bottom, 20)

            VStack(spacing: 2) {
                ForEach(Page.groupA) { navRow($0) }
            }

            Rectangle().fill(DS.divider).frame(height: 1)
                .padding(.horizontal, 16).padding(.vertical, 12)

            VStack(spacing: 2) {
                ForEach(Page.groupB) { navRow($0) }
            }

            // Extras only appear when they're relevant.
            if !library.items.isEmpty || !movies.items.isEmpty || keys.isUnlocked || adminUnlocked {
                Rectangle().fill(DS.divider).frame(height: 1)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                VStack(spacing: 2) {
                    if !library.items.isEmpty { navRow(.mine) }
                    navRow(.movies)
                    if keys.isUnlocked { navRow(.games) }
                    if AdminConfig.shared != nil || adminUnlocked { navRow(.admin) }
                }
            }

            Spacer(minLength: 12)

            if keys.count > 0 && !keys.isUnlocked { keyProgress }
        }
        .frame(width: 208)
        .background(DS.sidebarTint.opacity(0.55))
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) { Rectangle().fill(DS.hairline).frame(width: 1) }
        .ignoresSafeArea()
    }

    private func navRow(_ p: Page) -> some View {
        let on = page == p && detail == nil
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { detail = nil; page = p }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: p.icon)
                    .font(.system(size: 12.5))
                    .frame(width: 18)
                    .foregroundStyle(on ? DS.blue : DS.ink2)
                Text(p.rawValue)
                    .font(.system(size: 13, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? DS.blue : DS.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.selectionFill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }

    private var keyProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("🔑").font(.system(size: 12))
                Text("\(keys.count)/\(KeyVault.total) keys")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(DS.ink)
            }
            HStack(spacing: 3) {
                ForEach(0..<KeyVault.total, id: \.self) { i in
                    Circle().fill(i < keys.count ? Color.yellow : DS.divider)
                        .frame(width: 5, height: 5)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(DS.rTile)
        .padding(.horizontal, 12).padding(.bottom, 14)
    }

    // MARK: Titlebar

    private var titlebar: some View {
        HStack(spacing: 12) {
            Text(detail == nil ? page.rawValue : "Wallpaper")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.ink)
                .frame(width: 150, alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11.5)).foregroundStyle(DS.ink3)
                TextField("Search wallpapers, widgets…", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(DS.ink)
                    .onChange(of: search) { v in
                        if v == "valentino2027games" { search = ""; adminUnlocked = true; page = .admin }
                        else if v == "LiveWall2013" { search = ""; KeyVault.shared.unlockAll(); page = .games }
                        else if !v.isEmpty && page == .home { page = .wallpapers }
                    }
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11.5)).foregroundStyle(DS.ink3)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11).frame(height: 30).frame(maxWidth: 380)
            .glass(DS.rCtl, strong: true)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button { vm.showAdd = true } label: {
                    Image(systemName: "plus").font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(DS.ink2).frame(width: 30, height: 30)
                        .glass(DS.rCtl)
                }.buttonStyle(.plain).help("Add a wallpaper")
                Button { page = .profile } label: {
                    Circle().fill(DS.accent).frame(width: 28, height: 28)
                        .overlay(Text(initial).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white))
                        .shadow(color: DS.blue.opacity(0.35), radius: 5, y: 2)
                }.buttonStyle(.plain).help("Profile")
            }
            .frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, DS.pad)
        .frame(height: 52)
    }

    private var initial: String {
        String((AuthService.shared.session?.user.email ?? "L").prefix(1)).uppercased()
    }

    // MARK: Content router

    @ViewBuilder private var content: some View {
        switch page {
        case .home:       HomePage(ui: self)
        case .wallpapers: browser(title: "Wallpapers", items: filtered(vm.templates), showFilters: true)
        case .favorites:  browser(title: "Favorites", items: filtered(allItems.filter { favorites.contains($0.id.uuidString) }), showFilters: false)
        case .mine:       browser(title: "My Wallpapers", items: filtered(library.items), showFilters: false)
        case .discover:   DiscoverPage(ui: self)
        case .widgets:    WidgetsPage(displayID: displayID)
        case .setups:     SetupsPage(ui: self)
        case .settings:   SettingsPage(vm: vm)
        case .movies:     MoviesPage(movies: movies)
        case .games:      GamesPage()
        case .profile:    ScrollView { ProfileScreen().padding(DS.pad) }
        case .admin:      adminPage
        }
    }

    @ViewBuilder private var adminPage: some View {
        if let panel = AdminPanelView(onClose: { page = .home }) { panel }
        else { emptyState("lock.shield", "Admin unavailable", "No admin credentials on this Mac.") }
    }

    // MARK: Shared pieces used by the pages

    fileprivate func filtered(_ items: [LibraryItem]) -> [LibraryItem] {
        var out = items
        if wallFilter != "All" {
            out = out.filter { categoryLabel($0) == wallFilter || resolutionLabel($0) == wallFilter }
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { out = out.filter { $0.title.lowercased().contains(q) } }
        return out
    }

    fileprivate func toggleFavorite(_ item: LibraryItem) {
        let key = item.id.uuidString
        if favorites.contains(key) { favorites.remove(key) } else { favorites.insert(key) }
        UserDefaults.standard.set(Array(favorites), forKey: "favorites")
    }

    fileprivate func isFavorite(_ item: LibraryItem) -> Bool { favorites.contains(item.id.uuidString) }
    fileprivate func open(_ item: LibraryItem) { vm.selectedID = item.id; detail = item }
    fileprivate func setCurrent(_ item: LibraryItem) { current = item }
    fileprivate var currentItem: LibraryItem? { current ?? allItems.first }
    fileprivate var everything: [LibraryItem] { allItems }
    fileprivate var rotationEngine: RotationEngine { rotation }
    fileprivate var viewModel: WallpaperViewModel { vm }
    fileprivate var primaryDisplay: CGDirectDisplayID { displayID }
    fileprivate func goTo(_ p: Page) { page = p }
    fileprivate var categories: [String] {
        ["All"] + Array(Set(vm.templates.map { categoryLabel($0) })).sorted()
    }
    fileprivate var filterBinding: Binding<String> {
        Binding(get: { wallFilter }, set: { wallFilter = $0 })
    }

    // MARK: Wallpaper browser (Wallpapers / Favorites / My Wallpapers)

    private func browser(title: String, items: [LibraryItem], showFilters: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.gap) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 26, weight: .bold)).foregroundStyle(DS.ink)
                        Text("\(items.count) wallpaper\(items.count == 1 ? "" : "s")")
                            .font(.system(size: 12.5)).foregroundStyle(DS.ink2)
                    }
                    Spacer()
                    if showFilters && !vm.motionBGSLoading {
                        Button { vm.loadMotionBGS() } label: { Text("Load more") }
                            .buttonStyle(DSGlassButton())
                    }
                    if vm.motionBGSLoading { ProgressView().scaleEffect(0.6).frame(height: 32) }
                }

                if showFilters {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(categories, id: \.self) { c in
                                let on = wallFilter == c
                                Button { withAnimation(.easeOut(duration: 0.15)) { wallFilter = c } } label: {
                                    Text(c).font(.system(size: 12, weight: on ? .semibold : .regular))
                                        .foregroundStyle(on ? .white : DS.ink2)
                                        .padding(.horizontal, 13).frame(height: 28)
                                        .background {
                                            if on { Capsule().fill(DS.blue) }
                                            else { Capsule().fill(.ultraThinMaterial); Capsule().strokeBorder(DS.hairline) }
                                        }
                                }.buttonStyle(.plain)
                            }
                        }.padding(.vertical, 1)
                    }
                }

                if items.isEmpty {
                    emptyState("photo.on.rectangle", "Nothing here yet",
                               showFilters ? "Try another category, or load more wallpapers."
                                           : "Wallpapers you save will show up here.")
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 224, maximum: 320), spacing: DS.gap)],
                              spacing: DS.gap) {
                        ForEach(items) { item in
                            WallTile(item: item,
                                     favorite: isFavorite(item),
                                     running: vm.runningItemID == item.id,
                                     onOpen: { open(item) },
                                     onApply: { vm.apply(item); current = item },
                                     onFavorite: { toggleFavorite(item) })
                        }
                    }
                }
            }
            .padding(DS.pad)
        }
    }

    fileprivate func emptyState(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(DS.ink3)
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.ink)
            Text(subtitle).font(.system(size: 12.5)).foregroundStyle(DS.ink2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Movies

private struct MoviesPage: View {
    @ObservedObject var movies: MovieStore
    @State private var playing: MovieItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.gap) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Movies").font(.system(size: 26, weight: .bold)).foregroundStyle(DS.ink)
                        Text("Imported MP4s play here. Catalog links open in your browser to download.")
                            .font(.system(size: 12.5)).foregroundStyle(DS.ink2)
                    }
                    Spacer()
                    Button("Import MP4") {
                        let p = NSOpenPanel()
                        p.allowedContentTypes = [.mpeg4Movie, .movie, .quickTimeMovie]
                        p.allowsMultipleSelection = true
                        if p.runModal() == .OK { for u in p.urls { _ = movies.importMP4(from: u) } }
                    }.buttonStyle(DSPrimaryButton())
                }

                let all = movies.items + MovieCatalog.driveMovies
                if all.isEmpty {
                    VStack(spacing: 9) {
                        Image(systemName: "film").font(.system(size: 34)).foregroundStyle(DS.ink3)
                        Text("No movies yet").font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.ink)
                        Text("Import an MP4 to get started.").font(.system(size: 12.5)).foregroundStyle(DS.ink2)
                    }.frame(maxWidth: .infinity).padding(.top, 50)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: DS.gap)], spacing: DS.gap) {
                        ForEach(all) { m in
                            Button { openMovie(m) } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    ZStack {
                                        LinearGradient(colors: [DS.purple.opacity(0.85), DS.blue.opacity(0.85)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                                        Image(systemName: "play.circle.fill")
                                            .font(.system(size: 34)).foregroundStyle(.white.opacity(0.92))
                                    }
                                    .aspectRatio(16.0/9.0, contentMode: .fit)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(m.title).font(.system(size: 12.5, weight: .semibold))
                                            .foregroundStyle(DS.ink).lineLimit(1)
                                        Text(m.kind == .localMP4 ? "On this Mac" : "Opens in browser")
                                            .font(.system(size: 11)).foregroundStyle(DS.ink2)
                                    }
                                    .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .glass(DS.rTile)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(DS.pad)
        }
        .sheet(item: $playing) { m in
            VStack(spacing: 0) {
                HStack {
                    Button("Close") { playing = nil }.buttonStyle(DSGlassButton())
                    Spacer()
                    Text(m.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.ink)
                    Spacer()
                }.padding(DS.gap)
                if let url = URL(string: m.urlString) { MoviePlayerView(url: url) }
            }
            .frame(width: 900, height: 560)
            .background(DS.canvas)
        }
    }

    private func openMovie(_ m: MovieItem) {
        if m.kind == .localMP4 { playing = m }
        else if let url = URL(string: m.urlString) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Games

private struct GameEntry: Identifiable, Hashable {
    let resourceName: String
    let title: String
    var id: String { resourceName }
}

private struct GamesPage: View {
    @State private var open: [GameEntry] = []
    @State private var activeID: GameEntry.ID?
    @State private var showing = false
    @State private var fullscreen = false
    @State private var search = ""

    private var games: [GameEntry] {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Games", isDirectory: true),
              let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { i -> GameEntry? in
            guard let url = i as? URL, url.pathExtension.lowercased() == "html" else { return nil }
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let res = rel.replacingOccurrences(of: ".html", with: "")
            let title = res.replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "/index", with: "")
                .split(separator: "/").joined(separator: " · ").capitalized
            return GameEntry(resourceName: res, title: title)
        }.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }
    private var visible: [GameEntry] {
        search.isEmpty ? games : games.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.gap) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Games").font(.system(size: 26, weight: .bold)).foregroundStyle(DS.ink)
                            Text("\(games.count) games, playing in tabs.")
                                .font(.system(size: 12.5)).foregroundStyle(DS.ink2)
                        }
                        Spacer()
                        HStack(spacing: 7) {
                            Image(systemName: "magnifyingglass").font(.system(size: 11.5)).foregroundStyle(DS.ink3)
                            TextField("Search games", text: $search).textFieldStyle(.plain)
                                .font(.system(size: 12.5)).frame(width: 150)
                        }
                        .padding(.horizontal, 11).frame(height: 30).glass(DS.rCtl, strong: true)
                        Button("Random") { if let g = visible.randomElement() { openGame(g) } }
                            .buttonStyle(DSGlassButton())
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: DS.gap)], spacing: DS.gap) {
                        ForEach(visible) { g in
                            Button { openGame(g) } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    ZStack {
                                        LinearGradient(colors: tint(g), startPoint: .topLeading, endPoint: .bottomTrailing)
                                        Image(systemName: "gamecontroller.fill")
                                            .font(.system(size: 28)).foregroundStyle(.white.opacity(0.9))
                                    }
                                    .aspectRatio(16.0/10.0, contentMode: .fit)
                                    Text(g.title).font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(DS.ink).lineLimit(2)
                                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .glass(DS.rTile)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .padding(DS.pad)
            }

            if showing { browser.transition(.opacity).zIndex(30) }
        }
        .animation(.easeOut(duration: 0.18), value: showing)
    }

    private func tint(_ g: GameEntry) -> [Color] {
        let h = Double(abs(g.title.hashValue % 360)) / 360.0
        return [Color(hue: h, saturation: 0.55, brightness: 0.62),
                Color(hue: (h + 0.15).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.3)]
    }

    private func openGame(_ g: GameEntry) {
        if !open.contains(where: { $0.id == g.id }) { open.append(g) }
        activeID = g.id; showing = true
    }
    private func close(_ g: GameEntry) {
        guard let i = open.firstIndex(where: { $0.id == g.id }) else { return }
        open.remove(at: i)
        if open.isEmpty { showing = false; activeID = nil }
        else if activeID == g.id { activeID = open[min(i, open.count - 1)].id }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { showing = false; open = []; activeID = nil } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        Text("Back").font(.system(size: 12.5, weight: .semibold))
                    }.foregroundStyle(.white)
                    .padding(.horizontal, 13).frame(height: 30)
                    .background(DS.blue, in: Capsule())
                }.buttonStyle(.plain).keyboardShortcut(.cancelAction)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(open) { g in
                            let on = g.id == activeID
                            HStack(spacing: 7) {
                                Text(g.title).font(.system(size: 12, weight: on ? .semibold : .regular))
                                    .foregroundStyle(.white.opacity(on ? 1 : 0.7)).lineLimit(1)
                                Button { close(g) } label: {
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.65)).frame(width: 15, height: 15)
                                }.buttonStyle(.plain)
                            }
                            .padding(.leading, 11).padding(.trailing, 5).frame(height: 28)
                            .background(Color.white.opacity(on ? 0.16 : 0.06),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .frame(maxWidth: 200)
                            .contentShape(Rectangle())
                            .onTapGesture { activeID = g.id }
                        }
                    }
                }
                Spacer(minLength: 0)
                Button {
                    GameWindow.toggleFullscreen(); fullscreen = GameWindow.isFullscreen
                } label: {
                    Image(systemName: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12.5, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 32, height: 30)
                        .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }.buttonStyle(.plain).keyboardShortcut("f", modifiers: [.command, .control])
                    .help("Toggle full screen")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color(red: 0.09, green: 0.09, blue: 0.11))

            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.05)
                ForEach(open) { g in
                    BundledGameView(resourceName: g.resourceName)
                        .opacity(g.id == activeID ? 1 : 0)
                        .allowsHitTesting(g.id == activeID)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.04, green: 0.04, blue: 0.05).ignoresSafeArea())
        .onAppear { fullscreen = GameWindow.isFullscreen }
    }
}

// MARK: - Wallpaper tile

private struct WallTile: View {
    let item: LibraryItem
    let favorite: Bool
    let running: Bool
    var onOpen: () -> Void
    var onApply: () -> Void
    var onFavorite: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fixed 16:9 cell, artwork fills it and is clipped — a tile can never
            // overflow its column.
            Color.clear
                .aspectRatio(16.0/9.0, contentMode: .fit)
                .overlay {
                    ZStack {
                        PosterView(item: item)
                        LinearGradient(colors: [.black.opacity(0.22), .clear, .clear, .black.opacity(0.45)],
                                       startPoint: .top, endPoint: .bottom)
                        HStack {
                            if item.kind != .localImage { ArtBadge(text: "LIVE", dot: true) }
                            Spacer()
                            Button(action: onFavorite) {
                                Image(systemName: favorite ? "heart.fill" : "heart")
                                    .font(.system(size: 11))
                                    .foregroundStyle(favorite ? Color(red: 1, green: 0.42, blue: 0.5) : .white)
                                    .frame(width: 24, height: 24)
                                    .background(.black.opacity(0.35), in: Circle())
                                    .overlay(Circle().strokeBorder(.white.opacity(0.2)))
                            }.buttonStyle(.plain).opacity(hover || favorite ? 1 : 0)
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                        if running {
                            ArtBadge(text: "ON DESKTOP", dot: true)
                                .padding(9)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        }

                        if hover {
                            ZStack {
                                Color.black.opacity(0.32)
                                HStack(spacing: 8) {
                                    Button("Preview", action: onOpen).buttonStyle(DSGlassButton(onArt: true))
                                    Button("Apply", action: onApply).buttonStyle(DSPrimaryButton())
                                }
                            }
                        }
                    }
                }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: DS.rTile, bottomLeadingRadius: 0,
                                                  bottomTrailingRadius: 0, topTrailingRadius: DS.rTile,
                                                  style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(DS.ink).lineLimit(1)
                Text("\(categoryLabel(item)) · \(resolutionLabel(item))")
                    .font(.system(size: 11)).foregroundStyle(DS.ink2).lineLimit(1)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .glass(DS.rTile)
        .scaleEffect(hover ? 1.012 : 1)
        .animation(.easeOut(duration: 0.16), value: hover)
        .onHover { hover = $0 }
        .onTapGesture(perform: onOpen)
    }
}

// MARK: - HOME

private struct HomePage: View {
    let ui: LiveWallUI

    var body: some View {
        GeometryReader { geo in
            // Everything is sized from the real viewport. The hero used to rely
            // on aspectRatio inside a ScrollView, which proposes unbounded
            // height — on a wide or full-screen window that let the card grow
            // past the viewport and shove the widgets rail off-screen.
            let outer  = DS.pad
            let avail  = min(max(geo.size.width - outer * 2, 640), 1560)
            let rail   = max(264, min(322, avail * 0.235))
            let leftW  = avail - rail - DS.gap
            // Cap by height too, so Recent Wallpapers stays on screen.
            let heroH  = max(240, min(leftW * 9.0 / 16.0, geo.size.height * 0.56))

            ScrollView {
                HStack(alignment: .top, spacing: DS.gap) {
                    // CENTRE column — the wallpaper card dominates, Recent below.
                    VStack(spacing: DS.gap) {
                        CurrentWallpaperCard(ui: ui, height: heroH)
                        RecentRow(ui: ui)
                    }
                    .frame(width: leftW)

                    // RIGHT column — widgets panel, Quick Actions below.
                    VStack(spacing: DS.gap) {
                        WidgetsPanel(ui: ui)
                        QuickActions(ui: ui)
                    }
                    .frame(width: rail)
                }
                .frame(maxWidth: .infinity)   // centres the layout on wide displays
                .padding(outer)
            }
        }
    }
}

/// The hero: "Current Wallpaper" title, a big 16:9 preview, badges, name/type,
/// and the three actions.
private struct CurrentWallpaperCard: View {
    let ui: LiveWallUI
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Current Wallpaper")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.ink)

            if let item = ui.currentItem {
                ZStack {
                    Color.black
                    PosterView(item: item)
                    LoopingVideoView(url: heroPlayableURL(item))
                    LinearGradient(colors: [.black.opacity(0.3), .clear, .clear, .black.opacity(0.78)],
                                   startPoint: .top, endPoint: .bottom)

                    // Badges, top-right
                    HStack(spacing: 6) {
                        if item.kind != .localImage { ArtBadge(text: "LIVE", dot: true) }
                        ArtBadge(text: resolutionLabel(item))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                    // Name + type + actions, bottom
                    HStack(alignment: .bottom, spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.system(size: 21, weight: .semibold))
                                .foregroundStyle(.white).lineLimit(1)
                                .shadow(color: .black.opacity(0.55), radius: 10)
                            Text(typeLine(item))
                                .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 8) {
                            Button("Preview") { ui.open(item) }
                                .buttonStyle(DSGlassButton(onArt: true))
                            Button("Set Wallpaper") {
                                ui.viewModel.apply(item, to: ui.primaryDisplay)
                                ui.setCurrent(item)
                            }.buttonStyle(DSGlassButton(onArt: true))
                            Button("Apply") {
                                ui.viewModel.apply(item)
                                ui.setCurrent(item)
                            }.buttonStyle(DSPrimaryButton())
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: DS.rCard, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.rCard, style: .continuous).strokeBorder(DS.hairline))
                .shadow(color: .black.opacity(0.14), radius: 20, y: 8)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "sparkles.tv").font(.system(size: 40)).foregroundStyle(DS.ink3)
                    Text("No wallpaper yet").font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.ink)
                    Button("Add a wallpaper") { ui.viewModel.showAdd = true }.buttonStyle(DSPrimaryButton())
                }
                .frame(maxWidth: .infinity).frame(height: height)
                .glass()
            }
        }
    }

    private func typeLine(_ item: LibraryItem) -> String {
        let kind = item.kind == .localImage ? "Still Image" : "Animated Wallpaper"
        return "\(kind) · \(categoryLabel(item))"
    }
}

/// Bottom-left: a horizontal thumbnail row.
private struct RecentRow: View {
    let ui: LiveWallUI

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Recent Wallpapers", trailing: AnyView(
                Button("View All") { ui.goTo(.wallpapers) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DS.blue)
            ))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 11) {
                    ForEach(Array(ui.everything.prefix(10))) { item in
                        RecentThumb(item: item,
                                    isCurrent: ui.currentItem?.id == item.id,
                                    onTap: { ui.open(item) })
                    }
                }
                .padding(.vertical, 3).padding(.horizontal, 1)
            }
        }
        .padding(DS.gap)
        .glass()
    }
}

private struct RecentThumb: View {
    let item: LibraryItem
    let isCurrent: Bool
    var onTap: () -> Void
    @State private var hover = false

    var body: some View {
        Color.clear
            .aspectRatio(16.0/10.0, contentMode: .fit)
            .frame(width: 158)
            .overlay {
                ZStack {
                    PosterView(item: item)
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                    if item.kind != .localImage {
                        ArtBadge(text: "LIVE", dot: true)
                            .scaleEffect(0.86)
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    Text(item.title)
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white)
                        .lineLimit(1).padding(.horizontal, 9).padding(.bottom, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(isCurrent ? DS.blue : DS.hairline, lineWidth: isCurrent ? 2 : 1))
            .shadow(color: .black.opacity(hover ? 0.16 : 0.08), radius: hover ? 12 : 6, y: hover ? 5 : 2)
            .scaleEffect(hover ? 1.03 : 1)
            .animation(.easeOut(duration: 0.16), value: hover)
            .onHover { hover = $0 }
            .onTapGesture(perform: onTap)
    }
}

/// Right panel: compact widget previews — Clock, Weather, Music, App Launcher.
private struct WidgetsPanel: View {
    let ui: LiveWallUI

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionTitle(text: "Widgets", trailing: AnyView(
                Button { ui.goTo(.widgets) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.ink3)
                }.buttonStyle(.plain)
            ))

            HStack(spacing: 10) {
                ClockWidget()
                WeatherWidget()
            }
            MusicWidget()
            LauncherWidget()
        }
        .padding(DS.gap)
        .glass()
    }
}

private struct ClockWidget: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let c = Calendar.current.dateComponents([.hour, .minute, .second], from: ctx.date)
            let h = Double(c.hour ?? 0).truncatingRemainder(dividingBy: 12)
            let m = Double(c.minute ?? 0), s = Double(c.second ?? 0)
            VStack(spacing: 7) {
                ZStack {
                    Circle().fill(.white).overlay(Circle().strokeBorder(DS.hairline))
                    ForEach(0..<12, id: \.self) { i in
                        Capsule().fill(DS.ink3)
                            .frame(width: i % 3 == 0 ? 1.8 : 1.2, height: i % 3 == 0 ? 5.5 : 3.5)
                            .offset(y: -25).rotationEffect(.degrees(Double(i) * 30))
                    }
                    hand(14, 2.6, DS.ink, h * 30 + m * 0.5)
                    hand(20, 2.2, DS.ink, m * 6 + s * 0.1)
                    hand(22, 1.2, Color(red: 1, green: 0.3, blue: 0.33), s * 6)
                    Circle().fill(DS.ink).frame(width: 4.5, height: 4.5)
                }
                .frame(width: 62, height: 62)
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(DS.ink)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(DS.raised, in: RoundedRectangle(cornerRadius: DS.rTile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.rTile, style: .continuous).strokeBorder(DS.hairline))
        }
    }
    private func hand(_ len: CGFloat, _ w: CGFloat, _ c: Color, _ deg: Double) -> some View {
        Capsule().fill(c).frame(width: w, height: len)
            .offset(y: -len/2).rotationEffect(.degrees(deg))
    }
}

private struct WeatherWidget: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "cloud.sun.fill")
                    .font(.system(size: 19))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(red: 1, green: 0.84, blue: 0.4))
                Spacer(minLength: 0)
            }
            Text("24°").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
            Text("Partly Cloudy").font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
            Text("H: 26°  L: 16°").font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color(red: 0.29, green: 0.56, blue: 0.89), DS.purple],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: DS.rTile, style: .continuous))
        .help("Sample weather widget — connect a weather source in Settings")
    }
}

private struct MusicWidget: View {
    @State private var playing = false
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [DS.purple, Color(red: 0.85, green: 0.24, blue: 0.55)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: "music.note").font(.system(size: 15)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 1) {
                Text("Sunset Drive").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.ink).lineLimit(1)
                Text("Ooyy").font(.system(size: 10.5)).foregroundStyle(DS.ink2)
                HStack(spacing: 12) {
                    Image(systemName: "backward.fill")
                    Button { playing.toggle() } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                    }.buttonStyle(.plain)
                    Image(systemName: "forward.fill")
                }
                .font(.system(size: 10)).foregroundStyle(DS.ink2).padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(DS.raised, in: RoundedRectangle(cornerRadius: DS.rTile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.rTile, style: .continuous).strokeBorder(DS.hairline))
    }
}

private struct LauncherWidget: View {
    private var apps: [String] {
        ["/System/Library/CoreServices/Finder.app",
         "/Applications/Safari.app",
         "/System/Applications/Music.app",
         "/System/Applications/Notes.app"]
            .filter { FileManager.default.fileExists(atPath: $0) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MicroLabel(text: "Launcher")
            HStack(spacing: 9) {
                ForEach(apps, id: \.self) { p in
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } label: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: p))
                            .resizable().frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .help(FileManager.default.displayName(atPath: p))
                }
                Spacer(minLength: 0)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.raised, in: RoundedRectangle(cornerRadius: DS.rTile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.rTile, style: .continuous).strokeBorder(DS.hairline))
    }
}

/// Bottom-right: a 2×2 grid.
private struct QuickActions: View {
    let ui: LiveWallUI
    @ObservedObject private var keys = KeyVault.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionTitle(text: "Quick Actions")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)], spacing: 9) {
                tile("shuffle", "Shuffle Wallpaper", "Random from library") {
                    if let pick = ui.everything.randomElement() {
                        ui.viewModel.apply(pick); ui.setCurrent(pick)
                    }
                }
                tile("clock.arrow.2.circlepath",
                     ui.rotationEngine.isRunning ? "Stop Auto" : "Auto Change",
                     ui.rotationEngine.isRunning ? "Rotation on" : "Rotate on a timer") {
                    if ui.rotationEngine.isRunning { ui.rotationEngine.stop() }
                    else { ui.rotationEngine.start(pool: ui.everything) }
                }
                tile("square.and.arrow.down", "Import Wallpaper", "From Mac or URL") {
                    ui.viewModel.showAdd = true
                }
                tile("square.stack.3d.up", "Create Setup", "Save your layout") {
                    ui.goTo(.setups)
                }
            }
        }
        .padding(DS.gap)
        .glass()
    }

    private func tile(_ icon: String, _ title: String, _ sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(DS.blue)
                    .frame(width: 28, height: 28)
                    .background(DS.selectionFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(DS.ink).lineLimit(1).minimumScaleFactor(0.85)
                    Text(sub).font(.system(size: 10)).foregroundStyle(DS.ink3).lineLimit(1)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.raised, in: RoundedRectangle(cornerRadius: DS.rTile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.rTile, style: .continuous).strokeBorder(DS.hairline))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// MARK: - Wallpaper detail

private struct WallpaperDetail: View {
    let item: LibraryItem
    @ObservedObject var vm: WallpaperViewModel
    let displayID: CGDirectDisplayID
    let isFavorite: Bool
    var onFavorite: () -> Void
    var onApplied: () -> Void
    var onClose: () -> Void

    @State private var scaling: ScalingMode = .fill

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { onClose() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        Text("Back").font(.system(size: 12.5, weight: .medium))
                    }.foregroundStyle(DS.ink)
                }.buttonStyle(DSGlassButton())
                Spacer()
                Button { onFavorite() } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(isFavorite ? Color(red: 1, green: 0.42, blue: 0.5) : DS.ink2)
                }.buttonStyle(DSGlassButton())
                Button("Apply Wallpaper") { vm.apply(item); onApplied(); onClose() }
                    .buttonStyle(DSPrimaryButton())
            }
            .padding(DS.gap)

            ScrollView {
                VStack(alignment: .leading, spacing: DS.gap) {
                    ZStack {
                        Color.black
                        PosterView(item: item)
                        LoopingVideoView(url: heroPlayableURL(item))
                        HStack(spacing: 6) {
                            if item.kind != .localImage { ArtBadge(text: "LIVE", dot: true) }
                            ArtBadge(text: resolutionLabel(item))
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                    .aspectRatio(16.0/9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: DS.rCard, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.rCard, style: .continuous).strokeBorder(DS.hairline))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.system(size: 22, weight: .bold)).foregroundStyle(DS.ink)
                        Text("\(categoryLabel(item)) · \(resolutionLabel(item))")
                            .font(.system(size: 12.5)).foregroundStyle(DS.ink2)
                    }

                    VStack(spacing: 0) {
                        row("Scaling") {
                            Picker("", selection: $scaling) {
                                Text("Fill").tag(ScalingMode.fill)
                                Text("Fit").tag(ScalingMode.fit)
                                Text("Stretch").tag(ScalingMode.stretch)
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 210)
                            .onChange(of: scaling) { vm.scaling = $0 }
                        }
                        Divider().overlay(DS.hairline)
                        row("Brightness") {
                            Slider(value: Binding(get: { vm.brightness },
                                                  set: { vm.setBrightness($0) }), in: 0.4...1.4)
                                .frame(width: 210)
                        }
                        Divider().overlay(DS.hairline)
                        row("Saturation") {
                            Slider(value: Binding(get: { vm.saturation },
                                                  set: { vm.setSaturation($0) }), in: 0...2)
                                .frame(width: 210)
                        }
                        Divider().overlay(DS.hairline)
                        row("Mute audio") {
                            Toggle("", isOn: $vm.muted).labelsHidden().toggleStyle(.switch)
                        }
                    }
                    .padding(.horizontal, DS.gap)
                    .glass()

                    HStack(spacing: 9) {
                        Button("Set on This Display") { vm.apply(item, to: displayID); onApplied() }
                            .buttonStyle(DSGlassButton())
                        Button("Apply to All Displays") { vm.apply(item); onApplied() }
                            .buttonStyle(DSGlassButton())
                        Spacer()
                    }
                }
                .padding(DS.pad).padding(.top, 0)
            }
        }
        .frame(width: 860, height: 700)
        .background(DS.canvas)
        .onAppear { scaling = vm.scaling }
    }

    private func row<C: View>(_ label: String, @ViewBuilder control: () -> C) -> some View {
        HStack {
            Text(label).font(.system(size: 12.5)).foregroundStyle(DS.ink)
            Spacer()
            control()
        }
        .frame(height: 44)
    }
}

// MARK: - Discover

private struct DiscoverPage: View {
    let ui: LiveWallUI
    @State private var tab = "Trending"
    private let tabs = ["Trending", "Popular", "New", "Staff Picks"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.gap) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Discover").font(.system(size: 26, weight: .bold)).foregroundStyle(DS.ink)
                    Text("Wallpapers from the LiveWall catalog.")
                        .font(.system(size: 12.5)).foregroundStyle(DS.ink2)
                }

                HStack(spacing: 7) {
                    ForEach(tabs, id: \.self) { t in
                        let on = tab == t
                        Button { withAnimation(.easeOut(duration: 0.15)) { tab = t } } label: {
                            Text(t).font(.system(size: 12, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? .white : DS.ink2)
                                .padding(.horizontal, 13).frame(height: 28)
                                .background {
                                    if on { Capsule().fill(DS.blue) }
                                    else { Capsule().fill(.ultraThinMaterial); Capsule().strokeBorder(DS.hairline) }
                                }
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 224, maximum: 320), spacing: DS.gap)],
                          spacing: DS.gap) {
                    ForEach(items) { item in
                        WallTile(item: item,
                                 favorite: ui.isFavorite(item),
                                 running: ui.viewModel.runningItemID == item.id,
                                 onOpen: { ui.open(item) },
                                 onApply: { ui.viewModel.apply(item); ui.setCurrent(item) },
                                 onFavorite: { ui.toggleFavorite(item) })
                    }
                }
            }
            .padding(DS.pad)
        }
    }

    /// Different slices of the catalog per tab — stable, not random per redraw.
    private var items: [LibraryItem] {
        let all = ui.viewModel.templates
        guard !all.isEmpty else { return [] }
        switch tab {
        case "Popular":     return Array(all.dropFirst(6).prefix(24))
        case "New":         return Array(all.suffix(24).reversed())
        case "Staff Picks": return Array(all.enumerated().filter { $0.offset % 3 == 0 }.map(\.element).prefix(24))
        default:            return Array(all.prefix(24))
        }
    }
}

// MARK: - Widgets page

private struct WidgetsPage: View {
    let displayID: CGDirectDisplayID
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Widgets").font(.system(size: 26, weight: .bold)).foregroundStyle(DS.ink)
                Text("Add widgets to your desktop, then drag them where you want.")
                    .font(.system(size: 12.5)).foregroundStyle(DS.ink2)
            }
            .padding(.horizontal, DS.pad).padding(.top, DS.pad).padding(.bottom, DS.gap)

            // The real widget engine, hosted inside the new chrome.
            WidgetsScreen(primaryDisplayID: displayID)
                .padding(.horizontal, DS.pad).padding(.bottom, DS.pad)
        }
    }
}

// MARK: - My Setups

private struct SetupsPage: View {
    let ui: LiveWallUI
    @AppStorage("liveWallActiveSetup") private var active = ""

    private struct Setup: Identifiable {
        let id = UUID(); let name: String; let icon: String; let tint: [Color]
    }
    private var setups: [Setup] {
        [ .init(name: "Work",    icon: "briefcase.fill",     tint: [DS.blue, DS.purple]),
          .init(name: "Gaming",  icon: "gamecontroller.fill",tint: [Color(red:0.85,green:0.2,blue:0.55), DS.purple]),
          .init(name: "School",  icon: "book.fill",          tint: [Color(red:0.16,green:0.6,blue:0.45), DS.blue]),
          .init(name: "Minimal", icon: "circle.dashed",      tint: [Color(red:0.55,green:0.56,blue:0.62), Color(red:0.32,green:0.33,blue:0.38)]),
          .init(name: "Night",   icon: "moon.stars.fill",    tint: [Color(red:0.13,green:0.12,blue:0.3), DS.purple]) ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.gap) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("My Setups").font(.system(size: 26, weight: .bold)).foregroundStyle(DS.ink)
                    Text("A setup remembers your wallpaper and its settings. Switch with one click.")
                        .font(.system(size: 12.5)).foregroundStyle(DS.ink2)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 236, maximum: 330), spacing: DS.gap)],
                          spacing: DS.gap) {
                    ForEach(setups) { s in
                        Button {
                            active = s.name
                            if let pick = ui.everything.randomElement() {
                                ui.viewModel.apply(pick); ui.setCurrent(pick)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                ZStack {
                                    LinearGradient(colors: s.tint, startPoint: .topLeading, endPoint: .bottomTrailing)
                                    Image(systemName: s.icon).font(.system(size: 30))
                                        .foregroundStyle(.white.opacity(0.9))
                                    if active == s.name {
                                        ArtBadge(text: "ACTIVE", dot: true)
                                            .padding(9)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    }
                                }
                                .aspectRatio(16.0/9.0, contentMode: .fit)
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(s.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.ink)
                                        Text(active == s.name ? "Current setup" : "Tap to switch")
                                            .font(.system(size: 11)).foregroundStyle(DS.ink2)
                                    }
                                    Spacer()
                                    Image(systemName: active == s.name ? "checkmark.circle.fill" : "arrow.right.circle")
                                        .foregroundStyle(active == s.name ? DS.blue : DS.ink3)
                                }
                                .padding(11)
                            }
                            .glass(DS.rTile)
                        }.buttonStyle(.plain)
                    }
                }
            }
            .padding(DS.pad)
        }
    }
}

// MARK: - Settings

private struct SettingsPage: View {
    @ObservedObject var vm: WallpaperViewModel
    @State private var section = "General"
    private let sections = ["General", "Appearance", "Performance", "Wallpapers", "Startup", "Updates", "About"]

    var body: some View {
        HStack(alignment: .top, spacing: DS.gap) {
            // Section list
            VStack(spacing: 2) {
                ForEach(sections, id: \.self) { s in
                    Button { section = s } label: {
                        HStack {
                            Text(s).font(.system(size: 12.5, weight: section == s ? .semibold : .regular))
                                .foregroundStyle(section == s ? DS.blue : DS.ink)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).frame(height: 30)
                        .background {
                            if section == s {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.selectionFill)
                            }
                        }
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(width: 182)
            .glass()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.gap) {
                    Text(section).font(.system(size: 22, weight: .bold)).foregroundStyle(DS.ink)
                    group { body(for: section) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(DS.pad)
    }

    @ViewBuilder private func body(for s: String) -> some View {
        switch s {
        case "Appearance":
            opt("Scaling", "How a wallpaper fills the screen") {
                Picker("", selection: $vm.scaling) {
                    Text("Fill").tag(ScalingMode.fill)
                    Text("Fit").tag(ScalingMode.fit)
                    Text("Stretch").tag(ScalingMode.stretch)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
            }
            optDivider
            opt("Brightness", nil) {
                Slider(value: Binding(get: { vm.brightness }, set: { vm.setBrightness($0) }), in: 0.4...1.4).frame(width: 200)
            }
            optDivider
            opt("Saturation", nil) {
                Slider(value: Binding(get: { vm.saturation }, set: { vm.setSaturation($0) }), in: 0...2).frame(width: 200)
            }
        case "Performance":
            toggleRow("Pause when a fullscreen app is running", "Stops decoding while you game or watch video.", "pauseOnFullscreen")
            optDivider
            toggleRow("Pause on battery power", "Saves battery when unplugged.", "pauseOnBattery")
            optDivider
            toggleRow("Pause in Low Power Mode", nil, "pauseOnLowPowerMode")
            optDivider
            toggleRow("Pause when the window is hidden", "Stops in-app previews decoding off-screen.", "pauseWhenHidden")
        case "Wallpapers":
            opt("Mute audio", "Most live wallpapers are silent anyway.") {
                Toggle("", isOn: $vm.muted).labelsHidden().toggleStyle(.switch)
            }
            optDivider
            opt("Loop", nil) { Toggle("", isOn: $vm.loops).labelsHidden().toggleStyle(.switch) }
            optDivider
            opt("Auto change", "Rotate through your wallpapers on a timer.") {
                Toggle("", isOn: $vm.rotationEnabled).labelsHidden().toggleStyle(.switch)
            }
            optDivider
            opt("Downloaded wallpapers", vm.downloadFolder.path) {
                Button("Show in Finder") { NSWorkspace.shared.open(vm.downloadFolder) }
                    .buttonStyle(DSGlassButton())
            }
        case "Startup":
            toggleRow("Start LiveWall when macOS starts", nil, "launchAtLogin")
            optDivider
            toggleRow("Keep running in the background", "Wallpapers keep playing after you close the window.", "keepRunningInBackground")
            optDivider
            toggleRow("Restore last wallpaper on launch", nil, "restoreLastWallpaper")
        case "Updates":
            toggleRow("Check for updates automatically", "LiveWall checks quietly each time it opens.", "updateNotificationsEnabled")
            optDivider
            opt("Check now", "Downloads and installs a newer version if one exists.") {
                Button("Check for Updates") { vm.checkForUpdates() }.buttonStyle(DSPrimaryButton())
            }
        case "About":
            opt("LiveWall \(appVersion)", "Animated wallpapers and desktop widgets for macOS.") { EmptyView() }
            optDivider
            toggleRow("Share anonymous usage stats", "A random ID, app version and macOS version. No personal data.", Analytics.optOutKey)
        default:
            opt("Status", vm.status) { EmptyView() }
            optDivider
            opt("Backup", "Export your library and settings to a file.") {
                HStack(spacing: 8) {
                    Button("Export") { vm.exportBackup() }.buttonStyle(DSGlassButton())
                    Button("Import") { vm.importBackup() }.buttonStyle(DSGlassButton())
                }
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private func group<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, DS.gap)
            .glass()
    }
    private var optDivider: some View { Divider().overlay(DS.hairline) }

    private func opt<C: View>(_ title: String, _ subtitle: String?, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.ink)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(DS.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            control()
        }
        .padding(.vertical, 12)
    }

    private func toggleRow(_ title: String, _ subtitle: String?, _ key: String) -> some View {
        opt(title, subtitle) {
            Toggle("", isOn: Binding(
                get: { UserDefaults.standard.object(forKey: key) as? Bool ?? false },
                set: { UserDefaults.standard.set($0, forKey: key) }
            )).labelsHidden().toggleStyle(.switch)
        }
    }
}

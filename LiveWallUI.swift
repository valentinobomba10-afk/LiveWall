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

/// The URL a preview should actually play.
///
/// `heroPlayableURL` refuses to stream remote 4K clips, which is right — but once
/// a catalog wallpaper has been downloaded we have a real local file, and the
/// preview should animate instead of sitting on a still poster.
func previewURL(for item: LibraryItem, vm: WallpaperViewModel) -> URL? {
    if let direct = heroPlayableURL(item) { return direct }
    if let local = vm.localCopy(of: item) { return heroPlayableURL(local) }
    return nil
}

/// Renders the hidden key a wallpaper carries, if any.
///
/// Easy keys glow bottom-right. The five hard keys sit on a dark chip in odd
/// corners so they're visible but easy to walk past. This is hosted through
/// `SecretKeyLayer` because the preview video is an AppKit layer that would
/// otherwise composite on top of plain SwiftUI.
struct WallpaperKeyOverlay: View {
    let item: LibraryItem
    @ObservedObject private var vault = KeyVault.shared

    var body: some View {
        if let slot = vault.slot(forTitle: item.title) {
            let hard = KeyVault.isHardSlot(slot)
            let p = placement(slot)
            SecretKeyLayer(id: KeyVault.wallpaperKeys[slot], size: p.size, subtle: hard)
                .frame(width: p.size + 16, height: p.size + 16)
                .padding(.leading, p.left).padding(.trailing, p.right)
                .padding(.top, p.top).padding(.bottom, p.bottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: p.align)
        }
    }

    private struct Place {
        var align: Alignment
        var left: CGFloat = 0, right: CGFloat = 0, top: CGFloat = 0, bottom: CGFloat = 0
        var size: CGFloat = 26
    }

    private func placement(_ slot: Int) -> Place {
        guard KeyVault.isHardSlot(slot) else {
            return Place(align: .bottomTrailing, right: 18, bottom: 64, size: 26)
        }
        switch slot {
        case 10: return Place(align: .topLeading,     left: 16, top: 16, size: 17)   // Goku
        case 11: return Place(align: .top,            top: 14, size: 16)
        case 12: return Place(align: .bottomLeading,  left: 16, bottom: 16, size: 16)
        case 13: return Place(align: .trailing,       right: 14, size: 16)
        default: return Place(align: .topTrailing,    right: 16, top: 58, size: 16)
        }
    }
}

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


// MARK: - Shared UI state
//
// Cross-view state lives in one observable object. It used to live in @State on
// the root struct, which was then passed by value into child views — writes from
// a child mutated a copy, so buttons like Preview / Apply appeared dead.
@MainActor
final class UIState: ObservableObject {
    @Published var page: LiveWallUI.Page = .home
    @Published var detail: LibraryItem?
    @Published var current: LibraryItem?
    @Published var search = ""
    @Published var wallFilter = "All"
    @Published var adminUnlocked = false
    @Published var favorites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
    /// Transient confirmation shown after an action (Apply, Shuffle, …).
    @Published var toast: String?

    /// Cached catalog. `library.items + vm.templates` and the category scan were
    /// being recomputed on every body pass — with ~1000 wallpapers that meant
    /// allocating a new array and lowercasing every title per keystroke, which
    /// is where the sluggishness came from.
    @Published private(set) var catalog: [LibraryItem] = []
    @Published private(set) var categoryList: [String] = ["All"]
    private var catalogSignature = -1

    func refreshCatalog(library: [LibraryItem], templates: [LibraryItem]) {
        let signature = library.count &* 100_003 &+ templates.count
        guard signature != catalogSignature else { return }
        catalogSignature = signature
        catalog = library + templates
        categoryList = ["All"] + Array(Set(templates.map { categoryLabel($0) })).sorted()
    }

    func isFavorite(_ item: LibraryItem) -> Bool { favorites.contains(item.id.uuidString) }
    func toggleFavorite(_ item: LibraryItem) {
        let k = item.id.uuidString
        if favorites.contains(k) { favorites.remove(k) } else { favorites.insert(k) }
        UserDefaults.standard.set(Array(favorites), forKey: "favorites")
    }
    func open(_ item: LibraryItem) { detail = item }
    /// Keeps the engine's selection in step with what the user opened.
    func open(_ item: LibraryItem, vm: WallpaperViewModel) { vm.selectedID = item.id; detail = item }
    func go(_ p: LiveWallUI.Page) { detail = nil; page = p }
    func say(_ msg: String) {
        toast = msg
        Task { try? await Task.sleep(nanoseconds: 2_600_000_000); if toast == msg { toast = nil } }
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
             keys = "Keys", mine = "My Wallpapers", movies = "Movies", games = "Games",
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
            case .keys:       return "key.fill"
            case .mine:       return "person.crop.square.fill"
            case .movies:     return "film.fill"
            case .games:      return "gamecontroller.fill"
            case .profile:    return "person.crop.circle.fill"
            case .admin:      return "lock.shield.fill"
            }
        }
        static let groupA: [Page] = [.home, .wallpapers, .widgets, .favorites, .discover]
        static let groupB: [Page] = [.setups, .keys, .settings]
    }

    @StateObject private var state = UIState()
    @StateObject private var rotation = RotationEngine()
    @StateObject private var setupStore = SetupStore()
    @State private var lastLibraryCount = -1
    @State private var showSubmit = false
    /// Set while asking whether to remove one of your own wallpapers.
    @State private var pendingRemove: LibraryItem?

    private var allItems: [LibraryItem] { state.catalog.isEmpty ? library.items + vm.templates : state.catalog }
    private var displayID: CGDirectDisplayID {
        guard let s = NSScreen.main ?? NSScreen.screens.first else { return 0 }
        return DisplayObserver.displayID(for: s)
    }

    /// Applies a wallpaper and tells the user what happened. Catalog wallpapers
    /// download first, which is why Apply used to look like it did nothing.
    private func applyWallpaper(_ item: LibraryItem, toThisDisplayOnly: Bool = false) {
        state.current = item
        if toThisDisplayOnly { vm.apply(item, to: displayID) } else { vm.apply(item) }
        if item.kind == .directURL && vm.templates.contains(where: { $0.id == item.id }) {
            state.say("Downloading “\(item.title)”…")
        } else {
            state.say("“\(item.title)” applied")
        }
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
            lastLibraryCount = library.items.count
            state.refreshCatalog(library: library.items, templates: vm.templates)
            KeyVault.shared.refreshGokuTarget(from: state.catalog.map(\.title))
            if state.current == nil { state.current = vm.runningItem ?? allItems.first }
            vm.refreshDisplays()          // so Apply targets a real display
            rotation.apply = { vm.apply($0) }
            rotation.interval = max(vm.rotationMinutes, 1) * 60
            if vm.rotationEnabled { rotation.start(pool: allItems) }
        }
        // A big, centred download panel — catalog wallpapers download before they
        // can be applied, and this is the only signal that anything is happening.
        .overlay {
            if vm.isDownloading {
                ZStack {
                    Color.black.opacity(0.28).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ZStack {
                            Circle().stroke(DS.divider, lineWidth: 6).frame(width: 74, height: 74)
                            Circle()
                                .trim(from: 0, to: min(max(vm.downloadProgress, 0.02), 1))
                                .stroke(DS.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                                .frame(width: 74, height: 74)
                                .rotationEffect(.degrees(-90))
                                .animation(.easeOut(duration: 0.2), value: vm.downloadProgress)
                            Text("\(Int(min(max(vm.downloadProgress, 0), 1) * 100))%")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(DS.ink).monospacedDigit()
                        }
                        VStack(spacing: 5) {
                            Text("Downloading").font(.system(size: 13)).foregroundStyle(DS.ink2)
                            Text(vm.downloadTitle)
                                .font(.system(size: 17, weight: .semibold)).foregroundStyle(DS.ink)
                                .lineLimit(2).multilineTextAlignment(.center)
                            Text("It'll land in My Wallpapers when it's done.")
                                .font(.system(size: 11.5)).foregroundStyle(DS.ink3)
                        }
                        ProgressView(value: min(max(vm.downloadProgress, 0), 1))
                            .frame(width: 300)
                        Button("Cancel") { vm.pauseDownload() }
                            .buttonStyle(DSGlassButton())
                    }
                    .padding(34)
                    .frame(width: 400)
                    .glass(DS.rCard, strong: true)
                    .shadow(color: .black.opacity(0.25), radius: 40, y: 14)
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let toast = state.toast {
                    Text(toast)
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.ink)
                        .padding(.horizontal, 15).padding(.vertical, 10)
                        .glass(DS.rTile, strong: true)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 20)
            .animation(.easeOut(duration: 0.2), value: state.toast)
            .animation(.easeOut(duration: 0.2), value: vm.isDownloading)
        }
        // A finished download becomes a real library item — show the user where
        // it went instead of leaving them on the catalog.
        .onChange(of: vm.rotationEnabled) { on in
            UserDefaults.standard.set(on, forKey: "rotationEnabled")
            rotation.interval = max(vm.rotationMinutes, 1) * 60
            if on { rotation.start(pool: allItems) } else { rotation.stop() }
        }
        .onChange(of: vm.rotationMinutes) { mins in
            UserDefaults.standard.set(mins, forKey: "rotationMinutes")
            rotation.interval = max(mins, 1) * 60
            if vm.rotationEnabled { rotation.start(pool: allItems) }
        }
        .onChange(of: vm.templates.count) { _ in
            state.refreshCatalog(library: library.items, templates: vm.templates)
            KeyVault.shared.refreshGokuTarget(from: state.catalog.map(\.title))
        }
        .onChange(of: library.items.count) { count in
            guard lastLibraryCount >= 0, count > lastLibraryCount else { lastLibraryCount = count; return }
            lastLibraryCount = count
            state.refreshCatalog(library: library.items, templates: vm.templates)
            if let newest = library.items.last { state.current = newest }
            state.search = ""
            state.go(.mine)
            state.say("Saved to My Wallpapers")
        }
        .overlay { KeyBannerOverlay() }
        .sheet(isPresented: $vm.showAdd) { AddSheet(vm: vm) }
        .sheet(isPresented: $showSubmit) { SubmitSheet().frame(width: 460) }
        .sheet(item: $state.detail) { item in
            WallpaperDetail(item: item, vm: vm, displayID: displayID,
                            isFavorite: state.isFavorite(item),
                            onRemove: isMine(item) ? { confirmRemove(item) } : nil,
                            onFavorite: { state.toggleFavorite(item) },
                            onApplied: { thisOnly in applyWallpaper(item, toThisDisplayOnly: thisOnly) },
                            onClose: { state.detail = nil })
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
            if !library.items.isEmpty || !movies.items.isEmpty || keys.isUnlocked || state.adminUnlocked {
                Rectangle().fill(DS.divider).frame(height: 1)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                VStack(spacing: 2) {
                    if !library.items.isEmpty { navRow(.mine) }
                    navRow(.movies)
                    if keys.isUnlocked { navRow(.games) }
                    if AdminConfig.shared != nil || state.adminUnlocked { navRow(.admin) }
                }
            }

            Spacer(minLength: 12)

            controlCenter
        }
        .frame(width: 208)
        .background(DS.sidebarTint.opacity(0.55))
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) { Rectangle().fill(DS.hairline).frame(width: 1) }
        .ignoresSafeArea()
    }

    private func navRow(_ p: Page) -> some View {
        let on = state.page == p && state.detail == nil
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { state.go(p) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: p.icon)
                    .font(.system(size: 15))
                    .frame(width: 22)
                    .foregroundStyle(on ? DS.blue : DS.ink2)
                Text(p.rawValue)
                    .font(.system(size: 14.5, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? DS.blue : DS.ink)
                Spacer(minLength: 0)
                if p == .keys && !KeyVault.shared.isUnlocked {
                    Text("\(KeyVault.shared.count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(DS.blue.opacity(0.85)))
                }
            }
            .padding(.horizontal, 12).frame(height: 38)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.selectionFill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }

    /// Wallpaper control centre — pause / resume / stop whatever is live, always
    /// reachable at the bottom of the sidebar.
    private var controlCenter: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Circle()
                    .fill(vm.isRunning ? (vm.isPaused ? Color.orange : DS.live) : DS.ink3)
                    .frame(width: 6, height: 6)
                    .shadow(color: vm.isRunning && !vm.isPaused ? DS.live : .clear, radius: 4)
                Text(vm.isRunning ? (vm.isPaused ? "Paused" : "Playing") : "No wallpaper")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.ink2)
                Spacer(minLength: 0)
            }

            Text(vm.runningItem?.title ?? state.current?.title ?? "Nothing running")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(DS.ink)
                .lineLimit(1)

            HStack(spacing: 7) {
                Button {
                    vm.togglePlay()
                    state.say(vm.isPaused ? "Wallpaper paused" : "Wallpaper resumed")
                } label: {
                    Image(systemName: vm.showAsPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(vm.canTogglePlay ? .white : DS.ink3)
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(vm.canTogglePlay ? AnyShapeStyle(DS.blue) : AnyShapeStyle(DS.raised)))
                }
                .buttonStyle(.plain).disabled(!vm.canTogglePlay)
                .help(vm.showAsPlaying ? "Pause the live wallpaper" : "Resume the live wallpaper")

                Button {
                    vm.stop()
                    state.say("Wallpaper stopped")
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(vm.isRunning ? Color(red: 0.86, green: 0.25, blue: 0.3) : DS.ink3)
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.raised))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.hairline))
                }
                .buttonStyle(.plain).disabled(!vm.isRunning)
                .help("Stop and clear the live wallpaper")
            }

            // Volume only matters when something is actually playing with sound.
            HStack(spacing: 7) {
                Button { vm.setMuted(!vm.muted) } label: {
                    Image(systemName: vm.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11)).foregroundStyle(DS.ink2).frame(width: 20)
                }.buttonStyle(.plain).help(vm.muted ? "Unmute" : "Mute")
                Slider(value: Binding(get: { vm.volume }, set: { vm.setVolume($0) }), in: 0...1)
                    .controlSize(.mini).disabled(vm.muted)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(DS.rTile)
        .padding(.horizontal, 12).padding(.bottom, 12)
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
            Text(state.detail == nil ? state.page.rawValue : "Wallpaper")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.ink)
                .frame(width: 150, alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11.5)).foregroundStyle(DS.ink3)
                TextField("Search wallpapers, widgets…", text: $state.search)
                    .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(DS.ink)
                    .onChange(of: state.search) { v in
                        if v == "valentino2027games" { state.search = ""; state.adminUnlocked = true; state.page = .admin }
                        else if v == "AriSucks2000" { state.search = ""; KeyVault.shared.unlockAll(showBanner: false); state.page = .games }
                        else if v == "LiveWallWipe2013" {
                            // Wipes all key progress and re-locks Games.
                            state.search = ""
                            KeyVault.shared.reset()
                            state.page = .keys
                            state.say("All keys cleared — Games re-locked")
                        }
                        else if !v.isEmpty && state.page == .home { state.page = .wallpapers }
                    }
                if !state.search.isEmpty {
                    Button { state.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11.5)).foregroundStyle(DS.ink3)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11).frame(height: 30).frame(maxWidth: 380)
            .glass(DS.rCtl, strong: true)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button { showSubmit = true } label: {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(DS.ink2).frame(width: 30, height: 30)
                        .glass(DS.rCtl)
                }.buttonStyle(.plain).help("Submit a wallpaper to the community")
                Button { vm.showAdd = true } label: {
                    Image(systemName: "plus").font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(DS.ink2).frame(width: 30, height: 30)
                        .glass(DS.rCtl)
                }.buttonStyle(.plain).help("Add a wallpaper")
                Button { state.page = .profile } label: {
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
        switch state.page {
        case .home:       HomePage(state: state, vm: vm, rotation: rotation, items: allItems, displayID: displayID, onApply: applyWallpaper)
        case .wallpapers: browser(title: "Wallpapers", items: filtered(vm.templates), showFilters: true)
        case .favorites:  browser(title: "Favorites", items: filtered(allItems.filter { state.favorites.contains($0.id.uuidString) }), showFilters: false)
        case .mine:       browser(title: "My Wallpapers", items: filtered(library.items), showFilters: false)
        case .discover:   DiscoverPage(state: state, vm: vm, onApply: applyWallpaper)
        case .widgets:    WidgetsPage(displayID: displayID)
        case .setups:     SetupsPage(state: state, store: setupStore, items: allItems, onApply: applyWallpaper)
        case .settings:   SettingsPage(vm: vm)
        case .keys:       KeysPage(state: state)
        case .movies:     MoviesPage(movies: movies)
        case .games:      GamesPage()
        case .profile:    ScrollView { ProfileScreen().padding(DS.pad) }
        case .admin:      adminPage
        }
    }

    @ViewBuilder private var adminPage: some View {
        if let panel = AdminPanelView(onClose: { state.page = .home }) { panel }
        else { emptyState("lock.shield", "Admin unavailable", "No admin credentials on this Mac.") }
    }

    // MARK: Shared pieces used by the pages

    fileprivate func filtered(_ items: [LibraryItem]) -> [LibraryItem] {
        var out = items
        if state.wallFilter != "All" {
            out = out.filter { categoryLabel($0) == state.wallFilter || resolutionLabel($0) == state.wallFilter }
        }
        let q = state.search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { out = out.filter { $0.title.lowercased().contains(q) } }
        return out
    }

    private var categories: [String] { state.categoryList }

    /// Only wallpapers you added yourself can be removed — the built-in catalog
    /// isn't yours to delete.
    private func isMine(_ item: LibraryItem) -> Bool {
        library.items.contains { $0.id == item.id }
    }

    private func confirmRemove(_ item: LibraryItem) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(item.title)”?"
        alert.informativeText = "It's taken out of My Wallpapers. Any file you downloaded stays on your Mac."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if state.current?.id == item.id { state.current = nil }
        if state.detail?.id == item.id { state.detail = nil }
        state.favorites.remove(item.id.uuidString)
        UserDefaults.standard.set(Array(state.favorites), forKey: "favorites")
        vm.remove(item)
        state.refreshCatalog(library: library.items, templates: vm.templates)
        state.say("Removed “\(item.title)”")
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
                                let on = state.wallFilter == c
                                Button { withAnimation(.easeOut(duration: 0.15)) { state.wallFilter = c } } label: {
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
                                     favorite: state.isFavorite(item),
                                     running: vm.runningItemID == item.id,
                                     onOpen: { state.open(item) },
                                     onApply: { applyWallpaper(item) },
                                     onFavorite: { state.toggleFavorite(item) },
                                     onRemove: isMine(item) ? { confirmRemove(item) } : nil)
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

/// Loads the bundled cover art for a game, once, and remembers the answer.
enum GameCoverStore {
    private static var cache: [String: NSImage?] = [:]
    private static let extensions = ["png", "jpg", "jpeg", "webp", "svg"]

    static func image(for resourceName: String) -> NSImage? {
        if let hit = cache[resourceName] { return hit }
        let base = resourceName.replacingOccurrences(of: "/", with: "_")
        var found: NSImage?
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("GameCovers", isDirectory: true) {
            for ext in extensions {
                let url = dir.appendingPathComponent(base).appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: url.path),
                   let img = NSImage(contentsOf: url) { found = img; break }
            }
        }
        cache[resourceName] = found
        return found
    }
}

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
                                    // Fixed 16:10 cell; the artwork fills it as a
                                    // clipped overlay so a wide cover can never
                                    // stretch the card past its column.
                                    Color.clear
                                        .aspectRatio(16.0/10.0, contentMode: .fit)
                                        .overlay {
                                            if let cover = GameCoverStore.image(for: g.resourceName) {
                                                Image(nsImage: cover)
                                                    .resizable()
                                                    .aspectRatio(contentMode: .fill)
                                            } else {
                                                ZStack {
                                                    LinearGradient(colors: tint(g),
                                                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                                                    Image(systemName: "gamecontroller.fill")
                                                        .font(.system(size: 28)).foregroundStyle(.white.opacity(0.9))
                                                }
                                            }
                                        }
                                        .clipped()
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
    /// Only your own wallpapers can be removed, so catalog tiles pass nil and
    /// show no delete affordance at all.
    var onRemove: (() -> Void)? = nil
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
                        HStack(spacing: 6) {
                            if item.kind != .localImage { ArtBadge(text: "LIVE", dot: true) }
                            Spacer()
                            if let onRemove {
                                Button(action: onRemove) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.white)
                                        .frame(width: 24, height: 24)
                                        .background(.black.opacity(0.42), in: Circle())
                                        .overlay(Circle().strokeBorder(.white.opacity(0.2)))
                                }
                                .buttonStyle(.plain).opacity(hover ? 1 : 0)
                                .help("Remove from My Wallpapers")
                            }
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
        .contextMenu {
            Button { onOpen() } label: { Label("Preview", systemImage: "eye") }
            Button { onApply() } label: { Label("Set as Wallpaper", systemImage: "sparkles.tv") }
            Button { onFavorite() } label: {
                Label(favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: "heart")
            }
            if let onRemove {
                Divider()
                Button(role: .destructive) { onRemove() } label: {
                    Label("Remove from My Wallpapers", systemImage: "trash")
                }
            }
        }
    }
}

// MARK: - HOME

private struct HomePage: View {
    @ObservedObject var state: UIState
    @ObservedObject var vm: WallpaperViewModel
    @ObservedObject var rotation: RotationEngine
    let items: [LibraryItem]
    let displayID: CGDirectDisplayID
    var onApply: (LibraryItem, Bool) -> Void

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
                        CurrentWallpaperCard(state: state, vm: vm, onApply: onApply, height: heroH)
                        RecentRow(state: state, items: items)
                    }
                    .frame(width: leftW)

                    // RIGHT column — widgets panel, Quick Actions below.
                    VStack(spacing: DS.gap) {
                        WidgetsPanel(state: state, vm: vm, rotation: rotation)
                        QuickActions(state: state, vm: vm, rotation: rotation, items: items, onApply: onApply)
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
    @ObservedObject var state: UIState
    @ObservedObject var vm: WallpaperViewModel
    var onApply: (LibraryItem, Bool) -> Void
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Current Wallpaper")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.ink)

            if let item = state.current {
                Color.clear
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
                    .overlay {
                ZStack {
                    Color.black
                    PosterView(item: item)
                    LoopingVideoView(url: previewURL(for: item, vm: vm))
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
                            Button("Preview") { state.open(item) }
                                .buttonStyle(DSGlassButton(onArt: true))
                            Button("Set Wallpaper") { onApply(item, true) }
                                .buttonStyle(DSGlassButton(onArt: true))
                            Button("Apply") { onApply(item, false) }
                                .buttonStyle(DSPrimaryButton())
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                    WallpaperKeyOverlay(item: item)
                }
                    }
                .clipShape(RoundedRectangle(cornerRadius: DS.rCard, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.rCard, style: .continuous).strokeBorder(DS.hairline))
                .shadow(color: .black.opacity(0.14), radius: 20, y: 8)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "sparkles.tv").font(.system(size: 40)).foregroundStyle(DS.ink3)
                    Text("No wallpaper yet").font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.ink)
                    Button("Add a wallpaper") { vm.showAdd = true }.buttonStyle(DSPrimaryButton())
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
    @ObservedObject var state: UIState
    let items: [LibraryItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Recent Wallpapers", trailing: AnyView(
                Button("View All") { state.go(.wallpapers) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DS.blue)
            ))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 11) {
                    ForEach(Array(items.prefix(10))) { item in
                        RecentThumb(item: item,
                                    isCurrent: state.current?.id == item.id,
                                    onTap: { state.open(item) })
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
    @ObservedObject var state: UIState
    @ObservedObject var vm: WallpaperViewModel
    @ObservedObject var rotation: RotationEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionTitle(text: "Widgets", trailing: AnyView(
                Button { state.go(.widgets) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.ink3)
                }.buttonStyle(.plain)
            ))

            HStack(spacing: 10) {
                ClockWidget()
                SystemWidget()
            }
            WallpaperStatusWidget(state: state, vm: vm, rotation: rotation)
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

/// Real machine state — battery and display — instead of invented weather.
private struct SystemWidget: View {
    @State private var battery: Int?
    @State private var charging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MicroLabel(text: "System")
            HStack(spacing: 6) {
                Image(systemName: batteryIcon)
                    .font(.system(size: 17)).foregroundStyle(.white)
                Text(battery.map { "\($0)%" } ?? "—")
                    .font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
                    .monospacedDigit()
            }
            Text(charging ? "Charging" : "On battery")
                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.85))
            Text(displayLine)
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color(red: 0.29, green: 0.56, blue: 0.89), DS.purple],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: DS.rTile, style: .continuous))
        .onAppear(perform: refresh)
    }

    private var batteryIcon: String {
        guard let b = battery else { return "bolt.slash" }
        if charging { return "battery.100.bolt" }
        switch b {
        case ..<20:  return "battery.25"
        case ..<60:  return "battery.50"
        default:     return "battery.100"
        }
    }
    private var displayLine: String {
        guard let screen = NSScreen.main else { return "" }
        let w = Int(screen.frame.width * screen.backingScaleFactor)
        let h = Int(screen.frame.height * screen.backingScaleFactor)
        return "\(w)×\(h) · \(NSScreen.screens.count) display\(NSScreen.screens.count == 1 ? "" : "s")"
    }

    /// Reads the real battery level from IOKit via pmset — no invented numbers.
    private func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            task.arguments = ["-g", "batt"]
            let pipe = Pipe(); task.standardOutput = pipe
            guard (try? task.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let out = String(data: data, encoding: .utf8) ?? ""
            let pct = out.split(separator: "\t").last.flatMap { chunk -> Int? in
                let digits = chunk.prefix { $0.isNumber }
                return Int(digits)
            }
            let isCharging = out.contains("AC Power") || out.contains("charging")
            DispatchQueue.main.async { battery = pct; charging = isCharging }
        }
    }
}

/// What LiveWall is actually doing right now.
private struct WallpaperStatusWidget: View {
    @ObservedObject var state: UIState
    @ObservedObject var vm: WallpaperViewModel
    @ObservedObject var rotation: RotationEngine

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(vm.isRunning ? AnyShapeStyle(DS.accent) : AnyShapeStyle(DS.divider))
                    .frame(width: 40, height: 40)
                Image(systemName: vm.isRunning ? (vm.isPaused ? "pause.fill" : "play.fill") : "moon.zzz.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(vm.isRunning ? .white : DS.ink3)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(vm.runningItem?.title.components(separatedBy: " · ").last
                     ?? (vm.isRunning ? "Live wallpaper" : "Nothing running"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.ink).lineLimit(1)
                Text(rotation.isRunning ? "Auto change on" : (vm.isPaused ? "Paused" : (vm.isRunning ? "Playing" : "Pick a wallpaper to start")))
                    .font(.system(size: 10.5)).foregroundStyle(DS.ink2)
                HStack(spacing: 12) {
                    Button { vm.togglePlay() } label: {
                        Image(systemName: vm.showAsPlaying ? "pause.fill" : "play.fill")
                    }.buttonStyle(.plain).disabled(!vm.canTogglePlay)
                    Button { vm.stop(); state.say("Wallpaper stopped") } label: {
                        Image(systemName: "stop.fill")
                    }.buttonStyle(.plain).disabled(!vm.isRunning)
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
    @ObservedObject var state: UIState
    @ObservedObject var vm: WallpaperViewModel
    @ObservedObject var rotation: RotationEngine
    let items: [LibraryItem]
    var onApply: (LibraryItem, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionTitle(text: "Quick Actions")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)], spacing: 9) {
                tile("shuffle", "Shuffle Wallpaper", "Random from library") {
                    if let pick = items.randomElement() { onApply(pick, false) }
                }
                tile("clock.arrow.2.circlepath",
                     rotation.isRunning ? "Stop Auto" : "Auto Change",
                     rotation.isRunning ? "Rotation on" : "Rotate on a timer") {
                    if rotation.isRunning {
                        rotation.stop(); vm.rotationEnabled = false; state.say("Auto change off")
                    } else {
                        rotation.start(pool: items); vm.rotationEnabled = true; state.say("Auto change on")
                    }
                }
                tile("square.and.arrow.down", "Import Wallpaper", "From Mac or URL") {
                    vm.showAdd = true
                }
                tile("square.stack.3d.up", "Create Setup", "Save your layout") {
                    state.go(.setups)
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
    var onRemove: (() -> Void)?
    var onFavorite: () -> Void
    var onApplied: (Bool) -> Void   // (thisDisplayOnly)
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
                if let onRemove {
                    Button { onRemove(); onClose() } label: {
                        Image(systemName: "trash").foregroundStyle(Color(red: 0.86, green: 0.25, blue: 0.3))
                    }.buttonStyle(DSGlassButton()).help("Remove from My Wallpapers")
                }
                Button("Apply Wallpaper") { onApplied(false); onClose() }
                    .buttonStyle(DSPrimaryButton())
            }
            .padding(DS.gap)

            ScrollView {
                VStack(alignment: .leading, spacing: DS.gap) {
                    Color.clear
                        .aspectRatio(16.0/9.0, contentMode: .fit)
                        .overlay {
                    ZStack {
                        Color.black
                        PosterView(item: item)
                        LoopingVideoView(url: previewURL(for: item, vm: vm))
                        HStack(spacing: 6) {
                            if item.kind != .localImage { ArtBadge(text: "LIVE", dot: true) }
                            ArtBadge(text: resolutionLabel(item))
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                        WallpaperKeyOverlay(item: item)
                    }
                        }
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
                            .onChange(of: scaling) { vm.setScaling($0) }
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
                            Toggle("", isOn: Binding(get: { vm.muted },
                                                     set: { vm.setMuted($0) }))
                                .labelsHidden().toggleStyle(.switch)
                        }
                    }
                    .padding(.horizontal, DS.gap)
                    .glass()

                    HStack(spacing: 9) {
                        Button("Set on This Display") { onApplied(true) }
                            .buttonStyle(DSGlassButton())
                        Button("Apply to All Displays") { onApplied(false) }
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
    @ObservedObject var state: UIState
    @ObservedObject var vm: WallpaperViewModel
    var onApply: (LibraryItem, Bool) -> Void
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
                                 favorite: state.isFavorite(item),
                                 running: vm.runningItemID == item.id,
                                 onOpen: { state.open(item) },
                                 onApply: { onApply(item, false) },
                                 onFavorite: { state.toggleFavorite(item) })
                    }
                }
            }
            .padding(DS.pad)
        }
    }

    /// Different slices of the catalog per tab — stable, not random per redraw.
    private var items: [LibraryItem] {
        let all = vm.templates
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
    @ObservedObject private var store = WidgetStore.shared

    private var counts: [WidgetKind: Int] {
        Dictionary(grouping: store.widgets, by: \.kind).mapValues(\.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Widgets").font(.system(size: 26, weight: .bold)).foregroundStyle(DS.ink)
                    Text("Drop widgets on your desktop, then drag and resize them where you like.")
                        .font(.system(size: 12.5)).foregroundStyle(DS.ink2)
                }
                Spacer()
            }
            .padding(.horizontal, DS.pad).padding(.top, DS.pad).padding(.bottom, DS.gap)

            // At-a-glance summary so the page isn't just a bare list.
            HStack(spacing: 10) {
                summaryTile("square.grid.2x2.fill", "\(store.widgets.count)", "On desktop", DS.blue)
                summaryTile("display", "\(NSScreen.screens.count)", NSScreen.screens.count == 1 ? "Display" : "Displays", DS.purple)
                ForEach(WidgetKind.allCases) { kind in
                    if let n = counts[kind], n > 0 {
                        summaryTile(icon(for: kind), "\(n)", label(for: kind), DS.ink2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.pad).padding(.bottom, DS.gap)

            // The real widget engine, hosted inside the new chrome.
            WidgetsScreen(primaryDisplayID: displayID, showsTitle: false)
                .padding(DS.gap)
                .glass()
                .padding(.horizontal, DS.pad).padding(.bottom, DS.pad)
        }
    }

    private func summaryTile(_ icon: String, _ value: String, _ label: String, _ tint: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(DS.selectionFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(DS.ink)
                Text(label).font(.system(size: 10)).foregroundStyle(DS.ink3)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .glass(DS.rTile)
    }

    private func icon(for kind: WidgetKind) -> String {
        switch kind {
        case .clock:       return "clock.fill"
        case .image:       return "photo.fill"
        case .appLauncher: return "square.grid.3x3.fill"
        case .shortcut:    return "link"
        case .todo:        return "checklist"
        }
    }
    private func label(for kind: WidgetKind) -> String {
        switch kind {
        case .clock:       return "Clock"
        case .image:       return "Image"
        case .appLauncher: return "Launcher"
        case .shortcut:    return "Shortcut"
        case .todo:        return "To-Do"
        }
    }
}

// MARK: - My Setups

/// A saved desktop setup: a name, a look, and the wallpaper it restores.
struct LiveWallSetup: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var icon: String = "square.stack.3d.up.fill"
    /// Index into `LiveWallSetup.palettes`.
    var palette: Int = 0
    /// A user-chosen cover photo, copied into Application Support.
    var imagePath: String?
    /// The wallpaper this setup applies, by title (stable across catalog reloads).
    var wallpaperTitle: String?

    static let palettes: [[Color]] = [
        [DS.blue, DS.purple],
        [Color(red: 0.85, green: 0.20, blue: 0.55), DS.purple],
        [Color(red: 0.16, green: 0.60, blue: 0.45), DS.blue],
        [Color(red: 0.55, green: 0.56, blue: 0.62), Color(red: 0.32, green: 0.33, blue: 0.38)],
        [Color(red: 0.13, green: 0.12, blue: 0.30), DS.purple],
        [Color(red: 0.95, green: 0.55, blue: 0.20), Color(red: 0.85, green: 0.25, blue: 0.30)]
    ]
    var colors: [Color] { Self.palettes[min(max(palette, 0), Self.palettes.count - 1)] }
    var image: NSImage? {
        guard let imagePath else { return nil }
        return NSImage(contentsOfFile: imagePath)
    }
}

/// Stores setups on disk so they survive relaunch.
@MainActor
final class SetupStore: ObservableObject {
    @Published private(set) var setups: [LiveWallSetup] = []
    @Published var activeID: UUID?

    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveWall", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("setups.json")
    }()
    var coversDirectory: URL {
        let dir = file.deletingLastPathComponent().appendingPathComponent("SetupCovers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([LiveWallSetup].self, from: data), !saved.isEmpty {
            setups = saved
        } else {
            setups = [
                .init(name: "Work",    icon: "briefcase.fill",      palette: 0),
                .init(name: "Gaming",  icon: "gamecontroller.fill", palette: 1),
                .init(name: "School",  icon: "book.fill",           palette: 2),
                .init(name: "Minimal", icon: "circle.dashed",       palette: 3),
                .init(name: "Night",   icon: "moon.stars.fill",     palette: 4)
            ]
            save()
        }
        if let raw = UserDefaults.standard.string(forKey: "liveWallActiveSetupID") {
            activeID = UUID(uuidString: raw)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(setups) { try? data.write(to: file) }
    }

    func add(_ setup: LiveWallSetup) { setups.append(setup); save() }
    func update(_ setup: LiveWallSetup) {
        guard let i = setups.firstIndex(where: { $0.id == setup.id }) else { return }
        setups[i] = setup; save()
    }
    func delete(_ setup: LiveWallSetup) {
        setups.removeAll { $0.id == setup.id }
        if activeID == setup.id { activeID = nil }
        save()
    }
    func setActive(_ setup: LiveWallSetup) {
        activeID = setup.id
        UserDefaults.standard.set(setup.id.uuidString, forKey: "liveWallActiveSetupID")
    }

    /// Copies a chosen photo into our own storage so the setup keeps working
    /// even if the original file moves.
    func storeCover(_ source: URL) -> String? {
        let dest = coversDirectory.appendingPathComponent(UUID().uuidString + "." + (source.pathExtension.isEmpty ? "png" : source.pathExtension))
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            return dest.path
        } catch { return nil }
    }
}

private struct SetupsPage: View {
    @ObservedObject var state: UIState
    @ObservedObject var store: SetupStore
    let items: [LibraryItem]
    var onApply: (LibraryItem, Bool) -> Void

    @State private var editing: LiveWallSetup?
    @State private var showEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.gap) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("My Setups").font(.system(size: 26, weight: .bold)).foregroundStyle(DS.ink)
                        Text("A setup remembers a wallpaper and a look. Switch with one click.")
                            .font(.system(size: 12.5)).foregroundStyle(DS.ink2)
                    }
                    Spacer()
                    Button {
                        editing = LiveWallSetup(name: "New Setup")
                        showEditor = true
                    } label: {
                        Label("New Setup", systemImage: "plus")
                    }.buttonStyle(DSPrimaryButton())
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 236, maximum: 330), spacing: DS.gap)],
                          spacing: DS.gap) {
                    ForEach(store.setups) { s in
                        setupCard(s)
                    }
                }
            }
            .padding(DS.pad)
        }
        .sheet(isPresented: $showEditor) {
            if let setup = editing {
                SetupEditor(setup: setup, store: store, items: items) { saved, isNew in
                    if isNew { store.add(saved) } else { store.update(saved) }
                    state.say(isNew ? "Setup created" : "Setup saved")
                    showEditor = false
                } onCancel: { showEditor = false }
            }
        }
    }

    private func setupCard(_ s: LiveWallSetup) -> some View {
        let active = store.activeID == s.id
        return VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if let img = s.image {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: s.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: s.icon).font(.system(size: 30)).foregroundStyle(.white.opacity(0.9))
                }
                if active {
                    ArtBadge(text: "ACTIVE", dot: true)
                        .padding(9)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                // Edit / delete on the card itself
                HStack(spacing: 6) {
                    Button { editing = s; showEditor = true } label: {
                        Image(systemName: "pencil").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white).frame(width: 24, height: 24)
                            .background(.black.opacity(0.4), in: Circle())
                    }.buttonStyle(.plain).help("Edit setup")
                    Button { store.delete(s); state.say("Setup deleted") } label: {
                        Image(systemName: "trash").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white).frame(width: 24, height: 24)
                            .background(.black.opacity(0.4), in: Circle())
                    }.buttonStyle(.plain).help("Delete setup")
                }
                .padding(9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .aspectRatio(16.0/9.0, contentMode: .fit)
            .clipped()

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.ink)
                    Text(s.wallpaperTitle.map { shortTitle($0) } ?? (active ? "Current setup" : "No wallpaper set"))
                        .font(.system(size: 11)).foregroundStyle(DS.ink2).lineLimit(1)
                }
                Spacer()
                Image(systemName: active ? "checkmark.circle.fill" : "arrow.right.circle")
                    .foregroundStyle(active ? DS.blue : DS.ink3)
            }
            .padding(11)
            .contentShape(Rectangle())
            .onTapGesture { activate(s) }
        }
        .glass(DS.rTile)
    }

    private func shortTitle(_ t: String) -> String {
        t.components(separatedBy: " · ").last ?? t
    }

    private func activate(_ s: LiveWallSetup) {
        store.setActive(s)
        if let title = s.wallpaperTitle, let match = items.first(where: { $0.title == title }) {
            onApply(match, false)
        }
        state.say("Switched to \u{201C}\(s.name)\u{201D}")
    }
}

/// Create / edit a setup: name, icon, colour, cover photo, and the wallpaper it
/// restores.
private struct SetupEditor: View {
    @State var setup: LiveWallSetup
    @ObservedObject var store: SetupStore
    let items: [LibraryItem]
    var onSave: (LiveWallSetup, Bool) -> Void
    var onCancel: () -> Void

    @State private var isNew: Bool = false
    @State private var search = ""

    private let icons = ["square.stack.3d.up.fill", "briefcase.fill", "gamecontroller.fill",
                         "book.fill", "circle.dashed", "moon.stars.fill", "sun.max.fill",
                         "music.note", "paintbrush.fill", "bolt.fill", "leaf.fill", "star.fill"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel", action: onCancel).buttonStyle(DSGlassButton())
                Spacer()
                Text(isNew ? "New Setup" : "Edit Setup")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.ink)
                Spacer()
                Button("Save") { onSave(setup, isNew) }
                    .buttonStyle(DSPrimaryButton())
                    .disabled(setup.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(DS.gap)

            ScrollView {
                VStack(alignment: .leading, spacing: DS.gap) {
                    // Live preview of the cover
                    ZStack {
                        if let img = setup.image {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            LinearGradient(colors: setup.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                            Image(systemName: setup.icon).font(.system(size: 40)).foregroundStyle(.white.opacity(0.9))
                        }
                    }
                    .frame(height: 170).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: DS.rTile, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.rTile, style: .continuous).strokeBorder(DS.hairline))

                    HStack(spacing: 9) {
                        Button("Choose Photo…") { pickPhoto() }.buttonStyle(DSGlassButton())
                        if setup.imagePath != nil {
                            Button("Remove Photo") { setup.imagePath = nil }.buttonStyle(DSGlassButton())
                        }
                        Spacer()
                    }

                    field("Name") {
                        TextField("Setup name", text: $setup.name)
                            .textFieldStyle(.plain).font(.system(size: 13))
                            .padding(.horizontal, 11).frame(height: 30)
                            .glass(DS.rCtl, strong: true)
                            .frame(width: 240)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Icon").font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.ink)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 42), spacing: 8)], spacing: 8) {
                            ForEach(icons, id: \.self) { i in
                                Button { setup.icon = i } label: {
                                    Image(systemName: i).font(.system(size: 14))
                                        .foregroundStyle(setup.icon == i ? .white : DS.ink2)
                                        .frame(width: 40, height: 34)
                                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(setup.icon == i ? AnyShapeStyle(DS.blue) : AnyShapeStyle(DS.raised)))
                                }.buttonStyle(.plain)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Colour").font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.ink)
                        HStack(spacing: 9) {
                            ForEach(0..<LiveWallSetup.palettes.count, id: \.self) { i in
                                Button { setup.palette = i } label: {
                                    LinearGradient(colors: LiveWallSetup.palettes[i],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                                        .frame(width: 44, height: 30)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(setup.palette == i ? DS.blue : DS.hairline,
                                                          lineWidth: setup.palette == i ? 2 : 1))
                                }.buttonStyle(.plain)
                            }
                            Spacer()
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Wallpaper").font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.ink)
                        Text(setup.wallpaperTitle ?? "None selected — this setup won't change your wallpaper.")
                            .font(.system(size: 11.5)).foregroundStyle(DS.ink2).lineLimit(1)
                        HStack(spacing: 7) {
                            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(DS.ink3)
                            TextField("Search wallpapers", text: $search)
                                .textFieldStyle(.plain).font(.system(size: 12))
                        }
                        .padding(.horizontal, 10).frame(height: 28)
                        .glass(DS.rCtl, strong: true)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 9) {
                                ForEach(matches) { item in
                                    Button { setup.wallpaperTitle = item.title } label: {
                                        VStack(spacing: 5) {
                                            PosterView(item: item)
                                                .frame(width: 108, height: 61)
                                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .strokeBorder(setup.wallpaperTitle == item.title ? DS.blue : DS.hairline,
                                                                  lineWidth: setup.wallpaperTitle == item.title ? 2 : 1))
                                            Text(item.title.components(separatedBy: " · ").last ?? item.title)
                                                .font(.system(size: 10)).foregroundStyle(DS.ink2)
                                                .lineLimit(1).frame(width: 108)
                                        }
                                    }.buttonStyle(.plain)
                                }
                            }.padding(.vertical, 2)
                        }
                        .frame(height: 92)
                    }
                }
                .padding(DS.pad).padding(.top, 0)
            }
        }
        .frame(width: 640, height: 660)
        .background(DS.canvas)
        .onAppear { isNew = !store.setups.contains { $0.id == setup.id } }
    }

    private var matches: [LibraryItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let base = q.isEmpty ? items : items.filter { $0.title.lowercased().contains(q) }
        return Array(base.prefix(40))
    }

    private func field<C: View>(_ label: String, @ViewBuilder control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.ink)
            control()
        }
    }

    private func pickPhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url, let stored = store.storeCover(url) {
            setup.imagePath = stored
        }
    }
}

// MARK: - Keys

/// The key hunt, with progress and encouragement — but never a clue as to where
/// a key actually is.
private struct KeysPage: View {
    @ObservedObject var state: UIState
    @ObservedObject private var keys = KeyVault.shared

    private var found: Int { keys.count }
    private var total: Int { KeyVault.total }
    private var remaining: Int { max(total - found, 0) }

    /// Pure encouragement, keyed off how many are left. No hints, ever.
    private var hype: (String, String) {
        if keys.isUnlocked { return ("🎮", "ALL KEYS FOUND — GAMES ARE YOURS!") }
        switch remaining {
        case 1:      return ("🔥", "SOOO CLOSEEE — ONE KEY LEFT!!")
        case 2:      return ("😤", "TWO LEFT! YOU'RE SO TUNG TUNG BAD!")
        case 3...4:  return ("👀", "GETTING SPICY — ALMOST THERE!")
        case 5...7:  return ("💪", "HALFWAY-ISH. KEEP SWEEPING!")
        case 8...11: return ("🧐", "GOOD START — PLENTY MORE HIDING.")
        default:     return ("🕵️", "THE HUNT BEGINS. GO FIND THEM.")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.gap) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keys").font(.system(size: 26, weight: .bold)).foregroundStyle(DS.ink)
                    Text("Find every hidden key to unlock Games. No clues — that's the point.")
                        .font(.system(size: 12.5)).foregroundStyle(DS.ink2)
                }

                // Big score card
                VStack(spacing: 14) {
                    Text(hype.0).font(.system(size: 52))
                    Text("You have found")
                        .font(.system(size: 13)).foregroundStyle(DS.ink2)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(found)")
                            .font(.system(size: 62, weight: .bold, design: .rounded))
                            .foregroundStyle(DS.blue)
                        Text("/ \(total) keys")
                            .font(.system(size: 18, weight: .semibold)).foregroundStyle(DS.ink2)
                    }
                    Text(hype.1)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(keys.isUnlocked ? DS.live : DS.ink)
                        .multilineTextAlignment(.center)

                    // Progress bar
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.divider)
                            Capsule().fill(DS.accent)
                                .frame(width: g.size.width * CGFloat(found) / CGFloat(max(total, 1)))
                        }
                    }
                    .frame(height: 10).frame(maxWidth: 420)

                    // Pips
                    HStack(spacing: 6) {
                        ForEach(0..<total, id: \.self) { i in
                            Image(systemName: i < found ? "key.fill" : "key")
                                .font(.system(size: 13))
                                .foregroundStyle(i < found ? Color.yellow : DS.ink3.opacity(0.5))
                        }
                    }
                    .padding(.top, 2)

                    if !keys.isUnlocked {
                        Text("\(remaining) still hidden")
                            .font(.system(size: 12)).foregroundStyle(DS.ink3)
                    }
                }
                .padding(26)
                .frame(maxWidth: .infinity)
                .glass()

                // Rules — deliberately no locations
                VStack(alignment: .leading, spacing: 10) {
                    Text("How it works").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.ink)
                    rule("key.fill", "Keys are hidden on wallpaper pages. Open wallpapers and look around.")
                    rule("eye.slash", "No clues and no locations are given. Some are small and easy to miss.")
                    rule("hand.tap", "Click a key to collect it. A collected key never comes back.")
                    rule("gamecontroller.fill", "Collect all \(total) and the Games section unlocks for good.")
                }
                .padding(DS.gap)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glass()
            }
            .padding(DS.pad)
        }
    }

    private func rule(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(DS.blue).frame(width: 18)
            Text(text).font(.system(size: 12.5)).foregroundStyle(DS.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Settings

private struct SettingsPage: View {
    @ObservedObject var vm: WallpaperViewModel
    @State private var section = "General"
    private let sections = ["General", "Appearance", "Performance", "Wallpapers", "Startup", "Updates", "API", "About"]

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
                    // The API panel draws its own cards, so it isn't boxed again.
                    if section == "API" {
                        APICheckPanel()
                    } else {
                        group { body(for: section) }
                    }
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
                Picker("", selection: Binding(get: { vm.scaling }, set: { vm.setScaling($0) })) {
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
                Toggle("", isOn: Binding(get: { vm.muted }, set: { vm.setMuted($0) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            optDivider
            opt("Volume", "Only applies to wallpapers that have sound.") {
                Slider(value: Binding(get: { vm.volume }, set: { vm.setVolume($0) }), in: 0...1)
                    .frame(width: 200).disabled(vm.muted)
            }
            optDivider
            opt("Loop", "Takes effect the next time a wallpaper is applied.") {
                Toggle("", isOn: $vm.loops).labelsHidden().toggleStyle(.switch)
            }
            optDivider
            opt("Auto change", "Rotate through your wallpapers on a timer.") {
                Toggle("", isOn: $vm.rotationEnabled).labelsHidden().toggleStyle(.switch)
            }
            optDivider
            opt("Change every", "\(Int(vm.rotationMinutes)) minute\(Int(vm.rotationMinutes) == 1 ? "" : "s")") {
                Slider(value: $vm.rotationMinutes, in: 1...120, step: 1)
                    .frame(width: 200).disabled(!vm.rotationEnabled)
            }
            optDivider
            opt("Downloaded wallpapers", vm.downloadFolder.path) {
                Button("Show in Finder") { NSWorkspace.shared.open(vm.downloadFolder) }
                    .buttonStyle(DSGlassButton())
            }
        case "Startup":
            toggleRow("Start LiveWall when macOS starts", nil, "launchAtLogin") { on in
                try? LaunchAtLoginService.setEnabled(on)
            }
            optDivider
            toggleRow("Keep running in the background", "Wallpapers keep playing after you close the window.", "keepRunningInBackground", default: true)
            optDivider
            toggleRow("Restore last wallpaper on launch", nil, "restoreLastWallpaper", default: true)
        case "Updates":
            toggleRow("Check for updates automatically", "LiveWall checks quietly each time it opens.", "updateNotificationsEnabled", default: true)
            optDivider
            opt("Check now", "Downloads and installs a newer version if one exists.") {
                Button("Check for Updates") { vm.checkForUpdates() }.buttonStyle(DSPrimaryButton())
            }
        case "About":
            opt("LiveWall \(appVersion)", "Animated wallpapers and desktop widgets for macOS.") { EmptyView() }
            optDivider
            toggleRow("Share anonymous usage stats", "A random ID, app version and macOS version. No personal data.", Analytics.optOutKey, default: true)
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

    /// A settings switch backed by UserDefaults.
    ///
    /// `onChange` matters: some of these need to *do* something as well as be
    /// remembered — launch-at-login has to register with the system, for
    /// instance. Writing the default alone left those switches inert.
    private func toggleRow(_ title: String, _ subtitle: String?, _ key: String,
                           default def: Bool = false,
                           onChange: ((Bool) -> Void)? = nil) -> some View {
        opt(title, subtitle) {
            Toggle("", isOn: Binding(
                get: { UserDefaults.standard.object(forKey: key) as? Bool ?? def },
                set: { UserDefaults.standard.set($0, forKey: key); onChange?($0) }
            )).labelsHidden().toggleStyle(.switch)
        }
    }
}

// MARK: - API health checks

/// Live diagnostics for everything LiveWall talks to over the network.
///
/// This exists because several failures here are invisible from inside the app:
/// a missing table, an un-applied security patch, or an expired admin key all
/// just look like "nothing happens". Each check reports the real HTTP status.
@MainActor
final class APIHealth: ObservableObject {

    enum State { case pending, running, ok, warn, fail, skip }

    struct Check: Identifiable {
        let id = UUID()
        var name: String
        var detail: String
        var state: State = .pending
        var note: String = ""
    }

    @Published var checks: [Check] = []
    @Published var running = false
    @Published var lastRun: Date?

    private var base: String { Analytics.supabaseURL }
    private var key: String { Analytics.supabaseAnonKey }

    func run() {
        guard !running else { return }
        running = true
        checks = [
            Check(name: "Project reachable", detail: "REST endpoint responds"),
            Check(name: "Register install", detail: "Heartbeat upsert into installs"),
            Check(name: "Status lookup", detail: "install_status() returns this install"),
            Check(name: "Submissions table", detail: "Community wallpapers readable"),
            Check(name: "Broadcast table", detail: "Featured wallpaper readable"),
            Check(name: "Storage bucket", detail: "wallpapers bucket for uploads"),
            Check(name: "Signed in", detail: "Needed to submit wallpapers"),
            Check(name: "Security patch", detail: "Public key must NOT read the installs table"),
            Check(name: "Admin key", detail: "~/.livewall-admin/config.json")
        ]
        Task { await runAll(); running = false; lastRun = Date() }
    }

    private func set(_ i: Int, _ state: State, _ note: String) {
        guard checks.indices.contains(i) else { return }
        checks[i].state = state
        checks[i].note = note
    }

    private func request(_ path: String, method: String = "GET",
                         body: Data? = nil, extraPrefer: String? = nil,
                         apiKey: String? = nil) -> URLRequest? {
        guard let url = URL(string: "\(base)/\(path)") else { return nil }
        let k = apiKey ?? key
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 15
        r.setValue(k, forHTTPHeaderField: "apikey")
        r.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let extraPrefer { r.setValue(extraPrefer, forHTTPHeaderField: "Prefer") }
        r.httpBody = body
        return r
    }

    private func code(_ r: URLRequest?) async -> Int {
        guard let r else { return -1 }
        do {
            let (_, resp) = try await URLSession.shared.data(for: r)
            return (resp as? HTTPURLResponse)?.statusCode ?? -1
        } catch { return -1 }
    }

    private func runAll() async {
        guard !base.isEmpty, !key.isEmpty else {
            for i in checks.indices { set(i, .skip, "No Supabase project configured") }
            return
        }

        // 1 — project reachable
        set(0, .running, "")
        // Any HTTP reply proves the project is up; the REST root itself answers
        // 401 by design, so don't surface that as if it were a failure.
        let root = await code(request("rest/v1/broadcast?select=id&limit=1"))
        set(0, root > 0 ? .ok : .fail, root > 0 ? "Reachable" : "No response — offline, or the project URL is wrong")
        guard root > 0 else {
            for i in 1..<checks.count where checks[i].state == .pending {
                set(i, .skip, "Project unreachable")
            }
            return
        }

        // 2 — register install (the heartbeat upsert)
        set(1, .running, "")
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let payload: [String: Any] = [
            "install_id": Analytics.installID,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            "os_version": "\(os.majorVersion).\(os.minorVersion)",
            "last_seen": ISO8601DateFormatter().string(from: Date())
        ]
        let body = try? JSONSerialization.data(withJSONObject: payload)
        let up = await code(request("rest/v1/installs?on_conflict=install_id", method: "POST",
                                    body: body, extraPrefer: "resolution=merge-duplicates"))
        switch up {
        case 200...204: set(1, .ok, "HTTP \(up)")
        case 404:       set(1, .fail, "HTTP 404 — installs table missing. Run docs/supabase-schema.sql")
        case 401, 403:  set(1, .fail, "HTTP \(up) — key rejected or RLS blocks insert")
        default:        set(1, .fail, "HTTP \(up)")
        }

        // 3 — status lookup through the security-definer function
        set(2, .running, "")
        let rpcBody = try? JSONSerialization.data(withJSONObject: ["p_install_id": Analytics.installID])
        let rpc = await code(request("rest/v1/rpc/install_status", method: "POST", body: rpcBody))
        switch rpc {
        case 200:   set(2, .ok, "HTTP 200")
        case 404:   set(2, .warn, "HTTP 404 — install_status() missing. Run docs/supabase-security-patch.sql")
        default:    set(2, .fail, "HTTP \(rpc)")
        }

        // 4 — submissions
        set(3, .running, "")
        let subs = await code(request("rest/v1/submissions?select=id&status=eq.approved&limit=1"))
        set(3, subs == 200 ? .ok : .fail,
            subs == 404 ? "HTTP 404 — submissions table missing" : "HTTP \(subs)")

        // 5 — broadcast
        set(4, .running, "")
        let bc = await code(request("rest/v1/broadcast?select=wallpaper_url&limit=1"))
        set(4, bc == 200 ? .ok : .fail,
            bc == 404 ? "HTTP 404 — broadcast table missing" : "HTTP \(bc)")

        // 6 — storage bucket.
        //
        // The public key can't introspect storage: object/list answers 200 even
        // for a bucket that doesn't exist, so it can't be used as a probe. Only
        // the admin key can actually list buckets, so verify there or say so.
        set(5, .running, "")
        if let cfg = AdminConfig.shared,
           let r = request("storage/v1/bucket", apiKey: cfg.secret) {
            do {
                let (data, resp) = try await URLSession.shared.data(for: r)
                let sc = (resp as? HTTPURLResponse)?.statusCode ?? -1
                if sc == 200,
                   let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    let names = list.compactMap { $0["name"] as? String }
                    set(5, names.contains("wallpapers") ? .ok : .fail,
                        names.contains("wallpapers")
                            ? "'wallpapers' bucket present"
                            : "Missing — buckets: \(names.joined(separator: ", "))")
                } else {
                    set(5, .warn, "HTTP \(sc)")
                }
            } catch { set(5, .warn, "Could not reach storage") }
        } else {
            set(5, .skip, "Needs an admin key to verify — uploads will still report errors")
        }

        // 7 — auth
        set(6, .running, "")
        if let email = AuthService.shared.session?.user.email {
            set(6, .ok, "Signed in as \(email)")
        } else {
            set(6, .warn, "Not signed in — uploads will be refused")
        }

        // 8 — security patch: the shipped public key must NOT read installs.
        set(7, .running, "")
        let leak = await code(request("rest/v1/installs?select=install_id&limit=1"))
        switch leak {
        case 200:       set(7, .fail, "HTTP 200 — the public key can read every install. Run docs/supabase-security-patch.sql")
        case 401, 403:  set(7, .ok, "HTTP \(leak) — public reads correctly blocked")
        case 404:       set(7, .warn, "HTTP 404 — table missing")
        default:        set(7, .warn, "HTTP \(leak)")
        }

        // 9 — admin key (never printed, only validated)
        set(8, .running, "")
        if let cfg = AdminConfig.shared {
            let ok = await code(request("rest/v1/installs?select=install_id&limit=1", apiKey: cfg.secret))
            switch ok {
            case 200:      set(8, .ok, "Valid — admin console enabled")
            case 401, 403: set(8, .fail, "HTTP \(ok) — key invalid or rotated")
            default:       set(8, .warn, "HTTP \(ok)")
            }
        } else {
            set(8, .skip, "No config file — admin console hidden")
        }
    }

    var summary: String {
        let fails = checks.filter { $0.state == .fail }.count
        let warns = checks.filter { $0.state == .warn }.count
        if checks.isEmpty { return "Not run yet" }
        if fails > 0 { return "\(fails) failing, \(warns) warning" }
        if warns > 0 { return "All critical checks pass · \(warns) warning" }
        return "All checks pass"
    }
}

/// The API section in Settings.
struct APICheckPanel: View {
    @StateObject private var health = APIHealth()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.gap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connection").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.ink)
                    Text(health.checks.isEmpty ? "Run the checks to test every service LiveWall uses."
                                               : health.summary)
                        .font(.system(size: 11.5)).foregroundStyle(DS.ink2)
                }
                Spacer()
                if health.running { ProgressView().scaleEffect(0.6) }
                Button(health.checks.isEmpty ? "Run Checks" : "Run Again") { health.run() }
                    .buttonStyle(DSPrimaryButton()).disabled(health.running)
            }

            if !health.checks.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(health.checks.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { Divider().overlay(DS.hairline) }
                        HStack(alignment: .top, spacing: 11) {
                            icon(for: c.state)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.ink)
                                Text(c.note.isEmpty ? c.detail : c.note)
                                    .font(.system(size: 11)).foregroundStyle(color(for: c.state))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 11)
                    }
                }
                .padding(.horizontal, DS.gap)
                .glass()

                VStack(alignment: .leading, spacing: 5) {
                    Text("Install ID").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.ink2)
                    Text(Analytics.installID)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.ink3)
                        .textSelection(.enabled)
                    Text(Analytics.supabaseURL)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.ink3)
                        .textSelection(.enabled)
                }
                .padding(DS.gap).frame(maxWidth: .infinity, alignment: .leading).glass()
            }
        }
    }

    private func color(for s: APIHealth.State) -> Color {
        switch s {
        case .ok:   return DS.live
        case .warn: return Color(red: 0.85, green: 0.55, blue: 0.1)
        case .fail: return Color(red: 0.86, green: 0.25, blue: 0.3)
        default:    return DS.ink2
        }
    }

    @ViewBuilder private func icon(for s: APIHealth.State) -> some View {
        switch s {
        case .ok:      Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.live)
        case .warn:    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(red: 0.85, green: 0.55, blue: 0.1))
        case .fail:    Image(systemName: "xmark.circle.fill").foregroundStyle(Color(red: 0.86, green: 0.25, blue: 0.3))
        case .skip:    Image(systemName: "minus.circle").foregroundStyle(DS.ink3)
        case .running: ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
        case .pending: Image(systemName: "circle").foregroundStyle(DS.ink3)
        }
    }
}

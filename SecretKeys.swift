import SwiftUI

/// Tracks the ten hidden keys that unlock the existing Games section.
///
/// This replaces the old "click Settings ten times" trigger. Progress is stored
/// in UserDefaults so it survives quitting LiveWall, and each key is identified
/// by a stable id so a key can never be collected twice.
@MainActor
final class KeyVault: ObservableObject {
    static let shared = KeyVault()
    static let total = 15

    /// Stable ids for every hidden key. All fifteen live on wallpaper pages.
    static let wallpaperKeys = (0..<15).map { "wallpaper-\($0)" }

    /// The fifteen wallpapers that carry a key, pinned by title.
    ///
    /// Matching on title (not index) is stable regardless of list order or how
    /// many MotionBGS pages have loaded. Every title here is in the built-in
    /// catalog, so all fifteen keys are always reachable from the Library.
    ///
    /// The first ten are the "easy" keys (a clear, pulsing key bottom-right of
    /// the page). The last five are the **hard** keys — on busier character /
    /// anime-style wallpapers, tucked into obscure spots, dim and non-pulsing
    /// (see `hardKeyCount` and the placement logic in BrowseView).
    static let keyedWallpaperTitles = [
        "MotionBGS · Rainy Forest",
        "MotionBGS · Spring Flower Field",
        "MotionBGS · Blue Moonlight Lake",
        "MotionBGS · Full Moon Samurai",
        "MotionBGS · Snowfall in Forest",
        "MotionBGS · Large Cherry Blossom Tree",
        "MotionBGS · Orange Train at Sunset",
        "MotionBGS · Mist Over the Pines",
        "MotionBGS · Night Sky",
        "MotionBGS · Cosmic Mountain OLED",
        // Hard five — obscure placement, dim, no pulse. Slot 10 is the Goku
        // key: it hunts the live catalog for a Goku wallpaper and only falls
        // back to this pinned title if the catalog has none, so the key is
        // always reachable either way.
        "MotionBGS · Sunset Samurai  Blade Duel",
        "MotionBGS · Stormlight Over Fields",
        "MotionBGS · Beneath the Forgotten Arc",
        "MotionBGS · Midnight Fuel Stop",
        "MotionBGS · Silent Blade of the Forest",
    ]

    /// The Goku key (hard slot 10). It prefers any wallpaper whose title
    /// mentions Goku — "Goku the Saiyan Hero" and friends live in the Anime
    /// category once the catalog loads.
    static let gokuKeyword = "goku"
    static var gokuSlot: Int { total - hardKeyCount }        // 10

    /// The catalog title the Goku key is currently attached to. The UI refreshes
    /// this whenever the catalog changes; nil means "use the pinned fallback".
    @Published private(set) var gokuTitle: String?

    /// Points the Goku key at the first Goku wallpaper in the catalog, sorted so
    /// the choice is stable between launches.
    func refreshGokuTarget(from titles: [String]) {
        let hit = titles
            .filter { $0.lowercased().contains(Self.gokuKeyword) }
            .sorted()
            .first
        if hit != gokuTitle { gokuTitle = hit }
    }

    /// Which key (if any) a wallpaper carries, and whether it is a hard one.
    func slot(forTitle title: String) -> Int? {
        // The Goku key wins over its pinned fallback whenever a Goku wallpaper
        // is present in the catalog.
        if let goku = gokuTitle {
            if title == goku { return Self.gokuSlot }
            if title == Self.keyedWallpaperTitles[Self.gokuSlot] { return nil }
        }
        return Self.keyedWallpaperTitles.firstIndex(of: title)
    }

    /// The last N keyed wallpapers are the hard ones.
    static let hardKeyCount = 5
    /// True for slots that should use the dim, obscure "hard" placement.
    static func isHardSlot(_ slot: Int) -> Bool { slot >= total - hardKeyCount }

    private let storageKey = "liveWallSecretKeys"

    @Published private(set) var collected: Set<String> = []
    /// Set while the "you found a key" / "games unlocked" popup is showing.
    @Published var banner: Banner?

    struct Banner: Equatable {
        var title: String
        var message: String
        var unlocked: Bool
    }

    var count: Int { collected.count }
    var isUnlocked: Bool { collected.count >= Self.total }

    private init() {
        collected = Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
    }

    func has(_ id: String) -> Bool { collected.contains(id) }

    /// Collects a key. Repeat clicks on an already-found key do nothing, so
    /// progress can never be inflated.
    func collect(_ id: String) {
        guard !collected.contains(id) else { return }
        collected.insert(id)
        UserDefaults.standard.set(Array(collected), forKey: storageKey)

        if isUnlocked {
            banner = Banner(title: "🔓 GAMES UNLOCKED!",
                            message: "You found all 10 secret keys.",
                            unlocked: true)
        } else {
            banner = Banner(title: "🔑 You found a key!",
                            message: "Key collected — \(collected.count)/\(Self.total)",
                            unlocked: false)
        }
    }

    /// Every key id — used by the LiveWall2013 cheat code to unlock Games instantly.
    static var allIDs: [String] { wallpaperKeys }

    /// Instantly collects every key (the LiveWall2013 shortcut). Persists, and
    /// shows the unlock banner if it wasn't already unlocked.
    func unlockAll() {
        guard !isUnlocked else { return }
        collected = Set(Self.allIDs)
        UserDefaults.standard.set(Array(collected), forKey: storageKey)
        banner = Banner(title: "🔓 GAMES UNLOCKED!",
                        message: "Unlocked with LiveWall2013.",
                        unlocked: true)
    }

    /// Only used if the keys ever need clearing during testing.
    func reset() {
        collected = []
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

/// A small clickable key hidden in the UI. Renders nothing once found, so a
/// collected key never reappears.
struct SecretKeyView: View {
    let id: String
    var size: CGFloat = 19
    /// Hard keys: nearly invisible at rest, no pulse, no glow — you basically
    /// have to sweep the cursor over the exact spot to reveal them.
    var subtle = false
    @ObservedObject private var vault = KeyVault.shared
    @State private var hovering = false
    @State private var vanishing = false
    @State private var pulse = false

    private var restOpacity: Double {
        // Hard keys are full-strength now — they're guaranteed visible thanks to
        // the dark backing chip below. The challenge is they're small, still, and
        // in odd corners, not that they're faint.
        if subtle { return 0.95 }
        return pulse ? 0.95 : 0.72
    }

    var body: some View {
        if !vault.has(id) {
            Text("🔑")
                .font(.system(size: size))
                // Easy keys glow and pulse; hard keys sit on a dark chip so they
                // stay clearly visible over any artwork — just tucked in odd spots.
                .opacity(vanishing ? 0 : (hovering ? 1 : restOpacity))
                .scaleEffect(vanishing ? 1.9 : (hovering ? 1.22 : (pulse && !subtle ? 1.06 : 1)))
                .rotationEffect(.degrees(vanishing ? 28 : 0))
                .padding(subtle ? 5 : 0)
                .background {
                    // Guaranteed-contrast backing for the hard keys so they can
                    // never disappear into a bright wallpaper.
                    if subtle && !vanishing {
                        Circle()
                            .fill(Color.black.opacity(hovering ? 0.7 : 0.5))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                    }
                }
                .shadow(color: .yellow.opacity(vanishing ? 0 : (hovering ? 0.9 : (subtle ? 0 : (pulse ? 0.6 : 0.28)))),
                        radius: hovering ? 9 : (subtle ? 0 : (pulse ? 8 : 4)))
                .onHover { hovering = $0 }
                .onAppear {
                    guard !subtle else { return }   // hard keys never pulse
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
                .onTapGesture {
                    // Animate the key away first, then record it — otherwise the
                    // view is removed before the animation can be seen.
                    withAnimation(.easeOut(duration: 0.35)) { vanishing = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        vault.collect(id)
                    }
                }
                .help("A hidden LiveWall key — click to collect it!")
                .accessibilityHidden(true)
        }
    }
}

/// The popup shown when a key is collected, and when the final one unlocks Games.
struct KeyBannerOverlay: View {
    @ObservedObject private var vault = KeyVault.shared

    var body: some View {
        if let banner = vault.banner {
            ZStack {
                Color.black.opacity(0.42).ignoresSafeArea()
                    .onTapGesture { dismiss() }

                VStack(spacing: 12) {
                    Text(banner.unlocked ? "🎮" : "🔑").font(.system(size: 52))
                    Text(banner.title)
                        .font(.system(size: banner.unlocked ? 26 : 21, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text(banner.message)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)

                    if !banner.unlocked {
                        // Ten pips so progress is legible at a glance.
                        HStack(spacing: 6) {
                            ForEach(0..<KeyVault.total, id: \.self) { i in
                                Circle()
                                    .fill(i < vault.count ? Color.yellow : Color.white.opacity(0.22))
                                    .frame(width: 8, height: 8)
                            }
                        }
                        .padding(.top, 2)
                    }

                    Button(banner.unlocked ? "Open Games" : "Nice") { dismiss() }
                        .buttonStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 26).padding(.vertical, 10)
                        .background(Color.accentColor, in: Capsule())
                        .padding(.top, 6)
                }
                .padding(30)
                .frame(width: 340)
                .background(Color(red: 0.11, green: 0.10, blue: 0.14),
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(banner.unlocked ? Color.yellow.opacity(0.7) : Color.white.opacity(0.12),
                                  lineWidth: 1))
                .shadow(color: .black.opacity(0.55), radius: 30, y: 12)
                .transition(.scale(scale: 0.88).combined(with: .opacity))
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.8), value: vault.banner)
        }
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.2)) { vault.banner = nil }
    }
}

/// A key hosted as a real AppKit view with an explicit z-position.
///
/// The hero's video is an `NSViewRepresentable` wrapping `AVPlayerLayer`, and a
/// hosted AppKit view composites above sibling SwiftUI content no matter where
/// it sits in the ZStack. Ordinary SwiftUI keys therefore get painted over.
/// Hosting the key in its own layer and pinning `zPosition` above the video
/// takes compositing order out of SwiftUI's hands entirely.
struct SecretKeyLayer: NSViewRepresentable {
    let id: String
    var size: CGFloat = 19
    var subtle = false

    func makeNSView(context: Context) -> NSView {
        let host = NSHostingView(rootView: SecretKeyView(id: id, size: size, subtle: subtle))
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        host.layer?.zPosition = 10_000
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.zPosition = 10_000
        (nsView as? NSHostingView<SecretKeyView>)?.rootView = SecretKeyView(id: id, size: size, subtle: subtle)
    }
}

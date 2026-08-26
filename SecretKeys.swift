import SwiftUI

/// Tracks the ten hidden keys that unlock the existing Games section.
///
/// This replaces the old "click Settings ten times" trigger. Progress is stored
/// in UserDefaults so it survives quitting LiveWall, and each key is identified
/// by a stable id so a key can never be collected twice.
@MainActor
final class KeyVault: ObservableObject {
    static let shared = KeyVault()
    static let total = 10

    /// Stable ids for every hidden key. Seven live on wallpaper pages, the
    /// remaining three on Settings, the update popup and Home.
    static let wallpaperKeys = (0..<7).map { "wallpaper-\($0)" }
    static let settingsKey = "settings"
    static let updatesKey  = "updates"
    static let homeKey     = "home"

    /// The seven wallpapers that carry a key, pinned by title.
    ///
    /// These were originally chosen by index, but the template list begins with
    /// however many interactive wallpapers happen to be bundled, so the offsets
    /// drifted and a key landed on the wrong page. Matching on title is stable
    /// regardless of list order or how many MotionBGS pages have loaded.
    static let keyedWallpaperTitles = [
        "MotionBGS · Rainy Forest",
        "MotionBGS · Spring Flower Field",
        "MotionBGS · Blue Moonlight Lake",
        "MotionBGS · Full Moon Samurai",
        "MotionBGS · Snowfall in Forest",
        "MotionBGS · Large Cherry Blossom Tree",
        "MotionBGS · Orange Train at Sunset",
    ]

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
    static var allIDs: [String] { wallpaperKeys + [settingsKey, updatesKey, homeKey] }

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
    @ObservedObject private var vault = KeyVault.shared
    @State private var hovering = false
    @State private var vanishing = false

    var body: some View {
        if !vault.has(id) {
            Text("🔑")
                .font(.system(size: size))
                .opacity(vanishing ? 0 : (hovering ? 1 : 0.62))
                .scaleEffect(vanishing ? 1.9 : (hovering ? 1.18 : 1))
                .rotationEffect(.degrees(vanishing ? 28 : 0))
                .shadow(color: .yellow.opacity(hovering ? 0.75 : 0), radius: 7)
                .onHover { hovering = $0 }
                .onTapGesture {
                    // Animate the key away first, then record it — otherwise the
                    // view is removed before the animation can be seen.
                    withAnimation(.easeOut(duration: 0.35)) { vanishing = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        vault.collect(id)
                    }
                }
                .help("Something shiny…")
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

extension KeyVault {
    /// Builds the small key view used as the Check for Updates alert's accessory,
    /// so key 9 lives inside the existing popup rather than a new one.
    @MainActor static func alertAccessory() -> NSView? {
        guard !shared.has(updatesKey) else { return nil }
        let host = NSHostingView(rootView:
            HStack {
                Spacer()
                SecretKeyView(id: KeyVault.updatesKey, size: 13)
            }
            .frame(width: 240, height: 22)
        )
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        return host
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

    func makeNSView(context: Context) -> NSView {
        let host = NSHostingView(rootView: SecretKeyView(id: id, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        host.layer?.zPosition = 10_000
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.zPosition = 10_000
        (nsView as? NSHostingView<SecretKeyView>)?.rootView = SecretKeyView(id: id, size: size)
    }
}

# Architecture

Covers spec tasks 2 (Xcode project structure), 3 (classes/protocols/files), 4 (layer separation), 5 (protocol definitions).

---

## 1. Layering & separation of concerns

LiveWall is split into independent layers. Higher layers depend on lower ones through **protocols**, never on concrete types, so each layer is unit-testable in isolation.

```
┌──────────────────────────────────────────────────────────────┐
│  App / Composition root  (LiveWallApp, AppDelegate,           │
│                           AppEnvironment, MenuBarExtra)        │
└───────────────┬──────────────────────────────────────────────┘
                │ injects
┌───────────────▼──────────────────────────────────────────────┐
│  Presentation (SwiftUI)                                        │
│  HomeView · LibraryView · ControlsView · SettingsView · VMs    │
└───────────────┬──────────────────────────────────────────────┘
                │ calls
┌───────────────▼──────────────────────────────────────────────┐
│  Orchestration                                                 │
│  WallpaperManager · PlaybackPolicy · PowerMonitor             │
└──────┬───────────────┬───────────────┬───────────────┬────────┘
       │               │               │               │
┌──────▼─────┐  ┌──────▼──────┐  ┌─────▼──────┐  ┌─────▼────────┐
│ Window mgmt│  │ Display mgmt│  │  Rendering │  │  Persistence │
│ DesktopWin │  │ DisplayMgr  │  │  Renderers │  │ SettingsSvc  │
│ …Controller│  │             │  │  (AV / Web)│  │ Library      │
└────────────┘  └─────────────┘  └────────────┘  └──────────────┘
       │                                 │
       └───────── AppKit / CoreGraphics ─┴── AVFoundation / WebKit
```

**Rule:** the rendering layer knows nothing about windows or displays; it produces an `NSView`. The window layer knows nothing about `AVPlayer`/`WKWebView`; it hosts an opaque `NSView`. `WallpaperManager` wires them together.

---

## 2. Xcode / SPM project structure

Primary code lives in an SPM package so logic is testable without the app shell. The Xcode app target links the package and holds the app-only bits (entitlements, Info.plist, assets, `@main`).

```
LiveWall/
├── Package.swift
├── LiveWall.xcodeproj/                 # app target: signing, entitlements, Info.plist, assets
├── App/                                # app-shell-only sources (in the Xcode target)
│   ├── LiveWallApp.swift               # @main SwiftUI App
│   ├── AppDelegate.swift               # NSApplicationDelegate: policy, menu bar, lifecycle
│   ├── AppEnvironment.swift            # composition root / DI container
│   ├── Info.plist
│   ├── LiveWall.entitlements
│   └── Assets.xcassets
├── Sources/
│   ├── LiveWallCore/                   # pure model + policy, NO AppKit/AVFoundation/WebKit
│   │   ├── Models/
│   │   │   ├── WallpaperItem.swift
│   │   │   ├── WallpaperKind.swift
│   │   │   ├── FillMode.swift
│   │   │   ├── DisplaySelection.swift
│   │   │   ├── AppSettings.swift
│   │   │   ├── VideoQuality.swift
│   │   │   ├── FrameRateLimit.swift
│   │   │   └── PlaybackState.swift
│   │   ├── Policy/
│   │   │   ├── PlaybackPolicy.swift
│   │   │   └── PlaybackConditions.swift
│   │   ├── Errors/
│   │   │   └── WallpaperError.swift
│   │   └── Support/
│   │       ├── YouTubeURLParser.swift
│   │       └── Logging.swift
│   ├── LiveWallServices/               # protocols + concrete services (AppKit/AV/WebKit allowed)
│   │   ├── Protocols/
│   │   │   ├── SettingsService.swift
│   │   │   ├── LaunchAtLoginService.swift
│   │   │   ├── DisplayManaging.swift
│   │   │   └── WallpaperRenderer.swift
│   │   ├── Settings/
│   │   │   ├── UserDefaultsSettingsService.swift
│   │   │   └── LibraryStore.swift
│   │   ├── Login/
│   │   │   └── SMAppServiceLaunchAtLogin.swift
│   │   ├── Display/
│   │   │   ├── ScreenDisplayManager.swift
│   │   │   └── DisplayInfo.swift
│   │   ├── Power/
│   │   │   └── PowerMonitor.swift
│   │   ├── Window/
│   │   │   ├── DesktopWindow.swift
│   │   │   ├── DesktopWindowController.swift
│   │   │   └── DesktopWindowLevel.swift
│   │   ├── Rendering/
│   │   │   ├── WallpaperRendererFactory.swift
│   │   │   ├── VideoWallpaperRenderer.swift
│   │   │   ├── WebWallpaperRenderer.swift
│   │   │   └── YouTubeEmbedHTML.swift
│   │   └── Manager/
│   │       └── WallpaperManager.swift
│   └── LiveWallUI/                     # SwiftUI views + view models
│       ├── Home/ (HomeView, HomeViewModel)
│       ├── Library/ (LibraryView, LibraryItemCell)
│       ├── Controls/ (PlaybackControlsView, DisplayPickerView, FillModePicker)
│       ├── Preview/ (WallpaperPreviewView)
│       ├── Settings/ (SettingsView, SettingsViewModel)
│       └── Components/ (shared views, formatters)
└── Tests/
    ├── LiveWallCoreTests/              # policy, URL parser, settings codec, models
    └── LiveWallServicesTests/         # display reconciliation, settings persistence, factory
```

**`Package.swift` sketch**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LiveWall",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LiveWallCore", targets: ["LiveWallCore"]),
        .library(name: "LiveWallServices", targets: ["LiveWallServices"]),
        .library(name: "LiveWallUI", targets: ["LiveWallUI"]),
    ],
    targets: [
        .target(name: "LiveWallCore"),
        .target(name: "LiveWallServices", dependencies: ["LiveWallCore"]),
        .target(name: "LiveWallUI", dependencies: ["LiveWallCore", "LiveWallServices"]),
        .testTarget(name: "LiveWallCoreTests", dependencies: ["LiveWallCore"]),
        .testTarget(name: "LiveWallServicesTests", dependencies: ["LiveWallServices"]),
    ]
)
```

> **Why this split:** `LiveWallCore` has zero UI/media imports, so `PlaybackPolicy`, `YouTubeURLParser`, settings coding, and display-reconciliation math are testable headlessly and fast. Media/window code lives one layer up.

---

## 3. Domain models (`LiveWallCore/Models`)

```swift
public enum WallpaperKind: String, Codable, Sendable, CaseIterable {
    case localVideo
    case directVideoURL
    case youTube
    case youTubeLive
}

public enum FillMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case fill      // AVLayerVideoGravity.resizeAspectFill  — crop to cover
    case fit       // AVLayerVideoGravity.resizeAspect      — letterbox
    case stretch   // AVLayerVideoGravity.resize            — distort to fill
    case center    // no scaling, natural size centered
    public var id: String { rawValue }
}

public struct WallpaperItem: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var kind: WallpaperKind
    public var title: String
    /// Security-scoped bookmark for `.localVideo`. Resolve before each use.
    public var localBookmark: Data?
    /// Remote video URL for `.directVideoURL`.
    public var remoteURL: URL?
    /// Canonical 11-char YouTube video id for `.youTube` / `.youTubeLive`.
    public var youTubeVideoID: String?
    public var createdAt: Date
    public var lastUsedAt: Date?
    /// Optional per-item override of the global default fill mode.
    public var preferredFillMode: FillMode?

    public init(id: UUID = UUID(), kind: WallpaperKind, title: String,
                localBookmark: Data? = nil, remoteURL: URL? = nil,
                youTubeVideoID: String? = nil, createdAt: Date = .now,
                lastUsedAt: Date? = nil, preferredFillMode: FillMode? = nil) { … }
}

/// Which displays a wallpaper is applied to.
public enum DisplaySelection: Codable, Hashable, Sendable {
    case allDisplays
    case mainDisplay
    case specific(Set<CGDirectDisplayIDBox>)   // stable IDs; box makes it Codable
}

public enum VideoQuality: String, Codable, Sendable, CaseIterable {
    case auto, p2160, p1440, p1080, p720, p480
}

public enum FrameRateLimit: Int, Codable, Sendable, CaseIterable {
    case unlimited = 0, fps24 = 24, fps30 = 30, fps60 = 60
}

public enum PlaybackState: String, Codable, Sendable {
    case idle, preparing, playing, paused, failed
}
```

> `CGDirectDisplayID` is a `UInt32`; it is `Codable` already, but wrap it in a small `CGDirectDisplayIDBox` if you need `Set` stability with extra metadata. If not, `Set<UInt32>` is fine — keep it simple.

---

## 4. Protocols (spec task 5)

All six requested protocols are defined here with exact signatures. Concrete implementations live in `LiveWallServices`.

### 4.1 `WallpaperSource`
Resolves a persisted `WallpaperItem` into something playable, handling security-scoped access for local files. Kept protocol-based so tests can inject fakes.

```swift
public protocol WallpaperSource {
    var item: WallpaperItem { get }
    /// Resolve to a playable resource. For local files this starts security-scoped
    /// access; the returned handle must be released via `endAccess()`.
    func resolve() throws -> ResolvedWallpaper
    func endAccess()
}

public enum ResolvedWallpaper {
    /// Local or direct-URL video. `accessURL` is non-nil only for security-scoped local files.
    case avURL(URL, accessURL: URL?)
    /// YouTube embed by canonical video id (+ isLive hint).
    case youTube(videoID: String, isLive: Bool)
}
```

Concrete sources: `LocalFileSource`, `DirectURLSource`, `YouTubeSource` — each `init(item:)`.

### 4.2 `WallpaperRenderer`
Draws one item into one window's content view. Two implementations. **`AnyObject`** so the window can hold it; **`@MainActor`** because it touches views/layers.

```swift
@MainActor
public protocol WallpaperRenderer: AnyObject {
    var item: WallpaperItem { get }
    /// Layer-backed view the window installs as contentView. Never nil after `prepare()`.
    var contentView: NSView { get }
    var isPlaying: Bool { get }
    /// Callback for terminal failures (network, decode, embed-disabled, …).
    var onFailure: ((WallpaperError) -> Void)? { get set }

    func prepare() throws          // build player/webview, load content, do NOT auto-play
    func play()
    func pause()
    func setMuted(_ muted: Bool)
    func setVolume(_ volume: Float)     // 0.0…1.0
    func setLooping(_ looping: Bool)
    func setFillMode(_ mode: FillMode)
    func setFrameRateLimit(_ limit: FrameRateLimit)
    func teardown()                // release player/webview, stop access; idempotent
}
```

### 4.3 `WallpaperManager`
Single orchestrator. Concrete `@MainActor final class WallpaperManager: ObservableObject` — see §5.

```swift
@MainActor
public protocol WallpaperManaging: ObservableObject {
    var activeItem: WallpaperItem? { get }
    var playbackState: PlaybackState { get }
    var isRunning: Bool { get }

    func setWallpaper(_ item: WallpaperItem, on selection: DisplaySelection) throws
    func stop()
    func play()
    func pause()
    func setMuted(_ muted: Bool)
    func setVolume(_ volume: Float)
    func setLooping(_ looping: Bool)
    func setFillMode(_ mode: FillMode)
    func setDisplaySelection(_ selection: DisplaySelection)
}
```

### 4.4 `DisplayManaging`
Enumerates screens with stable IDs and reports hot-plug/rearrange events.

```swift
@MainActor
public protocol DisplayManaging: AnyObject {
    var displays: [DisplayInfo] { get }
    /// Fired on connect/disconnect/resolution/arrangement change (debounced).
    var onChange: (([DisplayInfo]) -> Void)? { get set }
    func start()
    func stop()
    func screen(for id: CGDirectDisplayID) -> NSScreen?
    func displayInfo(for id: CGDirectDisplayID) -> DisplayInfo?
}

public struct DisplayInfo: Identifiable, Hashable, Sendable {
    public let id: CGDirectDisplayID     // stable across the session; use as window key
    public let localizedName: String
    public let frame: CGRect             // full frame in global coordinates
    public let backingScaleFactor: CGFloat
    public let isMain: Bool
}
```

### 4.5 `SettingsService`
Persists `AppSettings` and the wallpaper library.

```swift
@MainActor
public protocol SettingsService: AnyObject {
    var settings: AppSettings { get set }        // setting triggers async save
    var library: [WallpaperItem] { get }

    func load()
    func save()

    func addToLibrary(_ item: WallpaperItem)
    func updateInLibrary(_ item: WallpaperItem)
    func removeFromLibrary(_ id: UUID)
    func item(with id: UUID) -> WallpaperItem?

    /// Combine publisher so views/manager react to settings changes.
    var settingsPublisher: AnyPublisher<AppSettings, Never> { get }
}
```

### 4.6 `LaunchAtLoginService`

```swift
public protocol LaunchAtLoginService: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}
```

---

## 5. Key concrete classes & responsibilities

### `WallpaperManager` (Orchestration)
The heart of the app. Owns the mapping of display → (window controller + renderer). Applies playback policy.

```swift
@MainActor
public final class WallpaperManager: ObservableObject, WallpaperManaging {
    @Published public private(set) var activeItem: WallpaperItem?
    @Published public private(set) var playbackState: PlaybackState = .idle
    @Published public private(set) var isRunning = false

    // One window + renderer per display id. Never more than one per display.
    private var controllers: [CGDirectDisplayID: DesktopWindowController] = [:]
    private var renderers:  [CGDirectDisplayID: WallpaperRenderer] = [:]

    private let displayManager: DisplayManaging
    private let settings: SettingsService
    private let power: PowerMonitor
    private let rendererFactory: WallpaperRendererFactory
    private var cancellables = Set<AnyCancellable>()

    public init(displayManager: DisplayManaging,
                settings: SettingsService,
                power: PowerMonitor,
                rendererFactory: WallpaperRendererFactory) { … }

    // MARK: WallpaperManaging
    public func setWallpaper(_ item: WallpaperItem, on selection: DisplaySelection) throws { … }
    public func stop() { … }                 // teardown all renderers + close all windows
    public func play()  { … }
    public func pause() { … }
    // …volume/mute/loop/fill/displaySelection…

    // MARK: internal reconciliation
    private func reconcileWindows(for selection: DisplaySelection) { … } // add/remove per display
    private func evaluatePlaybackPolicy() { … }                         // called on power/visibility change
    private func handleDisplaysChanged(_ displays: [DisplayInfo]) { … }
    private var userWantsPlaying = false
}
```

**Responsibilities:**
- Create exactly one `DesktopWindowController` + `WallpaperRenderer` per selected display; enforce the one-window-per-display invariant.
- Subscribe to `displayManager.onChange`, `power.$…` publishers, and `settings.settingsPublisher`; recompute via `PlaybackPolicy` and call `play()`/`pause()`/`teardown()` accordingly.
- On failure callbacks from a renderer, set `playbackState = .failed`, tear that renderer down, and forward a `WallpaperError` to the UI.
- Persist `lastWallpaperID` and `lastUsedAt` through `SettingsService`.

### `PlaybackPolicy` (Core, pure)
Pure function — no side effects — so it is trivially unit-tested. See [performance-and-power.md](performance-and-power.md).

```swift
public enum PlaybackPolicy {
    public static func shouldPlay(_ c: PlaybackConditions, settings: AppSettings) -> Bool
}
public struct PlaybackConditions: Equatable, Sendable {
    public var userWantsPlaying: Bool
    public var isVisible: Bool
    public var onBattery: Bool
    public var lowPowerMode: Bool
    public var otherAppFullscreen: Bool
    public var screenLocked: Bool
    public var displayAsleep: Bool
}
```

### `PowerMonitor` (Orchestration)
Publishes the environmental inputs to `PlaybackPolicy`. Details & exact notification names in [performance-and-power.md](performance-and-power.md).

### Rendering, Window, Display, Settings, Login
Each has a dedicated doc:
- Window + display → [window-and-displays.md](window-and-displays.md)
- Renderers (AV + Web) → [playback.md](playback.md)
- Settings + login + restore → [settings-and-startup.md](settings-and-startup.md)

---

## 6. Composition root (`App/AppEnvironment.swift`)

Single place that constructs concrete services and injects them. This is the only place `WallpaperManager` sees concrete types.

```swift
@MainActor
final class AppEnvironment: ObservableObject {
    let settings: SettingsService
    let displayManager: DisplayManaging
    let power: PowerMonitor
    let launchAtLogin: LaunchAtLoginService
    let wallpaperManager: WallpaperManager

    init() {
        let settings = UserDefaultsSettingsService()
        settings.load()
        let displayManager = ScreenDisplayManager()
        let power = PowerMonitor()
        let factory = WallpaperRendererFactory(settings: settings)

        self.settings = settings
        self.displayManager = displayManager
        self.power = power
        self.launchAtLogin = SMAppServiceLaunchAtLogin()
        self.wallpaperManager = WallpaperManager(
            displayManager: displayManager, settings: settings,
            power: power, rendererFactory: factory)

        displayManager.start()
        power.start()
    }
}
```

Injected once at the top:

```swift
@main
struct LiveWallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var env = AppEnvironment()

    var body: some Scene {
        Window("LiveWall", id: "main") {
            HomeView()
                .environmentObject(env)
                .environmentObject(env.wallpaperManager)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("LiveWall", systemImage: "photo.on.rectangle.angled") {
            MenuBarContent().environmentObject(env)
        }

        Settings { SettingsView().environmentObject(env) }
    }
}
```

`AppDelegate` sets activation policy (`.accessory` menu-bar-first, promote to `.regular` while the main window is open), restores the last wallpaper (see [settings-and-startup.md](settings-and-startup.md)), and owns app-lifecycle observers not tied to a single view.

---

## 7. Concurrency model

- All UI, window, renderer, and manager code is **`@MainActor`**. `NSWindow`, `AVPlayerLayer`, and `WKWebView` are main-thread-only.
- Pure `LiveWallCore` types are `Sendable` and actor-agnostic.
- Async asset loading uses `AVAsset` `load(_:)` (`async`) off the main actor, then hops back to the main actor to attach layers.
- IOKit/power run-loop callbacks arrive on the main run loop; marshal to the main actor before mutating `@Published` state.

---

## 8. Dependency & import rules (enforced in review)

| Target | May import |
| --- | --- |
| `LiveWallCore` | Foundation, CoreGraphics (types only). **No** AppKit, AVFoundation, WebKit, SwiftUI. |
| `LiveWallServices` | Foundation, AppKit, AVFoundation, WebKit, IOKit, ServiceManagement, Combine, `LiveWallCore`. |
| `LiveWallUI` | SwiftUI, Combine, `LiveWallCore`, `LiveWallServices`. |
| `App/` | everything + entitlements/Info.plist. |

If `LiveWallCore` ever needs `import AppKit`, the abstraction is wrong — push the type down as a plain value or up into `LiveWallServices`.

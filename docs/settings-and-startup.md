# Settings & Startup

Covers spec task 13 (all settings) plus persistence, launch-at-login, and restore-last-wallpaper startup behaviour (part of task 4).

---

## 1. `AppSettings` model (Core)

```swift
public struct AppSettings: Codable, Equatable, Sendable {
    // Startup
    public var launchAtLogin: Bool          = false
    public var restoreLastWallpaper: Bool   = true
    public var lastWallpaperID: UUID?       = nil
    public var lastDisplaySelection: DisplaySelection = .allDisplays

    // Power / pause policy
    public var pauseOnBattery: Bool         = false
    public var pauseOnLowPowerMode: Bool    = true
    public var pauseWhenAppFullscreen: Bool = true

    // Audio / video defaults
    public var muteByDefault: Bool          = true
    public var defaultVolume: Float         = 0.5
    public var loopByDefault: Bool          = true
    public var defaultFillMode: FillMode    = .fill
    public var videoQuality: VideoQuality   = .auto
    public var frameRateLimit: FrameRateLimit = .fps30

    public init() {}
}
```

**Field semantics (task 13 checklist):**

| Setting | Type | Effect |
| --- | --- | --- |
| Launch LiveWall at login | `launchAtLogin` | Registers app as a login item via `SMAppService` (§3). |
| Restore last wallpaper on open | `restoreLastWallpaper` | On launch, re-apply `lastWallpaperID` to `lastDisplaySelection` (§4). |
| Pause on battery power | `pauseOnBattery` | `PlaybackPolicy` stops playback when on battery. |
| Pause in Low Power Mode | `pauseOnLowPowerMode` | `PlaybackPolicy` stops when `ProcessInfo.isLowPowerModeEnabled`. |
| Pause when another app is fullscreen | `pauseWhenAppFullscreen` | `PlaybackPolicy` stops when a fullscreen app is frontmost (best-effort detection). |
| Mute by default | `muteByDefault` | Initial `isMuted`/embed `mute` state. |
| Video quality | `videoQuality` | Hint for source selection / YouTube `setPlaybackQuality`; `.auto` recommended. |
| Frame-rate limit | `frameRateLimit` | Caps rendering effort (best-effort; see [performance-and-power.md](performance-and-power.md)). |

> Quality/frame-rate for local video are best-effort: AVFoundation decodes what the file contains. The frame-rate limit primarily governs the *preview* and any re-render, and documents intent for the desktop layer. YouTube quality is a **hint** via the IFrame API, never enforced by stream manipulation.

---

## 2. Persistence — `UserDefaultsSettingsService`

Settings live in `UserDefaults`; the library (which can grow and holds bookmark `Data`) is stored as JSON, either in `UserDefaults` under one key or in a JSON file in Application Support. Prefer a JSON file for the library to keep `UserDefaults` small.

```swift
@MainActor
public final class UserDefaultsSettingsService: SettingsService {
    @Published public var settings = AppSettings() { didSet { scheduleSave() } }
    public private(set) var library: [WallpaperItem] = []

    public var settingsPublisher: AnyPublisher<AppSettings, Never> { $settings.eraseToAnyPublisher() }

    private let defaults = UserDefaults.standard
    private let settingsKey = "com.livewall.settings.v1"
    private let libraryURL: URL   // Application Support/LiveWall/library.json
    private var saveTask: Task<Void, Never>?

    public func load() {
        if let data = defaults.data(forKey: settingsKey),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) { settings = s }
        library = (try? JSONDecoder().decode([WallpaperItem].self,
                    from: Data(contentsOf: libraryURL))) ?? []
    }

    public func save() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: settingsKey) }
        if let data = try? JSONEncoder().encode(library) { try? data.write(to: libraryURL, options: .atomic) }
    }

    private func scheduleSave() {                       // debounce rapid slider/toggle writes
        saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(for: .milliseconds(400)); save() }
    }

    public func addToLibrary(_ item: WallpaperItem)    { library.append(item); scheduleSave() }
    public func updateInLibrary(_ item: WallpaperItem) {
        if let i = library.firstIndex(where: { $0.id == item.id }) { library[i] = item; scheduleSave() }
    }
    public func removeFromLibrary(_ id: UUID) { library.removeAll { $0.id == id }; scheduleSave() }
    public func item(with id: UUID) -> WallpaperItem?  { library.first { $0.id == id } }
}
```

- **Versioned key** (`…v1`) so future migrations are clean.
- Encode/decode is round-trip tested (see acceptance tests SET-1).
- `library.json` path: `FileManager.default.url(for: .applicationSupportDirectory, …)/LiveWall/library.json`; create the directory on first run.
- Schema migration: on decode failure, keep defaults, log, and back up the unreadable file rather than crashing.

---

## 3. Launch at login — `SMAppServiceLaunchAtLogin` (task 13, `LaunchAtLoginService`)

Use the modern **`SMAppService`** (macOS 13+). It works in the App Sandbox and for both direct and App Store distribution — no separate helper bundle needed for the main app.

```swift
import ServiceManagement

public final class SMAppServiceLaunchAtLogin: LaunchAtLoginService {
    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        }
    }
}
```

**Wiring:** the General settings toggle calls `setEnabled` and, on throw, reverts the toggle and shows the error. If `status == .requiresApproval`, tell the user to enable LiveWall in **System Settings ▸ General ▸ Login Items** (deep-link with `SMAppService.openSystemSettingsLoginItems()`).

**Do not** use the deprecated `SMLoginItemSetEnabled`/`LSSharedFileList` paths — they're brittle on modern macOS.

---

## 4. Restore last wallpaper on launch (startup behaviour)

Owned by `AppDelegate.applicationDidFinishLaunching`, after `AppEnvironment` is built.

```swift
func applicationDidFinishLaunching(_ n: Notification) {
    NSApp.setActivationPolicy(.accessory)          // menu-bar-first; promote when main window opens
    let env = AppEnvironment.shared
    guard env.settings.settings.restoreLastWallpaper,
          let id = env.settings.settings.lastWallpaperID,
          let item = env.settings.item(with: id) else { return }
    do {
        try env.wallpaperManager.setWallpaper(item, on: env.settings.settings.lastDisplaySelection)
    } catch {
        // Missing file / removed video etc. — surface non-modally, clear lastWallpaperID.
        env.settings.settings.lastWallpaperID = nil
    }
}
```

- On every successful `setWallpaper`, persist `lastWallpaperID` + `lastDisplaySelection` and bump `lastUsedAt`.
- If restore fails (file moved, YouTube video gone), fail quietly: log, notify via menu bar badge/toast, and don't block startup.
- If `launchAtLogin` + `restoreLastWallpaper` are both on, the wallpaper appears shortly after login with no window shown (accessory app).

---

## 5. Activation policy detail

- Default: `.accessory` — no Dock icon, menu-bar-only, wallpaper runs in the background.
- When the user opens the main window (from the menu bar), switch to `.regular` so the window is focusable and appears normally; when it closes, drop back to `.accessory`.
- The desktop overlay windows are unaffected by activation policy — they stay at desktop level regardless.

```swift
func showMainWindow() { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); openWindow(id: "main") }
func mainWindowDidClose() { NSApp.setActivationPolicy(.accessory) }
```

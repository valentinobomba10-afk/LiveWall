# Review 001 — Initial skeleton

Reviewer: lead architect. Scope: the first end-to-end skeleton Codex committed (compiles via `swift build`). Graded against [code-review-checklist.md](code-review-checklist.md), [SPEC.md](../SPEC.md), and the acceptance tests.

**Verdict:** Good bones and — importantly — **fully compliant** (honest wallpaper language + official YouTube embed, no downloading/ad-block/DRM bypass). But the app does **not yet work end-to-end**: the two `*Renderer` classes are dead code, playback runs through a SwiftUI preview whose play/pause can't be controlled, and the whole power/display/settings spine is unwired. No retain cycles or leaks were found. Fix the blockers first, then the majors in the order below.

Legend: `[B]` blocker · `[M]` major · `[m]` minor/cleanup · `[+]` keep (done well).

---

## [+] What's already right (don't regress these)
- **Compliance is clean.** Honest "cannot replace the native wallpaper" copy in `README.md` and `Views/SettingsView.swift` (About). YouTube uses only the official `/embed/` iframe — no stream extraction, ad-blocking, or DRM/geo/age bypass anywhere. (CMP-1, CMP-2 pass.)
- **Window fundamentals** in `Windows/WallpaperWindow.swift` are mostly correct: `.borderless`, `canBecomeKey/Main == false`, `ignoresMouseEvents == true`, `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]`, desktop-ish level, black opaque, no shadow.
- **No retain cycles / leaks found.** `DisplayManager` and `PowerStateService` observers capture `[weak self]`.
- **Right modern APIs:** `SMAppService` for login (`Services/LaunchAtLoginService.swift`); `didChangeScreenParametersNotification` in `DisplayManager`; `os.Logger` wrapper.
- `WallpaperManager.setWallpaper` calls `stopWallpaper()` first — prevents stacking players on repeated "Set".
- `YouTubeURLParser` handles `youtu.be`, `watch?v=`, `embed`, `shorts`, `live`.

---

## [B] Blockers — fix before anything else

### [B1] Play/Pause (and therefore ALL pausing) is a no-op for local video
`Windows/WallpaperWindowController.swift:11-12`
```swift
func play()  { (window.contentView as? NSHostingView<WallpaperPreviewView>)?.rootView.play() }
func pause() { (window.contentView as? NSHostingView<WallpaperPreviewView>)?.rootView.pause() }
```
`rootView` returns a **copy** of the `WallpaperPreviewView` struct. The `AVPlayer` lives in `@State private var player` (`Views/WallpaperPreviewView.swift:8`), which SwiftUI stores outside the struct value — so `rootView.play()` operates on a detached copy whose `player` is `nil`. Result: manual Pause/Play does nothing, and every future power/lock/occlusion pause will silently fail too.
**Fix:** don't drive playback through a SwiftUI view value. Use an AppKit renderer the controller holds a reference to (see [playback.md §2](playback.md#2-local--direct-url-video--videowallpaperrenderer) — `VideoWallpaperRenderer` with an `AVPlayerLayer`-backed `NSView`). The controller installs `renderer.contentView` and calls `renderer.play()/pause()` on the object directly. This also fixes B-tier dead code (see [m1]).

### [B2] Force-unwrap crash landmine on missing/unresolvable file
`Sources/LocalVideoSource.swift:7`
```swift
init(item: WallpaperItem) { id = item.id; name = item.name; url = item.resolvedURL! }
```
`resolvedURL` is optional and returns `nil` when the bookmark can't resolve and there's no fallback URL (moved/deleted file). This is a hard crash. (Currently unreachable because the renderers are dead code — but it will crash the moment you wire them.)
**Fix:** make the source resolution `throws` (`throw WallpaperError.missingLocalFile`) and `guard let`. Never force-unwrap `resolvedURL`. See [error-handling.md §3](error-handling.md#3-detection-details-per-case-task-14-list) case 3.

---

## [M] Major — the app isn't feature-complete or robust until these land

### [M1] Local video never loops
`Views/WallpaperPreviewView.swift:13` uses `AVPlayer(url:)` + `player?.play()`; `item.loops` is ignored, so the video plays once and stops.
**Fix:** `AVQueuePlayer` + `AVPlayerLooper` (retain the looper!), per [playback.md §2.1-2.2](playback.md#21-design). (LOC-4)

### [M2] YouTube playback is broken (autoplay, control, mute)
`Renderers/YouTubeRenderer.swift:6-11` and the `YouTubePreview` in `Views/WallpaperPreviewView.swift:23-27`:
- `autoplay=1` **without** `mute=1` → browsers/YouTube block unmuted autoplay; the video won't start.
- No `enablejsapi=1` → the `postMessage` play/pause commands are ignored.
- `setMuted`/`setVolume` are empty `{}` → mute/volume don't work; "mute by default" can't be honored.
- `baseURL: nil` → origin is `about:blank`; use `https://www.youtube.com`.
**Fix:** adopt the IFrame Player API template in [playback.md §3.3-3.4](playback.md#33-embed-html-youtubeembedhtml) (`mute=1`, `enablejsapi=1`, `onReady→playVideo`, JS bridge for play/pause/mute/volume). (YT-2, YT-4)

### [M3] No YouTube error handling
No `WKNavigationDelegate`, no IFrame `onError` handler anywhere. Private/removed (100), embedding-disabled (101/150), age/region, and no-internet are undetected and unsurfaced (task 14).
**Fix:** add the `WKScriptMessageHandler`/navigation-delegate mapping and `WallpaperError.youTube(fromIFrameCode:)` from [error-handling.md §1-3](error-handling.md#1-wallpapererror-core). Add the 15 s embed timeout. (YT-5, YT-6, YT-7)

### [M4] Multi-monitor hot-plug is not handled for wallpaper windows
`Services/WallpaperManager.swift:16` stores `controllers: [WallpaperWindowController]` (array, not keyed by display) and never observes `DisplayManager`/`didChangeScreenParameters`. So connect/disconnect/rearrange (task 8) does nothing; a disconnected display leaves an orphan window+player.
**Fix:** key controllers by `CGDirectDisplayID`; subscribe to display changes and `reconcileWindows` (add/remove/update) per [window-and-displays.md §3.3-4](window-and-displays.md#33-applying-to-selected-displays). Enforce one-window-per-display. (DISP-3, DISP-4, DISP-5, DISP-6)

### [M5] Power / lock / sleep / occlusion pausing is entirely unwired
`PowerStateService` and `FullscreenDetectionService` are never injected in `LiveWallApp.swift` and never consumed by `WallpaperManager`. There are **no** lock, display-sleep, or window-occlusion observers. None of task 15's auto-pause works.
**Fix:** build `PowerMonitor` + occlusion handling and route everything through a single `PlaybackPolicy` decision, per [performance-and-power.md §2-4](performance-and-power.md#2-playbackpolicy--the-single-source-of-truth-pure-in-core). (PWR-1…PWR-6)

### [M6] `PowerStateService` reports the wrong signal
`Services/PowerStateService.swift`: `isOnBattery = ProcessInfo.processInfo.isLowPowerModeEnabled`. Battery state ≠ Low Power Mode — these are different settings (tasks list them separately). `import IOKit.pwr_mgt` is present but unused.
**Fix:** read AC-vs-battery via IOKit power sources; keep LPM as a separate `isLowPowerMode` flag. See [performance-and-power.md §3.1-3.2](performance-and-power.md#31-low-power-mode). (PWR-4, PWR-5)

### [M7] Fullscreen heuristic yields constant false positives
`Services/FullscreenDetectionService.swift`: `anotherAppIsFullscreen = (frontmost != current) && (NSApp.isActive == false)` is true almost any time LiveWall isn't frontmost — i.e., during normal use. If wired as-is it would pause the wallpaper constantly.
**Fix:** use the bounds/level heuristic in [performance-and-power.md §3.5](performance-and-power.md#35-other-app-fullscreen-best-effort), bias toward *not* pausing when uncertain, and **never** call APIs that trigger Screen Recording permission (no `kCGWindowName`, no `CGWindowListCreateImage`).

### [M8] Settings are neither persisted nor wired
`Services/SettingsService.swift` is an in-memory singleton with `private init()` and no load/save — every toggle resets on relaunch. Nothing consumes `pauseOnBattery`/`pauseOnFullscreen`/`restoreOnLaunch`/`defaultMuted`. `Views/SettingsView.swift` doesn't expose **Launch at login**, and `LaunchAtLoginService` is never called. Missing entirely: pause-on-Low-Power-Mode, video quality, frame-rate limit.
**Fix:** implement persistence + full field set + wiring per [settings-and-startup.md](settings-and-startup.md). (SET-1, SET-2, SET-3, SET-5)

### [M9] No menu-bar item, no restore-on-launch, wrong activation policy
`AppDelegate.swift` only does `NSApp.setActivationPolicy(.regular)`; the declared `statusItem` is never created, there's no `MenuBarExtra` in `LiveWallApp.swift`, and there's no restore-last-wallpaper on launch. Spec is menu-bar-first (`.accessory`) with restore.
**Fix:** add `MenuBarExtra`, restore logic, and accessory/regular policy switching per [settings-and-startup.md §3-5](settings-and-startup.md#4-restore-last-wallpaper-on-launch-startup-behaviour) and [architecture.md §6](architecture.md#6-composition-root-appappenvironmentswift). (LOC-6, SET-4, WIN-7)

### [M10] Security-scoped file access is never started (sandbox-fatal)
`Models/WallpaperItem.swift:18-21` `resolvedURL` resolves the bookmark but never calls `startAccessingSecurityScopedResource()`, and being a computed property it can't balance start/stop. Works now only because the SPM dev build isn't sandboxed; it will fail the moment the sandbox entitlements from [security-distribution.md §3.1](security-distribution.md#31-sandbox-entitlements-recommended-set) are applied.
**Fix:** resolve + `startAccessing…` inside a source object and pair a `stopAccessing…` in teardown, per [playback.md §2.3](playback.md#23-local-file-access-sandbox-safe). Handle `bookmarkDataIsStale` by re-creating the bookmark. (LOC-7, LOC-8)

### [M11] You can only ever set the newest library item
`Views/HomeView.swift` preview and `apply()` use `library.items.first`; `Views/WallpaperLibraryView.swift` has no set/remove/rename actions. There's no "selected item" model.
**Fix:** add a selected `WallpaperItem` binding driving preview + Set; add Library context actions (Set / Remove / Rename). (LOC-1, library UX in [ui.md §6](ui.md#6-libraryview-saved-wallpaper-library))

---

## [m] Minor & cleanup

- **[m1] Dead code / architecture split.** `Renderers/LocalVideoRenderer.swift`, `Renderers/YouTubeRenderer.swift`, and the `Sources/*Source.swift` types are not wired to the render path (which uses `WallpaperPreviewView`). Decide one architecture: recommend the **AppKit layer renderers** for the desktop window (fixes B1, cheaper than `VideoPlayer`) and keep a lightweight preview. Then either wire or delete the unused classes.
- **[m2] `project.yml` build bug.** `sources: [LiveWall]` points at the **empty** `LiveWall/` directory; an XcodeGen build would produce an app with no code. Point `sources` at the real folders (`App`, `Models`, `Renderers`, `Services`, `Sources`, `Utilities`, `Views`, `Windows`) or move code under `LiveWall/`. Keep SPM and XcodeGen in sync.
- **[m3] `WallpaperWindow` hardening.** Set `isReleasedWhenClosed = false` (latent over-release crash if `window.close()` is ever called), plus `isMovable = false`, `isExcludedFromWindowsMenu = true`, and add `.fullScreenNone` to `collectionBehavior`. Note `close()` in the controller only does `orderOut` + nil contentView — call an explicit teardown too.
- **[m4] Window level `+1` is undocumented magic.** `CGWindowLevelForKey(.desktopWindow) + 1` is fine (still below the icon layer) — either drop the `+1` or add a comment explaining it keeps you above the system desktop picture but below icons.
- **[m5] Centre scaling not implemented.** `WallpaperScalingMode.center.videoGravity` returns `"resizeAspect"` (identical to Fit). Implement true 1:1 centered per [playback.md §2.2](playback.md#22-implementation).
- **[m6] WKWebView uses the persistent data store** → YouTube cookies written to disk. Use `WKWebsiteDataStore.nonPersistent()` and set `mediaTypesRequiringUserActionForPlayback = []`. (CMP-3, privacy)
- **[m7] `ForEach(displays.displays, id: \.self)`** keys UI by `NSScreen` identity, which churns on screen-parameter changes; key by `stableID`.
- **[m8] Ad-hoc `NSError`** in `WallpaperManager`/renderers → adopt the typed `WallpaperError` so the UI can map messages (error-handling.md).
- **[m9] Scenes.** `WindowGroup` allows multiple main windows (prefer `Window(id:)`); Settings is a sidebar `NavigationLink` rather than the standard `Settings{}` scene (⌘,).
- **[m10] Debounce** `DisplayManager`'s `didChangeScreenParameters` (a rearrange fires several notifications).
- **[m11] `Package.swift` excludes** only README/project.yml/Package.swift — also exclude `docs`, `SPEC.md`, and build noise so SPM doesn't warn about non-source files.

---

## Suggested order of work
1. **B1 + m1** — switch the desktop render path to an AppKit `AVPlayerLayer` renderer the controller controls (unblocks all pausing).
2. **B2 + M10** — safe, sandbox-correct local file resolution.
3. **M1** — looping.
4. **M4** — display-ID-keyed reconcile + hot-plug.
5. **M5 + M6 + M7** — `PowerMonitor` + `PlaybackPolicy` + occlusion (wire pausing).
6. **M2 + M3 + m6** — YouTube IFrame API + error handling + non-persistent store.
7. **M8 + M9** — settings persistence/wiring, menu bar, restore-on-launch.
8. **M11** — item selection + library actions.
9. Sweep the remaining `[m]` items and re-run the acceptance suite.

Re-request review after step 5 (the spine) and again before distribution.

# Implementation Plan (for Codex)

Covers spec task 22. Ordered so that **every phase ends in something runnable and testable**. Do phases in order; don't start a phase until the previous one's exit criteria pass. Check boxes as you go.

Each task references the doc that specifies it and the acceptance tests it must satisfy.

---

## Phase 0 — Project skeleton
- [ ] Create SPM package with targets `LiveWallCore`, `LiveWallServices`, `LiveWallUI` + test targets ([architecture.md](architecture.md#2-xcode--spm-project-structure)).
- [ ] Create Xcode app target `LiveWall` linking the packages; set deployment target macOS 13.0; `ARCHS = arm64 x86_64`.
- [ ] Add `Info.plist` (`LSUIElement`/accessory handled at runtime) and `LiveWall.entitlements` (sandbox set from [security-distribution.md](security-distribution.md#31-sandbox-entitlements-recommended-set)).
- [ ] Add `os.Logger` wrapper (`Logging.swift`).
- **Exit:** app launches to an empty menu-bar item + empty window; unit test target runs.

## Phase 1 — Core models & pure logic (no UI/media)
- [ ] Implement all `LiveWallCore/Models` types ([architecture.md](architecture.md#3-domain-models-livewallcoremodels)).
- [ ] Implement `PlaybackPolicy` + `PlaybackConditions` ([performance-and-power.md](performance-and-power.md#2-playbackpolicy--the-single-source-of-truth-pure-in-core)).
- [ ] Implement `YouTubeURLParser` ([playback.md](playback.md#32-url-parsing--canonical-video-id-youtubeurlparser-in-core-unit-tested)).
- [ ] Implement `WallpaperError` + `youTube(fromIFrameCode:)` ([error-handling.md](error-handling.md#1-wallpapererror-core)).
- [ ] **Tests:** PWR-8, YT-1, ERR-3, SET-1 (Codable), DISP-7 (write the pure diff helper here or in services).
- **Exit:** `LiveWallCoreTests` green; zero AppKit/AV/WebKit imports in Core.

## Phase 2 — Settings & persistence
- [ ] `SettingsService` protocol + `UserDefaultsSettingsService` + `LibraryStore` ([settings-and-startup.md](settings-and-startup.md#2-persistence--userdefaultssettingsservice)).
- [ ] Debounced save; versioned key; Application Support `library.json`.
- [ ] **Tests:** SET-1, SET-2 (persistence round-trip).
- **Exit:** settings + library persist across relaunch.

## Phase 3 — Displays
- [ ] `DisplayManaging` + `ScreenDisplayManager` + `DisplayInfo` + `NSScreen.displayID` ([window-and-displays.md](window-and-displays.md#3-multi-display-support-task-7)).
- [ ] Debounced `didChangeScreenParameters` handling.
- [ ] **Tests:** DISP-7 (reconcile diff) with injected display lists.
- **Exit:** display list logs correctly on connect/disconnect (manual DISP smoke).

## Phase 4 — Desktop window
- [ ] `DesktopWindow`, `DesktopContentView`, `DesktopWindowLevel`, `DesktopWindowController` ([window-and-displays.md](window-and-displays.md#1-the-desktop-level-window-desktopwindow)).
- [ ] Verify all task-6 window properties (level, click-through, non-activating, collection behaviour, full-frame).
- [ ] Temporary: install a solid-color `NSView` to prove the window behaves.
- [ ] **Tests:** WIN-1…WIN-7 (manual).
- **Exit:** a color fills the desktop behind apps and icons, click-through, no focus theft, no Dock/Mission Control entry.

## Phase 5 — Local video renderer
- [ ] `WallpaperRenderer` protocol; `VideoWallpaperRenderer` with `AVQueuePlayer`+`AVPlayerLooper`+`AVPlayerLayer` ([playback.md](playback.md#2-local--direct-url-video--videowallpaperrenderer)).
- [ ] `LocalFileSource`/`DirectURLSource`; security-scoped bookmarks; fill modes; mute/volume/loop.
- [ ] Correct `teardown()` (release player, stop access, invalidate observers).
- [ ] **Tests:** LOC-1…LOC-8, URL-1…URL-4.
- **Exit:** local + direct-URL video plays as wallpaper with all controls.

## Phase 6 — Wallpaper manager + window/display wiring
- [ ] `WallpaperManager` with per-display `controllers`/`renderers` dictionaries; `reconcileWindows`; one-window invariant ([architecture.md](architecture.md#5-key-concrete-classes--responsibilities), [window-and-displays.md](window-and-displays.md#33-applying-to-selected-displays)).
- [ ] Hook `DisplayManaging.onChange` → reconcile (DISP add/remove/update).
- [ ] `setWallpaper/stop/play/pause/setMuted/setVolume/setLooping/setFillMode/setDisplaySelection`.
- [ ] Persist `lastWallpaperID`/`lastDisplaySelection`/`lastUsedAt`.
- [ ] **Tests:** DISP-1…DISP-6, ERR-2 (stress), LOC-6.
- **Exit:** multi-display set/stop works; hot-plug reconciles; no duplicate players/orphans.

## Phase 7 — Power & policy
- [ ] `PowerMonitor` (LPM, battery/IOKit, lock distributed notifs, sleep/wake, fullscreen heuristic) ([performance-and-power.md](performance-and-power.md#3-powermonitor--inputs--exact-notifications)).
- [ ] Per-window occlusion → per-display visibility.
- [ ] `WallpaperManager.evaluatePlaybackPolicy()` driven by all inputs.
- [ ] Re-apply window level + order-to-back on wake.
- [ ] **Tests:** PWR-1…PWR-7, PWR-9.
- **Exit:** playback pauses/resumes per policy; memory returns to baseline on stop.

## Phase 8 — YouTube renderer
- [ ] `WebWallpaperRenderer` + `YouTubeEmbedHTML` (official IFrame API, non-persistent store, single `yt` handler) ([playback.md](playback.md#3-youtube--webwallpaperrenderer-wkwebview--iframe-player-api)).
- [ ] Map IFrame `onError` → `WallpaperError`; navigation-failure handling; 15 s embed timeout.
- [ ] Reachability check ([error-handling.md](error-handling.md#4-reachability-lightweight)).
- [ ] **Tests:** YT-2…YT-8, ERR-1.
- **Exit:** YouTube video + livestream play; all error cases handled; compliance review passes.

## Phase 9 — SwiftUI UI
- [ ] `AppEnvironment` composition root; `LiveWallApp` scenes; `AppDelegate` activation policy + restore-on-launch ([architecture.md](architecture.md#6-composition-root-appappenvironmentswift), [settings-and-startup.md](settings-and-startup.md#4-restore-last-wallpaper-on-launch-startup-behaviour)).
- [ ] `HomeView`, `WallpaperPreviewView`, `PlaybackControlsView`, `DisplayPickerView`, `FillModePicker`, `LibraryView`, `SettingsView` ([ui.md](ui.md)).
- [ ] `MenuBarExtra` content (play/pause/stop/mute/open/settings/quit).
- [ ] Add Local Video / Add YouTube Link flows.
- [ ] **Tests:** LOC-1/2/3, YT-2, SET-2/3/4/5, WIN-7.
- **Exit:** full UI drives all features; preview tears down on disappear.

## Phase 10 — Launch at login & startup
- [ ] `SMAppServiceLaunchAtLogin` + settings toggle with error/approval handling ([settings-and-startup.md](settings-and-startup.md#3-launch-at-login--smappservicelaunchatlogin-task-13-launchatloginservice)).
- [ ] Restore last wallpaper wired into `applicationDidFinishLaunching`.
- [ ] **Tests:** SET-3, LOC-6, SET-4.
- **Exit:** app can launch at login and restore silently.

## Phase 11 — Hardening, polish, compliance
- [ ] Run full acceptance suite on Apple Silicon (+ Intel if available), single + dual display.
- [ ] Instruments: Leaks + Allocations (players/webviews released on stop); Energy log.
- [ ] Compliance grep gates: banned wallpaper phrases; stream-extraction/ad-block terms ([acceptance-tests.md](acceptance-tests.md#compliance--honesty-cmp)).
- [ ] Accessibility labels; Reduce Motion handling.
- [ ] **Tests:** CMP-1…CMP-3, PWR-7, ERR-2.
- **Exit:** all acceptance tests pass; review checklist clean.

## Phase 12 — Distribution
- [ ] Universal release build; Hardened Runtime; Developer ID signing.
- [ ] Notarize + staple; build DMG; verify `spctl`/`codesign` ([security-distribution.md](security-distribution.md#5-code-signing--notarization-task-20)).
- [ ] Write/verify `README.md` ([../README.md](../README.md)).
- **Exit:** a notarized DMG installs and runs from a clean Mac.

---

## Global definition of done (every PR)
1. Builds for arm64 + x86_64, no warnings-as-errors violations.
2. Relevant unit tests added/updated and green.
3. No item from [code-review-checklist.md](code-review-checklist.md) violated.
4. No capability from [SPEC.md](../SPEC.md#21-legal--content-compliance--youtube) §2.1 introduced.
5. Docs updated if behaviour changed.

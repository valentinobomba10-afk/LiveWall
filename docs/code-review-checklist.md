# Code Review Checklist

This is what the reviewer (lead architect) checks on every change Codex submits. It operationalizes the review mandate: crashes, memory leaks, retain cycles, duplicated players, invalid window levels, broken multi-monitor behaviour, security problems, and unsupported claims about native wallpapers.

Reviewer note: since there is no code yet, this is the standing rubric. When code exists, review against it and file findings as `file:line` with a concrete failure scenario.

---

## 1. Crashes & defensive coding
- [ ] No force-unwraps (`!`) on: `NSScreen`/`NSScreen.main`, `displayID`, dictionary lookups, `URL(string:)`, bookmark resolution, `deviceDescription` keys, JS results.
- [ ] No `try!`, no `fatalError`, no `as!` on external/optional data.
- [ ] `DesktopWindow.isReleasedWhenClosed == false` (else `close()` over-releases → crash).
- [ ] All `NSScreen` lookups during display transitions are guarded (may be `nil` mid-change).
- [ ] Async asset/JS callbacks guard `weak self` and check the object is still alive.
- [ ] No main-thread blocking (synchronous asset loads, `runModal` off the main flow, etc.).

## 2. Memory leaks & retain cycles
- [ ] `AVPlayerLooper` is **retained** for the player's lifetime (losing it silently stops looping and leaks the queue).
- [ ] `WKWebView`: script message handler removed in `teardown` (`removeScriptMessageHandler(forName:)`) — a live handler retains the web view via `WKUserContentController` → cycle.
- [ ] `WKWebView.navigationDelegate = nil` on teardown.
- [ ] KVO (`NSKeyValueObservation`) invalidated; `NotificationCenter`/`DistributedNotificationCenter`/`NSWorkspace` observers removed; `NWPathMonitor` cancelled; IOKit run-loop source invalidated.
- [ ] Closures stored on long-lived objects (`onChange`, `onFailure`, publishers' sinks) capture `[weak self]`.
- [ ] `Combine` `cancellables` retained and torn down; no self-retaining sinks.
- [ ] `deinit` does not touch main-actor-only AVKit/WebKit objects assuming they still exist — teardown must have run explicitly.
- [ ] Instruments Leaks + Allocations: after `stop()`, `AVQueuePlayer`/`AVPlayerLayer`/`WKWebView`/window allocations return to baseline.

## 3. Duplicated / orphaned players & windows
- [ ] Exactly **one** `DesktopWindowController` + one `WallpaperRenderer` per `CGDirectDisplayID` (dictionaries keyed by id, never by `NSScreen`).
- [ ] `DesktopWindowController.install` tears down any previous renderer before adding a new one.
- [ ] Setting a new wallpaper while one runs replaces cleanly (no stacked players/layers).
- [ ] Display disconnect removes the controller and tears down its renderer (no orphan window bound to a gone display).
- [ ] Home preview player is separate from desktop renderers and is torn down in `onDisappear`.
- [ ] `stop()` / `applicationWillTerminate` tear down every renderer and close every window.
- [ ] No renderer/`AVPlayerLayer` shared across multiple windows.

## 4. Window levels & desktop behaviour
- [ ] Level is `CGWindowLevelForKey(.desktopWindow)` (behind icons) — never a positive/normal/floating level.
- [ ] `.desktopIconWindow` level used **only** behind an explicit "hide desktop icons" setting.
- [ ] `styleMask == [.borderless]`; `isMovable == false`; `ignoresMouseEvents == true`.
- [ ] `canBecomeKey`/`canBecomeMain` overridden to `false`; shown via `orderBack`/`orderFrontRegardless`, never `makeKeyAndOrderFront`.
- [ ] `collectionBehavior` includes `.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone`; `isExcludedFromWindowsMenu == true`.
- [ ] Uses full `screen.frame` (not `visibleFrame`).
- [ ] Level/order re-applied after wake and screen-parameter changes.

## 5. Multi-monitor correctness
- [ ] Everything keyed by stable `CGDirectDisplayID`.
- [ ] `didChangeScreenParameters` handling is debounced and idempotent.
- [ ] Add/remove/update reconcile covers: connect, disconnect, resolution change, arrangement change, main-display change, clamshell/no-displays.
- [ ] `DisplaySelection` (`.allDisplays`/`.mainDisplay`/`.specific`) intersected with currently-present displays.
- [ ] No assumption that `NSScreen.main` exists during transitions.

## 6. Security & privacy
- [ ] Sandbox entitlements minimal (network client, user-selected read-only, app-scope bookmarks). No `files.all`, no temporary exceptions.
- [ ] Local files accessed only via security-scoped bookmarks; `stop`Accessing paired with every `start`Accessing.
- [ ] `WKWebView` uses `.nonPersistent()` data store; only the single read-only `yt` message handler; embed loaded with `youtube.com` base URL.
- [ ] No code triggers Screen Recording TCC (no `CGWindowListCreateImage`, no `kCGWindowName` reads) — fullscreen heuristic is bounds/level only.
- [ ] No analytics/telemetry/third-party SDKs; no secrets in bundle.
- [ ] Logging uses `os.Logger` with `privacy: .private` for paths/URLs/ids; no `print`.
- [ ] No personal data in URLs/query strings; `library.json` in the app container.

## 7. Compliance — YouTube & "native wallpaper" claims (hard gates)
- [ ] **No** stream extraction, downloading, or caching of YouTube media (grep: `googlevideo`, `player_response`, `get_video_info`, `yt-dlp`, `ytdl`).
- [ ] **No** ad blocking/skipping (grep for ad-related CSS selectors, auto-click of skip controls).
- [ ] **No** DRM/geo/age/login/private bypass; on restriction, the app surfaces an error and stops.
- [ ] Only the official IFrame API methods are called (`playVideo`, `pauseVideo`, `mute`, `unMute`, `setVolume`, optional quality hint).
- [ ] **No** UI/README/Store string claims replacing the native macOS wallpaper (grep banned phrases from [security-distribution.md](security-distribution.md#user-facing-language)).

## 8. Architecture & concurrency
- [ ] Import rules honoured: `LiveWallCore` has no AppKit/AV/WebKit/SwiftUI.
- [ ] UI/window/renderer/manager code is `@MainActor`; IOKit/notification callbacks marshal to main before mutating `@Published`.
- [ ] Views are thin; no window/player refs in view models.
- [ ] Errors flow renderer → manager → UI; never swallowed silently, never crash.
- [ ] `PlaybackPolicy` remains pure (no side effects) and is the only place the "should play" decision is made.

## 9. Tests & docs
- [ ] Unit tests added/updated for changed Core/Services logic; green in CI.
- [ ] Relevant acceptance-test IDs demonstrated or automated.
- [ ] Behaviour changes reflected in the docs.

---

## Severity guidance for findings
- **Blocker:** any §7 compliance violation, any crash path, retain cycle keeping a player/webview alive, duplicated/orphaned players, positive window level, sandbox-escaping entitlement.
- **Major:** leaked observer, missing teardown branch, multi-monitor reconcile gap, main-thread block.
- **Minor:** naming drift from the domain vocabulary, missing accessibility label, log hygiene.

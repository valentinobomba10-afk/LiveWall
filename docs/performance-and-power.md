# Performance & Power

Covers spec task 15. Goal: a live wallpaper should be nearly invisible in Activity Monitor when it isn't being seen.

---

## 1. Performance budget (MacBook targets)

| Metric | Target (1080p30 local video, single display) |
| --- | --- |
| CPU (app process) while visible | < 3–5% on Apple Silicon; hardware-decoded |
| CPU while paused/hidden | ~0% (player paused, no timer churn) |
| GPU | Rely on hardware video decode + Core Animation compositing; no per-frame CPU blits |
| Memory | One `AVQueuePlayer`/`WKWebView` per active display; released on stop |
| Energy Impact | "Low" when visible; negligible when paused |

Principles:
- **Never** draw with a `CADisplayLink`/timer loop for video — `AVPlayerLayer` and `WKWebView` composite themselves.
- **Never** run a player for a display that isn't showing anything.
- Pause aggressively; resume cheaply.

---

## 2. `PlaybackPolicy` — the single source of truth (pure, in Core)

Every "should we be playing?" decision goes through one pure function so it is unit-testable and there's no scattered ad-hoc logic.

```swift
public struct PlaybackConditions: Equatable, Sendable {
    public var userWantsPlaying: Bool     // user pressed play and a wallpaper is set
    public var isVisible: Bool            // at least one target display is awake & not covered
    public var onBattery: Bool
    public var lowPowerMode: Bool
    public var otherAppFullscreen: Bool
    public var screenLocked: Bool
    public var displayAsleep: Bool
}

public enum PlaybackPolicy {
    public static func shouldPlay(_ c: PlaybackConditions, settings: AppSettings) -> Bool {
        guard c.userWantsPlaying else { return false }
        if c.screenLocked            { return false }
        if c.displayAsleep           { return false }
        if !c.isVisible              { return false }
        if settings.pauseOnLowPowerMode    && c.lowPowerMode        { return false }
        if settings.pauseOnBattery         && c.onBattery           { return false }
        if settings.pauseWhenAppFullscreen && c.otherAppFullscreen  { return false }
        return true
    }
}
```

`WallpaperManager.evaluatePlaybackPolicy()` builds `PlaybackConditions` from `PowerMonitor` + visibility, calls `shouldPlay`, and drives each renderer:

```swift
private func evaluatePlaybackPolicy() {
    let want = PlaybackPolicy.shouldPlay(currentConditions(), settings: settings.settings)
    for (_, r) in renderers { want ? r.play() : r.pause() }
    playbackState = want ? .playing : .paused
}
```

Call it whenever any input changes: user actions, `PowerMonitor` publishers, display changes, window occlusion.

---

## 3. `PowerMonitor` — inputs & exact notifications

```swift
@MainActor
public final class PowerMonitor: ObservableObject {
    @Published public private(set) var isOnBattery = false
    @Published public private(set) var isLowPowerMode = false
    @Published public private(set) var isScreenLocked = false
    @Published public private(set) var isDisplayAsleep = false
    @Published public private(set) var isOtherAppFullscreen = false

    private var runLoopSource: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []

    public func start() {
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        refreshBattery()
        registerPowerSource()
        registerNotifications()
        refreshFullscreen()
    }
    public func stop() { /* remove observers, invalidate run-loop source */ }
}
```

### 3.1 Low Power Mode
```swift
NotificationCenter.default.addObserver(
  forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
    self?.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
}
```

### 3.2 Battery vs AC (IOKit)
```swift
import IOKit.ps
private func refreshBattery() {
    guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef] else { return }
    var onBattery = false
    for src in list {
        if let d = IOPSGetPowerSourceDescription(snap, src)?.takeUnretainedValue() as? [String: Any],
           let state = d[kIOPSPowerSourceStateKey] as? String {
            onBattery = (state == kIOPSBatteryPowerValue)
        }
    }
    isOnBattery = onBattery
}
// Live updates:
private func registerPowerSource() {
    let ctx = Unmanaged.passUnretained(self).toOpaque()
    guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
        guard let ctx else { return }
        let me = Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue()
        Task { @MainActor in me.refreshBattery() }
    }, ctx)?.takeRetainedValue() else { return }
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    runLoopSource = src
}
```

### 3.3 Screen lock / unlock (distributed notifications)
```swift
let dnc = DistributedNotificationCenter.default()
dnc.addObserver(forName: .init("com.apple.screenIsLocked"),   object: nil, queue: .main) { [weak self] _ in self?.isScreenLocked = true;  self?.notifyChanged() }
dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.isScreenLocked = false; self?.notifyChanged() }
```
> These names are stable and widely used but not formally documented. Treat as best-effort: if they ever stop firing, the sleep/wake path below still pauses playback. Do not gate correctness solely on them.

### 3.4 Display sleep / wake & system sleep (`NSWorkspace`)
```swift
let wsnc = NSWorkspace.shared.notificationCenter
wsnc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.isDisplayAsleep = true;  self?.notifyChanged() }
wsnc.addObserver(forName: NSWorkspace.screensDidWakeNotification,  object: nil, queue: .main) { [weak self] _ in self?.isDisplayAsleep = false; self?.notifyChanged() }
wsnc.addObserver(forName: NSWorkspace.willSleepNotification,       object: nil, queue: .main) { [weak self] _ in self?.isDisplayAsleep = true;  self?.notifyChanged() }
wsnc.addObserver(forName: NSWorkspace.didWakeNotification,         object: nil, queue: .main) { [weak self] _ in self?.isDisplayAsleep = false; self?.notifyChanged() }
```
On wake, `WallpaperManager` should also re-apply window `level` and re-order windows to back (some transitions perturb ordering).

### 3.5 Other-app fullscreen (best-effort)
Reliable detection of *another* app's fullscreen state has no clean public API. Use a heuristic and document the limitation:
```swift
private func refreshFullscreen() {
    // Heuristic: frontmost app owns a window at normal level covering a whole screen,
    // and the menu bar is auto-hidden. Combine NSWorkspace.frontmostApplication with
    // CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) bounds checks.
    // Fall back to `false` (don't pause) if uncertain — never pause on a false positive.
}
```
Recompute on `NSWorkspace.didActivateApplicationNotification` and `activeSpaceDidChangeNotification`. Because it's heuristic, bias toward *not* pausing when unsure so the wallpaper doesn't flicker off during normal use. This is the one policy input allowed to be approximate.

---

## 4. Visibility & occlusion

- **Window occlusion:** observe `NSWindow.didChangeOcclusionStateNotification` on each `DesktopWindow`; when `occlusionState` no longer contains `.visible`, treat that display as not visible and pause its renderer. This automatically pauses when a fullscreen/maximized app fully covers the desktop window on that display.
- **Space changes:** with `.canJoinAllSpaces`, the window is present on all Spaces, but occlusion still reports visibility per Space, so occlusion handles the fullscreen-on-one-display case for free.
- Prefer per-display pause: if display A is covered but B is not, pause A's renderer only.

```swift
NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
    object: window, queue: .main) { [weak self] _ in
        let visible = window.occlusionState.contains(.visible)
        self?.setDisplayVisible(displayID, visible)   // → evaluatePlaybackPolicy()
}
```

---

## 5. Resource lifecycle & the one-window invariant

- **One window + one renderer per display id.** Enforced by the `[CGDirectDisplayID: …]` dictionaries and `DesktopWindowController.install` tearing down any previous renderer.
- **Stop = full teardown.** `WallpaperManager.stop()` calls `close()` on every controller, which calls `renderer.teardown()` (releases `AVQueuePlayer`/`AVPlayerLooper`/`WKWebView`), then closes the window.
- **Pause ≠ teardown.** Pausing keeps the player/webview alive (cheap resume) but stops decode. Only tear down on stop, display disconnect, or app quit.
- **Preview teardown.** The Home preview player is torn down in `onDisappear` so it never lingers as a duplicate.
- **Quit:** `applicationWillTerminate` → `wallpaperManager.stop()` to release everything cleanly.

### Teardown checklist (both renderers)
- `AVQueuePlayer`: `pause()`, `removeAllItems()`, `looper.disableLooping()`, `playerLayer.player = nil`, `removeFromSuperlayer()`, invalidate KVO/notification observers, `stopAccessingSecurityScopedResource()`.
- `WKWebView`: `stopLoading()`, remove script message handler (avoids a strong ref cycle via `WKUserContentController`), `navigationDelegate = nil`, `loadHTMLString("")`, `removeFromSuperview()`, nil out.

---

## 6. Frame-rate & quality controls (best-effort, honest)

- **Frame-rate limit:** there is no public API to hard-cap an `AVPlayerLayer`'s output fps. Options: pick source assets that match, and use the setting to cap the *preview* and any future custom rendering. Document it as a hint, not a guarantee.
- **Video quality:** for YouTube, call `setPlaybackQuality`/`setPlaybackQualityRange` as a **hint** only (YouTube may ignore it). For local/direct, quality equals the file. Never manipulate streams to force quality.
- These honest limitations must be reflected in the README's "Known limitations."

---

## 7. What review will check (performance)

- No `Timer`/`DispatchSourceTimer`/`CVDisplayLink` driving video frames.
- Players are paused (not just hidden) when policy says stop.
- No duplicate players per display; no orphan windows after disconnect.
- `teardown` releases the heavy objects (verified by Instruments: allocations return to baseline after stop).
- Observers are removed in `stop`/`teardown` (no leaks, no zombie callbacks).

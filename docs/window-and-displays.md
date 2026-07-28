# Window & Display Management

Covers spec tasks 6 (borderless desktop window), 7 (multi-display), 8 (connect/disconnect/rearrange).

This is the highest-risk area for correctness. Follow it exactly.

---

## 1. The desktop-level window (`DesktopWindow`)

### 1.1 Requirements → implementation map (task 6)

| Requirement | Implementation |
| --- | --- |
| Covers the selected screen | `setFrame(screen.frame, display: true)` using **full** `frame`, not `visibleFrame` |
| No title bar | `styleMask = [.borderless]` |
| Cannot be moved | `isMovable = false`, `isMovableByWindowBackground = false` |
| Never becomes active/key | subclass overrides `canBecomeKey`/`canBecomeMain` → `false`; show with `orderFrontRegardless()` (never `makeKeyAndOrderFront`) |
| Not in the Dock | window is borderless (not miniaturizable) + app runs as `.accessory`; also `isExcludedFromWindowsMenu = true` |
| Not in Mission Control where possible | `collectionBehavior` = `.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone` |
| Stays at desktop level | `level = DesktopWindowLevel.value` (see §1.3) |
| Doesn't block clicks | `ignoresMouseEvents = true` |
| Doesn't cover menu bar/Dock incorrectly | at desktop level the menu bar & Dock draw *above* it automatically; use full `frame` and let the OS composite |

### 1.2 `DesktopWindow.swift`

```swift
import AppKit

/// Borderless, click-through, non-activating window pinned to the desktop layer.
final class DesktopWindow: NSWindow {

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        configure(for: screen)
    }

    private func configure(for screen: NSScreen) {
        level               = DesktopWindowLevel.value
        collectionBehavior  = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isMovable           = false
        isMovableByWindowBackground = false
        ignoresMouseEvents  = true          // clicks fall through to the real desktop/icons
        hasShadow           = false
        isExcludedFromWindowsMenu = true
        isReleasedWhenClosed = false        // we manage lifetime explicitly (avoid over-release crash)
        backgroundColor     = .black         // avoids white flash before first frame
        isOpaque            = true
        displaysWhenScreenProfileChanges = true
        tabbingMode         = .disallowed
        setFrame(screen.frame, display: false)
    }

    // Desktop wallpaper must never steal focus or key state.
    override var canBecomeKey: Bool  { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}
```

> **`isReleasedWhenClosed = false` is mandatory.** With the default `true`, calling `close()` releases the window while ARC still holds a reference → over-release crash. We own the lifetime via `DesktopWindowController`.

### 1.3 The window level — behind icons, above the desktop picture

macOS orders desktop layers as: **desktop picture** < **desktop icons** < normal windows. To sit *behind* the desktop icons (icons stay visible on top of your video — the usual, desired behaviour), use the desktop-picture level:

```swift
enum DesktopWindowLevel {
    /// Behind desktop icons (icons remain visible). This is the default.
    static let value = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))

    /// Optional alternative: draw *over* the icons (hides them). Not default.
    static let aboveIcons = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
}
```

- **Do not** use `.normal`, `.floating`, or any positive level — those would cover the user's apps.
- **Do not** use `kCGDesktopIconWindowLevel` itself for the default; that hides icons. Only expose it behind a setting if the user asks for "hide desktop icons."
- Recheck the level in `windowDidChangeScreen`/after wake — some OS transitions can reset ordering; re-apply `level` and call `orderBack(nil)` / `orderFrontRegardless()`.

### 1.4 Hosting the renderer's view

The window's `contentView` is a plain layer-backed container; the renderer's `contentView` is installed into it and pinned with autoresizing so it tracks resolution changes.

```swift
final class DesktopContentView: NSView {
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // belt-and-suspenders click-through
}
```

---

## 2. `DesktopWindowController` — one per display

Owns exactly one `DesktopWindow` + the renderer installed in it. `WallpaperManager` keeps a `[CGDirectDisplayID: DesktopWindowController]`, guaranteeing **one window per display**.

```swift
@MainActor
final class DesktopWindowController {
    let displayID: CGDirectDisplayID
    private let window: DesktopWindow
    private let container: DesktopContentView
    private(set) var renderer: WallpaperRenderer?

    init(displayID: CGDirectDisplayID, screen: NSScreen) {
        self.displayID = displayID
        self.window = DesktopWindow(screen: screen)
        self.container = DesktopContentView(frame: screen.frame)
        container.wantsLayer = true
        window.contentView = container
    }

    func install(_ renderer: WallpaperRenderer) {
        // Remove any previous renderer first — never stack two players in one window.
        if let old = self.renderer { old.teardown(); old.contentView.removeFromSuperview() }
        self.renderer = renderer
        let v = renderer.contentView
        v.frame = container.bounds
        v.autoresizingMask = [.width, .height]
        container.addSubview(v)
    }

    func show() { window.orderBack(nil) }        // place at back of desktop layer
    func hide() { window.orderOut(nil) }

    func updateFrame(to screen: NSScreen) {
        window.setFrame(screen.frame, display: true)
        container.frame = window.contentView?.bounds ?? screen.frame
    }

    /// Full teardown — call on stop or when the display disconnects.
    func close() {
        renderer?.teardown()
        renderer?.contentView.removeFromSuperview()
        renderer = nil
        window.contentView = nil
        window.orderOut(nil)
        window.close()             // safe because isReleasedWhenClosed == false
    }
}
```

**Invariants (checked in review):**
- A controller is created once per display id and stored in the manager's dictionary.
- `install` tears down the previous renderer before adding a new one.
- `close` always tears down the renderer (releases `AVPlayer`/`WKWebView`) before ordering out.

---

## 3. Multi-display support (task 7)

### 3.1 Stable identity
`NSScreen` objects are transient; the **`CGDirectDisplayID` is the stable key**. Extract it once and key everything off it:

```swift
extension NSScreen {
    var displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return deviceDescription[key] as? CGDirectDisplayID
    }
}
```

### 3.2 `ScreenDisplayManager`

```swift
@MainActor
final class ScreenDisplayManager: DisplayManaging {
    private(set) var displays: [DisplayInfo] = []
    var onChange: (([DisplayInfo]) -> Void)?
    private var debounce: Task<Void, Never>?

    func start() {
        refresh()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func stop() { NotificationCenter.default.removeObserver(self); debounce?.cancel() }

    @objc private func screensChanged() {
        // Coalesce bursts (an arrangement change fires several notifications).
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.refresh()
            self.onChange?(self.displays)
        }
    }

    private func refresh() {
        displays = NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            return DisplayInfo(
                id: id,
                localizedName: screen.localizedName,
                frame: screen.frame,
                backingScaleFactor: screen.backingScaleFactor,
                isMain: screen == NSScreen.main)
        }
    }

    func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == id }
    }
    func displayInfo(for id: CGDirectDisplayID) -> DisplayInfo? {
        displays.first { $0.id == id }
    }
}
```

> `NSScreen.localizedName` is available on macOS 10.15+. Prefer it over parsing IOKit for display names.

### 3.3 Applying to selected displays
`WallpaperManager.reconcileWindows(for:)` computes the **target set** of display IDs from `DisplaySelection`, then diffs against `controllers.keys`:

```swift
private func targetDisplayIDs(for selection: DisplaySelection) -> Set<CGDirectDisplayID> {
    switch selection {
    case .allDisplays:      return Set(displayManager.displays.map(\.id))
    case .mainDisplay:      return Set(displayManager.displays.filter(\.isMain).map(\.id))
    case .specific(let s):  return Set(s.map(\.value)).intersection(displayManager.displays.map(\.id))
    }
}

private func reconcileWindows(for selection: DisplaySelection) {
    let target = targetDisplayIDs(for: selection)
    let current = Set(controllers.keys)

    for id in current.subtracting(target) {           // remove
        controllers[id]?.close(); controllers[id] = nil
        renderers[id]?.teardown(); renderers[id] = nil
    }
    for id in target.subtracting(current) {           // add
        guard let item = activeItem, let screen = displayManager.screen(for: id) else { continue }
        let controller = DesktopWindowController(displayID: id, screen: screen)
        let renderer = try? rendererFactory.makeRenderer(for: item)
        if let renderer { attach(renderer, to: controller, id: id) }
    }
    for id in target.intersection(current) {          // update frame (resolution/arrangement)
        if let screen = displayManager.screen(for: id) { controllers[id]?.updateFrame(to: screen) }
    }
    evaluatePlaybackPolicy()
}
```

Each display gets its **own** renderer instance and its own `AVPlayer`/`WKWebView`. (Sharing one player across windows is not supported — an `AVPlayerLayer` can only belong to one layer tree.)

---

## 4. Reacting to display changes (task 8)

All driven by `NSApplication.didChangeScreenParametersNotification` (debounced in §3.2). On each change, `WallpaperManager.handleDisplaysChanged` runs:

| Event | Behaviour |
| --- | --- |
| **Display connected** | If selection is `.allDisplays` (or `.specific` includes it), create a controller+renderer for the new id and start it. |
| **Display disconnected** | `close()` its controller (tears down player/webview), remove from dictionaries. Never leave an orphan window bound to a gone display. |
| **Resolution / scale change** | `updateFrame(to:)` on the existing controller; `AVPlayerLayer`/`WKWebView` resize via autoresizing mask. |
| **Rearrangement / main display change** | Recompute frames for all controllers; if selection is `.mainDisplay`, move the wallpaper to the new main. |
| **All external displays gone, laptop closed (clamshell)** | Reconcile to remaining screens; if none, stop cleanly (no crash). |

```swift
private func handleDisplaysChanged(_ displays: [DisplayInfo]) {
    guard isRunning else { return }
    reconcileWindows(for: currentSelection)   // add/remove/update all in one pass
}
```

**Edge cases to handle (and test — see acceptance tests DISP-1…DISP-6):**
- A display id that disappears and reappears (cable reseat) must not leak the old controller.
- `displayManager.screen(for:)` may briefly return `nil` mid-transition — guard every unwrap; do not force-unwrap `NSScreen`.
- Wake-from-sleep fires screen-parameter changes; re-apply window `level` and re-order to back after reconciling.
- Never assume `NSScreen.main` exists during a transition; treat `nil` as "no displays, stop."

---

## 5. Window ordering, Spaces & fullscreen interaction

- `.canJoinAllSpaces` makes the wallpaper appear on every Space, so switching Spaces keeps it visible.
- `.stationary` stops the window from being swept by Mission Control / Exposé animations.
- When another app enters **native fullscreen**, that app gets its own Space; the desktop-level window is simply not visible there — no action needed for correctness. The optional "pause when another app is fullscreen" behaviour is a *power* optimization handled in [performance-and-power.md](performance-and-power.md), not a window-ordering concern.
- Do **not** try to raise the window above fullscreen apps. That is neither possible nor desirable.

---

## 6. What NOT to do (common wallpaper-app bugs)

- ❌ Using `visibleFrame` → leaves a gap where the menu bar/Dock are.
- ❌ `makeKeyAndOrderFront(_:)` → steals focus; use `orderBack`/`orderFrontRegardless`.
- ❌ Positive window level → covers the user's apps.
- ❌ Reusing one `AVPlayerLayer`/renderer across multiple windows → blank or flickering secondary displays.
- ❌ Forgetting `ignoresMouseEvents = true` → users can't click desktop icons or right-click the desktop.
- ❌ `isReleasedWhenClosed = true` → crash on `close()`.
- ❌ Keying windows by `NSScreen` object identity → breaks on every screen-parameter change; key by `CGDirectDisplayID`.

import AppKit

/// Borderless, click-through, non-activating window pinned to the desktop layer.
/// This is the "overlay" that stands in for a real animated wallpaper — macOS has
/// no public API to replace the system desktop picture with video.
final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Called with `true` when the window is at least partially visible, `false` when
    /// fully covered (e.g. a maximized/fullscreen app) — used to pause hidden playback.
    var onOcclusionChange: ((Bool) -> Void)?

    init(screen: NSScreen) {
        // Note: the `screen:` variant is a convenience initializer; a subclass must
        // call the designated initializer (without `screen:`). We position via setFrame.
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        // Just above the system desktop picture, still below the desktop icons.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isMovable = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = true          // clicks fall through to the desktop / icons
        isOpaque = true
        backgroundColor = .black           // avoids a white flash before the first frame
        hasShadow = false
        isReleasedWhenClosed = false       // we manage lifetime; avoids over-release crash
        isExcludedFromWindowsMenu = true
        setFrame(screen.frame, display: false)
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification, object: self)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func applyColorControls(brightness: Double, saturation: Double) {
        guard let layer = contentView?.layer else { return }
        let filter = CIFilter(name: "CIColorControls")
        filter?.setValue(brightness - 1, forKey: kCIInputBrightnessKey)
        filter?.setValue(saturation, forKey: kCIInputSaturationKey)
        layer.filters = filter.map { [$0] }
    }

    @objc private func occlusionChanged() {
        onOcclusionChange?(occlusionState.contains(.visible))
    }
}

import AppKit

/// Tracks the connected screens and notifies observers when the arrangement changes
/// (connect / disconnect / resolution / rearrange).
final class DisplayObserver {
    private(set) var screens: [NSScreen] = NSScreen.screens
    private var handlers: [() -> Void] = []

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.screens = NSScreen.screens
                self.handlers.forEach { $0() }
        }
    }

    /// Register a callback fired (on the main queue) whenever the display set changes.
    func addHandler(_ handler: @escaping () -> Void) { handlers.append(handler) }

    /// Stable identifier for a screen; use this as a key, never the NSScreen object.
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func name(for screen: NSScreen) -> String { screen.localizedName }
}

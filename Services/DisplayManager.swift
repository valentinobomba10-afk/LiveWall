import AppKit

@MainActor final class DisplayManager: ObservableObject {
    @Published private(set) var displays: [NSScreen] = NSScreen.screens
    init() { NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.displays = NSScreen.screens } }
    func displayName(_ screen: NSScreen) -> String { screen.localizedName }
    func stableID(_ screen: NSScreen) -> String { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? screen.localizedName }
}

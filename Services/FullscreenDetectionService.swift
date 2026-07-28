import AppKit

@MainActor final class FullscreenDetectionService: ObservableObject {
    @Published private(set) var anotherAppIsFullscreen = false
    func refresh() {
        // Public API limitation: NSWorkspace can identify the frontmost app, but cannot
        // reliably inspect another app's private fullscreen state. Keep this conservative.
        anotherAppIsFullscreen = NSWorkspace.shared.frontmostApplication?.processIdentifier != NSRunningApplication.current.processIdentifier && NSApp.isActive == false
    }
}

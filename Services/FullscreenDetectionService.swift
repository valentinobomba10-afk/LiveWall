import AppKit

@MainActor final class FullscreenDetectionService: ObservableObject {
    @Published private(set) var anotherAppIsFullscreen = false

    /// True only when the frontmost *other* app has a window covering an entire
    /// display (a real fullscreen app or game).
    ///
    /// The old check merely asked "is another app focused?", which is true nearly
    /// all the time for a wallpaper app — so the wallpaper paused and resumed on
    /// every focus change and looked glitchy. This inspects actual window bounds
    /// (window metadata needs no screen-recording permission) and only trips on a
    /// window that fills a whole screen, including the menu-bar area.
    func refresh() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != NSRunningApplication.current.processIdentifier else {
            anotherAppIsFullscreen = false
            return
        }
        let pid = front.processIdentifier
        let displaySizes = NSScreen.screens.map { $0.frame.size }

        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        for window in list {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let w = bounds["Width"] as? Double, let h = bounds["Height"] as? Double
            else { continue }

            // A fullscreen window matches a display's full width AND height.
            // (A merely maximized window is shorter by the menu bar.)
            for size in displaySizes where abs(w - size.width) < 4 && abs(h - size.height) < 4 {
                anotherAppIsFullscreen = true
                return
            }
        }
        anotherAppIsFullscreen = false
    }
}

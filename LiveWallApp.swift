import AppKit
import Foundation

@main
struct LiveWallApp {
    static func main() {
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 128 * 1024 * 1024,
                                   diskPath: "LiveWallPosters")
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

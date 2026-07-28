import AppKit
import SwiftUI

@MainActor final class WallpaperWindowController {
    private let window: WallpaperWindow
    init(screen: NSScreen) { window = WallpaperWindow(screen: screen) }
    func show(item: WallpaperItem) {
        window.contentView = NSHostingView(rootView: WallpaperPreviewView(item: item, isWallpaper: true))
        window.orderFrontRegardless()
    }
    func play() { (window.contentView as? NSHostingView<WallpaperPreviewView>)?.rootView.play() }
    func pause() { (window.contentView as? NSHostingView<WallpaperPreviewView>)?.rootView.pause() }
    func close() { window.orderOut(nil); window.contentView = nil }
}

import AppKit
import AVFoundation

protocol WallpaperRenderer: AnyObject {
    func load(source: WallpaperSource) async throws
    func play(); func pause(); func stop(); func setMuted(_ muted: Bool); func setVolume(_ volume: Float)
}
protocol WallpaperManaging: AnyObject {
    func setWallpaper(_ item: WallpaperItem, on displays: [NSScreen]) async throws
    func stopWallpaper(); func pauseWallpaper(); func resumeWallpaper()
}

@MainActor final class WallpaperManager: ObservableObject, WallpaperManaging {
    @Published private(set) var activeItem: WallpaperItem?
    @Published private(set) var isPlaying = false
    private var controllers: [WallpaperWindowController] = []
    func setWallpaper(_ item: WallpaperItem, on displays: [NSScreen]) async throws {
        stopWallpaper(); guard !displays.isEmpty else { throw NSError(domain: "LiveWall", code: 1, userInfo: [NSLocalizedDescriptionKey: "Select at least one display."]) }
        activeItem = item
        for display in displays { let controller = WallpaperWindowController(screen: display); controller.show(item: item); controllers.append(controller) }
        isPlaying = true
    }
    func stopWallpaper() { controllers.forEach { $0.close() }; controllers.removeAll(); activeItem = nil; isPlaying = false }
    func pauseWallpaper() { controllers.forEach { $0.pause() }; isPlaying = false }
    func resumeWallpaper() { controllers.forEach { $0.play() }; isPlaying = true }
}

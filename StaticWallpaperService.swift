import AppKit
import Foundation

/// Writes a still frame beneath the live overlay so the selected look remains
/// visible whenever LiveWall is paused or not running.
@MainActor enum StaticWallpaperService {
    static func applyStill(from item: LibraryItem, to displayIDs: Set<CGDirectDisplayID>) async {
        guard let kind = item.wallpaperKind() else { return }
        if case let .localImage(source) = kind {
            setDesktopImage(source, displayIDs: displayIDs)
            return
        }
        guard case let .localVideo(source) = kind, let image = await ThumbnailGenerator.frame(url: source) else { return }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LiveWall/StillWallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent("\(item.id.uuidString).jpg")
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else { return }
        do {
            try jpeg.write(to: output, options: .atomic)
            setDesktopImage(output, displayIDs: displayIDs)
        } catch { NSLog("[LiveWall] Could not set static wallpaper: \(error.localizedDescription)") }
    }

    private static func setDesktopImage(_ url: URL, displayIDs: Set<CGDirectDisplayID>) {
        for screen in NSScreen.screens where displayIDs.contains(DisplayObserver.displayID(for: screen)) {
            do { try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:]) }
            catch { NSLog("[LiveWall] Could not set picture background: \(error.localizedDescription)") }
        }
    }
}

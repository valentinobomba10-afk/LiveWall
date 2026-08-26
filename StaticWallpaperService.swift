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

    private static let originalKey = "liveWallOriginalDesktop"

    /// Records the user's real desktop picture per display, once, before LiveWall
    /// ever overwrites it with a still — so "Turn Off" can put it back.
    static func saveOriginalIfNeeded() {
        var saved = UserDefaults.standard.dictionary(forKey: originalKey) as? [String: String] ?? [:]
        for screen in NSScreen.screens {
            let id = String(DisplayObserver.displayID(for: screen))
            guard saved[id] == nil, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { continue }
            // Never record one of our own stills as the "original".
            if !url.path.contains("LiveWall/StillWallpapers") { saved[id] = url.path }
        }
        UserDefaults.standard.set(saved, forKey: originalKey)
    }

    /// Restores the saved original desktop picture on every display.
    static func restoreOriginal() {
        let saved = UserDefaults.standard.dictionary(forKey: originalKey) as? [String: String] ?? [:]
        for screen in NSScreen.screens {
            let id = String(DisplayObserver.displayID(for: screen))
            guard let path = saved[id] else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [:])
        }
    }

    private static func setDesktopImage(_ url: URL, displayIDs: Set<CGDirectDisplayID>) {
        saveOriginalIfNeeded()   // capture the true original before overwriting it
        for screen in NSScreen.screens where displayIDs.contains(DisplayObserver.displayID(for: screen)) {
            do { try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:]) }
            catch { NSLog("[LiveWall] Could not set picture background: \(error.localizedDescription)") }
        }
    }
}

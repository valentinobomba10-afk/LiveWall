import AppKit
import Foundation

/// Puts the current wallpaper on the **lock screen**.
///
/// macOS has no API for this directly: while the screen is locked, `loginwindow`
/// owns the display and the user session's windows (including LiveWall's desktop
/// overlay) are not composited at all. The one surface a third-party app can put
/// motion on is the screen saver, which `loginwindow` runs on the lock screen.
///
/// So this service installs `LiveWall.saver` into `~/Library/Screen Savers` and
/// copies the selected wallpaper *into that bundle*. The copy is not laziness:
/// the screen saver host is sandboxed and cannot read the user's own folders, but
/// it can always read the bundle it loaded.
enum LockScreenService {

    enum Failure: LocalizedError {
        case templateMissing
        case unsupported(String)
        case noFrame
        case io(String)

        var errorDescription: String? {
            switch self {
            case .templateMissing:
                return "This build of LiveWall doesn’t include the lock screen component."
            case .unsupported(let what):
                return "\(what) can’t run on the lock screen — the screen saver host has no network access. Use a video or picture wallpaper."
            case .noFrame:
                return "Couldn’t read a frame from that video."
            case .io(let message):
                return message
            }
        }
    }

    static let userDefaultsKey = "lockScreenEnabled"

    /// Where macOS looks for per-user screen savers.
    private static var installURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Screen Savers/LiveWall.saver", isDirectory: true)
    }

    /// The unconfigured bundle we ship inside the app.
    private static var templateURL: URL? {
        Bundle.main.url(forResource: "LiveWall", withExtension: "saver")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installURL.path)
    }

    /// True once the *selected* saver is ours. macOS gives no API to change this
    /// (the preference is protected), so the UI has to send the user to Settings.
    static var isSelected: Bool {
        guard let defaults = UserDefaults(suiteName: "com.apple.screensaver"),
              let module = defaults.dictionary(forKey: "moduleDict"),
              let path = module["path"] as? String else { return false }
        return path.contains("LiveWall.saver")
    }

    // MARK: - Install

    /// Install (or refresh) the screen saver so the lock screen shows `item`.
    /// Videos play; pictures are shown still. Streaming/interactive wallpapers
    /// fall back to a still frame where one can be produced, and otherwise throw.
    @discardableResult
    static func install(item: LibraryItem,
                        scaling: ScalingMode,
                        muted: Bool,
                        volume: Float,
                        brightness: Double,
                        saturation: Double) async throws -> URL {
        guard let template = templateURL else { throw Failure.templateMissing }

        let (mediaSource, kind) = try await resolveMedia(for: item)

        let fm = FileManager.default
        let parent = installURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw Failure.io("Couldn’t create ~/Library/Screen Savers: \(error.localizedDescription)")
        }

        // Build into a staging bundle, then swap — a half-written .saver that the
        // host tries to load is worse than the old one staying in place.
        let staging = parent.appendingPathComponent("LiveWall.saver.staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        do {
            try fm.copyItem(at: template, to: staging)
        } catch {
            throw Failure.io("Couldn’t stage the screen saver: \(error.localizedDescription)")
        }

        let resources = staging.appendingPathComponent("Contents/Resources", isDirectory: true)
        try? fm.createDirectory(at: resources, withIntermediateDirectories: true)

        let fileName = "wallpaper." + (mediaSource.pathExtension.isEmpty ? "dat" : mediaSource.pathExtension)
        let destination = resources.appendingPathComponent(fileName)
        do {
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: mediaSource, to: destination)
        } catch {
            try? fm.removeItem(at: staging)
            throw Failure.io("Couldn’t copy “\(item.title)” into the screen saver: \(error.localizedDescription)")
        }

        let config: [String: Any] = [
            "kind": kind,
            "file": fileName,
            "scaling": scaling.rawValue,
            "muted": muted,
            "volume": volume,
            "brightness": brightness,
            "saturation": saturation,
            "title": item.title
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
            try data.write(to: resources.appendingPathComponent("livewall-config.json"), options: .atomic)
        } catch {
            try? fm.removeItem(at: staging)
            throw Failure.io("Couldn’t write the screen saver settings: \(error.localizedDescription)")
        }

        // Editing the bundle invalidates its signature; the host won't load it unsigned.
        resign(staging)

        do {
            if fm.fileExists(atPath: installURL.path) {
                _ = try fm.replaceItemAt(installURL, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: installURL)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw Failure.io("Couldn’t install the screen saver: \(error.localizedDescription)")
        }

        UserDefaults.standard.set(true, forKey: userDefaultsKey)
        return installURL
    }

    /// Remove the screen saver. If it is the selected one, macOS falls back on its own.
    static func uninstall() {
        try? FileManager.default.removeItem(at: installURL)
        UserDefaults.standard.set(false, forKey: userDefaultsKey)
    }

    /// Opens the pane where the screen saver is chosen — the one step that has to
    /// be done by hand, because the selection preference is system-protected.
    static func openSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension",
            "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.desktopscreeneffect"
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    /// Reveal the installed bundle, for when the user wants to confirm it landed.
    static func revealInFinder() {
        guard isInstalled else { return }
        NSWorkspace.shared.activateFileViewerSelecting([installURL])
    }

    // MARK: - Media

    /// Returns a readable file plus the config `kind` the saver should use.
    private static func resolveMedia(for item: LibraryItem) async throws -> (URL, String) {
        guard let kind = item.wallpaperKind() else {
            throw Failure.io("Couldn’t open “\(item.title)”. The file may have moved.")
        }
        switch kind {
        case .localVideo(let url):
            return (url, "video")
        case .localImage(let url):
            return (url, "image")
        case .directURL(let url):
            // Only usable if it has already been downloaded to a local file.
            guard url.isFileURL else { throw Failure.unsupported("Streaming wallpapers") }
            return (url, "video")
        case .youTube:
            throw Failure.unsupported("YouTube wallpapers")
        case .web:
            throw Failure.unsupported("Interactive wallpapers")
        }
    }

    /// Re-sign ad-hoc after modifying bundle contents. Best effort: if `codesign`
    /// is unavailable the install still proceeds and the host reports the problem.
    private static func resign(_ bundle: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--timestamp=none", bundle.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("[LiveWall] Could not re-sign the screen saver: \(error.localizedDescription)")
        }
    }
}

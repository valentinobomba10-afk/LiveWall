import AppKit
import Foundation

/// Downloads a LiveWall release and swaps it in for the running copy, then
/// relaunches — so "Download Update" actually updates the app instead of just
/// opening a browser.
///
/// The swap can't happen while the bundle is running, so it's handed to a small
/// detached shell script that waits for this process to quit, replaces the
/// bundle, and reopens it. This is the same shape Sparkle uses; it is kept
/// deliberately small and readable.
@MainActor
enum UpdateInstaller {

    /// Downloads `asset`, extracts it, and installs it over the running app.
    /// On any failure it falls back to opening the download in the browser, so
    /// the user is never left with no path forward.
    static func installUpdate(from asset: URL, fallback: URL) {
        Task {
            do {
                try await run(asset: asset)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t install automatically"
                alert.informativeText = "\(error.localizedDescription)\n\nOpening the download in your browser instead."
                alert.runModal()
                NSWorkspace.shared.open(fallback)
            }
        }
    }

    private static func run(asset: URL) async throws {
        // 1. Download the zip.
        let (tempZip, response) = try await URLSession.shared.download(from: asset)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Err.download
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("LiveWallUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("LiveWall.zip")
        try? fm.removeItem(at: zip)
        try fm.moveItem(at: tempZip, to: zip)

        // 2. Extract with ditto (handles .app bundles correctly).
        let extract = work.appendingPathComponent("extract")
        try fm.createDirectory(at: extract, withIntermediateDirectories: true)
        try shell("/usr/bin/ditto", ["-x", "-k", zip.path, extract.path])

        // 3. Find the new LiveWall.app.
        guard let newApp = try fm.contentsOfDirectory(at: extract, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw Err.noApp }

        // 4. Confirm before replacing the running app.
        let current = Bundle.main.bundleURL
        let alert = NSAlert()
        alert.messageText = "Install the update now?"
        alert.informativeText = "LiveWall will quit, update itself, and reopen."
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // 5. Hand the swap to a detached script and quit. The script waits for
        //    this pid to exit, replaces the bundle, strips the download
        //    quarantine, and reopens the app.
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = work.appendingPathComponent("swap.sh")
        let body = """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        /bin/rm -rf "\(current.path)"
        /usr/bin/ditto "\(newApp.path)" "\(current.path)"
        /usr/bin/xattr -dr com.apple.quarantine "\(current.path)" 2>/dev/null
        /usr/bin/open "\(current.path)"
        /bin/rm -rf "\(work.path)"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try shell("/bin/chmod", ["+x", script.path])

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [script.path]
        try task.run()   // detached: it outlives us on purpose

        NSApp.terminate(nil)
    }

    @discardableResult
    private static func shell(_ launchPath: String, _ args: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw Err.command(launchPath) }
        return task.terminationStatus
    }

    enum Err: LocalizedError {
        case download, noApp, command(String)
        var errorDescription: String? {
            switch self {
            case .download:        return "The download failed."
            case .noApp:           return "The update didn’t contain a LiveWall app."
            case .command(let c):  return "A step failed (\(c))."
            }
        }
    }
}

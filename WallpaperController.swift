import AppKit

/// Owns the desktop overlay windows and their renderers — exactly one per display.
/// Supports a *different* wallpaper per display, and pauses per-display for power
/// policy (battery/Low Power/lock/sleep) and window occlusion.
final class WallpaperController {
    struct Request {
        var kind: WallpaperKind
        var muted: Bool
        var volume: Float
        var loops: Bool
        var scaling: ScalingMode
        var displayIDs: Set<CGDirectDisplayID>   // empty == main display only
    }

    private(set) var isRunning = false
    private(set) var isPaused = false            // user-intent pause (play/pause button)

    /// Fired after the applied set changes — used to persist state for restore.
    var onChange: (() -> Void)?

    private var requests: [CGDirectDisplayID: Request] = [:]      // per-display content
    private var windows: [CGDirectDisplayID: DesktopWindow] = [:]
    private var renderers: [CGDirectDisplayID: WallpaperRenderer] = [:]
    private var covered: Set<CGDirectDisplayID> = []              // occluded displays
    private var powerPaused = false                              // battery / lock / sleep policy
    private var externalPaused = false                           // fullscreen/game policy
    private var visualBrightness = 1.0
    private var visualSaturation = 1.0
    private var pointerTimer: Timer?

    private let displays: DisplayObserver

    init(displays: DisplayObserver) {
        self.displays = displays
        displays.addHandler { [weak self] in self?.reconcile() }
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.sendPointerPosition() }
    }

    deinit { pointerTimer?.invalidate() }

    /// Apply `request` to its target displays, leaving other displays' wallpapers running.
    /// (Set one display at a time to give each screen a different wallpaper.)
    func setWallpaper(_ request: Request) {
        for id in resolveTargets(request.displayIDs) {
            var perDisplay = request
            perDisplay.displayIDs = [id]
            requests[id] = perDisplay
            removeWindow(id)          // replace any existing content on this display
            installWindow(id)
        }
        isRunning = !requests.isEmpty
        isPaused = false
        onChange?()
    }

    func stop() {
        for id in Array(windows.keys) { removeWindow(id) }
        requests.removeAll()
        covered.removeAll()
        isRunning = false
        isPaused = false
        onChange?()
    }

    func stop(displayID id: CGDirectDisplayID) {
        removeWindow(id)
        requests[id] = nil
        isRunning = !requests.isEmpty
        onChange?()
    }

    func play()  { isPaused = false; applyPlaybackState() }
    func pause() { isPaused = true;  applyPlaybackState() }

    func setMuted(_ m: Bool)   { for id in requests.keys { requests[id]?.muted = m };  renderers.values.forEach { $0.setMuted(m) } }
    func setVolume(_ v: Float)  { for id in requests.keys { requests[id]?.volume = v }; renderers.values.forEach { $0.setVolume(v) } }
    func setScaling(_ s: ScalingMode) { for id in requests.keys { requests[id]?.scaling = s }; renderers.values.forEach { $0.setScaling(s) } }
    func setColorControls(brightness: Double, saturation: Double) {
        visualBrightness = brightness
        visualSaturation = saturation
        for window in windows.values { window.applyColorControls(brightness: brightness, saturation: saturation) }
    }

    /// Power policy hook — pause/resume everything for battery/Low Power/lock/sleep.
    func setPowerPaused(_ paused: Bool) {
        guard powerPaused != paused else { return }
        powerPaused = paused
        applyPlaybackState()
    }

    func setExternalPaused(_ paused: Bool) {
        guard externalPaused != paused else { return }
        externalPaused = paused
        applyPlaybackState()
    }

    // MARK: - Persistence (restore on launch)

    private struct Persisted: Codable {
        var type: String; var value: String; var displayID: UInt32
        var muted: Bool; var volume: Float; var loops: Bool; var scaling: String
    }

    func snapshotData() -> Data? {
        let items: [Persisted] = requests.map { id, r in
            let type: String, value: String
            switch r.kind {
            case .localVideo(let u): type = "local";   value = u.path
            case .localImage(let u): type = "image";   value = u.path
            case .directURL(let u):  type = "direct";  value = u.absoluteString
            case .youTube(let vid):  type = "youtube"; value = vid
            case .web(let url):      type = "web";     value = url.absoluteString
            }
            return Persisted(type: type, value: value, displayID: id,
                             muted: r.muted, volume: r.volume, loops: r.loops, scaling: r.scaling.rawValue)
        }
        return try? JSONEncoder().encode(items)
    }

    func restore(_ data: Data) {
        guard let items = try? JSONDecoder().decode([Persisted].self, from: data) else { return }
        for p in items {
            let kind: WallpaperKind
            switch p.type {
            case "local":
                let url = URL(fileURLWithPath: p.value)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                kind = .localVideo(url)
            case "direct":
                guard let url = URL(string: p.value) else { continue }
                if url.host?.contains("drive") == true,
                   !MovieCatalog.driveMovies.contains(where: { $0.urlString == p.value }) {
                    // Do not restore movies removed from the verified catalog.
                    // Old Drive entries can return quota/error HTML forever and
                    // otherwise leave users with a black desktop after updating.
                    continue
                }
                kind = .directURL(url)
            case "image":
                let url = URL(fileURLWithPath: p.value)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                kind = .localImage(url)
            case "youtube":
                kind = .youTube(p.value)
            case "web":
                guard let url = URL(string: p.value) else { continue }
                guard url.host?.hasSuffix("1flex.org") != true else { continue }
                kind = .web(url)
            default:
                continue
            }
            setWallpaper(Request(kind: kind, muted: p.muted, volume: p.volume, loops: p.loops,
                                 scaling: ScalingMode(rawValue: p.scaling) ?? .fill, displayIDs: [p.displayID]))
        }
    }

    // MARK: - Playback gating

    private var pauseWhenHidden: Bool { UserDefaults.standard.bool(forKey: "pauseWhenHidden") } // opt-in, default false
    private func shouldPlay(_ id: CGDirectDisplayID) -> Bool {
        if isPaused || powerPaused || externalPaused { return false }
        // NSWindow occlusion is not trustworthy for a desktop-level window:
        // Finder's own desktop window is reported as covering LiveWall, which
        // can pause every wallpaper permanently. Fullscreen and power pausing
        // are handled by their dedicated, reliable policies instead.
        return true
    }
    private func applyPlaybackState() {
        for (id, r) in renderers { shouldPlay(id) ? r.play() : r.pause() }
    }

    /// Tracks the cursor without receiving mouse clicks, so interactive wallpapers
    /// respond while the normal desktop remains completely usable.
    /// Only interactive (web) wallpapers use the pointer. Skip the 30 fps work
    /// entirely for ordinary video/image wallpapers — the common case.
    private var hasInteractiveWallpaper: Bool {
        requests.values.contains { if case .web = $0.kind { return true } else { return false } }
    }

    private func sendPointerPosition() {
        guard !windows.isEmpty, hasInteractiveWallpaper else { return }
        let mouse = NSEvent.mouseLocation
        for (id, window) in windows {
            let frame = window.frame
            guard frame.contains(mouse) else { renderers[id]?.setPointer(nil); continue }
            let point = CGPoint(x: (mouse.x - frame.minX) / frame.width * 2 - 1,
                                y: (mouse.y - frame.minY) / frame.height * 2 - 1)
            renderers[id]?.setPointer(point)
        }
    }
    private func setCovered(_ id: CGDirectDisplayID, _ isCovered: Bool) {
        // The control window itself sits above the desktop overlay. AppKit then
        // reports the wallpaper as occluded, which used to pause a newly chosen
        // movie the instant the user pressed “Set as Background”. Keep playback
        // active while LiveWall is frontmost; occlusion pausing is only for
        // other applications covering the desktop.
        let coveredByLiveWall = isCovered && NSApp.isActive && NSApp.windows.contains {
            $0.isVisible && !($0 is DesktopWindow)
        }
        if isCovered && !coveredByLiveWall { covered.insert(id) } else { covered.remove(id) }
        if let r = renderers[id] { shouldPlay(id) ? r.play() : r.pause() }
    }

    // MARK: - Window lifecycle

    private func installWindow(_ id: CGDirectDisplayID) {
        guard windows[id] == nil, let screen = screen(for: id), let request = requests[id] else { return }
        let window = DesktopWindow(screen: screen)
        window.onOcclusionChange = { [weak self] visible in self?.setCovered(id, !visible) }
        let container = NSView(frame: screen.frame)
        container.wantsLayer = true
        window.contentView = container
        let renderer = makeRenderer(for: request)
        renderer.view.frame = container.bounds
        renderer.view.autoresizingMask = [.width, .height]
        container.addSubview(renderer.view)
        addWatermark(to: container, screen: screen)
        window.applyColorControls(brightness: visualBrightness, saturation: visualSaturation)
        windows[id] = window
        renderers[id] = renderer
        window.orderFrontRegardless()
        renderer.start()
        if !shouldPlay(id) { renderer.pause() }
    }

    /// A small "LiveWall" badge in the bottom-right of the live wallpaper itself,
    /// so the branding sits on the desktop, not just in the control window.
    private func addWatermark(to container: NSView, screen: NSScreen) {
        let badge = NSView()
        badge.wantsLayer = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        badge.layer?.cornerRadius = 22
        badge.layer?.cornerCurve = .continuous

        let mark = NSView()
        mark.wantsLayer = true
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.layer?.cornerRadius = 9
        mark.layer?.cornerCurve = .continuous
        let grad = CAGradientLayer()
        grad.colors = [NSColor.systemPurple.cgColor, NSColor.systemBlue.cgColor]
        grad.startPoint = CGPoint(x: 0, y: 0); grad.endPoint = CGPoint(x: 1, y: 1)
        grad.frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        grad.cornerRadius = 9
        mark.layer?.addSublayer(grad)

        let label = NSTextField(labelWithString: "LiveWall")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 22, weight: .bold)
        label.textColor = NSColor.white.withAlphaComponent(0.9)
        label.backgroundColor = .clear
        label.isBordered = false

        badge.addSubview(mark)
        badge.addSubview(label)
        container.addSubview(badge)

        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 34),
            mark.heightAnchor.constraint(equalToConstant: 34),
            mark.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 13),
            mark.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            badge.heightAnchor.constraint(equalToConstant: 44),
            badge.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            badge.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -28),
        ])
        badge.alphaValue = 0.85
    }

    private func removeWindow(_ id: CGDirectDisplayID) {
        renderers[id]?.teardown(); renderers[id] = nil
        windows[id]?.onOcclusionChange = nil
        windows[id]?.orderOut(nil); windows[id]?.contentView = nil; windows[id] = nil
        covered.remove(id)
    }

    // MARK: - Hot-plug reconcile

    private func reconcile() {
        let present = Set(displays.screens.map { DisplayObserver.displayID(for: $0) })
        for id in Set(windows.keys).subtracting(present) { removeWindow(id) }          // disconnected
        for id in Set(requests.keys).intersection(present) where windows[id] == nil { installWindow(id) } // (re)connect
        for id in Set(windows.keys).intersection(present) {                             // resolution / arrangement
            if let screen = screen(for: id) { windows[id]?.setFrame(screen.frame, display: true) }
        }
        isRunning = !requests.isEmpty
    }

    private func resolveTargets(_ ids: Set<CGDirectDisplayID>) -> [CGDirectDisplayID] {
        let avail = displays.screens.map { DisplayObserver.displayID(for: $0) }
        if ids.isEmpty {
            if let main = NSScreen.main ?? displays.screens.first { return [DisplayObserver.displayID(for: main)] }
            return []
        }
        return ids.filter { avail.contains($0) }
    }

    private func screen(for id: CGDirectDisplayID) -> NSScreen? {
        displays.screens.first { DisplayObserver.displayID(for: $0) == id }
    }

    private func makeRenderer(for request: Request) -> WallpaperRenderer {
        switch request.kind {
        case .localVideo(let url):
            return VideoWallpaperRenderer(url: url, muted: request.muted, volume: request.volume,
                                          loops: request.loops, scaling: request.scaling)
        case .directURL(let url):
            if url.host?.contains("drive") == true {
                return GoogleDriveStreamWallpaperRenderer(downloadURL: url, muted: request.muted,
                                                           volume: request.volume, loops: request.loops,
                                                           scaling: request.scaling)
            }
            return HTML5VideoWallpaperRenderer(url: url, muted: request.muted, volume: request.volume,
                                               loops: request.loops, scaling: request.scaling)
        case .localImage(let url):
            return ImageWallpaperRenderer(url: url, scaling: request.scaling)
        case .youTube(let id):
            return YouTubeWallpaperRenderer(videoID: id, muted: request.muted)
        case .web(let url):
            return InteractiveWebWallpaperRenderer(url: url, muted: request.muted, volume: request.volume)
        }
    }
}

import AppKit
import SwiftUI
import ServiceManagement
import Carbon.HIToolbox

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: NSWindow?
    private let displays = DisplayObserver()
    private lazy var controller = WallpaperController(displays: displays)
    private lazy var library = LibraryStore()
    private lazy var movies = MovieStore()
    private lazy var viewModel = WallpaperViewModel(controller: controller, displayObserver: displays, library: library)
    // Desktop widgets live in their own window layer, one level above the
    // wallpaper overlay, so they stay visible while it animates.
    private let widgetStore = WidgetStore.shared
    private lazy var widgetLayer = WidgetLayerController(store: widgetStore, displays: displays)
    private let power = PowerMonitor()
    private var statusItem: NSStatusItem?
    private var turnOffHotKey: EventHotKeyRef?
    private var fullscreenTimer: Timer?
    private let fullscreen = FullscreenDetectionService()
    private var keepRunningInBackground: Bool { UserDefaults.standard.object(forKey: "keepRunningInBackground") as? Bool ?? true }
    private var restoreEnabled: Bool { UserDefaults.standard.object(forKey: "restoreLastWallpaper") as? Bool ?? true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LiveWall is designed to stay active by default. People can opt into
        // battery/fullscreen pauses from Settings when they want to save power.
        UserDefaults.standard.register(defaults: [
            "keepRunningInBackground": true,
            "restoreLastWallpaper": true,
            "pauseOnBattery": false,
            "pauseOnLowPowerMode": false,
            "pauseOnFullscreen": false,
            "pauseWhenHidden": false,
            // Auto-check for updates at launch is on by default (opt-out in
            // Settings). Without this default the key read back false, so the
            // launch check never ran and "auto update" appeared broken.
            "updateNotificationsEnabled": true
        ])
        // Launch-at-login is opt-in (Settings), default off. Forcing it on every
        // start auto-started the app as a login background process, which raced
        // the system menu-bar agent and crashed the status item — and is
        // user-hostile for a public app besides.
        if UserDefaults.standard.object(forKey: "launchAtLogin") == nil {
            UserDefaults.standard.set(false, forKey: "launchAtLogin")
        }
        try? LaunchAtLoginService.setEnabled(UserDefaults.standard.bool(forKey: "launchAtLogin"))
        // Bring the widget layer up at launch so saved widgets restore
        // themselves onto the right displays without opening the window.
        _ = widgetLayer
        setUpMenu()
        showControlWindow()
        NSApp.activate(ignoringOtherApps: true)
        power.onChange = { [weak self] pause in self?.controller.setPowerPaused(pause) }
        power.start()
        fullscreenTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.fullscreen.refresh()
            let enabled = UserDefaults.standard.object(forKey: "pauseOnFullscreen") as? Bool ?? false
            self.controller.setExternalPaused(enabled && self.fullscreen.anotherAppIsFullscreen)
        }
        // Create the menu-bar item once the app is actually active. Building it
        // during launch (especially a login-launched background start) races the
        // system menu-bar agent's scene connection, which crashed in AppKit.
        DispatchQueue.main.async { [weak self] in self?.setUpStatusItem() }
        controller.onChange = { [weak self] in self?.persistState() }
        registerTurnOffHotKey()
        // The sign-up gate is gone, so the saved wallpaper restores immediately.
        if restoreEnabled { restoreState() }
        if UserDefaults.standard.bool(forKey: "updateNotificationsEnabled") { viewModel.checkForUpdates(silent: true) }
        // Anonymous install ping. No-ops unless a Supabase project is configured
        // in Analytics.swift and the user has left the Settings toggle on.
        Analytics.recordLaunch()
        Analytics.checkStatus { banned in
            Task { @MainActor in
                Analytics.isBanned = banned
                // A banned install stops running wallpapers rather than
                // pretending to work. It does nothing else to the computer.
                if banned { self.controller.stop() }
            }
        }
        UserDefaults.standard.set(true, forKey: "startupPromptShown")
    }

    private func showControlWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = LiveWallRootView(vm: viewModel, library: library, movies: movies)
        let hosting = NSHostingView(rootView: root)
        // Without this, NSHostingView pushes the SwiftUI content's own minimum
        // size up as a window constraint, so the window refuses to shrink past
        // whatever the widest row happens to need. The layout is adaptive, so
        // let the window drive the size instead of the content.
        hosting.sizingOptions = []
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 740),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "LiveWall"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true          // content flows under a translucent titlebar
        win.isOpaque = false                           // let the vibrancy sample the desktop behind
        win.backgroundColor = .clear
        win.contentView = hosting
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 720, height: 520)
        win.center()
        win.setFrameAutosaveName("LiveWallMainWindow")
        win.makeKeyAndOrderFront(nil)
        window = win
    }

    // Closing the control window keeps the wallpaper running in the background.
    // Closing the control window must not stop the wallpaper. The menu bar's
    // Quit command remains the explicit way to terminate the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        fullscreenTimer?.invalidate()
        controller.stop()
    }

    private func setUpMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About LiveWall", action: nil, keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide LiveWall",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit LiveWall",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "LiveWall",
                           action: #selector(showControlWindowMenu), keyEquivalent: "0")
        windowItem.submenu = windowMenu

        let backgroundItem = NSMenuItem(title: "Keep LiveWall Running in Background", action: #selector(toggleBackgroundMode), keyEquivalent: "")
        backgroundItem.target = self
        backgroundItem.state = keepRunningInBackground ? .on : .off
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(backgroundItem)

        // Edit menu so the URL text field supports copy / paste / select-all.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func showControlWindowMenu() { showControlWindow() }

    @objc private func toggleBackgroundMode(_ sender: NSMenuItem) {
        let enabled = !keepRunningInBackground
        UserDefaults.standard.set(enabled, forKey: "keepRunningInBackground")
        sender.state = enabled ? .on : .off
    }

    private func showStartupPrompt() {
        UserDefaults.standard.set(true, forKey: "startupPromptShown")
        let keepBackground = NSButton(checkboxWithTitle: "Keep LiveWall running in the background", target: nil, action: nil)
        keepBackground.state = keepRunningInBackground ? .on : .off
        let alert = NSAlert()
        alert.messageText = "Launch LiveWall at startup?"
        alert.informativeText = "LiveWall can start automatically when you sign in and keep your live wallpaper running after the control window is closed."
        alert.addButton(withTitle: "Launch at Startup")
        alert.addButton(withTitle: "Not Now")
        alert.accessoryView = keepBackground
        let response = alert.runModal()
        let shouldLaunch = response == .alertFirstButtonReturn
        UserDefaults.standard.set(keepBackground.state == .on, forKey: "keepRunningInBackground")
        if shouldLaunch {
            do { try SMAppService.mainApp.register() }
            catch { NSLog("[LiveWall] Could not register launch-at-login: \(error.localizedDescription)") }
        }
    }

    // MARK: - Restore last wallpaper

    private func persistState() {
        if let data = controller.snapshotData() { UserDefaults.standard.set(data, forKey: "restoreState") }
    }
    private func restoreState() {
        guard let data = UserDefaults.standard.data(forKey: "restoreState") else { return }
        controller.restore(data)
    }

    // MARK: - Menu-bar control

    private func setUpStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "sparkles.tv", accessibilityDescription: "LiveWall")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        rebuildStatusMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { if menu === statusItem?.menu { rebuildStatusMenu() } }

    private func rebuildStatusMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        func add(_ title: String, subtitle: String? = nil, symbol: String, key: String = "",
                 action: Selector?, target: AnyObject? = self, destructive: Bool = false, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.attributedTitle = StatusMenuStyle.title(title, subtitle: subtitle, destructive: destructive)
            item.image = StatusMenuStyle.chip(symbol, destructive: destructive)
            item.target = target
            item.isEnabled = enabled
            if !key.isEmpty { item.keyEquivalentModifierMask = .command }
            menu.addItem(item)
        }

        add("Open LiveWall", symbol: "square.grid.2x2.fill", key: "1", action: #selector(showControlWindowMenu))
        menu.addItem(.separator())
        add(viewModel.showAsPlaying ? "Pause" : "Play",
            symbol: viewModel.showAsPlaying ? "pause.fill" : "play.fill",
            key: "p", action: #selector(menuTogglePlay), enabled: viewModel.isRunning)
        add("Previous", symbol: "backward.fill", key: "[", action: #selector(menuPrevious))
        add("Next", symbol: "forward.fill", key: "]", action: #selector(menuNext))
        add("Loop", subtitle: viewModel.loops ? "On" : "Off", symbol: "repeat", action: #selector(menuToggleLoop))
        add(viewModel.muted ? "Unmute Audio" : "Mute Audio",
            symbol: viewModel.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            key: "m", action: #selector(menuToggleMute))
        menu.addItem(.separator())
        add("Turn Off Wallpaper", subtitle: "Back to your normal desktop  \(HotKey.display)",
            symbol: "xmark.circle.fill", action: #selector(menuTurnOff), enabled: viewModel.isRunning)
        menu.addItem(.separator())
        add("Quit LiveWall", symbol: "power", key: "q",
            action: #selector(NSApplication.terminate(_:)), target: nil, destructive: true)
    }

    @objc private func menuTurnOff() { viewModel.restoreNormalDesktop() }

    @objc private func menuTogglePlay() { viewModel.togglePlay() }
    @objc private func menuStop() { viewModel.stop() }
    @objc private func menuToggleMute() { viewModel.setMuted(!viewModel.muted) }
    @objc private func menuToggleLoop() { viewModel.loops.toggle() }
    @objc private func menuPrevious() { cycleWallpaper(-1) }
    @objc private func menuNext() { cycleWallpaper(1) }

    private func cycleWallpaper(_ direction: Int) {
        let items = viewModel.templates + viewModel.library.items
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == viewModel.runningItemID } ?? (direction > 0 ? -1 : 0)
        let next = (current + direction + items.count) % items.count
        viewModel.apply(items[next])
    }

    private var hotKeyHandlerInstalled = false

    /// Registers the user's custom global shortcut for "turn off wallpaper".
    /// Re-called whenever the shortcut changes. The Carbon event handler is
    /// installed once; only the key registration is swapped.
    private func registerTurnOffHotKey() {
        if !hotKeyHandlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
                guard let userData else { return noErr }
                let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { me.viewModel.restoreNormalDesktop() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
            hotKeyHandlerInstalled = true

            // Re-register when the user records a new shortcut in Settings.
            NotificationCenter.default.addObserver(forName: HotKey.changed, object: nil, queue: .main) { [weak self] _ in
                self?.registerTurnOffHotKey()
            }
        }

        if let existing = turnOffHotKey { UnregisterEventHotKey(existing); turnOffHotKey = nil }
        let id = EventHotKeyID(signature: OSType(0x4C575446), id: 1)   // 'LWTF'
        RegisterEventHotKey(HotKey.keyCode, HotKey.carbonModifiers, id,
                            GetApplicationEventTarget(), 0, &turnOffHotKey)
    }

    @objc private func menuToggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("[LiveWall] login toggle failed: \(error.localizedDescription)") }
    }
}

import AppKit
import IOKit.ps

extension Notification.Name {
    static let liveWallPowerSettingsChanged = Notification.Name("LiveWallPowerSettingsChanged")
}

/// Watches power/session state and reports whether wallpaper playback should pause.
/// Lock and display sleep always pause (nothing is visible); battery and Low Power
/// Mode are user-configurable via UserDefaults.
final class PowerMonitor {
    /// Called on the main queue whenever the "should pause" decision changes.
    var onChange: ((Bool) -> Void)?

    private(set) var onBattery = false
    private(set) var lowPower = false
    private(set) var locked = false
    private(set) var asleep = false
    private var runLoopSource: CFRunLoopSource?
    private var lastValue: Bool?

    // Settings (defaults chosen for battery friendliness).
    static let pauseOnBatteryKey = "pauseOnBattery"
    static let pauseOnLowPowerKey = "pauseOnLowPowerMode"
    var pauseOnBattery: Bool { UserDefaults.standard.object(forKey: Self.pauseOnBatteryKey) as? Bool ?? false }
    var pauseOnLowPower: Bool { UserDefaults.standard.object(forKey: Self.pauseOnLowPowerKey) as? Bool ?? false }

    var shouldPause: Bool {
        if locked || asleep { return true }
        if pauseOnBattery && onBattery { return true }
        if pauseOnLowPower && lowPower { return true }
        return false
    }

    func start() {
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        refreshBattery()
        registerPowerSource()

        let nc = NotificationCenter.default
        nc.addObserver(forName: .liveWallPowerSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.settingsChanged()
        }
        nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled; self?.emit()
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.asleep = true;  self?.emit() }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification,  object: nil, queue: .main) { [weak self] _ in self?.asleep = false; self?.emit() }
        ws.addObserver(forName: NSWorkspace.willSleepNotification,       object: nil, queue: .main) { [weak self] _ in self?.asleep = true;  self?.emit() }
        ws.addObserver(forName: NSWorkspace.didWakeNotification,         object: nil, queue: .main) { [weak self] _ in self?.asleep = false; self?.emit() }

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"),   object: nil, queue: .main) { [weak self] _ in self?.locked = true;  self?.emit() }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.locked = false; self?.emit() }

        emit(force: true)
    }

    /// Re-evaluate after the user changes a pause setting.
    func settingsChanged() { emit(force: true) }

    private func emit(force: Bool = false) {
        let value = shouldPause
        if force || value != lastValue { lastValue = value; onChange?(value) }
    }

    private func refreshBattery() {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef] else { return }
        var battery = false
        for src in list {
            if let d = IOPSGetPowerSourceDescription(snap, src)?.takeUnretainedValue() as? [String: Any],
               let state = d[kIOPSPowerSourceStateKey] as? String, state == kIOPSBatteryPowerValue {
                battery = true
            }
        }
        onBattery = battery
    }

    private func registerPowerSource() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.refreshBattery()
            monitor.emit()
        }, ctx)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        runLoopSource = src
    }
}

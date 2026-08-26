import AppKit
import Carbon.HIToolbox

/// The user-customisable global shortcut for "turn off wallpaper / restore normal
/// desktop". Stored in UserDefaults; defaults to ⌃⌥⌘W.
enum HotKey {
    static let codeKey = "turnOffHotKeyCode"
    static let modsKey = "turnOffHotKeyMods"   // NSEvent.ModifierFlags rawValue
    static let charKey = "turnOffHotKeyChar"   // for display only
    static let changed = Notification.Name("LiveWallHotKeyChanged")

    static var keyCode: UInt32 {
        UInt32(UserDefaults.standard.object(forKey: codeKey) as? Int ?? kVK_ANSI_W)
    }

    static var nsModifiers: NSEvent.ModifierFlags {
        if let raw = UserDefaults.standard.object(forKey: modsKey) as? UInt {
            return NSEvent.ModifierFlags(rawValue: raw)
        }
        return [.control, .option, .command]
    }

    /// Carbon modifier mask for RegisterEventHotKey.
    static var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        let f = nsModifiers
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option)  { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift)   { m |= UInt32(shiftKey) }
        return m
    }

    /// Human-readable form, e.g. "⌃⌥⌘W".
    static var display: String {
        var s = ""
        let f = nsModifiers
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option)  { s += "⌥" }
        if f.contains(.shift)   { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        s += (UserDefaults.standard.string(forKey: charKey) ?? "W").uppercased()
        return s
    }

    static func save(keyCode: Int, modifiers: NSEvent.ModifierFlags, char: String) {
        UserDefaults.standard.set(keyCode, forKey: codeKey)
        UserDefaults.standard.set(modifiers.rawValue, forKey: modsKey)
        UserDefaults.standard.set(char, forKey: charKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

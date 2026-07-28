import AppKit

/// Styling for the menu-bar dropdown so it reads like a modern, polished menu:
/// rounded icon "chips", a title with an optional subtitle, and ⌘ shortcuts.
enum StatusMenuStyle {
    /// A rounded-rect icon chip (dark translucent fill + tinted SF Symbol).
    static func chip(_ symbol: String, destructive: Bool = false) -> NSImage {
        let size = NSSize(width: 26, height: 26)
        let image = NSImage(size: size)
        image.lockFocus()
        let bg = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5),
                              xRadius: 7, yRadius: 7)
        NSColor.white.withAlphaComponent(0.10).setFill()
        bg.fill()
        let tint: NSColor = destructive ? .systemRed : .white
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        if let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            let s = sym.size
            sym.draw(in: NSRect(x: (size.width - s.width) / 2, y: (size.height - s.height) / 2,
                                width: s.width, height: s.height))
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// Title with an optional smaller, secondary subtitle line.
    static func title(_ title: String, subtitle: String? = nil, destructive: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: destructive ? NSColor.systemRed : NSColor.labelColor
        ])
        if let subtitle {
            result.append(NSAttributedString(string: "\n" + subtitle, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
        }
        return result
    }
}

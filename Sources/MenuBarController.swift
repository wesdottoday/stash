import AppKit

final class MenuBarController {
    var onPreferences: (() -> Void)?
    var onQuit: (() -> Void)?

    private var statusItem: NSStatusItem?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = Self.mustacheImage()
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "stash"
        }

        let menu = NSMenu()
        let prefs = NSMenuItem(title: "Preferences…",
                               action: #selector(prefsClicked),
                               keyEquivalent: ",")
        prefs.keyEquivalentModifierMask = [.command]
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit",
                              action: #selector(quitClicked),
                              keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    func uninstall() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func prefsClicked() { onPreferences?() }
    @objc private func quitClicked()  { onQuit?() }

    // MARK: - Icon ------------------------------------------------------------

    /// Prefer SF Symbols (which exist on macOS 11+ and look right at every
    /// menu-bar size). Fall back to a hand-drawn silhouette if the symbol
    /// isn't present in the running OS's SF Symbols catalogue.
    static func mustacheImage() -> NSImage {
        let symbolCandidates = ["mustache.fill", "mustache",
                                "moustache.fill", "moustache"]
        for name in symbolCandidates {
            if let symbol = NSImage(systemSymbolName: name,
                                    accessibilityDescription: "stash") {
                symbol.isTemplate = true
                if #available(macOS 12.0, *) {
                    let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                    if let configured = symbol.withSymbolConfiguration(config) {
                        configured.isTemplate = true
                        return configured
                    }
                }
                return symbol
            }
        }
        return drawnMustacheImage()
    }

    /// Fallback drawing for OS versions that don't ship a mustache symbol.
    /// Designed at 18 × 13 logical points (the menu bar's effective drawing
    /// area on a 22pt-tall bar) and rendered as a single closed silhouette so
    /// the OS's template tint applies cleanly.
    private static func drawnMustacheImage() -> NSImage {
        let size = NSSize(width: 18, height: 13)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            let w = rect.width
            let h = rect.height
            let centerY = h * 0.50
            let bulgeY  = h * 0.78   // top of each handlebar curl
            let dipY    = h * 0.42   // bottom of the centre dip
            let tipY    = h * 0.32   // tail tips
            let path = NSBezierPath()

            // Top edge: left tail → up over left curl → centre dip → up over
            // right curl → right tail.
            path.move(to: NSPoint(x: w * 0.03, y: centerY))
            path.curve(to: NSPoint(x: w * 0.22, y: bulgeY),
                       controlPoint1: NSPoint(x: w * 0.05, y: bulgeY),
                       controlPoint2: NSPoint(x: w * 0.10, y: bulgeY))
            path.curve(to: NSPoint(x: w * 0.42, y: centerY),
                       controlPoint1: NSPoint(x: w * 0.33, y: bulgeY),
                       controlPoint2: NSPoint(x: w * 0.40, y: centerY + 0.5))
            path.curve(to: NSPoint(x: w * 0.50, y: dipY),
                       controlPoint1: NSPoint(x: w * 0.45, y: dipY),
                       controlPoint2: NSPoint(x: w * 0.47, y: dipY))
            path.curve(to: NSPoint(x: w * 0.58, y: centerY),
                       controlPoint1: NSPoint(x: w * 0.53, y: dipY),
                       controlPoint2: NSPoint(x: w * 0.55, y: dipY))
            path.curve(to: NSPoint(x: w * 0.78, y: bulgeY),
                       controlPoint1: NSPoint(x: w * 0.60, y: centerY + 0.5),
                       controlPoint2: NSPoint(x: w * 0.67, y: bulgeY))
            path.curve(to: NSPoint(x: w * 0.97, y: centerY),
                       controlPoint1: NSPoint(x: w * 0.90, y: bulgeY),
                       controlPoint2: NSPoint(x: w * 0.95, y: bulgeY))

            // Right outside down
            path.line(to: NSPoint(x: w * 0.97, y: tipY))
            // Bottom edge — gentle curve back across the underside
            path.curve(to: NSPoint(x: w * 0.50, y: tipY * 0.85),
                       controlPoint1: NSPoint(x: w * 0.80, y: tipY * 0.4),
                       controlPoint2: NSPoint(x: w * 0.65, y: tipY * 0.5))
            path.curve(to: NSPoint(x: w * 0.03, y: tipY),
                       controlPoint1: NSPoint(x: w * 0.35, y: tipY * 0.5),
                       controlPoint2: NSPoint(x: w * 0.20, y: tipY * 0.4))
            path.close()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

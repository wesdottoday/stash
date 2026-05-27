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

    /// A minimal mustache silhouette drawn as a template image.
    static func mustacheImage() -> NSImage {
        let size = NSSize(width: 22, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            let path = NSBezierPath()
            // Stylised handlebar — two arcs joined at the centre
            let w = rect.width
            let h = rect.height
            let cy = h * 0.45
            // Left curl
            path.move(to: NSPoint(x: w * 0.02, y: cy + h * 0.10))
            path.curve(to: NSPoint(x: w * 0.25, y: cy - h * 0.25),
                       controlPoint1: NSPoint(x: w * 0.05, y: cy - h * 0.10),
                       controlPoint2: NSPoint(x: w * 0.13, y: cy - h * 0.30))
            path.curve(to: NSPoint(x: w * 0.42, y: cy + h * 0.05),
                       controlPoint1: NSPoint(x: w * 0.35, y: cy - h * 0.15),
                       controlPoint2: NSPoint(x: w * 0.38, y: cy + h * 0.05))
            // Centre dip
            path.line(to: NSPoint(x: w * 0.50, y: cy + h * 0.02))
            path.line(to: NSPoint(x: w * 0.58, y: cy + h * 0.05))
            // Right curl
            path.curve(to: NSPoint(x: w * 0.75, y: cy - h * 0.25),
                       controlPoint1: NSPoint(x: w * 0.62, y: cy + h * 0.05),
                       controlPoint2: NSPoint(x: w * 0.65, y: cy - h * 0.15))
            path.curve(to: NSPoint(x: w * 0.98, y: cy + h * 0.10),
                       controlPoint1: NSPoint(x: w * 0.87, y: cy - h * 0.30),
                       controlPoint2: NSPoint(x: w * 0.95, y: cy - h * 0.10))
            path.curve(to: NSPoint(x: w * 0.50, y: cy - h * 0.10),
                       controlPoint1: NSPoint(x: w * 0.85, y: cy + h * 0.40),
                       controlPoint2: NSPoint(x: w * 0.65, y: cy + h * 0.20))
            path.curve(to: NSPoint(x: w * 0.02, y: cy + h * 0.10),
                       controlPoint1: NSPoint(x: w * 0.35, y: cy + h * 0.20),
                       controlPoint2: NSPoint(x: w * 0.15, y: cy + h * 0.40))
            path.close()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

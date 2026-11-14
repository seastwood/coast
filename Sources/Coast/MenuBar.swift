import AppKit

/// The menu bar icon and its menu: Enabled, Glide, Flick sensitivity, Quit.
final class MenuBar: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private var groups: [(base: String, parent: NSMenuItem, items: [(NSMenuItem, Double)], current: () -> Double)] = []

    // Menu bar glyph: a monochrome SF Symbol drawn as a TEMPLATE image, so the system tints it like
    // every other menu bar icon.
    private static let symbol = "cursorarrow.motionlines"

    init(inputOK: Bool) {
        super.init()
        let button = statusItem.button
        button?.image = Self.icon()
        button?.toolTip = inputOK ? appName : "\(appName) (no input permission)"

        let menu = NSMenu()
        // Header: app name + version in one plain title; the disabled item renders it in the standard
        // quiet gray.
        let header = NSMenuItem(title: "\(appName) \(appVersion)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        enabledItem.target = self
        menu.addItem(enabledItem)
        menu.addItem(.separator())

        let settings = Settings.shared
        addGroup(to: menu, "Glide", Settings.glidePresets, #selector(pickGlide(_:)), { settings.friction })
        addGroup(to: menu, "Flick sensitivity", Settings.sensitivityPresets, #selector(pickSensitivity(_:)), { settings.minLaunchSpeed })

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        refresh()
    }

    private func addGroup(to menu: NSMenu, _ base: String, _ presets: [(String, Double)], _ action: Selector, _ current: @escaping () -> Double) {
        let submenu = NSMenu()
        var items: [(NSMenuItem, Double)] = []
        for (label, value) in presets {
            let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            submenu.addItem(item)
            items.append((item, value))
        }
        let parent = NSMenuItem(title: base, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        menu.addItem(parent)
        groups.append((base, parent, items, current))
    }

    @objc private func toggleEnabled() {
        Engine.shared.setEnabled(!Settings.shared.enabled)
        refresh()
    }

    @objc private func pickGlide(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { Settings.shared.friction = v }
        refresh()
    }

    @objc private func pickSensitivity(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { Settings.shared.minLaunchSpeed = v }
        refresh()
    }

    @objc private func quit() {
        Engine.shared.stop()
        NSApp.terminate(nil)
    }

    /// Keeps the checkmarks, the "Glide: Medium" titles and the dimmed-when-off icon in sync.
    private func refresh() {
        let on = Settings.shared.enabled
        enabledItem.state = on ? .on : .off
        statusItem.button?.alphaValue = on ? 1.0 : 0.35
        for g in groups {
            let cur = g.current()
            var chosen: String?
            for (item, value) in g.items {
                let match = abs(value - cur) < 1e-9
                item.state = match ? .on : .off
                if match { chosen = item.title }
            }
            g.parent.title = chosen.map { "\(g.base): \($0)" } ?? g.base
        }
    }

    private static func icon() -> NSImage {
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: appName) {
            let sized = img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)) ?? img
            sized.isTemplate = true
            return sized
        }
        // Fallback: a simple trackball glyph (ring + dot). Template images are masked by alpha.
        let size: CGFloat = 18, inset: CGFloat = 2, dot: CGFloat = 4
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            NSColor.black.set()
            let ring = NSBezierPath(ovalIn: NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset))
            ring.lineWidth = 1.6
            ring.stroke()
            NSBezierPath(ovalIn: NSRect(x: size / 2 - dot / 2, y: size / 2 - dot / 2, width: dot, height: dot)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}

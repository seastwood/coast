import AppKit

/// The menu bar icon and its menu: Enabled, the Glide and Flick sensitivity sliders, Quit.
final class MenuBar: NSObject {
    private let engine: EngineHost
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private var glide: SliderRow!
    private var sensitivity: SliderRow!

    // Menu bar glyph: a monochrome SF Symbol drawn as a TEMPLATE image, so the system tints it like
    // every other menu bar icon.
    private static let symbol = "cursorarrow.motionlines"

    init(engine: EngineHost) {
        self.engine = engine
        super.init()
        statusItem.button?.image = Self.icon()
        statusItem.button?.toolTip = appName

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
        glide = SliderRow(title: "Glide", low: "Short", high: "Long",
                          value: Settings.slider(friction: settings.friction)) { [weak self] t in
            Settings.shared.friction = Settings.friction(slider: t)
            self?.engine.sendSettings()
        }
        sensitivity = SliderRow(title: "Flick sensitivity", low: "Low", high: "High",
                                value: Settings.slider(minLaunchSpeed: settings.minLaunchSpeed)) { [weak self] t in
            Settings.shared.minLaunchSpeed = Settings.minLaunchSpeed(slider: t)
            self?.engine.sendSettings()
        }
        for row in [glide!, sensitivity!] {
            let item = NSMenuItem()
            item.view = row
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        refresh()
    }

    /// The engine reports whether it could watch the trackpad.
    func setInputOK(_ ok: Bool) {
        statusItem.button?.toolTip = ok ? appName : "\(appName) (no input permission)"
    }

    @objc private func toggleEnabled() {
        Settings.shared.enabled.toggle()
        engine.sendSettings()
        refresh()
    }

    @objc private func quit() {
        engine.stop()
        NSApp.terminate(nil)
    }

    /// Keeps the checkmark and the dimmed-when-off icon in sync.
    private func refresh() {
        let on = Settings.shared.enabled
        enabledItem.state = on ? .on : .off
        statusItem.button?.alphaValue = on ? 1.0 : 0.35
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

/// A menu row with a title, the value as a percentage, and a slider between two end labels.
private final class SliderRow: NSView {
    private let valueLabel = NSTextField(labelWithString: "")
    private let slider: NSSlider
    private let onChange: (Double) -> Void

    init(title: String, low: String, high: String, value: Double, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        slider = NSSlider(value: value, minValue: 0, maxValue: 1, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 58))

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .menuFont(ofSize: 0)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        let lowLabel = NSTextField(labelWithString: low), highLabel = NSTextField(labelWithString: high)
        for l in [lowLabel, highLabel] {
            l.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
            l.textColor = .tertiaryLabelColor
        }
        highLabel.alignment = .right
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)

        // Menu items' text starts 14 pt in from the left edge on current macOS; match it.
        titleLabel.frame = NSRect(x: 14, y: 36, width: 160, height: 17)
        valueLabel.frame = NSRect(x: 176, y: 36, width: 60, height: 17)
        slider.frame = NSRect(x: 14, y: 16, width: 222, height: 20)
        lowLabel.frame = NSRect(x: 14, y: 2, width: 100, height: 14)
        highLabel.frame = NSRect(x: 136, y: 2, width: 100, height: 14)
        [titleLabel, valueLabel, slider, lowLabel, highLabel].forEach(addSubview)
        updateLabel()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func changed() {
        updateLabel()
        onChange(slider.doubleValue)
    }

    private func updateLabel() { valueLabel.stringValue = "\(Int((slider.doubleValue * 100).rounded()))%" }
}

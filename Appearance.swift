import AppKit

struct ClockAppearance {
    let defaults: UserDefaults

    var transparency: Double {
        let stored = defaults.object(forKey: "backgroundTransparency") as? Double ?? 85
        return stored.isFinite ? min(100, max(0, stored)) : 85
    }

    var color: NSColor {
        guard let values = defaults.array(forKey: "backgroundRGB") as? [Double],
              values.count == 3, values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            return NSColor(calibratedWhite: 0.09, alpha: 1)
        }
        return NSColor(srgbRed: values[0], green: values[1], blue: values[2], alpha: 1)
    }

    var fill: NSColor { color.withAlphaComponent(1 - transparency / 100) }

    func setTransparency(_ value: Double) {
        guard value.isFinite else { return }
        defaults.set(min(100, max(0, value)), forKey: "backgroundTransparency")
    }

    func setColor(_ value: NSColor) {
        guard let rgb = value.usingColorSpace(.sRGB) else { return }
        defaults.set([Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)], forKey: "backgroundRGB")
    }
}

final class AppearanceSettings: NSObject {
    weak var controller: ClockController?
    let window: NSPanel
    let slider = NSSlider(value: 85, minValue: 0, maxValue: 100, target: nil, action: nil)
    let valueLabel = NSTextField(labelWithString: "")
    let colorWell = NSColorWell()

    init(controller: ClockController) {
        self.controller = controller
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 310, height: 190), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        window.title = "时钟外观设置"
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.appearance = NSAppearance(named: .darkAqua)
        let content = window.contentView!
        let title = NSTextField(labelWithString: "背景透明度")
        title.frame = NSRect(x: 20, y: 145, width: 160, height: 20)
        content.addSubview(title)
        valueLabel.frame = NSRect(x: 220, y: 145, width: 70, height: 20)
        valueLabel.alignment = .right
        content.addSubview(valueLabel)
        slider.frame = NSRect(x: 18, y: 109, width: 274, height: 28)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changeTransparency)
        slider.setAccessibilityLabel("背景透明度")
        content.addSubview(slider)
        let colorLabel = NSTextField(labelWithString: "背景颜色")
        colorLabel.frame = NSRect(x: 20, y: 66, width: 160, height: 20)
        content.addSubview(colorLabel)
        colorWell.frame = NSRect(x: 232, y: 60, width: 58, height: 30)
        colorWell.target = self
        colorWell.isContinuous = true
        colorWell.action = #selector(changeColor)
        colorWell.setAccessibilityLabel("背景颜色")
        content.addSubview(colorWell)
        let hint = NSTextField(labelWithString: "即时生效并自动保存；文字和进度条不变。")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 20, y: 20, width: 275, height: 18)
        content.addSubview(hint)
        window.center()
    }

    func show() {
        guard let controller = controller else { return }
        slider.doubleValue = controller.appearance.transparency
        updateLabel()
        colorWell.color = controller.appearance.color
        NSColorPanel.shared.showsAlpha = false
        NSColorPanel.shared.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func updateLabel() {
        valueLabel.stringValue = String(format: "%.0f%%", slider.doubleValue)
    }

    @objc func changeTransparency() {
        controller?.appearance.setTransparency(slider.doubleValue)
        updateLabel()
        controller?.clockView.needsDisplay = true
    }

    @objc func changeColor() {
        controller?.appearance.setColor(colorWell.color)
        controller?.clockView.needsDisplay = true
    }
}

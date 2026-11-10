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

    /// 背景色偏深时用浅色文字；与气泡使用同一亮度规则。
    var usesLightText: Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return true }
        return rgb.redComponent * 0.2126 + rgb.greenComponent * 0.7152 + rgb.blueComponent * 0.0722 < 0.5
    }

    /// 额度卡片与按钮下的同色底板：保证高透明度时小字可读；透明度 90%→100% 时逐渐消失。
    var legibilityPlate: CGFloat { CGFloat(0.4 * min(1, max(0, (100 - transparency) / 10))) }

    var palette: ClockPalette { ClockPalette(light: usesLightText, base: color, plateAlpha: legibilityPlate) }

    func setTransparency(_ value: Double) {
        guard value.isFinite else { return }
        defaults.set(min(100, max(0, value)), forKey: "backgroundTransparency")
    }

    func setColor(_ value: NSColor) {
        guard let rgb = value.usingColorSpace(.sRGB) else { return }
        defaults.set([Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)], forKey: "backgroundRGB")
    }
}

/// 时钟、额度面板与按钮共用的配色：文字颜色随背景深浅切换，并带反色光晕以适应任意桌面。
struct ClockPalette {
    let light: Bool
    let base: NSColor
    let plateAlpha: CGFloat

    var ink: NSColor { light ? .white : NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1) }
    var primary: NSColor { ink.withAlphaComponent(0.96) }
    var secondary: NSColor { ink.withAlphaComponent(0.74) }
    var tertiary: NSColor { ink.withAlphaComponent(0.54) }
    func tint(_ alpha: CGFloat) -> NSColor { ink.withAlphaComponent(alpha) }
    var plate: NSColor { base.withAlphaComponent(plateAlpha) }
    var good: NSColor { light ? NSColor(srgbRed: 0.36, green: 0.80, blue: 0.88, alpha: 1) : NSColor(srgbRed: 0.0, green: 0.50, blue: 0.60, alpha: 1) }
    var warn: NSColor { light ? NSColor(srgbRed: 1.0, green: 0.66, blue: 0.30, alpha: 1) : NSColor(srgbRed: 0.80, green: 0.40, blue: 0.0, alpha: 1) }
    var critical: NSColor { light ? NSColor(srgbRed: 1.0, green: 0.42, blue: 0.40, alpha: 1) : NSColor(srgbRed: 0.78, green: 0.16, blue: 0.14, alpha: 1) }

    func level(_ remaining: Double) -> NSColor { remaining <= 10 ? critical : remaining <= 25 ? warn : good }

    func halo(blur: CGFloat, alpha: CGFloat) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = (light ? NSColor.black : NSColor.white).withAlphaComponent(light ? alpha : alpha * 1.2)
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = NSSize(width: 0, height: light ? -0.5 : 0)
        return shadow
    }

    func text(_ size: CGFloat, _ weight: NSFont.Weight = .regular, color: NSColor, align: NSTextAlignment = .natural, digits: Bool = false, truncate: NSLineBreakMode = .byTruncatingTail) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = align
        paragraph.lineBreakMode = truncate
        return [
            .font: digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .shadow: halo(blur: 2, alpha: 0.6)
        ]
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
        let hint = NSTextField(labelWithString: "即时生效并自动保存；文字颜色随背景深浅切换。")
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
        controller?.refreshAppearance()
    }

    @objc func changeColor() {
        controller?.appearance.setColor(colorWell.color)
        controller?.refreshAppearance()
    }
}

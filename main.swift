import AppKit

func displayedDate(_ date: Date) -> Date {
    date.addingTimeInterval(16 * 60 * 60)
}

func clockText(_ date: Date, seconds: Bool) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
    return formatter.string(from: date)
}

final class ClockView: NSView {
    weak var controller: ClockController?
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller = controller else { return }
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        let appearance = controller.appearance
        let palette = appearance.palette
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
        appearance.fill.setFill()
        shape.fill()
        // 双层描边：外侧暗线在浅色桌面上勾出边缘，内侧亮线在深色桌面上提亮边缘。
        NSColor(white: 0, alpha: 0.16).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let rim = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 15, yRadius: 15)
        NSColor(white: 1, alpha: palette.light ? 0.12 : 0.5).setStroke()
        rim.lineWidth = 1
        rim.stroke()

        let area = NSRect(x: 0, y: bounds.height - controller.clockHeight, width: bounds.width, height: controller.clockHeight)
        if controller.showQuota {
            palette.tint(0.12).setFill()
            NSRect(x: 14, y: area.minY, width: bounds.width - 28, height: 1).fill()
        }
        let now = displayedDate(Date())
        let text = clockText(now, seconds: controller.showSeconds)
        let digits = NSFont.monospacedDigitSystemFont(ofSize: controller.fontSize, weight: .medium)
        let time = NSMutableAttributedString(string: String(text.prefix(5)), attributes: [.font: digits, .foregroundColor: palette.primary])
        if controller.showSeconds {
            // 秒缩小、降低对比度并与时分共用基线：主次分明，宽度也更紧凑。
            time.addAttribute(.kern, value: controller.fontSize * 0.06, range: NSRange(location: 4, length: 1))
            time.append(NSAttributedString(string: String(text.dropFirst(5)), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: controller.secondsFontSize, weight: .medium),
                .foregroundColor: palette.secondary
            ]))
        }
        // 以数字的大写高度（而非行高）定位，各字号下的视觉留白一致。
        let dateBlock = controller.showDate ? controller.dateGap + controller.dateFontSize * 0.86 : 0
        let timeBaseline = round(area.maxY - controller.clockTopPadding - digits.capHeight)
        drawCentered(time, baseline: timeBaseline, palette: palette, softHalo: controller.fontSize * 0.2)
        if controller.showDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日 EEEE"
            let date = NSAttributedString(string: formatter.string(from: now), attributes: [
                .font: NSFont.systemFont(ofSize: controller.dateFontSize, weight: .medium),
                .foregroundColor: palette.tint(0.8),
                .kern: 0.3
            ])
            drawCentered(date, baseline: round(timeBaseline - dateBlock), palette: palette, softHalo: 5)
        }
    }

    /// 按基线居中绘制，并叠加“紧贴光晕 + 柔和外晕”，在浅色窗口或复杂壁纸上依然清晰。
    private func drawCentered(_ string: NSAttributedString, baseline: CGFloat, palette: ClockPalette, softHalo: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let width = ceil(string.size().width)
        let origin = NSPoint(x: round(bounds.midX - width / 2), y: baseline)
        context.saveGState()
        palette.halo(blur: softHalo, alpha: 0.28).set()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        palette.halo(blur: 1.5, alpha: 0.5).set()
        string.draw(with: NSRect(x: origin.x, y: origin.y, width: width + 2, height: 0), options: [], context: nil)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = controller?.makeMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// 与时钟融为一体的胶囊按钮：同色底板 + 半透明着色，悬停与按下有层次反馈。
final class HUDButton: NSButton {
    var palette = ClockPalette(light: true, base: .black, plateAlpha: 0.4) { didSet { needsDisplay = true } }
    var symbol: String? { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    convenience init(symbol: String?, title: String) {
        self.init(frame: .zero)
        self.symbol = symbol
        self.title = title
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryPushIn)
    }

    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private var contentColor: NSColor { !isEnabled ? palette.tertiary : hovering ? palette.primary : palette.secondary }
    private var titleAttributes: [NSAttributedString.Key: Any] { palette.text(11.5, .medium, color: contentColor) }

    private var symbolImage: NSImage? {
        guard let symbol = symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return nil }
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold).applying(NSImage.SymbolConfiguration(paletteColors: [contentColor]))
        return image.withSymbolConfiguration(configuration)
    }

    var fittingWidth: CGFloat {
        let textWidth = title.isEmpty ? 0 : ceil((title as NSString).size(withAttributes: titleAttributes).width)
        let iconWidth = symbolImage.map { ceil($0.size.width) } ?? 0
        guard textWidth > 0 else { return 26 }
        return 20 + iconWidth + (iconWidth > 0 ? 5 : 0) + textWidth
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        palette.plate.setFill()
        shape.fill()
        palette.tint(!isEnabled ? 0.04 : isHighlighted ? 0.24 : hovering ? 0.16 : 0.09).setFill()
        shape.fill()
        let image = symbolImage
        let titleSize = title.isEmpty ? .zero : (title as NSString).size(withAttributes: titleAttributes)
        let iconWidth = image?.size.width ?? 0
        let total = iconWidth + (iconWidth > 0 && titleSize.width > 0 ? 5 : 0) + titleSize.width
        var x = round(bounds.midX - total / 2)
        if let image = image {
            image.draw(in: NSRect(x: x, y: round(bounds.midY - image.size.height / 2), width: image.size.width, height: image.size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += iconWidth + 5
        }
        if titleSize.width > 0 {
            (title as NSString).draw(at: NSPoint(x: x, y: round(bounds.midY - titleSize.height / 2)), withAttributes: titleAttributes)
        }
    }
}

final class ClockController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let defaults = CommandLine.arguments.contains("--alert-ui-self-test") ? UserDefaults(suiteName: "local.floatingclock.alert-ui-test")! : UserDefaults.standard
    var panel: NSPanel!
    var clockView: ClockView!
    var statusItem: NSStatusItem!
    var timer: Timer?
    var quotaTimer: Timer?
    let quota = QuotaLoader()
    let quotaScroll = NSScrollView()
    let quotaContent = QuotaContentView()
    let disclosureButton = HUDButton(symbol: "chevron.right", title: "展开额度")
    let queryButton = HUDButton(symbol: "arrow.clockwise", title: "查询")
    let settingsButton = HUDButton(symbol: "gearshape", title: "")
    static let footerHeight: CGFloat = 44
    var appearance: ClockAppearance { ClockAppearance(defaults: defaults) }
    lazy var appearanceSettings = AppearanceSettings(controller: self)
    lazy var alertTracker = QuotaAlertTracker(defaults: defaults)
    let alertPresenter = QuotaAlertPresenter()
    var alertsEnabled: Bool { !defaults.bool(forKey: "quotaAlertsDisabled") }
    var alertsOnLeft: Bool { defaults.bool(forKey: "quotaAlertsOnLeft") }
    var showQuota: Bool { !defaults.bool(forKey: "hideQuota") }
    var secondsFontSize: CGFloat { round(fontSize * 0.5) }
    var dateFontSize: CGFloat { max(11, round(fontSize * 0.33)) }
    var dateGap: CGFloat { round(fontSize * 0.3) }
    /// 数字顶端到窗口上沿的留白；下方留白较小，与工具条间距合起来与上方视觉相等。
    var clockTopPadding: CGFloat { round(max(18, fontSize * 0.46)) }
    var clockHeight: CGFloat {
        let capHeight = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium).capHeight
        let block = capHeight + (showDate ? dateGap + dateFontSize * 0.86 : 0)
        return ceil(block + clockTopPadding * 1.6)
    }
    var showSeconds: Bool { !defaults.bool(forKey: "hideSeconds") }
    var showDate: Bool { !defaults.bool(forKey: "hideDate") }
    var locked: Bool { defaults.bool(forKey: "locked") }
    var fontSize: CGFloat {
        let stored = defaults.double(forKey: "fontSize")
        return stored > 0 ? stored : 36
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--alert-ui-self-test") {
            defaults.removePersistentDomain(forName: "local.floatingclock.alert-ui-test")
        }
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "悬浮时钟"
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        clockView = ClockView(frame: panel.contentView!.bounds)
        clockView.autoresizingMask = [.width, .height]
        clockView.controller = self
        panel.contentView = clockView
        quotaContent.controller = self
        quotaScroll.drawsBackground = false
        quotaScroll.hasVerticalScroller = true
        quotaScroll.autohidesScrollers = true
        quotaScroll.documentView = quotaContent
        clockView.addSubview(quotaScroll)
        for button in [disclosureButton, queryButton, settingsButton] {
            button.target = self
            clockView.addSubview(button)
        }
        disclosureButton.action = #selector(toggleQuota)
        queryButton.action = #selector(refreshQuota)
        queryButton.toolTip = "立即查询额度"
        queryButton.setAccessibilityLabel("查询额度")
        settingsButton.toolTip = "设置背景透明度和颜色"
        settingsButton.setAccessibilityLabel("外观设置")
        settingsButton.action = #selector(showAppearanceSettings)
        applySettings()
        if defaults.object(forKey: "originX") != nil {
            let saved = NSPoint(x: defaults.double(forKey: "originX"), y: defaults.double(forKey: "originY"))
            let candidate = NSRect(origin: saved, size: panel.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(candidate) }) {
                panel.setFrameOrigin(saved)
            } else { resetPosition() }
        } else { resetPosition() }
        panel.delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "悬浮时钟设置")
        refreshMenu()
        panel.orderFrontRegardless()
        let ticker = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.clockView.needsDisplay = true
            if self?.showQuota == true { self?.quotaContent.needsDisplay = true }
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
        quota.onChange = { [weak self] in self?.applySettings() }
        quota.onSnapshot = { [weak self] source, response in
            guard let self = self else { return }
            let alerts = self.alertTracker.consume(response, source: source.path, title: source.title, notify: self.alertsEnabled && !self.showQuota, visibleAlerts: self.alertPresenter.visibleAlerts)
            if !self.showQuota && self.alertsEnabled {
                self.alertPresenter.show(alerts, anchor: self.panel.frame, screen: self.panel.screen, left: self.alertsOnLeft)
            }
        }
        if CommandLine.arguments.contains("--alert-ui-self-test") {
            runQuotaAlertUITests(self)
            defaults.removePersistentDomain(forName: "local.floatingclock.alert-ui-test")
            NSApp.terminate(nil)
            return
        }
        quota.refresh()
        let refresher = Timer(timeInterval: QuotaAlertPolicy.refreshInterval, repeats: true) { [weak self] _ in self?.quota.refresh(userTriggered: false) }
        RunLoop.main.add(refresher, forMode: .common)
        quotaTimer = refresher
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if CommandLine.arguments.contains("--show-settings") {
            showAppearanceSettings()
        }
    }

    func item(_ title: String, action: Selector, checked: Bool? = nil, tag: Int = 0) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: "")
        result.target = self
        result.tag = tag
        if let checked = checked { result.state = checked ? .on : .off }
        return result
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let hint = NSMenuItem(title: "拖动时钟移动 · 右键打开设置", action: nil, keyEquivalent: "")
        menu.addItem(hint)
        menu.addItem(.separator())
        menu.addItem(item("锁定位置（鼠标穿透）", action: #selector(toggleLock), checked: locked))
        menu.addItem(item("显示秒", action: #selector(toggleSeconds), checked: showSeconds))
        menu.addItem(item("显示日期", action: #selector(toggleDate), checked: showDate))
        menu.addItem(item("外观设置（透明度与颜色）", action: #selector(showAppearanceSettings)))
        let reminderSettings = NSMenuItem(title: "额度冒泡设置", action: nil, keyEquivalent: "")
        let reminderMenu = NSMenu()
        reminderMenu.addItem(item("仅收起时提醒", action: #selector(toggleAlerts), checked: alertsEnabled))
        reminderMenu.addItem(item("时钟左上角", action: #selector(setAlertCorner(_:)), checked: alertsOnLeft, tag: 1))
        reminderMenu.addItem(item("时钟右上角", action: #selector(setAlertCorner(_:)), checked: !alertsOnLeft, tag: 0))
        reminderMenu.addItem(.separator())
        let persistenceHint = NSMenuItem(title: "冒泡常驻，单条关闭或展开后清除", action: nil, keyEquivalent: "")
        reminderMenu.addItem(persistenceHint)
        reminderMenu.addItem(item("清除全部冒泡", action: #selector(clearAlerts)))
        reminderMenu.addItem(item("测试提醒（需先收起额度）", action: #selector(testAlert)))
        reminderSettings.submenu = reminderMenu
        menu.addItem(reminderSettings)
        menu.addItem(item(showQuota ? "收起全部额度" : "展开全部额度", action: #selector(toggleQuota)))
        menu.addItem(item("立即刷新额度", action: #selector(refreshQuota)))
        menu.addItem(item("打开额度网页", action: #selector(openQuota)))
        for (title, size) in [("小号", 26), ("中号", 36), ("大号", 52)] {
            menu.addItem(item(title, action: #selector(setSize(_:)), checked: Int(fontSize) == size, tag: size))
        }
        menu.addItem(.separator())
        menu.addItem(item("移回主屏幕右上角", action: #selector(resetPosition)))
        menu.addItem(item("退出悬浮时钟", action: #selector(quit)))
        return menu
    }

    func refreshMenu() { statusItem?.menu = makeMenu() }

    func applySettings() {
        if showQuota || !alertsEnabled { alertPresenter.dismiss() }
        let width = max(320, ceil(fontSize * (showSeconds ? 5.25 : 3.5) + 36))
        let footer = Self.footerHeight
        let quotaHeight = showQuota ? quota.lines.reduce(CGFloat(8)) { $0 + $1.height } : 0
        let availableHeight = max(200, (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 800) - 48
        let size = NSSize(width: width, height: min(clockHeight + footer + quotaHeight, availableHeight))
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
        quotaScroll.isHidden = !showQuota
        // 底部工具条：左侧展开／收起，右侧查询与外观设置；两种状态下位置不变。
        disclosureButton.symbol = showQuota ? "chevron.down" : "chevron.right"
        disclosureButton.title = showQuota ? "收起额度" : "展开额度"
        disclosureButton.setAccessibilityLabel(showQuota ? "收起全部额度" : "展开全部额度")
        let loading = quota.sources.contains { $0.loading }
        queryButton.isEnabled = !loading
        queryButton.title = loading ? "查询中…" : "查询"
        let row: CGFloat = 26
        settingsButton.frame = NSRect(x: width - 10 - row, y: 10, width: row, height: row)
        let queryWidth = queryButton.fittingWidth
        queryButton.frame = NSRect(x: settingsButton.frame.minX - 6 - queryWidth, y: 10, width: queryWidth, height: row)
        disclosureButton.frame = NSRect(x: 10, y: 10, width: disclosureButton.fittingWidth, height: row)
        // 滚动区与内容等高，不再因 6pt 差值常驻滚动条；仅在超出屏幕时滚动。
        quotaScroll.frame = NSRect(x: 0, y: footer, width: width, height: max(0, size.height - clockHeight - footer))
        let previousHeight = quotaContent.frame.height
        quotaContent.setFrameSize(NSSize(width: quotaScroll.contentSize.width, height: quotaHeight))
        if previousHeight != quotaHeight {
            quotaContent.scroll(NSPoint(x: 0, y: max(0, quotaHeight - quotaScroll.contentSize.height)))
        }
        quotaContent.needsDisplay = true
        panel.isMovableByWindowBackground = !locked
        panel.ignoresMouseEvents = locked
        refreshAppearance()
        keepVisible()
        refreshMenu()
    }

    func keepVisible() {
        if !NSScreen.screens.contains(where: { $0.visibleFrame.contains(panel.frame) }) { resetPosition() }
    }

    func refreshAppearance() {
        let palette = appearance.palette
        for button in [disclosureButton, queryButton, settingsButton] { button.palette = palette }
        clockView.needsDisplay = true
        quotaContent.needsDisplay = true
        alertPresenter.updateAppearance(appearance)
    }

    @objc func toggleLock() { defaults.set(!locked, forKey: "locked"); applySettings() }
    @objc func toggleSeconds() { defaults.set(showSeconds, forKey: "hideSeconds"); applySettings() }
    @objc func toggleDate() { defaults.set(showDate, forKey: "hideDate"); applySettings() }
    @objc func toggleQuota() {
        let wasExpanded = showQuota
        if wasExpanded { alertTracker.captureDisplayBaselines(quota.sources) }
        defaults.set(wasExpanded, forKey: "hideQuota")
        applySettings()
    }
    @objc func refreshQuota() { quota.refresh(userTriggered: true) }
    @objc func showAppearanceSettings() { appearanceSettings.show() }
    @objc func openQuota() { NSWorkspace.shared.open(quota.baseURL.appendingPathComponent("quota")) }
    @objc func setSize(_ sender: NSMenuItem) { defaults.set(sender.tag, forKey: "fontSize"); applySettings() }
    @objc func screenChanged() {
        applySettings()
        alertPresenter.reposition(anchor: panel.frame, screen: panel.screen, left: alertsOnLeft)
    }
    @objc func toggleAlerts() {
        defaults.set(alertsEnabled, forKey: "quotaAlertsDisabled")
        applySettings()
    }
    @objc func setAlertCorner(_ sender: NSMenuItem) {
        defaults.set(sender.tag == 1, forKey: "quotaAlertsOnLeft")
        alertPresenter.reposition(anchor: panel.frame, screen: panel.screen, left: alertsOnLeft)
        refreshMenu()
    }
    @objc func clearAlerts() { alertPresenter.dismiss() }
    @objc func testAlert() {
        guard !showQuota && alertsEnabled else { return }
        alertPresenter.show([QuotaAlert(key: "test", title: "本机 · 示例账户 · 周额度", detail: "测试提醒 · 实际额度未改变", exhausted: false, previousRemaining: 90, remainingPercent: 80, resetAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)))], anchor: panel.frame, screen: panel.screen, left: alertsOnLeft)
    }
    @objc func resetPosition() {
        guard let screen = NSScreen.screens.first else { return }
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 24, y: screen.visibleFrame.maxY - panel.frame.height - 24))
    }
    func windowDidMove(_ notification: Notification) {
        defaults.set(panel.frame.origin.x, forKey: "originX")
        defaults.set(panel.frame.origin.y, forKey: "originY")
        alertPresenter.reposition(anchor: panel.frame, screen: panel.screen, left: alertsOnLeft)
    }
    @objc func quit() { NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--self-test") {
    let date = Date(timeIntervalSince1970: 0)
    precondition(displayedDate(date).timeIntervalSince(date) == 57600)
    let withSeconds = clockText(date, seconds: true)
    let withoutSeconds = clockText(date, seconds: false)
    precondition(withSeconds.count == 8 && withoutSeconds.count == 5)
    precondition(String(withSeconds.prefix(5)) == withoutSeconds)
    let testSuite = "local.floatingclock.appearance-test.\(UUID().uuidString)"
    let testDefaults = UserDefaults(suiteName: testSuite)!
    let appearance = ClockAppearance(defaults: testDefaults)
    precondition(appearance.transparency == 85)
    precondition(abs(appearance.fill.alphaComponent - 0.15) < 0.0001)
    appearance.setTransparency(75)
    precondition(ClockAppearance(defaults: testDefaults).transparency == 75)
    precondition(abs(appearance.fill.alphaComponent - 0.25) < 0.0001)
    appearance.setTransparency(150)
    precondition(appearance.transparency == 100)
    appearance.setTransparency(-10)
    precondition(appearance.transparency == 0)
    appearance.setColor(NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    precondition(abs(appearance.color.usingColorSpace(.sRGB)!.greenComponent - 0.4) < 0.0001)
    testDefaults.removePersistentDomain(forName: testSuite)
    print("PASS: appearance defaults, transparency bounds, alpha conversion and color persistence")
    runQuotaAlertTests()
    runQuotaFreshnessTests()
    for path in CommandLine.arguments.dropFirst(2) {
        let response = try JSONDecoder().decode(QuotaResponse.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let source = QuotaSource(path: "test", title: "测试")
        source.response = response
        precondition(!source.lines.isEmpty)
        precondition(source.lines.filter { $0.remaining != nil }.count == response.accounts.filter { ["ok", "stale"].contains($0.status) }.flatMap { $0.windows ?? [] }.count)
        precondition(source.lines.filter { $0.accountStart }.count == response.accounts.count)
        precondition(source.lines.filter { $0.accountEnd }.count == response.accounts.count)
        source.failed = true
        precondition(source.lines.contains { $0.title.contains("上次数据") })
        print("PASS: quota decoding, rendering rows and stale status: \(path)")
    }
    print("PASS: 24-hour clock formatting with and without seconds")
} else {
    let app = NSApplication.shared
    let controller = ClockController()
    app.setActivationPolicy(.accessory)
    app.delegate = controller
    app.run()
}

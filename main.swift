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
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 16, yRadius: 16)
        controller.appearance.fill.setFill()
        shape.fill()
        NSColor(white: 1, alpha: 0.15).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let now = displayedDate(Date())
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let timeAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: controller.fontSize, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let text = clockText(now, seconds: controller.showSeconds)
        let textHeight = (text as NSString).size(withAttributes: timeAttributes).height
        let clockBottom = bounds.height - controller.clockHeight
        let baseline = clockBottom + (controller.clockHeight - textHeight) / 2 + (controller.showDate ? 10 : 0)
        (text as NSString).draw(in: NSRect(x: 8, y: baseline, width: bounds.width - 16, height: textHeight), withAttributes: timeAttributes)
        if controller.showDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日  EEEE"
            (formatter.string(from: now) as NSString).draw(in: NSRect(x: 8, y: baseline - 22, width: bounds.width - 16, height: 19), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor(white: 1, alpha: 0.65),
                .paragraphStyle: paragraph
            ])
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = controller?.makeMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
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
    let disclosureButton = NSButton(title: "", target: nil, action: nil)
    let queryButton = NSButton(title: "查询额度", target: nil, action: nil)
    let settingsButton = NSButton(title: "", target: nil, action: nil)
    var appearance: ClockAppearance { ClockAppearance(defaults: defaults) }
    lazy var appearanceSettings = AppearanceSettings(controller: self)
    lazy var alertTracker = QuotaAlertTracker(defaults: defaults)
    let alertPresenter = QuotaAlertPresenter()
    var alertsEnabled: Bool { !defaults.bool(forKey: "quotaAlertsDisabled") }
    var alertsOnLeft: Bool { defaults.bool(forKey: "quotaAlertsOnLeft") }
    var showQuota: Bool { !defaults.bool(forKey: "hideQuota") }
    var clockHeight: CGFloat { ceil(fontSize * 1.35 + (showDate ? 44 : 22)) }
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
        for button in [disclosureButton, queryButton] {
            button.target = self
            button.bezelStyle = .rounded
            button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            button.appearance = NSAppearance(named: .darkAqua)
            clockView.addSubview(button)
        }
        disclosureButton.action = #selector(toggleQuota)
        queryButton.action = #selector(refreshQuota)
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "外观设置")
        settingsButton.isBordered = false
        settingsButton.contentTintColor = .white
        settingsButton.toolTip = "设置背景透明度和颜色"
        settingsButton.setAccessibilityLabel("外观设置")
        settingsButton.target = self
        settingsButton.action = #selector(showAppearanceSettings)
        clockView.addSubview(settingsButton)
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
        let quotaHeight = showQuota ? quota.lines.reduce(CGFloat(24)) { $0 + $1.height } : 0
        let availableHeight = max(200, (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 800) - 48
        let size = NSSize(width: width, height: min(clockHeight + 76 + quotaHeight, availableHeight))
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
        quotaScroll.isHidden = !showQuota
        disclosureButton.title = showQuota ? "▾ 收起全部额度" : "▸ 展开全部额度"
        disclosureButton.frame = NSRect(x: 14, y: size.height - clockHeight - 29, width: width - 28, height: 26)
        queryButton.frame = NSRect(x: 14, y: 12, width: width - 66, height: 28)
        settingsButton.frame = NSRect(x: width - 44, y: 12, width: 30, height: 28)
        let loading = quota.sources.contains { $0.loading }
        queryButton.isEnabled = !loading
        queryButton.title = loading ? "正在查询…" : "查询额度"
        quotaScroll.frame = NSRect(x: 0, y: 48, width: width, height: max(0, size.height - clockHeight - 82))
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
        clockView.needsDisplay = true
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

import AppKit

func runQuotaFreshnessTests() {
    let initial = Date(timeIntervalSince1970: 1_800_000_000)
    let timestamp = ISO8601DateFormatter().string(from: initial)
    let window = QuotaWindow(group: nil, label: "已用 20 GB", remaining_percent: 98, reset_at: nil)
    var account = QuotaAccount(label: "Traffic proxy", status: "ok", message: nil, windows: [window], provider: "decodo", last_success_at: timestamp, refresh_interval_seconds: 900, stale: false)
    precondition(!account.isDataStale(at: initial.addingTimeInterval(899)))
    precondition(account.isDataStale(at: initial.addingTimeInterval(900)))
    precondition(account.isDataStale(at: initial.addingTimeInterval(-1)))
    precondition(account.freshnessLine(at: initial)?.detail == "上次成功 " + shortTime(timestamp, date: true))
    precondition(account.freshnessLine(at: initial)?.title == "每 15 分钟抓取")
    account.refresh_interval_seconds = 300
    precondition(account.freshnessLine(at: initial)?.title == "每 5 分钟抓取")
    account.refresh_interval_seconds = 900
    account.stale = true
    precondition(account.freshnessLine(at: initial)?.warning == true)
    account.refreshing = true
    precondition(account.freshnessLine(at: initial)?.title == "数据已过期 · 抓取中")
    account = QuotaAccount(label: "Traffic proxy", status: "stale", message: nil, windows: [window], provider: "decodo", last_success_at: timestamp, refresh_interval_seconds: 900, stale: true)
    let source = QuotaSource(path: "test", title: "测试")
    source.response = QuotaResponse(updated_at: ISO8601DateFormatter().string(from: Date()), accounts: [account])
    precondition(source.lines.filter { $0.remaining != nil }.count == 1)
    precondition(source.lines.contains { $0.title == "数据已过期" && $0.warning })
    precondition(source.lines.contains { $0.detail == "上次成功 " + shortTime(timestamp, date: true) })
    account.last_success_at = nil
    precondition(account.freshnessLine(at: initial)?.detail == "上次成功 暂无")
    let legacy = QuotaAccount(label: "Other account", status: "ok", message: nil, windows: [window])
    precondition(legacy.freshnessLine(at: initial) == nil)
    let payload = """
    {"updated_at":"2030-01-01T00:00:00Z","accounts":[{"label":"Traffic proxy","provider":"decodo","status":"stale","last_success_at":"2029-12-31T23:50:00.000Z","refresh_interval_seconds":900,"stale":true,"refreshing":false,"windows":[]}]}
    """
    let decoded = try! JSONDecoder().decode(QuotaResponse.self, from: Data(payload.utf8))
    precondition(decoded.accounts[0].last_success_at == "2029-12-31T23:50:00.000Z")
    precondition(decoded.accounts[0].stale == true)
    print("PASS: Decodo success timestamps, fifteen-minute expiry, stale cached rows and backwards-compatible decoding")
}

func runQuotaBubbleUpdateTests() {
    let suite = "local.floatingclock.bubble-update-test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let tracker = QuotaAlertTracker(defaults: defaults)
    var visible: [String: QuotaAlert] = [:]
    var sequence = 0
    var lastSnapshot: QuotaResponse?
    func sample(_ remaining: Double, account: String = "Live quota", group: String? = nil, seconds: Double = 604800, provider: String? = nil, status: String = "ok", notify: Bool = true, reset: String? = "2031-01-01T00:00:00Z") -> [QuotaAlert] {
        sequence += 1
        let date = Date(timeIntervalSince1970: 1_900_000_000 + Double(sequence))
        let label = seconds == 18000 ? "5h" : provider == "decodo" ? "已用 \(100 - remaining) GB" : "周额度"
        let window = QuotaWindow(group: group, label: label, remaining_percent: remaining, reset_at: reset, window_seconds: seconds)
        let quota = QuotaAccount(label: account, status: status, message: nil, windows: [window], provider: provider)
        let snapshot = QuotaResponse(updated_at: ISO8601DateFormatter().string(from: date), accounts: [quota])
        lastSnapshot = snapshot
        let alerts = tracker.consume(snapshot, source: "local", title: "本机", notify: notify, visibleAlerts: visible)
        for alert in alerts { visible[alert.key] = alert }
        return alerts
    }
    precondition(sample(80).isEmpty)
    let first = sample(76)
    precondition(first.count == 1 && first[0].previousRemaining == 80)
    precondition(first[0].resetAt == "2031-01-01T00:00:00Z")
    precondition(first[0].resetText == "重置 " + shortTime("2031-01-01T00:00:00Z", date: true))
    var missingReset = first[0]
    missingReset.resetAt = nil
    precondition(missingReset.resetText == "重置时间未知")
    missingReset.resetAt = "invalid"
    precondition(missingReset.resetText == "重置时间未知")
    missingReset.resetAt = "2031-01-01T00:00:00.123Z"
    precondition(missingReset.resetText == "重置 " + shortTime(missingReset.resetAt!, date: true))
    precondition(sample(75.6).isEmpty)
    let onePoint = sample(75)
    precondition(onePoint.count == 1 && onePoint[0].key == first[0].key && onePoint[0].previousRemaining == 80)
    precondition(sample(74).first?.remainingPercent == 74)
    precondition(sample(72.4).count == 1)
    precondition(sample(72).isEmpty)
    precondition(sample(71.4).count == 1)
    precondition(sample(70.4, status: "stale").isEmpty)
    precondition(sample(70.4).count == 1)
    precondition(tracker.consume(lastSnapshot!, source: "local", title: "本机", notify: true, visibleAlerts: visible).isEmpty)
    visible.removeAll()
    precondition(sample(69.4).isEmpty)
    precondition(sample(68).count == 1)
    visible.removeAll()
    precondition(sample(67, notify: false).isEmpty)
    precondition(sample(66).isEmpty)
    precondition(sample(64).count == 1)
    precondition(sample(100, account: "Twenty-point", group: "Claude and GPT models").isEmpty)
    precondition(sample(81, account: "Twenty-point", group: "Claude and GPT models").isEmpty)
    let twenty = sample(80, account: "Twenty-point", group: "Claude and GPT models")
    precondition(twenty.count == 1)
    let twentyUpdate = sample(79, account: "Twenty-point", group: "Claude and GPT models")
    precondition(twentyUpdate.count == 1 && twentyUpdate[0].previousRemaining == 100)
    precondition(sample(78.5, account: "Twenty-point", group: "Claude and GPT models").isEmpty)
    precondition(sample(78, account: "Twenty-point", group: "Claude and GPT models").count == 1)
    visible.removeValue(forKey: twenty[0].key)
    precondition(sample(77, account: "Twenty-point", group: "Claude and GPT models").isEmpty)
    precondition(sample(80.3, account: "Decimal quota").isEmpty)
    precondition(sample(76.3, account: "Decimal quota").count == 1)
    precondition(sample(75.4, account: "Decimal quota").isEmpty)
    precondition(sample(75.3, account: "Decimal quota").count == 1)
    precondition(sample(80, account: "Traffic proxy", seconds: 2592000, provider: "decodo").isEmpty)
    let traffic = sample(76, account: "Traffic proxy", seconds: 2592000, provider: "decodo")
    let trafficUpdate = sample(75, account: "Traffic proxy", seconds: 2592000, provider: "decodo")
    precondition(trafficUpdate.count == 1 && trafficUpdate[0].key == traffic[0].key)
    precondition(trafficUpdate[0].previousRemaining == 80 && trafficUpdate[0].title.contains("25.0 GB"))
    precondition(sample(0, account: "Recovery quota", seconds: 18000).first?.exhausted == true)
    precondition(sample(100, account: "Recovery quota", seconds: 18000).first?.recovered == true)
    precondition(sample(99.4, account: "Recovery quota", seconds: 18000).isEmpty)
    let recoveryUpdate = sample(99, account: "Recovery quota", seconds: 18000)
    precondition(recoveryUpdate.count == 1 && recoveryUpdate[0].recovered && recoveryUpdate[0].previousRemaining == 0)
    let shiftedReset = sample(98, account: "Recovery quota", seconds: 18000, reset: "2032-01-01T00:00:00Z")
    precondition(shiftedReset.count == 1 && shiftedReset[0].recovered && shiftedReset[0].remainingPercent == 98)
    precondition(shiftedReset[0].resetAt == "2032-01-01T00:00:00Z")
    precondition(sample(0, account: "Recovery quota", seconds: 18000).first?.exhausted == true)
    precondition(sample(80, account: "Reset-only quota").isEmpty)
    precondition(sample(76, account: "Reset-only quota").count == 1)
    let resetOnly = sample(75.6, account: "Reset-only quota", reset: "2032-01-01T00:00:00Z")
    precondition(resetOnly.count == 1 && resetOnly[0].remainingPercent == 76 && resetOnly[0].previousRemaining == 80)
    precondition(resetOnly[0].resetAt == "2032-01-01T00:00:00Z")
    precondition(sample(75.3, account: "Reset-only quota", reset: "2032-01-01T00:00:00Z").isEmpty)
    precondition(sample(75, account: "Reset-only quota", reset: "2032-01-01T00:00:00Z").first?.remainingPercent == 75)
    let removedReset = sample(74.8, account: "Reset-only quota", reset: nil)
    precondition(removedReset.count == 1 && removedReset[0].remainingPercent == 75 && removedReset[0].resetText == "重置时间未知")
    precondition(sample(0, account: "Exhausted reset", seconds: 18000).first?.exhausted == true)
    let exhaustedReset = sample(0, account: "Exhausted reset", seconds: 18000, reset: "2032-01-01T00:00:00Z")
    precondition(exhaustedReset.count == 1 && exhaustedReset[0].exhausted && exhaustedReset[0].remainingPercent == 0)
    precondition(exhaustedReset[0].resetAt == "2032-01-01T00:00:00Z")
    print("PASS: first-bubble gates, one-point updates, reset timestamps, metadata-only replacement and recovery styling")
}

func runQuotaAlertTests() {
    let suite = "local.floatingclock.alert-test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let tracker = QuotaAlertTracker(defaults: defaults)
    let initial = Date(timeIntervalSince1970: 1_800_000_000)
    var sequence = 0
    func snapshot(_ remaining: Double, reset: String? = "2030-01-01T00:00:00Z", status: String = "ok", account: String = "Test", group: String? = nil) -> QuotaResponse {
        sequence += 1
        return QuotaResponse(updated_at: ISO8601DateFormatter().string(from: initial.addingTimeInterval(Double(sequence))), accounts: [QuotaAccount(label: account, status: status, message: nil, windows: [QuotaWindow(group: group, label: "周额度", remaining_percent: remaining, reset_at: reset)])])
    }
    func consume(_ response: QuotaResponse, notify: Bool = true, source: String = "local", using custom: QuotaAlertTracker? = nil) -> [QuotaAlert] {
        (custom ?? tracker).consume(response, source: source, title: source, notify: notify)
    }
    precondition(QuotaAlertPolicy.refreshInterval == 120)
    precondition(consume(snapshot(99)).isEmpty)
    precondition(consume(snapshot(96)).count == 1)
    precondition(consume(snapshot(95)).isEmpty)
    precondition(consume(snapshot(92)).count == 1)
    precondition(consume(snapshot(99)).isEmpty)
    precondition(consume(snapshot(92)).isEmpty)
    precondition(consume(snapshot(48)).count == 1)
    let exhausted = consume(snapshot(0))
    precondition(exhausted.count == 1 && exhausted[0].exhausted)
    precondition(exhausted[0].previousRemaining == 99 && exhausted[0].remainingPercent == 0)
    precondition(consume(snapshot(0)).isEmpty)
    precondition(consume(snapshot(100, reset: "2030-01-08T00:00:00Z")).isEmpty)
    precondition(consume(snapshot(96, reset: "2030-01-08T00:00:00Z")).count == 1)
    precondition(consume(snapshot(92, reset: "2030-01-08T00:00:00Z"), notify: false).isEmpty)
    precondition(consume(snapshot(91, reset: "2030-01-08T00:00:00Z")).isEmpty)
    precondition(consume(snapshot(88, reset: "2030-01-08T00:00:00Z")).count == 1)
    let cached = snapshot(84, reset: "2030-01-08T00:00:00Z")
    precondition(consume(cached).count == 1)
    precondition(consume(cached).isEmpty)
    precondition(consume(QuotaResponse(updated_at: "2020-01-01T00:00:00Z", accounts: cached.accounts)).isEmpty)
    precondition(consume(QuotaResponse(updated_at: "invalid", accounts: cached.accounts)).isEmpty)
    let restored = QuotaAlertTracker(defaults: defaults)
    precondition(consume(cached, using: restored).isEmpty)
    precondition(consume(snapshot(83, reset: "2030-01-08T00:00:00Z"), using: restored).isEmpty)
    precondition(consume(snapshot(80, reset: "2030-01-08T00:00:00Z"), using: restored).count == 1)
    precondition(consume(snapshot(0, status: "unavailable"), using: restored).isEmpty)
    precondition(consume(snapshot(79, reset: "2030-01-08T00:00:00Z"), using: restored).isEmpty)
    precondition(consume(snapshot(0, account: "New account")).isEmpty)
    precondition(consume(snapshot(80), source: "remote").isEmpty)
    precondition(consume(snapshot(76), source: "remote").count == 1)
    precondition(consume(snapshot(80, group: "Other model")).isEmpty)
    precondition(consume(snapshot(76, group: "Other model")).count == 1)
    precondition(consume(snapshot(80, reset: nil, account: "No reset")).isEmpty)
    precondition(consume(snapshot(76, reset: nil, account: "No reset")).count == 1)
    precondition(consume(snapshot(100, reset: nil, account: "No reset")).isEmpty)
    precondition(consume(snapshot(96, reset: nil, account: "No reset")).count == 1)
    for group in ["Claude and GPT models", "Gemini 4 Argon"] {
        precondition(consume(snapshot(100, group: group)).isEmpty)
        precondition(consume(snapshot(96, group: group)).isEmpty)
        precondition(consume(snapshot(81, group: group)).isEmpty)
        precondition(consume(snapshot(80, group: group)).count == 1)
        precondition(consume(snapshot(61, group: group)).isEmpty)
        precondition(consume(snapshot(60, group: group)).count == 1)
        precondition(consume(snapshot(0, group: group)).first?.exhausted == true)
    }
    for label in ["5 小时", "5 小时额度", "5h", "5-hour quota", "短期窗口"] {
        func shortSnapshot(_ remaining: Double, reset: String? = "2030-01-01T00:00:00Z") -> QuotaResponse {
            let model = snapshot(remaining, account: label)
            let window = QuotaWindow(group: nil, label: label, remaining_percent: remaining, reset_at: reset, window_seconds: 18000)
            let account = QuotaAccount(label: label, status: "ok", message: nil, windows: [window])
            precondition(QuotaAlertPolicy.step(account: account, window: window) == nil)
            return QuotaResponse(updated_at: model.updated_at, accounts: [account])
        }
        for remaining in [100.0, 80, 4] { precondition(consume(shortSnapshot(remaining)).isEmpty) }
        let depleted = consume(shortSnapshot(0))
        precondition(depleted.count == 1 && depleted[0].exhausted)
        precondition(consume(shortSnapshot(0)).isEmpty)
        precondition(consume(shortSnapshot(0), using: QuotaAlertTracker(defaults: defaults)).isEmpty)
        let recovery = consume(shortSnapshot(100, reset: "2030-01-02T00:00:00Z"))
        precondition(recovery.count == 1 && recovery[0].recovered && !recovery[0].exhausted)
        precondition(consume(shortSnapshot(100, reset: "2030-01-02T00:00:00Z")).isEmpty)
        precondition(consume(shortSnapshot(99, reset: "2030-01-02T00:00:00Z"), using: QuotaAlertTracker(defaults: defaults)).isEmpty)
        precondition(consume(shortSnapshot(0, reset: "2030-01-02T00:00:00Z")).first?.exhausted == true)
        precondition(consume(shortSnapshot(100, reset: "2030-01-03T00:00:00Z"), notify: false).isEmpty)
        precondition(consume(shortSnapshot(99, reset: "2030-01-03T00:00:00Z")).isEmpty)
        precondition(consume(shortSnapshot(0, reset: "2030-01-03T00:00:00Z"), notify: false).isEmpty)
        precondition(consume(shortSnapshot(0, reset: "2030-01-03T00:00:00Z")).isEmpty)
        precondition(consume(shortSnapshot(100, reset: "2030-01-04T00:00:00Z")).first?.recovered == true)
        precondition(consume(shortSnapshot(0, reset: "2030-01-05T00:00:00Z")).first?.exhausted == true)
        precondition(consume(shortSnapshot(0, reset: "2030-01-06T00:00:00Z")).isEmpty)
        precondition(consume(shortSnapshot(20, reset: nil)).first?.recovered == true)
        precondition(consume(shortSnapshot(0, reset: nil)).first?.exhausted == true)
        precondition(consume(shortSnapshot(0, reset: nil)).isEmpty)
        precondition(consume(shortSnapshot(50, reset: "2030-01-03T00:00:00Z")).first?.recovered == true)
        precondition(consume(shortSnapshot(49, reset: "2030-01-03T00:00:00Z")).isEmpty)
        precondition(consume(shortSnapshot(0, reset: "2030-01-03T00:00:00Z")).first?.exhausted == true)
        precondition(consume(shortSnapshot(0, reset: "2030-01-03T00:00:00Z")).isEmpty)
    }
    func traffic(_ remaining: Double, used: String) -> QuotaResponse {
        let model = snapshot(remaining)
        let window = QuotaWindow(group: nil, label: "已用 \(used) GB", remaining_percent: remaining, reset_at: "2030-01-01T00:00:00Z", window_seconds: 2592000)
        let account = QuotaAccount(label: "Traffic proxy", status: "ok", message: nil, windows: [window], provider: "decodo")
        return QuotaResponse(updated_at: model.updated_at, accounts: [account])
    }
    let firstTraffic = traffic(80, used: "20.0")
    precondition(consume(firstTraffic).isEmpty)
    precondition(consume(traffic(77, used: "23.0")).isEmpty)
    precondition(consume(traffic(76, used: "24.0")).count == 1)
    precondition(consume(traffic(75, used: "25.0")).isEmpty)
    precondition(consume(traffic(72, used: "28.0")).count == 1)
    precondition(consume(traffic(0, used: "100.0")).first?.exhausted == true)
    precondition(consume(traffic(0, used: "100.1")).isEmpty)
    let legacySuite = suite + ".legacy"
    let legacyDefaults = UserDefaults(suiteName: legacySuite)!
    defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
    let legacyKey = String(decoding: try! JSONEncoder().encode(["local", "Legacy account", "", "5 小时额度"]), as: UTF8.self) + ":0"
    let legacyState: [String: Any] = ["lowestRemaining": 0.0, "remaining": 0.0, "resetAt": "2030-01-01T00:00:00Z", "updatedAt": initial.timeIntervalSinceReferenceDate]
    legacyDefaults.set(try! JSONSerialization.data(withJSONObject: [legacyKey: legacyState]), forKey: "quotaAlertStates")
    let legacyResponse = QuotaResponse(updated_at: ISO8601DateFormatter().string(from: initial), accounts: [QuotaAccount(label: "Legacy account", status: "ok", message: nil, windows: [QuotaWindow(group: nil, label: "5 小时额度", remaining_percent: 0, reset_at: "2030-01-01T00:00:00Z", window_seconds: 18000)])])
    let legacyTracker = QuotaAlertTracker(defaults: legacyDefaults)
    precondition(legacyTracker.consume(legacyResponse, source: "local", title: "本机", notify: true).first?.exhausted == true)
    precondition(legacyTracker.consume(legacyResponse, source: "local", title: "本机", notify: true).isEmpty)
    precondition(QuotaAlertTracker(defaults: legacyDefaults).consume(legacyResponse, source: "local", title: "本机", notify: true).isEmpty)
    let firstZeroTracker = QuotaAlertTracker(defaults: UserDefaults(suiteName: suite + ".initial-zero")!)
    defer { UserDefaults(suiteName: suite + ".initial-zero")!.removePersistentDomain(forName: suite + ".initial-zero") }
    precondition(firstZeroTracker.consume(legacyResponse, source: "local", title: "本机", notify: true).first?.exhausted == true)
    precondition(firstZeroTracker.consume(legacyResponse, source: "local", title: "本机", notify: true).isEmpty)
    let baselineSource = QuotaSource(path: "local", title: "本机")
    let closeSnapshot = snapshot(80, account: "Baseline account")
    precondition(consume(closeSnapshot, notify: false).isEmpty)
    baselineSource.response = closeSnapshot
    tracker.captureDisplayBaselines([baselineSource])
    let firstDrop = consume(snapshot(76, account: "Baseline account"))
    precondition(firstDrop.count == 1 && firstDrop[0].previousRemaining == 80)
    let secondDrop = consume(snapshot(72, account: "Baseline account"))
    precondition(secondDrop.count == 1 && secondDrop[0].previousRemaining == 80)
    let expandedSnapshot = snapshot(68, account: "Baseline account")
    precondition(consume(expandedSnapshot, notify: false).isEmpty)
    baselineSource.response = expandedSnapshot
    tracker.captureDisplayBaselines([baselineSource])
    precondition(consume(snapshot(64, account: "Baseline account")).first?.previousRemaining == 68)
    precondition(consume(snapshot(60, account: "Baseline account"), using: QuotaAlertTracker(defaults: defaults)).first?.previousRemaining == 68)
    let visible = NSRect(x: -1200, y: 20, width: 1200, height: 780)
    let nearTopRight = QuotaBubbleLayout(anchor: NSRect(x: -330, y: 620, width: 320, height: 170), visible: visible, left: false, count: 1)
    precondition(nearTopRight.tailSide == .right && nearTopRight.frame.maxX <= -330)
    for anchor in [NSRect(x: -900, y: 250, width: 320, height: 170), NSRect(x: -1190, y: 620, width: 320, height: 170), NSRect(x: -330, y: 620, width: 320, height: 170)] {
        for left in [false, true] {
            for count in [1, 3, 26] {
                let layout = QuotaBubbleLayout(anchor: anchor, visible: visible, left: left, count: count)
                precondition(visible.contains(layout.frame))
                precondition(layout.contentHeight >= layout.frame.height)
                precondition(layout.tailOffset >= 28)
            }
        }
    }
    runQuotaBubbleUpdateTests()
    print("PASS: 5h exhaustion/repair, per-quota deduplication, cumulative collapse baseline, baseline persistence and weekly policies")
}

func runQuotaAlertUITests(_ controller: ClockController) {
    controller.defaults.set(true, forKey: "hideQuota")
    controller.applySettings()
    controller.testAlert()
    precondition(controller.alertPresenter.isVisible)
    if let screen = controller.panel.screen, let frame = controller.alertPresenter.displayedFrame {
        precondition(screen.visibleFrame.contains(frame))
    }
    controller.testAlert()
    precondition(controller.alertPresenter.alertCount == 1)
    let newer = QuotaAlert(key: "test", title: "同一额度", detail: "", exhausted: false, previousRemaining: 80, remainingPercent: 76, resetAt: "2031-01-01T00:00:00Z")
    for side in [QuotaTailSide.bottom, .top, .left, .right, .none] {
        let bubble = QuotaSpeechBubbleView(frame: NSRect(x: 0, y: 0, width: 244, height: QuotaBubbleLayout.bubbleHeight), alert: newer, side: side, tailOffset: 40)
        let fields = bubble.subviews.compactMap { $0 as? NSTextField }
        precondition(fields.count == 4 && QuotaBubbleLayout.bubbleHeight == 80)
        precondition(fields.contains { $0.stringValue == newer.resetText })
        for (index, field) in fields.enumerated() {
            precondition(bubble.bounds.contains(field.frame))
            for other in fields.dropFirst(index + 1) { precondition(!field.frame.intersects(other.frame)) }
        }
        let reset = fields.first { $0.stringValue == newer.resetText }!
        precondition((newer.resetText as NSString).size(withAttributes: [.font: reset.font!]).width <= reset.frame.width)
    }
    controller.alertPresenter.show([newer], anchor: controller.panel.frame, screen: controller.panel.screen, left: controller.alertsOnLeft)
    precondition(controller.alertPresenter.alertCount == 1 && controller.alertPresenter.firstBubble!.alert.remainingPercent == 76)
    let otherQuota = QuotaAlert(key: "independent-quota", title: "另一额度", detail: "", exhausted: false, previousRemaining: 60, remainingPercent: 56, resetAt: "2031-01-02T00:00:00Z")
    controller.alertPresenter.show([otherQuota], anchor: controller.panel.frame, screen: controller.panel.screen, left: controller.alertsOnLeft)
    precondition(controller.alertPresenter.alertCount == 2)
    RunLoop.main.run(until: Date().addingTimeInterval(8.2))
    precondition(controller.alertPresenter.isVisible && controller.alertPresenter.alertCount == 2)
    controller.alertPresenter.dismiss(at: 0)
    precondition(controller.alertPresenter.isVisible && controller.alertPresenter.alertCount == 1)
    let frameBeforeAppearanceChange = controller.alertPresenter.displayedFrame
    controller.appearanceSettings.slider.doubleValue = 75
    controller.appearanceSettings.changeTransparency()
    precondition(abs(controller.alertPresenter.firstBubble!.backgroundOpacity - 0.25) < 0.0001)
    controller.appearanceSettings.slider.doubleValue = 85
    controller.appearanceSettings.changeTransparency()
    precondition(abs(controller.alertPresenter.firstBubble!.backgroundOpacity - 0.15) < 0.0001)
    precondition(controller.alertPresenter.displayedFrame == frameBeforeAppearanceChange)
    if let bubble = controller.alertPresenter.firstBubble, let representation = bubble.bitmapImageRepForCachingDisplay(in: bubble.bounds) {
        bubble.cacheDisplay(in: bubble.bounds, to: representation)
        try! representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/floating-clock-speech-preview.png"))
    }
    let leftCorner = NSMenuItem()
    leftCorner.tag = 1
    controller.setAlertCorner(leftCorner)
    precondition(controller.alertPresenter.isVisible && controller.alertPresenter.alertCount == 1)
    let previousFrame = controller.alertPresenter.displayedFrame!
    let originalClockFrame = controller.panel.frame
    let shift: CGFloat = controller.panel.frame.minX > (controller.panel.screen?.visibleFrame.minX ?? 0) + 80 ? -60 : 60
    controller.panel.setFrameOrigin(NSPoint(x: originalClockFrame.minX + shift, y: originalClockFrame.minY))
    controller.alertPresenter.reposition(anchor: controller.panel.frame, screen: controller.panel.screen, left: controller.alertsOnLeft)
    precondition(controller.alertPresenter.displayedFrame != previousFrame)
    controller.panel.setFrame(originalClockFrame, display: true)
    controller.disclosureButton.performClick(nil)
    precondition(controller.showQuota && !controller.alertPresenter.isVisible)
    controller.testAlert()
    precondition(!controller.alertPresenter.isVisible)
    controller.disclosureButton.performClick(nil)
    let source = controller.quota.sources[0]
    func deliver(_ remaining: Double, sequence: Int) {
        let snapshot = QuotaResponse(updated_at: "2030-01-01T00:00:0\(sequence)Z", accounts: [QuotaAccount(label: "UI test", status: "ok", message: nil, windows: [QuotaWindow(group: nil, label: "周额度", remaining_percent: remaining, reset_at: "2030-01-08T00:00:00Z")])])
        controller.quota.onSnapshot?(source, snapshot)
    }
    deliver(95, sequence: 1)
    precondition(!controller.alertPresenter.isVisible)
    deliver(90, sequence: 2)
    precondition(controller.alertPresenter.isVisible)
    controller.disclosureButton.performClick(nil)
    deliver(80, sequence: 3)
    precondition(!controller.alertPresenter.isVisible)
    controller.disclosureButton.performClick(nil)
    deliver(79, sequence: 4)
    precondition(!controller.alertPresenter.isVisible)
    controller.toggleLock()
    deliver(70, sequence: 5)
    precondition(controller.panel.ignoresMouseEvents && controller.alertPresenter.isVisible && controller.alertPresenter.canClose)
    for index in 0..<25 {
        let alert = QuotaAlert(key: "overflow-\(index)", title: "独立额度 \(index)", detail: "", exhausted: false, remainingPercent: 80)
        controller.alertPresenter.show([alert], anchor: controller.panel.frame, screen: controller.panel.screen, left: controller.alertsOnLeft)
    }
    precondition(controller.alertPresenter.alertCount == 26)
    controller.alertPresenter.dismiss(at: 25)
    precondition(controller.alertPresenter.alertCount == 25)
    controller.alertPresenter.dismiss()
    precondition(!controller.alertPresenter.isVisible)
    let recovered = QuotaAlert(key: "recovery-test", title: "测试账户 · 5 小时额度", detail: "", exhausted: false, previousRemaining: 0, remainingPercent: 100, recovered: true, resetAt: "2031-01-01T00:00:00Z")
    controller.alertPresenter.show([recovered], anchor: controller.panel.frame, screen: controller.panel.screen, left: controller.alertsOnLeft)
    let recoveryFields = controller.alertPresenter.firstBubble!.subviews.compactMap { $0 as? NSTextField }
    precondition(recoveryFields.contains { $0.stringValue == "额度已恢复" })
    precondition(recoveryFields.contains { $0.stringValue.contains("100%") })
    precondition(recoveryFields.contains { $0.stringValue == recovered.resetText })
    let exhaustedAgain = QuotaAlert(key: "recovery-test", title: "测试账户 · 5 小时额度", detail: "", exhausted: true, previousRemaining: 5, remainingPercent: 0, resetAt: "2031-01-02T00:00:00Z")
    controller.alertPresenter.show([exhaustedAgain], anchor: controller.panel.frame, screen: controller.panel.screen, left: controller.alertsOnLeft)
    precondition(controller.alertPresenter.alertCount == 1 && controller.alertPresenter.firstBubble!.alert.exhausted)
    let exhaustedFields = controller.alertPresenter.firstBubble!.subviews.compactMap { $0 as? NSTextField }
    precondition(exhaustedFields.contains { $0.stringValue == "已用完" })
    precondition(exhaustedFields.contains { $0.stringValue == exhaustedAgain.resetText })
    controller.alertPresenter.dismiss()
    var cumulativeSequence = 0
    func deliverCumulative(_ remaining: Double, reset: String? = "2031-01-01T00:00:00Z") {
        cumulativeSequence += 1
        let date = Date(timeIntervalSince1970: 1_900_000_000 + Double(cumulativeSequence))
        let snapshot = QuotaResponse(updated_at: ISO8601DateFormatter().string(from: date), accounts: [QuotaAccount(label: "累计测试", status: "ok", message: nil, windows: [QuotaWindow(group: nil, label: "周额度", remaining_percent: remaining, reset_at: reset)])])
        source.response = snapshot
        controller.quota.onSnapshot?(source, snapshot)
    }
    controller.disclosureButton.performClick(nil)
    deliverCumulative(80)
    controller.disclosureButton.performClick(nil)
    deliverCumulative(76)
    precondition(controller.alertPresenter.alertCount == 1 && controller.alertPresenter.firstBubble!.alert.previousRemaining == 80)
    deliverCumulative(75.6)
    precondition(controller.alertPresenter.firstBubble!.alert.remainingPercent == 76)
    deliverCumulative(75.6, reset: "2031-01-02T00:00:00Z")
    let changedReset = controller.alertPresenter.firstBubble!
    precondition(changedReset.alert.remainingPercent == 76 && changedReset.alert.resetAt == "2031-01-02T00:00:00Z")
    precondition(changedReset.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == changedReset.alert.resetText })
    deliverCumulative(75)
    precondition(controller.alertPresenter.alertCount == 1 && controller.alertPresenter.firstBubble!.alert.previousRemaining == 80 && controller.alertPresenter.firstBubble!.alert.remainingPercent == 75)
    deliverCumulative(74)
    precondition(controller.alertPresenter.alertCount == 1 && controller.alertPresenter.firstBubble!.alert.remainingPercent == 74)
    deliverCumulative(72)
    precondition(controller.alertPresenter.alertCount == 1 && controller.alertPresenter.firstBubble!.alert.previousRemaining == 80)
    let cumulativeFields = controller.alertPresenter.firstBubble!.subviews.compactMap { $0 as? NSTextField }
    precondition(cumulativeFields.contains { $0.stringValue == "↓ 8.0 个百分点" })
    controller.disclosureButton.performClick(nil)
    precondition(!controller.alertPresenter.isVisible)
    deliverCumulative(68)
    controller.disclosureButton.performClick(nil)
    deliverCumulative(64)
    precondition(controller.alertPresenter.alertCount == 1 && controller.alertPresenter.firstBubble!.alert.previousRemaining == 68)
    deliverCumulative(63)
    precondition(controller.alertPresenter.alertCount == 1 && controller.alertPresenter.firstBubble!.alert.previousRemaining == 68 && controller.alertPresenter.firstBubble!.alert.remainingPercent == 63)
    controller.alertPresenter.dismiss(at: 0)
    deliverCumulative(62)
    precondition(!controller.alertPresenter.isVisible && controller.alertPresenter.visibleAlerts.isEmpty)
    deliverCumulative(60)
    precondition(controller.alertPresenter.alertCount == 1 && controller.alertPresenter.firstBubble!.alert.remainingPercent == 60)
    controller.disclosureButton.performClick(nil)
    precondition(!controller.alertPresenter.isVisible)
    print("PASS: compact reset-time layout, live reset updates, one-point replacement, cumulative decrease and 5h status rendering")
}

import AppKit

struct QuotaAlert {
    let key: String
    let title: String
    let detail: String
    let exhausted: Bool
    var previousRemaining: Double? = nil
    var remainingPercent: Double? = nil
    var recovered = false
    var resetAt: String? = nil

    var resetText: String {
        guard let resetAt = resetAt, quotaTimestamp(resetAt) != nil else { return "重置时间未知" }
        return "重置 " + shortTime(resetAt, date: true)
    }
}

private struct QuotaAlertState: Codable {
    let lowestRemaining: Double
    let resetAt: String?
    let updatedAt: Date
    let remaining: Double?
    let exhaustionHandled: Bool?
}

func quotaTimestamp(_ value: String) -> Date? {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = parser.date(from: value) { return date }
    parser.formatOptions = [.withInternetDateTime]
    return parser.date(from: value)
}

enum QuotaAlertPolicy {
    static let refreshInterval: TimeInterval = 120

    static func isDecodo(_ account: QuotaAccount) -> Bool {
        let provider = account.provider?.lowercased() ?? ""
        let name = account.label.lowercased()
        return provider == "decodo" || provider == "decode" || name.contains("decodo") || name.contains("decode")
    }

    static func isFiveHour(_ window: QuotaWindow) -> Bool {
        let label = window.label.lowercased().replacingOccurrences(of: " ", with: "")
        return window.window_seconds == 18000 || label.contains("5小时") || label.contains("5h") || label.contains("5-hour")
    }

    static func step(account: QuotaAccount, window: QuotaWindow) -> Double? {
        let label = window.label.lowercased().replacingOccurrences(of: " ", with: "")
        if isFiveHour(window) { return nil }
        if isDecodo(account) { return 4 }
        guard window.window_seconds == 604800 || label.contains("周") || label.contains("week") || label == "7d" else { return nil }
        let group = (window.group ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        return ["claudeandgptmodels", "gemini4argon"].contains(group) ? 20 : 4
    }

    static func windowIdentity(account: QuotaAccount, window: QuotaWindow) -> String {
        guard isDecodo(account) else { return window.label }
        return "traffic:" + (window.window_seconds.map { String($0) } ?? "default")
    }

    static func identity(source: String, account: QuotaAccount, window: QuotaWindow) -> String? {
        let components = [source, account.label, window.group ?? "", windowIdentity(account: account, window: window)]
        guard let encoded = try? JSONEncoder().encode(components) else { return nil }
        return String(decoding: encoded, as: UTF8.self)
    }
}

final class QuotaAlertTracker {
    let defaults: UserDefaults
    private var states: [String: QuotaAlertState]
    private var displayBaselines: [String: Double]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        displayBaselines = defaults.dictionary(forKey: "quotaAlertDisplayBaselines") as? [String: Double] ?? [:]
        states = defaults.data(forKey: "quotaAlertStates").flatMap {
            try? JSONDecoder().decode([String: QuotaAlertState].self, from: $0)
        } ?? [:]
    }

    func captureDisplayBaselines(_ sources: [QuotaSource]) {
        displayBaselines.removeAll()
        for source in sources {
            guard let response = source.response else { continue }
            var occurrences: [String: Int] = [:]
            for account in response.accounts where account.status == "ok" {
                for window in account.windows ?? [] where window.remaining_percent.isFinite {
                    guard QuotaAlertPolicy.step(account: account, window: window) != nil || QuotaAlertPolicy.isFiveHour(window),
                          let identity = QuotaAlertPolicy.identity(source: source.path, account: account, window: window) else { continue }
                    let occurrence = occurrences[identity, default: 0]
                    occurrences[identity] = occurrence + 1
                    displayBaselines[identity + ":\(occurrence)"] = window.remaining
                }
            }
        }
        defaults.set(displayBaselines, forKey: "quotaAlertDisplayBaselines")
    }

    func consume(_ response: QuotaResponse, source: String, title: String, notify: Bool, visibleAlerts: [String: QuotaAlert] = [:]) -> [QuotaAlert] {
        guard let updatedAt = quotaTimestamp(response.updated_at) else { return [] }
        var alerts: [QuotaAlert] = []
        var occurrences: [String: Int] = [:]
        for account in response.accounts where account.status == "ok" {
            for window in account.windows ?? [] where window.remaining_percent.isFinite {
                let step = QuotaAlertPolicy.step(account: account, window: window)
                let fiveHour = QuotaAlertPolicy.isFiveHour(window)
                guard step != nil || fiveHour else { continue }
                guard let identity = QuotaAlertPolicy.identity(source: source, account: account, window: window) else { continue }
                let occurrence = occurrences[identity, default: 0]
                occurrences[identity] = occurrence + 1
                let key = identity + ":\(occurrence)"
                let previous = states[key]
                let remaining = window.remaining
                if displayBaselines[key] == nil {
                    displayBaselines[key] = previous?.remaining ?? remaining
                }
                if let previous = previous, updatedAt <= previous.updatedAt {
                    let repairLegacyExhaustion = fiveHour && remaining == 0 && previous.exhaustionHandled == nil && updatedAt == previous.updatedAt
                    if !repairLegacyExhaustion { continue }
                }
                let recovered = fiveHour && remaining > 0 && previous.map { ($0.remaining ?? $0.lowestRemaining) == 0 } == true
                let resetChanged = previous.map { $0.resetAt != window.reset_at } ?? false
                let recoveredWithoutReset = previous.map {
                    $0.resetAt == nil && window.reset_at == nil && remaining > $0.lowestRemaining
                } ?? false
                let baseline = previous == nil || resetChanged || recoveredWithoutReset || recovered
                let lowest = baseline ? remaining : min(previous!.lowestRemaining, remaining)
                states[key] = QuotaAlertState(lowestRemaining: lowest, resetAt: window.reset_at, updatedAt: updatedAt, remaining: remaining, exhaustionHandled: fiveHour ? remaining == 0 : nil)
                let depleted = fiveHour ? remaining == 0 && previous?.exhaustionHandled != true : !baseline && remaining == 0 && (previous?.lowestRemaining ?? 0) > 0
                var crossed = false
                if !baseline, let step = step, let previous = previous {
                    crossed = Int(ceil(remaining / step)) < Int(ceil(previous.lowestRemaining / step))
                }
                let visible = visibleAlerts[key]
                let updateExisting = visible?.remainingPercent.map { $0 - remaining >= 1 - 0.000001 } == true
                let changed = visible == nil ? crossed : updateExisting
                let reset = window.reset_at.map { "重置 " + shortTime($0, date: true) } ?? "下次查询将继续更新额度"
                if notify, let visible = visible, visible.resetAt != window.reset_at, !depleted && !changed && !recovered {
                    alerts.append(QuotaAlert(key: key, title: visible.title, detail: reset, exhausted: visible.exhausted, previousRemaining: visible.previousRemaining, remainingPercent: visible.remainingPercent, recovered: visible.recovered, resetAt: window.reset_at))
                    continue
                }
                guard notify && (depleted || changed || recovered) else { continue }
                let label = [title, account.label, window.group, window.label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                let updatingExisting = updateExisting && !depleted && !recovered
                let comparison = updatingExisting ? visible?.previousRemaining : recovered ? previous?.remaining ?? previous?.lowestRemaining : displayBaselines[key]
                let showsRecovery = recovered || (updatingExisting && visible?.recovered == true)
                alerts.append(QuotaAlert(key: key, title: label, detail: reset, exhausted: depleted, previousRemaining: comparison, remainingPercent: remaining, recovered: showsRecovery, resetAt: window.reset_at))
            }
        }
        if let encoded = try? JSONEncoder().encode(states) {
            defaults.set(encoded, forKey: "quotaAlertStates")
        }
        defaults.set(displayBaselines, forKey: "quotaAlertDisplayBaselines")
        return alerts
    }
}

final class QuotaAlertPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class QuotaAlertPresenter: NSObject {
    private var window: QuotaAlertPanel?
    private let scroll = NSScrollView()
    private var pending: [QuotaAlert] = []
    private var anchorScreen: NSScreen?
    private var anchorFrame = NSRect.zero
    private var leftCorner = false
    private var bubbleAppearance = ClockAppearance(defaults: .standard)

    var isVisible: Bool { window?.isVisible ?? false }
    var canClose: Bool { window?.ignoresMouseEvents == false }
    var alertCount: Int { pending.count }
    var displayedFrame: NSRect? { window?.frame }
    var firstBubble: QuotaSpeechBubbleView? { scroll.documentView?.subviews.first as? QuotaSpeechBubbleView }
    var visibleAlerts: [String: QuotaAlert] {
        guard isVisible else { return [:] }
        return Dictionary(uniqueKeysWithValues: pending.map { ($0.key, $0) })
    }

    func updateAppearance(_ style: ClockAppearance) {
        bubbleAppearance = style
        for case let bubble as QuotaSpeechBubbleView in scroll.documentView?.subviews ?? [] {
            bubble.updateAppearance(style)
        }
    }

    func show(_ alerts: [QuotaAlert], anchor: NSRect, screen: NSScreen?, left: Bool) {
        guard !alerts.isEmpty else { return }
        for alert in alerts {
            if let index = pending.firstIndex(where: { $0.key == alert.key }) {
                pending[index] = alert
            } else {
                pending.append(alert)
            }
        }
        reposition(anchor: anchor, screen: screen, left: left)
    }

    func reposition(anchor: NSRect, screen: NSScreen?, left: Bool) {
        anchorFrame = anchor
        anchorScreen = screen ?? NSScreen.main
        leftCorner = left
        render()
    }

    private func render() {
        guard !pending.isEmpty, let screen = anchorScreen else { return }
        let layout = QuotaBubbleLayout(anchor: anchorFrame, visible: screen.visibleFrame, left: leftCorner, count: pending.count)
        let panel: QuotaAlertPanel
        if let existing = window {
            panel = existing
        } else {
            panel = QuotaAlertPanel(contentRect: layout.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "额度提醒"
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.ignoresMouseEvents = false
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            panel.contentView = scroll
            window = panel
        }
        let previousOffset = scroll.contentView.bounds.origin.y
        panel.setFrame(layout.frame, display: true)
        scroll.frame = NSRect(origin: .zero, size: layout.frame.size)
        let document = QuotaAlertListView(frame: NSRect(x: 0, y: 0, width: layout.frame.width, height: layout.contentHeight))
        for (index, alert) in pending.enumerated() {
            let offset = layout.stacksUp ? layout.contentHeight - QuotaBubbleLayout.bubbleHeight - CGFloat(index) * QuotaBubbleLayout.stride : CGFloat(index) * QuotaBubbleLayout.stride
            let bubble = QuotaSpeechBubbleView(frame: NSRect(x: 0, y: offset, width: layout.frame.width, height: QuotaBubbleLayout.bubbleHeight), alert: alert, side: index == 0 ? layout.tailSide : .none, tailOffset: layout.tailOffset)
            bubble.updateAppearance(bubbleAppearance)
            bubble.closeButton.tag = index
            bubble.closeButton.target = self
            bubble.closeButton.action = #selector(closeAlert(_:))
            document.addSubview(bubble)
        }
        scroll.documentView = document
        let offset = layout.stacksUp ? max(0, layout.contentHeight - layout.frame.height) : min(previousOffset, max(0, layout.contentHeight - layout.frame.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scroll.reflectScrolledClipView(scroll.contentView)
        panel.orderFrontRegardless()
    }

    @objc private func closeAlert(_ sender: NSButton) {
        dismiss(at: sender.tag)
    }

    func dismiss(at index: Int) {
        guard pending.indices.contains(index) else { return }
        pending.remove(at: index)
        if pending.isEmpty { dismiss() } else { render() }
    }

    @objc func dismiss() {
        window?.orderOut(nil)
        window = nil
        scroll.documentView = nil
        pending.removeAll()
    }
}

private final class QuotaAlertListView: NSView {
    override var isFlipped: Bool { true }
}

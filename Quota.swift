import AppKit

struct QuotaResponse: Decodable {
    let updated_at: String
    let accounts: [QuotaAccount]
}

struct QuotaAccount: Decodable {
    let label: String
    let status: String
    let message: String?
    let windows: [QuotaWindow]?
    var provider: String? = nil
    var last_success_at: String? = nil
    var refresh_interval_seconds: Double? = nil
    var stale: Bool? = nil
    var refreshing: Bool? = nil

    func isDataStale(at now: Date = Date()) -> Bool {
        guard let timestamp = last_success_at, let success = quotaDate(timestamp) else { return true }
        let interval = refresh_interval_seconds ?? 900
        let age = now.timeIntervalSince(success)
        return status == "stale" || stale == true || !interval.isFinite || interval <= 0 || age < 0 || age >= interval
    }

    func freshnessLine(at now: Date = Date()) -> QuotaLine? {
        guard provider == "decodo" || last_success_at != nil || refresh_interval_seconds != nil else { return nil }
        let expired = isDataStale(at: now)
        let cadence = String(format: "每 %.0f 分钟抓取", (refresh_interval_seconds ?? 900) / 60)
        let title = expired ? "数据已过期" + (refreshing == true ? " · 抓取中" : "") : refreshing == true ? "正在抓取…" : cadence
        let updated = last_success_at.map { shortTime($0, date: true) } ?? "暂无"
        return QuotaLine(title: title, detail: "上次成功 " + updated, remaining: nil, heading: false, warning: expired)
    }
}

struct QuotaWindow: Decodable {
    let group: String?
    let label: String
    let remaining_percent: Double
    let reset_at: String?
    var window_seconds: Double? = nil

    var remaining: Double { remaining_percent.isFinite ? min(100, max(0, remaining_percent)) : 0 }
}

struct QuotaLine {
    let title: String
    let detail: String
    let remaining: Double?
    let heading: Bool
    var accountStart = false
    var accountEnd = false
    var warning = false
    var group = false
    var height: CGFloat {
        if accountEnd { return 12 }
        if remaining != nil { return 44 }
        if heading { return 28 }
        return group ? 20 : 22
    }
}

final class QuotaSource {
    let path: String
    let title: String
    var response: QuotaResponse?
    var loading = false
    var failed = false

    init(path: String, title: String) {
        self.path = path
        self.title = title
    }

    var lines: [QuotaLine] {
        var result = [QuotaLine(title: title, detail: loading ? "刷新中…" : failed ? "连接失败 · 稍后重试" : "", remaining: nil, heading: true, warning: failed && !loading)]
        guard let response = response else {
            result.append(QuotaLine(title: failed ? "额度服务暂不可用" : "正在读取额度…", detail: "", remaining: nil, heading: false))
            return result
        }
        if !loading && !failed {
            result[0] = QuotaLine(title: title, detail: "更新 " + shortTime(response.updated_at, date: false), remaining: nil, heading: true)
        }
        if failed {
            result.append(QuotaLine(title: "以下为上次数据 · 更新 " + shortTime(response.updated_at, date: true), detail: "", remaining: nil, heading: false))
        }
        if response.accounts.isEmpty {
            result.append(QuotaLine(title: "未发现已接入账号", detail: "", remaining: nil, heading: false))
        }
        for account in response.accounts {
            result.append(QuotaLine(title: account.label, detail: "", remaining: nil, heading: true, accountStart: true))
            defer { result.append(QuotaLine(title: "", detail: "", remaining: nil, heading: false, accountEnd: true)) }
            if let freshness = account.freshnessLine() { result.append(freshness) }
            guard account.status == "ok" || account.status == "stale" else {
                result.append(QuotaLine(title: account.status == "unsupported" ? "暂不支持额度查询" : "暂时无法查询", detail: "", remaining: nil, heading: false))
                continue
            }
            var lastGroup: String?
            for window in account.windows ?? [] {
                if let group = window.group, group != lastGroup {
                    result.append(QuotaLine(title: group, detail: "", remaining: nil, heading: false, group: true))
                    lastGroup = group
                }
                let reset = window.reset_at.map { "重置 " + shortTime($0, date: true) } ?? "未提供重置时间"
                result.append(QuotaLine(title: window.label, detail: reset, remaining: window.remaining, heading: false, warning: account.provider == "decodo" && account.isDataStale()))
            }
            if account.windows?.isEmpty != false {
                result.append(QuotaLine(title: "提供方未返回额度窗口", detail: "", remaining: nil, heading: false))
            }
        }
        return result
    }
}

func quotaDate(_ value: String) -> Date? {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var parsed = parser.date(from: value)
    if parsed == nil {
        parser.formatOptions = [.withInternetDateTime]
        parsed = parser.date(from: value)
    }
    return parsed
}

func shortTime(_ value: String, date: Bool) -> String {
    guard let parsed = quotaDate(value) else { return "未知" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = date ? "M/d HH:mm" : "HH:mm"
    return formatter.string(from: displayedDate(parsed))
}

final class QuotaLoader {
    let sources = [QuotaSource(path: "local", title: "本机"), QuotaSource(path: "remote", title: "远端")]
    let baseURL = URL(string: "http://127.0.0.1:8318")!
    let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 75
        configuration.timeoutIntervalForResource = 80
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()
    var onChange: (() -> Void)?
    var onSnapshot: ((QuotaSource, QuotaResponse) -> Void)?
    var lines: [QuotaLine] { sources.flatMap { $0.lines } }

    func refresh(userTriggered: Bool = false) {
        for source in sources where !source.loading {
            source.loading = true
            let query = (userTriggered && source.path == "local") ? "?refresh_decodo=1" : ""
            let urlString = baseURL.appendingPathComponent(source.path + "/quota.json").absoluteString + query
            var request = URLRequest(url: URL(string: urlString)!)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            session.dataTask(with: request) { [weak self] data, response, error in
                let decoded: QuotaResponse?
                if error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200, let data = data {
                    decoded = try? JSONDecoder().decode(QuotaResponse.self, from: data)
                } else { decoded = nil }
                DispatchQueue.main.async {
                    source.loading = false
                    source.failed = decoded == nil
                    if let decoded = decoded {
                        source.response = decoded
                        self?.onSnapshot?(source, decoded)
                    }
                    self?.onChange?()
                }
            }.resume()
        }
        onChange?()
    }
}

final class QuotaContentView: NSView {
    weak var controller: ClockController?
    override var mouseDownCanMoveWindow: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let controller = controller else { return }
        if controller.showQuota {
            drawQuota(controller.quota.lines, in: bounds, top: bounds.height - controller.monitorHeight - 6, palette: controller.appearance.palette)
        }
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = controller?.makeMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// 按基线绘制单行文字；超出宽度时在末尾截断。返回实际绘制宽度。
@discardableResult
func drawTextLine(_ string: String, _ attributes: [NSAttributedString.Key: Any], x: CGFloat, baseline: CGFloat, width: CGFloat, alignRight: Bool = false) -> CGFloat {
    guard width > 0, !string.isEmpty else { return 0 }
    var kept = string
    var text = string
    while (text as NSString).size(withAttributes: attributes).width > width && !kept.isEmpty {
        kept.removeLast()
        text = kept + "…"
    }
    let measured = ceil((text as NSString).size(withAttributes: attributes).width)
    let originX = alignRight ? x + width - measured : x
    (text as NSString).draw(with: NSRect(x: originX, y: baseline, width: measured + 2, height: 0), options: [], attributes: attributes, context: nil)
    return measured
}

func drawQuota(_ lines: [QuotaLine], in bounds: NSRect, top: CGFloat, palette: ClockPalette) {
    let cardInset: CGFloat = 10
    let left = cardInset + 12
    let right = bounds.width - cardInset - 12
    // 卡片：同色底板保证可读性，再叠一层极淡的着色与描边划分账户。
    var cardTop: CGFloat?
    var cardCursor = top
    for line in lines {
        if line.accountStart { cardTop = cardCursor }
        if line.accountEnd, let start = cardTop {
            let rect = NSRect(x: cardInset, y: cardCursor - 4, width: bounds.width - cardInset * 2, height: start - cardCursor + 4).insetBy(dx: 0.5, dy: 0.5)
            let card = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            palette.plate.setFill()
            card.fill()
            palette.tint(0.06).setFill()
            card.fill()
            palette.tint(0.1).setStroke()
            card.lineWidth = 1
            card.stroke()
            cardTop = nil
        }
        cardCursor -= line.height
    }
    var cursor = top
    var inCard = false
    for line in lines {
        if line.accountStart { inCard = true }
        if line.accountEnd { inCard = false }
        let accent: NSColor? = line.warning ? palette.warn : nil
        if let remaining = line.remaining {
            // 第一行：名称 + 剩余比例（仅在偏低时着色）；第二行：进度条；第三行：重置时间。
            let level = accent ?? (remaining <= 25 ? palette.level(remaining) : palette.primary)
            let value = NSMutableAttributedString(string: "剩余 ", attributes: palette.text(10.5, color: accent ?? palette.tertiary))
            value.append(NSAttributedString(string: String(format: "%.0f%%", remaining), attributes: palette.text(13.5, .semibold, color: level, digits: true)))
            let valueWidth = ceil(value.size().width)
            value.draw(with: NSRect(x: right - valueWidth, y: cursor - 16, width: valueWidth + 2, height: 0), options: [], context: nil)
            drawTextLine(line.title, palette.text(12.5, color: accent ?? palette.primary), x: left, baseline: cursor - 16, width: right - left - valueWidth - 10)
            let bar = NSRect(x: left, y: cursor - 27, width: right - left, height: 4)
            palette.tint(0.14).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
            if remaining > 0 {
                (line.warning ? palette.tint(0.38) : palette.level(remaining)).setFill()
                NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(bar.height, bar.width * remaining / 100), height: bar.height), xRadius: 2, yRadius: 2).fill()
            }
            drawTextLine(line.detail, palette.text(10, color: accent?.withAlphaComponent(0.85) ?? palette.tertiary, digits: true), x: left, baseline: cursor - 39, width: right - left)
        } else if line.heading && !line.accountStart {
            // 来源分区（本机／远端）：卡片外的小标题，右侧为更新时间或连接状态。
            let detailWidth = drawTextLine(line.detail, palette.text(10, color: accent ?? palette.tertiary, digits: true), x: 14, baseline: cursor - 18, width: bounds.width - 28, alignRight: true)
            drawTextLine(line.title, palette.text(11.5, .semibold, color: palette.secondary), x: 14, baseline: cursor - 18, width: bounds.width - 40 - detailWidth)
        } else if line.accountStart {
            drawTextLine(line.title, palette.text(12.5, .semibold, color: palette.primary), x: left, baseline: cursor - 19, width: right - left)
        } else if line.group {
            drawTextLine(line.title, palette.text(10.5, .medium, color: palette.tertiary), x: left, baseline: cursor - 13, width: right - left)
        } else if !line.accountEnd {
            // 状态行：卡片内与内容左对齐，卡片外（如“以下为上次数据”）与分区标题对齐。
            let x = inCard ? left : 14
            let width = (inCard ? right : bounds.width - 14) - x
            let detailWidth = drawTextLine(line.detail, palette.text(10, color: accent?.withAlphaComponent(0.85) ?? palette.tertiary, digits: true), x: x, baseline: cursor - 15, width: width, alignRight: true)
            drawTextLine(line.title, palette.text(11.5, line.warning ? .medium : .regular, color: accent ?? palette.secondary), x: x, baseline: cursor - 15, width: width - detailWidth - (detailWidth > 0 ? 10 : 0))
        }
        cursor -= line.height
    }
}

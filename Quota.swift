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
}

struct QuotaWindow: Decodable {
    let group: String?
    let label: String
    let remaining_percent: Double
    let reset_at: String?

    var remaining: Double { remaining_percent.isFinite ? min(100, max(0, remaining_percent)) : 0 }
}

struct QuotaLine {
    let title: String
    let detail: String
    let remaining: Double?
    let heading: Bool
    var accountStart = false
    var accountEnd = false
    var height: CGFloat { accountEnd ? 14 : remaining == nil ? 23 : 43 }
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
        var result = [QuotaLine(title: title, detail: loading ? "刷新中…" : failed ? "连接失败 · 稍后重试" : "", remaining: nil, heading: true)]
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
            guard account.status == "ok" else {
                result.append(QuotaLine(title: account.status == "unsupported" ? "暂不支持额度查询" : "暂时无法查询", detail: "", remaining: nil, heading: false))
                continue
            }
            var lastGroup: String?
            for window in account.windows ?? [] {
                if let group = window.group, group != lastGroup {
                    result.append(QuotaLine(title: group, detail: "", remaining: nil, heading: false))
                    lastGroup = group
                }
                let reset = window.reset_at.map { "重置 " + shortTime($0, date: true) } ?? "未提供重置时间"
                result.append(QuotaLine(title: window.label, detail: reset, remaining: window.remaining, heading: false))
            }
            if account.windows?.isEmpty != false {
                result.append(QuotaLine(title: "提供方未返回额度窗口", detail: "", remaining: nil, heading: false))
            }
        }
        return result
    }
}

func shortTime(_ value: String, date: Bool) -> String {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var parsed = parser.date(from: value)
    if parsed == nil {
        parser.formatOptions = [.withInternetDateTime]
        parsed = parser.date(from: value)
    }
    guard let parsed = parsed else { return "未知" }
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
        configuration.timeoutIntervalForRequest = 65
        configuration.timeoutIntervalForResource = 70
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()
    var onChange: (() -> Void)?
    var lines: [QuotaLine] { sources.flatMap { $0.lines } }

    func refresh() {
        for source in sources where !source.loading {
            source.loading = true
            var request = URLRequest(url: baseURL.appendingPathComponent(source.path + "/quota.json"))
            request.cachePolicy = .reloadIgnoringLocalCacheData
            session.dataTask(with: request) { [weak self] data, response, error in
                let decoded: QuotaResponse?
                if error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200, let data = data {
                    decoded = try? JSONDecoder().decode(QuotaResponse.self, from: data)
                } else { decoded = nil }
                DispatchQueue.main.async {
                    source.loading = false
                    source.failed = decoded == nil
                    if let decoded = decoded { source.response = decoded }
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
        drawQuota(controller.quota.lines, in: bounds, top: bounds.height - 8)
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = controller?.makeMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

func drawQuota(_ lines: [QuotaLine], in bounds: NSRect, top: CGFloat) {
    var cardTop: CGFloat?
    var cardCursor = top
    for line in lines {
        if line.accountStart { cardTop = cardCursor + 3 }
        if line.accountEnd, let start = cardTop {
            let card = NSBezierPath(roundedRect: NSRect(x: 10, y: cardCursor - 4, width: bounds.width - 20, height: start - cardCursor + 4), xRadius: 9, yRadius: 9)
            NSColor(white: 1, alpha: 0.055).setFill()
            card.fill()
            NSColor(white: 1, alpha: 0.12).setStroke()
            card.lineWidth = 1
            card.stroke()
            cardTop = nil
        }
        cardCursor -= line.height
    }
    var cursor = top
    let rightAligned = NSMutableParagraphStyle()
    rightAligned.alignment = .right
    let truncated = NSMutableParagraphStyle()
    truncated.lineBreakMode = .byTruncatingTail
    for line in lines {
        let primary: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: line.heading ? .semibold : .regular),
            .foregroundColor: NSColor(white: 1, alpha: line.heading ? 0.95 : 0.72),
            .paragraphStyle: truncated
        ]
        let detail: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor(white: 1, alpha: 0.5),
            .paragraphStyle: rightAligned
        ]
        if let remaining = line.remaining {
            (line.title as NSString).draw(in: NSRect(x: 18, y: cursor - 16, width: 115, height: 16), withAttributes: primary)
            let percent = String(format: "剩余 %.0f%%", remaining)
            (percent as NSString).draw(in: NSRect(x: bounds.width - 100, y: cursor - 16, width: 82, height: 16), withAttributes: primary.merging([.paragraphStyle: rightAligned]) { _, new in new })
            let bar = NSRect(x: 18, y: cursor - 24, width: bounds.width - 36, height: 3)
            NSColor(white: 1, alpha: 0.12).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            (remaining <= 10 ? NSColor.systemRed : remaining <= 25 ? NSColor.systemOrange : NSColor.systemTeal).setFill()
            NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: bar.width * remaining / 100, height: bar.height), xRadius: 1.5, yRadius: 1.5).fill()
            (line.detail as NSString).draw(in: NSRect(x: 18, y: cursor - 39, width: bounds.width - 36, height: 13), withAttributes: detail)
        } else {
            (line.title as NSString).draw(in: NSRect(x: 18, y: cursor - 17, width: bounds.width - (line.detail.isEmpty ? 36 : 166), height: 18), withAttributes: primary)
            (line.detail as NSString).draw(in: NSRect(x: bounds.width - 166, y: cursor - 16, width: 148, height: 16), withAttributes: detail)
        }
        cursor -= line.height
    }
}

import AppKit

enum QuotaTailSide {
    case bottom, top, left, right, none
}

struct QuotaBubbleLayout {
    static let bubbleHeight: CGFloat = 80
    static let stride: CGFloat = 84
    let frame: NSRect
    let tailSide: QuotaTailSide
    let tailOffset: CGFloat
    let stacksUp: Bool
    let contentHeight: CGFloat

    init(anchor: NSRect, visible: NSRect, left: Bool, count: Int) {
        let safe = visible.insetBy(dx: 10, dy: 10)
        let width = min(CGFloat(244), safe.width)
        contentHeight = max(Self.bubbleHeight, CGFloat(count) * Self.stride - 4)
        let corner = left ? anchor.minX + 24 : anchor.maxX - 24
        let desiredX = corner - width / 2
        let horizontal = min(max(desiredX, safe.minX), safe.maxX - width)
        let above = safe.maxY - anchor.maxY - 4
        let below = anchor.minY - safe.minY - 4
        let preferredSideFits = (left ? anchor.minX - safe.minX : safe.maxX - anchor.maxX) >= width + 4
        let oppositeSideFits = (left ? safe.maxX - anchor.maxX : anchor.minX - safe.minX) >= width + 4
        let height: CGFloat
        if above >= Self.bubbleHeight {
            height = min(contentHeight, above)
            frame = NSRect(x: horizontal, y: anchor.maxY + 4, width: width, height: height)
            tailSide = .bottom
            tailOffset = min(max(corner - horizontal, 28), width - 28)
            stacksUp = true
        } else if preferredSideFits || oppositeSideFits {
            let useLeft = preferredSideFits ? left : !left
            height = min(contentHeight, safe.height)
            let target = anchor.maxY - 18
            let top = min(max(target + Self.bubbleHeight / 2, safe.minY + height), safe.maxY)
            frame = NSRect(x: useLeft ? anchor.minX - width - 4 : anchor.maxX + 4, y: top - height, width: width, height: height)
            tailSide = useLeft ? .right : .left
            tailOffset = min(max(target - (top - Self.bubbleHeight), 28), Self.bubbleHeight - 28)
            stacksUp = false
        } else if below >= Self.bubbleHeight {
            height = min(contentHeight, below)
            frame = NSRect(x: horizontal, y: anchor.minY - height - 4, width: width, height: height)
            tailSide = .top
            tailOffset = min(max(corner - horizontal, 28), width - 28)
            stacksUp = false
        } else {
            height = min(contentHeight, safe.height)
            frame = NSRect(x: horizontal, y: safe.maxY - height, width: width, height: height)
            tailSide = .bottom
            tailOffset = min(max(corner - horizontal, 28), width - 28)
            stacksUp = false
        }
    }
}

final class QuotaSpeechBubbleView: NSView {
    let closeButton = NSButton(title: "关闭这条提醒", target: nil, action: nil)
    let alert: QuotaAlert
    let side: QuotaTailSide
    let tailOffset: CGFloat
    private let nameField = NSTextField(labelWithString: "")
    private let amountField = NSTextField(labelWithString: "")
    private let deltaField = NSTextField(labelWithString: "")
    private let resetField = NSTextField(labelWithString: "")
    private var fillColor = NSColor(calibratedWhite: 0.09, alpha: 0.15)
    private var lightText = true
    var backgroundOpacity: CGFloat { fillColor.alphaComponent }
    private var accent: NSColor {
        if alert.recovered {
            return lightText ? NSColor(srgbRed: 0.55, green: 0.91, blue: 0.72, alpha: 1) : NSColor(srgbRed: 0.1, green: 0.48, blue: 0.3, alpha: 1)
        }
        if lightText {
            return alert.exhausted ? NSColor(srgbRed: 1, green: 0.65, blue: 0.48, alpha: 1) : NSColor(srgbRed: 0.67, green: 0.83, blue: 1, alpha: 1)
        }
        return alert.exhausted ? NSColor(srgbRed: 0.78, green: 0.24, blue: 0.23, alpha: 1) : NSColor(srgbRed: 0.21, green: 0.36, blue: 0.71, alpha: 1)
    }

    init(frame: NSRect, alert: QuotaAlert, side: QuotaTailSide, tailOffset: CGFloat) {
        self.alert = alert
        self.side = side
        self.tailOffset = tailOffset
        super.init(frame: frame)
        let body = bodyRect
        let x = body.minX + 10
        let right = body.maxX - 10
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭这条额度提醒")
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.setAccessibilityLabel("关闭这条额度提醒")
        closeButton.frame = NSRect(x: right - 14, y: body.maxY - 22, width: 18, height: 18)
        addSubview(closeButton)
        nameField.stringValue = alert.title
        nameField.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.toolTip = alert.title + "\n" + alert.resetText
        nameField.frame = NSRect(x: x, y: body.maxY - 21, width: body.width - 44, height: 16)
        addSubview(nameField)
        let current = alert.remainingPercent ?? (alert.exhausted ? 0 : 80)
        amountField.alignment = .right
        amountField.frame = NSRect(x: right - 88, y: body.minY + 17, width: 88, height: 23)
        addSubview(amountField)
        let change: String
        if alert.recovered {
            change = "额度已恢复"
        } else if alert.exhausted && (alert.previousRemaining ?? 0) == 0 {
            change = "等待额度恢复"
        } else if let previous = alert.previousRemaining {
            change = String(format: "↓ %.1f 个百分点", max(0, previous - current))
        } else { change = "额度变化" }
        deltaField.stringValue = change
        deltaField.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        deltaField.frame = NSRect(x: x, y: body.minY + 20, width: body.width - 114, height: 16)
        addSubview(deltaField)
        resetField.stringValue = alert.resetText
        resetField.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        resetField.lineBreakMode = .byTruncatingTail
        resetField.toolTip = alert.resetText
        resetField.setAccessibilityLabel("额度重置时间")
        resetField.frame = NSRect(x: x, y: body.minY + 3, width: body.width - 20, height: 12)
        addSubview(resetField)
        refreshTextColors()
    }

    required init?(coder: NSCoder) { nil }

    func updateAppearance(_ style: ClockAppearance) {
        fillColor = style.fill
        if let rgb = style.color.usingColorSpace(.sRGB) {
            lightText = rgb.redComponent * 0.2126 + rgb.greenComponent * 0.7152 + rgb.blueComponent * 0.0722 < 0.5
        }
        refreshTextColors()
        needsDisplay = true
    }

    private func refreshTextColors() {
        appearance = NSAppearance(named: lightText ? .darkAqua : .aqua)
        nameField.textColor = lightText ? NSColor.white.withAlphaComponent(0.9) : NSColor(calibratedWhite: 0.19, alpha: 1)
        deltaField.textColor = accent
        resetField.textColor = lightText ? NSColor.white.withAlphaComponent(0.65) : NSColor(calibratedWhite: 0.38, alpha: 1)
        closeButton.contentTintColor = lightText ? NSColor.white.withAlphaComponent(0.65) : NSColor(calibratedWhite: 0.48, alpha: 0.8)
        let amountText = NSMutableAttributedString(string: alert.exhausted ? "已用完" : "剩余 ", attributes: [.font: NSFont.systemFont(ofSize: alert.exhausted ? 16 : 10, weight: .medium), .foregroundColor: accent])
        if !alert.exhausted {
            let current = alert.remainingPercent ?? 80
            amountText.append(NSAttributedString(string: String(format: "%.0f%%", current), attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 19, weight: .semibold), .foregroundColor: accent]))
        }
        amountField.attributedStringValue = amountText
    }

    private var bodyRect: NSRect {
        var rect = NSRect(x: 5, y: 9, width: bounds.width - 10, height: 62)
        switch side {
        case .bottom: rect.origin.y = 13
        case .top: rect.origin.y = 5
        case .left: rect.origin.x += 8; rect.size.width -= 8
        case .right: rect.size.width -= 8
        case .none: break
        }
        return rect
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        let body = bodyRect
        let radius: CGFloat = 13
        let path = NSBezierPath()
        path.move(to: NSPoint(x: body.minX + radius, y: body.minY))
        func point(_ x: CGFloat, _ y: CGFloat) { path.line(to: NSPoint(x: x, y: y)) }
        if side == .bottom {
            point(tailOffset - 9, body.minY)
            path.curve(to: NSPoint(x: tailOffset, y: body.minY - 8), controlPoint1: NSPoint(x: tailOffset - 4, y: body.minY), controlPoint2: NSPoint(x: tailOffset - 3, y: body.minY - 7))
            path.curve(to: NSPoint(x: tailOffset + 9, y: body.minY), controlPoint1: NSPoint(x: tailOffset + 3, y: body.minY - 7), controlPoint2: NSPoint(x: tailOffset + 4, y: body.minY))
        }
        point(body.maxX - radius, body.minY)
        path.appendArc(withCenter: NSPoint(x: body.maxX - radius, y: body.minY + radius), radius: radius, startAngle: 270, endAngle: 360)
        if side == .right {
            point(body.maxX, tailOffset - 9)
            path.curve(to: NSPoint(x: body.maxX + 8, y: tailOffset), controlPoint1: NSPoint(x: body.maxX, y: tailOffset - 4), controlPoint2: NSPoint(x: body.maxX + 7, y: tailOffset - 3))
            path.curve(to: NSPoint(x: body.maxX, y: tailOffset + 9), controlPoint1: NSPoint(x: body.maxX + 7, y: tailOffset + 3), controlPoint2: NSPoint(x: body.maxX, y: tailOffset + 4))
        }
        point(body.maxX, body.maxY - radius)
        path.appendArc(withCenter: NSPoint(x: body.maxX - radius, y: body.maxY - radius), radius: radius, startAngle: 0, endAngle: 90)
        if side == .top {
            point(tailOffset + 9, body.maxY)
            path.curve(to: NSPoint(x: tailOffset, y: body.maxY + 8), controlPoint1: NSPoint(x: tailOffset + 4, y: body.maxY), controlPoint2: NSPoint(x: tailOffset + 3, y: body.maxY + 7))
            path.curve(to: NSPoint(x: tailOffset - 9, y: body.maxY), controlPoint1: NSPoint(x: tailOffset - 3, y: body.maxY + 7), controlPoint2: NSPoint(x: tailOffset - 4, y: body.maxY))
        }
        point(body.minX + radius, body.maxY)
        path.appendArc(withCenter: NSPoint(x: body.minX + radius, y: body.maxY - radius), radius: radius, startAngle: 90, endAngle: 180)
        if side == .left {
            point(body.minX, tailOffset + 9)
            path.curve(to: NSPoint(x: body.minX - 8, y: tailOffset), controlPoint1: NSPoint(x: body.minX, y: tailOffset + 4), controlPoint2: NSPoint(x: body.minX - 7, y: tailOffset + 3))
            path.curve(to: NSPoint(x: body.minX, y: tailOffset - 9), controlPoint1: NSPoint(x: body.minX - 7, y: tailOffset - 3), controlPoint2: NSPoint(x: body.minX, y: tailOffset - 4))
        }
        point(body.minX, body.minY + radius)
        path.appendArc(withCenter: NSPoint(x: body.minX + radius, y: body.minY + radius), radius: radius, startAngle: 180, endAngle: 270)
        path.close()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.14 * backgroundOpacity)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        fillColor.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        (lightText ? NSColor.white.withAlphaComponent(0.15) : NSColor.black.withAlphaComponent(0.18)).setStroke()
        path.lineWidth = 0.8
        path.stroke()
    }
}

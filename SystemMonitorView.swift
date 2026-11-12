import AppKit

final class SystemMonitorView: NSView {
    weak var controller: ClockController?
    var showsCapacityExplanation = false
    let diskButton = NSButton(title: "系统盘 ⌄", target: nil, action: nil)
    let infoButton = NSButton()
    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        diskButton.isBordered = false
        diskButton.alignment = .left
        diskButton.font = .systemFont(ofSize: 10.5)
        diskButton.cell?.lineBreakMode = .byTruncatingTail
        diskButton.target = self
        diskButton.action = #selector(selectDisk)
        diskButton.setAccessibilityLabel("选择监控磁盘")
        addSubview(diskButton)
        infoButton.isBordered = false
        infoButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "可清除空间说明")
        infoButton.imageScaling = .scaleProportionallyDown
        infoButton.target = self
        infoButton.action = #selector(toggleExplanation)
        infoButton.toolTip = "可用容量包含系统估算的可清除空间，不能重复相加；估算可能与 Finder 不同。本模块不执行清理。"
        infoButton.setAccessibilityLabel("显示或隐藏可清除空间说明")
        addSubview(infoButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("系统监控")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var contentHeight: CGFloat {
        guard let controller = controller else { return 0 }
        let enabled = controller.monitorConfiguration.enabled
        guard !enabled.isEmpty else { return 0 }
        guard controller.showSystemDetails else { return 34 }
        var groups: [CGFloat] = []
        if enabled.contains(.cpu) || enabled.contains(.memory) { groups.append(48) }
        if enabled.contains(.network) { groups.append(43) }
        if enabled.contains(.disk) { groups.append(controller.systemMonitor.snapshot.diskMounted ? 100 : 49) }
        return 54 + groups.reduce(0, +) + CGFloat(max(0, groups.count - 1)) * 14 + (enabled.contains(.disk) && showsCapacityExplanation ? 32 : 0)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller = controller else { return }
        let palette = controller.appearance.palette
        let snapshot = controller.systemMonitor.snapshot
        let enabled = controller.monitorConfiguration.enabled
        diskButton.isHidden = true
        infoButton.isHidden = true
        guard !enabled.isEmpty else { return }
        if !controller.showSystemDetails { drawSummary(snapshot, enabled: enabled, palette: palette); return }
        let card = NSBezierPath(roundedRect: NSRect(x: 10.5, y: 5.5, width: bounds.width - 21, height: bounds.height - 11), xRadius: 10, yRadius: 10)
        palette.plate.setFill()
        card.fill()
        palette.tint(0.06).setFill()
        card.fill()
        palette.tint(0.1).setStroke()
        card.lineWidth = 1
        card.stroke()
        let left: CGFloat = 23
        let right = bounds.width - 23
        text("系统监控", x: left + 19, y: bounds.height - 25, width: 100, size: 11.5, weight: .semibold, color: palette.secondary, palette: palette)
        drawSymbol("waveform.path.ecg", rect: NSRect(x: left, y: bounds.height - 24, width: 13, height: 13), color: palette.secondary)
        text(snapshot.sampled ? "\(Int(controller.monitorConfiguration.interval)) 秒刷新" : "采样中", x: right - 72, y: bounds.height - 25, width: 72, size: 9.5, color: palette.tertiary, palette: palette, right: true)
        var cursor = bounds.height - 42
        var hasPrevious = false
        func separate() {
            if hasPrevious {
                palette.tint(0.1).setFill()
                NSRect(x: left, y: cursor - 5, width: right - left, height: 1).fill()
                cursor -= 14
            }
            hasPrevious = true
        }
        let columns = [MonitorMetric.cpu, .memory].filter { enabled.contains($0) }
        if !columns.isEmpty {
            separate()
            let gap: CGFloat = 18
            let width = (right - left - gap * CGFloat(columns.count - 1)) / CGFloat(columns.count)
            for (index, metric) in columns.enumerated() {
                let origin = left + CGFloat(index) * (width + gap)
                let value = metric == .cpu ? snapshot.cpu : snapshot.memoryPercent
                text(metric == .cpu ? "CPU" : "内存", x: origin, y: cursor - 19, width: 48, size: 10.5, color: palette.secondary, palette: palette)
                text(value.map { String(format: "%.0f%%", $0) } ?? "—", x: origin + 35, y: cursor - 19, width: width - 35, size: 19, weight: .medium, color: palette.primary, palette: palette, right: true, digits: true)
                progress(value.map { $0 / 100 }, rect: NSRect(x: origin, y: cursor - 29, width: width, height: 3), palette: palette)
                if metric == .memory {
                    let detail = snapshot.memoryUsed.map { String(format: "%.1f / %.0f GB", Double($0) / 1_073_741_824, Double(snapshot.memoryTotal) / 1_073_741_824) } ?? "正在采样"
                    text(detail, x: origin, y: cursor - 42, width: width, size: 9.5, color: palette.tertiary, palette: palette, digits: true)
                }
            }
            cursor -= 48
        }
        if enabled.contains(.network) {
            separate()
            text("网络", x: left, y: cursor - 10, width: 60, size: 10.5, color: palette.secondary, palette: palette)
            text(snapshot.networkName, x: right - 100, y: cursor - 10, width: 100, size: 9.5, color: palette.tertiary, palette: palette, right: true)
            let half = (right - left - 18) / 2
            for (index, entry) in [("arrow.down", snapshot.network?.read), ("arrow.up", snapshot.network?.write)].enumerated() {
                let origin = left + CGFloat(index) * (half + 18)
                drawSymbol(entry.0, rect: NSRect(x: origin, y: cursor - 31, width: 11, height: 13), color: palette.good)
                text(entry.1.map { monitorSize($0, rate: true) } ?? "—", x: origin + 16, y: cursor - 32, width: half - 16, size: 13.5, weight: .medium, color: palette.primary, palette: palette, digits: true)
            }
            cursor -= 43
        }
        if enabled.contains(.disk) {
            separate()
            diskButton.isHidden = false
            diskButton.title = snapshot.diskName + " ⌄"
            diskButton.contentTintColor = palette.secondary
            diskButton.frame = NSRect(x: left - 2, y: cursor - 15, width: (right - left) * 0.58, height: 19)
            text(snapshot.diskMounted ? snapshot.capacity.map { monitorGB($0.total) } ?? "容量未知" : "未连接", x: right - 105, y: cursor - 10, width: 105, size: 9.5, color: palette.tertiary, palette: palette, right: true, digits: true)
            if snapshot.diskMounted {
                text("可用 ≈", x: left, y: cursor - 36, width: 46, size: 10.5, color: palette.secondary, palette: palette)
                text(snapshot.capacity?.available.map { monitorGB($0) } ?? "未知", x: left + 45, y: cursor - 36, width: right - left - 65, size: 17, weight: .medium, color: palette.primary, palette: palette, digits: true)
                infoButton.isHidden = false
                infoButton.frame = NSRect(x: right - 16, y: cursor - 37, width: 15, height: 15)
                infoButton.contentTintColor = palette.tertiary
                capacityBar(snapshot.capacity, rect: NSRect(x: left, y: cursor - 48, width: right - left, height: 4), palette: palette)
                text(snapshot.capacity.map { "空闲 " + monitorGB($0.free) } ?? "空闲未知", x: left, y: cursor - 62, width: (right - left) * 0.48, size: 9, color: palette.secondary, palette: palette, digits: true)
                text(snapshot.capacity?.purgeable.map { "可清除 ≈ " + monitorGB($0) } ?? "可清除未知", x: left + (right - left) * 0.45, y: cursor - 62, width: (right - left) * 0.55, size: 9, color: palette.secondary, palette: palette, right: true, digits: true)
                text("读取 " + (snapshot.disk.map { monitorSize($0.read, rate: true) } ?? "—"), x: left, y: cursor - 86, width: (right - left) / 2, size: 10.5, color: palette.secondary, palette: palette, digits: true)
                text("写入 " + (snapshot.disk.map { monitorSize($0.write, rate: true) } ?? "—"), x: (right + left) / 2, y: cursor - 86, width: (right - left) / 2, size: 10.5, color: palette.secondary, palette: palette, right: true, digits: true)
                cursor -= 100
            } else {
                text("磁盘已断开，重新连接后继续显示", x: left, y: cursor - 34, width: right - left, size: 10.5, color: palette.tertiary, palette: palette)
                cursor -= 49
            }
            if showsCapacityExplanation {
                text("可清除为系统估算，已包含在可用中。", x: left, y: cursor - 9, width: right - left, size: 9.5, color: palette.tertiary, palette: palette)
                text("数值可能与 Finder 不同；本模块不执行清理。", x: left, y: cursor - 23, width: right - left, size: 9.5, color: palette.tertiary, palette: palette)
            }
        }
        let description = [snapshot.cpu.map { String(format: "CPU %.0f%%", $0) }, snapshot.memoryPercent.map { String(format: "内存 %.0f%%", $0) }, snapshot.capacity?.available.map { "磁盘可用估算 " + monitorGB($0) }].compactMap { $0 }.joined(separator: "，")
        setAccessibilityValue(description)
    }

    private func drawSummary(_ snapshot: MonitorSnapshot, enabled: Set<MonitorMetric>, palette: ClockPalette) {
        palette.tint(0.1).setFill()
        NSRect(x: 14, y: bounds.height - 1, width: bounds.width - 28, height: 1).fill()
        var entries: [String] = []
        if enabled.contains(.cpu) { entries.append("CPU " + (snapshot.cpu.map { String(format: "%.0f%%", $0) } ?? "—")) }
        if enabled.contains(.memory) { entries.append("内存 " + (snapshot.memoryPercent.map { String(format: "%.0f%%", $0) } ?? "—")) }
        if enabled.contains(.network) {
            entries.append("↓ " + (snapshot.network.map { monitorSize($0.read, compact: true) } ?? "—"))
            entries.append("↑ " + (snapshot.network.map { monitorSize($0.write, compact: true) } ?? "—"))
        }
        if entries.isEmpty { entries.append(snapshot.diskMounted ? "磁盘可用 ≈ " + (snapshot.capacity?.available.map(monitorGB) ?? "未知") : "磁盘未连接") }
        let width = (bounds.width - 30) / CGFloat(entries.count)
        for (index, entry) in entries.enumerated() {
            text(entry, x: 15 + CGFloat(index) * width, y: 11, width: width - 3, size: 10, weight: .medium, color: palette.secondary, palette: palette, digits: true)
        }
        setAccessibilityValue(entries.joined(separator: "，"))
    }

    private func text(_ string: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, palette: ClockPalette, right: Bool = false, digits: Bool = false) {
        drawTextLine(string, palette.text(size, weight, color: color, digits: digits), x: x, baseline: y, width: width, alignRight: right)
    }

    private func progress(_ value: Double?, rect: NSRect, palette: ClockPalette) {
        palette.tint(0.12).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        guard let value = value, value > 0 else { return }
        palette.good.setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(min(1, value)), height: rect.height), xRadius: 2, yRadius: 2).fill()
    }

    private func capacityBar(_ capacity: MonitorCapacity?, rect: NSRect, palette: ClockPalette) {
        palette.tint(0.16).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        guard let capacity = capacity else { return }
        let freeWidth = rect.width * CGFloat(Double(capacity.free) / Double(capacity.total))
        let purgeWidth = rect.width * CGFloat(Double(capacity.purgeable ?? 0) / Double(capacity.total))
        palette.good.setFill()
        NSRect(x: rect.maxX - freeWidth, y: rect.minY, width: freeWidth, height: rect.height).fill()
        guard purgeWidth > 0 else { return }
        let purgeRect = NSRect(x: rect.maxX - freeWidth - purgeWidth, y: rect.minY, width: purgeWidth, height: rect.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: purgeRect).addClip()
        palette.good.withAlphaComponent(0.2).setFill()
        purgeRect.fill()
        palette.good.withAlphaComponent(0.7).setStroke()
        var position = purgeRect.minX - 4
        while position < purgeRect.maxX {
            let stripe = NSBezierPath()
            stripe.move(to: NSPoint(x: position, y: rect.minY))
            stripe.line(to: NSPoint(x: position + 4, y: rect.maxY))
            stripe.lineWidth = 1
            stripe.stroke()
            position += 4
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSymbol(_ name: String, rect: NSRect, color: NSColor) {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: rect.height, weight: .medium).applying(NSImage.SymbolConfiguration(paletteColors: [color])))
        image?.draw(in: rect)
    }

    @objc private func selectDisk() { controller?.appearanceSettings.show(tab: 1) }
    @objc private func toggleExplanation() { showsCapacityExplanation.toggle(); controller?.applySettings() }
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = controller?.makeMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

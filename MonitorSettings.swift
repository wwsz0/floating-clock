import AppKit

final class MonitorSettingsView: NSView {
    weak var controller: ClockController?
    private var metricButtons: [MonitorMetric: NSSwitch] = [:]
    let intervalPopup = NSPopUpButton()
    let volumePopup = NSPopUpButton()
    let interfacePopup = NSPopUpButton()

    init(controller: ClockController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 10, width: 310, height: 272))
        for (index, metric) in MonitorMetric.allCases.enumerated() {
            let label = NSTextField(labelWithString: metric.title)
            label.font = .systemFont(ofSize: 11)
            label.frame = NSRect(x: 20, y: 241 - CGFloat(index) * 27, width: 210, height: 20)
            addSubview(label)
            let button = NSSwitch(frame: NSRect(x: 248, y: 241 - CGFloat(index) * 27, width: 42, height: 22))
            button.tag = index
            button.controlSize = .small
            button.target = self
            button.action = #selector(changeMetric(_:))
            button.setAccessibilityLabel(metric.title)
            metricButtons[metric] = button
            addSubview(button)
        }
        for (popup, title, origin) in [(intervalPopup, "监控刷新", CGFloat(119)), (volumePopup, "显示磁盘", CGFloat(84)), (interfacePopup, "网络接口", CGFloat(49))] {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11)
            label.frame = NSRect(x: 20, y: origin + 3, width: 78, height: 20)
            addSubview(label)
            popup.frame = NSRect(x: 116, y: origin, width: 175, height: 25)
            popup.font = .systemFont(ofSize: 10.5)
            popup.target = self
            popup.setAccessibilityLabel(title)
            addSubview(popup)
        }
        for seconds in [1, 2, 5] {
            intervalPopup.addItem(withTitle: "每 \(seconds) 秒")
            intervalPopup.lastItem?.tag = seconds
        }
        intervalPopup.action = #selector(changeInterval)
        volumePopup.action = #selector(changeVolume)
        interfacePopup.action = #selector(changeInterface)
        let hint = NSTextField(wrappingLabelWithString: "磁盘容量每 60 秒更新；额度仍每 2 分钟查询。关闭全部指标后停止系统采集。")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 20, y: 0, width: 270, height: 35)
        addSubview(hint)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        guard let controller = controller else { return }
        let configuration = controller.monitorConfiguration
        for (metric, button) in metricButtons { button.state = configuration.enabled.contains(metric) ? .on : .off }
        intervalPopup.selectItem(withTag: Int(configuration.interval))
        volumePopup.removeAllItems()
        for volume in SystemSampler.volumes() {
            volumePopup.addItem(withTitle: volume.title)
            volumePopup.lastItem?.representedObject = volume.id
        }
        if !volumePopup.itemArray.contains(where: { $0.representedObject as? String == configuration.volumeID }) {
            volumePopup.addItem(withTitle: "所选磁盘（未连接）")
            volumePopup.lastItem?.representedObject = configuration.volumeID
        }
        if let item = volumePopup.itemArray.first(where: { $0.representedObject as? String == configuration.volumeID }) { volumePopup.select(item) }
        interfacePopup.removeAllItems()
        interfacePopup.addItem(withTitle: "自动（物理接口）")
        interfacePopup.lastItem?.representedObject = ""
        for interface in SystemSampler.interfaces() {
            interfacePopup.addItem(withTitle: interface.title)
            interfacePopup.lastItem?.representedObject = interface.id
        }
        if !interfacePopup.itemArray.contains(where: { $0.representedObject as? String == configuration.interface }) {
            interfacePopup.addItem(withTitle: "所选接口（未连接）")
            interfacePopup.lastItem?.representedObject = configuration.interface
        }
        if let item = interfacePopup.itemArray.first(where: { $0.representedObject as? String == configuration.interface }) { interfacePopup.select(item) }
    }

    @objc private func changeMetric(_ sender: NSSwitch) {
        let metric = MonitorMetric.allCases[sender.tag]
        controller?.defaults.set(sender.state != .on, forKey: "monitorDisabled_" + metric.rawValue)
        controller?.applySettings()
    }
    @objc private func changeInterval() {
        controller?.defaults.set(intervalPopup.selectedTag(), forKey: "monitorInterval")
        controller?.applySettings()
    }
    @objc private func changeVolume() {
        controller?.defaults.set(volumePopup.selectedItem?.representedObject as? String, forKey: "monitorVolume")
        controller?.applySettings()
    }
    @objc private func changeInterface() {
        controller?.defaults.set(interfacePopup.selectedItem?.representedObject as? String, forKey: "monitorInterface")
        controller?.applySettings()
    }
}

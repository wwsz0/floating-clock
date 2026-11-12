import AppKit

func runSystemMonitorTests() {
    let capacity = MonitorCapacity(total: 494_380_000_000, free: 40_990_000_000, important: 81_720_000_000)!
    precondition(capacity.available == 81_720_000_000 && capacity.purgeable == 40_730_000_000)
    precondition(capacity.available == capacity.free + capacity.purgeable!)
    precondition(MonitorCapacity(total: 100, free: 40, important: nil)!.purgeable == nil)
    precondition(MonitorCapacity(total: 100, free: 40, important: 0)!.available == nil)
    precondition(MonitorCapacity(total: 100, free: 40, important: 101)!.available == nil)
    precondition(MonitorCapacity(total: 100, free: 0, important: 0)!.available == 0)
    precondition(MonitorCapacity(total: 0, free: 0, important: 0) == nil)
    precondition(MonitorCapacity(total: 100, free: -1, important: 40) == nil)
    let first = MonitorCounters(identity: "interface-a", time: 10, read: 100, write: 200)
    let second = MonitorCounters(identity: "interface-a", time: 12, read: 300, write: 800)
    precondition(second.rates(since: first)!.read == 100 && second.rates(since: first)!.write == 300)
    precondition(second.rates(since: nil) == nil)
    precondition(first.rates(since: second) == nil)
    precondition(MonitorCounters(identity: "interface-b", time: 12, read: 300, write: 800).rates(since: first) == nil)
    precondition(MonitorCounters(identity: "interface-a", time: 12, read: 1, write: 800).rates(since: first) == nil)
    precondition(MonitorCounters(identity: "interface-a", time: 90, read: 300, write: 800).rates(since: first) == nil)
    precondition(monitorSize(0, rate: true) == "0 B/s")
    precondition(monitorSize(1_800_000, compact: true) == "1.80M")
    precondition(monitorSize(.nan) == "—" && monitorSize(-1) == "—")
    let suite = "local.floatingclock.monitor-test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    precondition(MonitorConfiguration(defaults: defaults).enabled.count == 4)
    precondition(MonitorConfiguration(defaults: defaults).interval == 2)
    defaults.set(5, forKey: "monitorInterval")
    precondition(MonitorConfiguration(defaults: defaults).interval == 5)
    defaults.set(0.1, forKey: "monitorInterval")
    precondition(MonitorConfiguration(defaults: defaults).interval == 2)
    for metric in MonitorMetric.allCases { defaults.set(true, forKey: "monitorDisabled_" + metric.rawValue) }
    precondition(MonitorConfiguration(defaults: defaults).enabled.isEmpty)
    defaults.removePersistentDomain(forName: suite)
    print("PASS: disk free/available/purgeable estimates, invalid and unknown capacity, counter baselines, resets, units and monitor preferences")
}

func runSystemMonitorUITests(_ controller: ClockController) {
    guard let outputIndex = CommandLine.arguments.firstIndex(of: "--monitor-ui-output"), CommandLine.arguments.count > outputIndex + 1 else { preconditionFailure("Provide --monitor-ui-output directory") }
    let output = URL(fileURLWithPath: CommandLine.arguments[outputIndex + 1], isDirectory: true)
    try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var snapshot = MonitorSnapshot()
    snapshot.cpu = 12
    snapshot.memoryTotal = 32 * 1_073_741_824
    snapshot.memoryUsed = UInt64(18.6 * 1_073_741_824)
    snapshot.network = MonitorRates(read: 1_800_000, write: 240_000)
    snapshot.networkName = "Wi-Fi"
    snapshot.networkConnected = true
    snapshot.disk = MonitorRates(read: 12_000_000, write: 4_000_000)
    snapshot.capacity = MonitorCapacity(total: 494_380_000_000, free: 40_990_000_000, important: 81_720_000_000)
    snapshot.sampled = true
    controller.systemMonitor.useTestSnapshot(snapshot)
    controller.applySettings()
    func capture(_ name: String, view: NSView? = nil) {
        let view = view ?? controller.clockView!
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: representation)
        }
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        NSColor(srgbRed: 0.14, green: 0.22, blue: 0.29, alpha: 1).setFill()
        view.bounds.fill()
        representation.draw(in: view.bounds)
        image.unlockFocus()
        let result = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try! result.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    }
    precondition(controller.panel.frame.width == 320)
    let buttons = [controller.disclosureButton, controller.systemButton, controller.queryButton, controller.settingsButton]
    for (index, button) in buttons.enumerated() {
        precondition(controller.clockView.bounds.contains(button.frame))
        for other in buttons.dropFirst(index + 1) { precondition(!button.frame.intersects(other.frame)) }
    }
    let expandedHeight = controller.panel.frame.height
    capture("native-expanded")
    controller.toggleSystem()
    precondition(controller.monitorHeight == 34 && controller.panel.frame.height < expandedHeight)
    capture("native-summary")
    let quotaVisibility = controller.showQuota
    controller.toggleSystem()
    precondition(controller.showQuota == quotaVisibility)
    controller.systemView.showsCapacityExplanation = true
    controller.applySettings()
    capture("native-capacity-detail")
    controller.systemView.showsCapacityExplanation = false
    let source = controller.quota.sources[0]
    source.response = QuotaResponse(updated_at: "2030-01-01T00:00:00Z", accounts: [QuotaAccount(label: "演示账户", status: "ok", message: nil, windows: [QuotaWindow(group: nil, label: "周额度", remaining_percent: 76, reset_at: "2030-01-08T00:00:00Z")])])
    controller.defaults.set(false, forKey: "hideQuota")
    controller.applySettings()
    capture("native-with-quota")
    precondition(controller.systemView.frame.minY >= 0)
    controller.defaults.set(true, forKey: "hideQuota")
    controller.appearanceSettings.show(tab: 1)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    capture("native-monitor-settings", view: controller.appearanceSettings.window.contentView)
    if CommandLine.arguments.contains("--monitor-ui-inspect") {
        print("READY: isolated native monitor settings inspection")
        fflush(stdout)
        RunLoop.main.run(until: Date().addingTimeInterval(60))
    }
    controller.appearanceSettings.window.orderOut(nil)
    snapshot.capacity = MonitorCapacity(total: 494_380_000_000, free: 40_990_000_000, important: nil)
    controller.systemMonitor.useTestSnapshot(snapshot)
    controller.applySettings()
    capture("native-capacity-unknown")
    snapshot.diskMounted = false
    snapshot.capacity = nil
    snapshot.disk = nil
    controller.systemMonitor.useTestSnapshot(snapshot)
    controller.applySettings()
    capture("native-disk-disconnected")
    for metric in MonitorMetric.allCases { controller.defaults.set(true, forKey: "monitorDisabled_" + metric.rawValue) }
    controller.applySettings()
    precondition(controller.monitorHeight == 0 && controller.quotaScroll.isHidden)
    print("PASS: native monitor geometry, independent disclosure, capacity details, settings, unknown/unmounted disk and all-disabled state")
}

import Foundation
import Darwin
import IOKit
import DiskArbitration
import SystemConfiguration

enum MonitorMetric: String, CaseIterable {
    case cpu, memory, network, disk

    var title: String {
        switch self {
        case .cpu: return "CPU 占用"
        case .memory: return "内存占用"
        case .network: return "网络上下行"
        case .disk: return "磁盘空间与读写"
        }
    }
}

struct MonitorConfiguration: Equatable {
    var enabled: Set<MonitorMetric> = Set(MonitorMetric.allCases)
    var interval: TimeInterval = 2
    var volumeID = "system"
    var interface = ""

    init() {}

    init(defaults: UserDefaults) {
        enabled = Set(MonitorMetric.allCases.filter { !defaults.bool(forKey: "monitorDisabled_" + $0.rawValue) })
        let stored = defaults.double(forKey: "monitorInterval")
        interval = [1.0, 2.0, 5.0].contains(stored) ? stored : 2
        volumeID = defaults.string(forKey: "monitorVolume") ?? "system"
        interface = defaults.string(forKey: "monitorInterface") ?? ""
    }
}

struct MonitorVolume: Equatable {
    let id: String
    let title: String
    let url: URL
}

struct MonitorCapacity {
    let total: Int64
    let free: Int64
    let available: Int64?
    var purgeable: Int64? { available.map { $0 - free } }

    init?(total: Int64, free: Int64, important: Int64?) {
        guard total > 0, free >= 0, free <= total else { return nil }
        self.total = total
        self.free = free
        available = important.flatMap { $0 >= free && $0 <= total ? $0 : nil }
    }
}

struct MonitorRates {
    let read: Double
    let write: Double
}

struct MonitorCounters {
    let identity: String
    let time: TimeInterval
    let read: UInt64
    let write: UInt64

    func rates(since previous: MonitorCounters?) -> MonitorRates? {
        guard let previous = previous, previous.identity == identity,
              time > previous.time, time - previous.time <= 30,
              read >= previous.read, write >= previous.write else { return nil }
        let elapsed = time - previous.time
        return MonitorRates(read: Double(read - previous.read) / elapsed, write: Double(write - previous.write) / elapsed)
    }
}

struct MonitorSnapshot {
    var cpu: Double?
    var memoryUsed: UInt64?
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var memoryPercent: Double? { memoryUsed.map { min(100, Double($0) / Double(max(1, memoryTotal)) * 100) } }
    var network: MonitorRates?
    var networkName = "未连接"
    var networkConnected = false
    var disk: MonitorRates?
    var diskName = "系统盘"
    var diskMounted = true
    var capacity: MonitorCapacity?
    var sampled = false
}

func monitorSize(_ bytes: Double, rate: Bool = false, compact: Bool = false) -> String {
    guard bytes.isFinite, bytes >= 0 else { return "—" }
    let units = compact ? ["B", "K", "M", "G", "T"] : ["B", "KB", "MB", "GB", "TB"]
    var value = bytes
    var unit = 0
    while value >= 1000 && unit < units.count - 1 { value /= 1000; unit += 1 }
    let digits = unit == 0 || value >= 100 ? 0 : value >= 10 ? 1 : 2
    let number = String(format: "%.*f", digits, value)
    return number + (compact ? "" : " ") + units[unit] + (rate && !compact ? "/s" : "")
}

func monitorGB(_ bytes: Int64) -> String { String(format: "%.2f GB", Double(bytes) / 1_000_000_000) }

final class MonitorDiskReader {
    private var service: io_registry_entry_t = 0
    private var registryID: UInt64 = 0
    private var previous: MonitorCounters?
    private let session = DASessionCreate(kCFAllocatorDefault)

    deinit { if service != 0 { IOObjectRelease(service) } }

    func reset() {
        if service != 0 { IOObjectRelease(service) }
        service = 0
        registryID = 0
        previous = nil
    }

    private func statistics(_ entry: io_registry_entry_t) -> (UInt64, UInt64)? {
        guard let values = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
              let read = values["Bytes (Read)"] as? NSNumber,
              let write = values["Bytes (Write)"] as? NSNumber else { return nil }
        return (read.uint64Value, write.uint64Value)
    }

    func bind(volume: MonitorVolume?) {
        guard let volume = volume, let session = session,
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume.url as CFURL) else { reset(); return }
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { reset(); return }
        defer { IOObjectRelease(media) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(media, kIOServicePlane, IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { reset(); return }
        defer { IOObjectRelease(iterator) }
        var candidate = IOIteratorNext(iterator)
        while candidate != 0 {
            if statistics(candidate) != nil {
                var identifier: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(candidate, &identifier)
                if service != 0 && identifier == registryID { IOObjectRelease(candidate); return }
                reset()
                service = candidate
                registryID = identifier
                return
            }
            IOObjectRelease(candidate)
            candidate = IOIteratorNext(iterator)
        }
        reset()
    }

    func sample(at time: TimeInterval) -> MonitorRates? {
        guard service != 0, let values = statistics(service) else { previous = nil; return nil }
        let current = MonitorCounters(identity: String(registryID), time: time, read: values.0, write: values.1)
        defer { previous = current }
        return current.rates(since: previous)
    }
}

final class SystemSampler {
    private var previousCPU: (ticks: [UInt32], time: TimeInterval)?
    private var previousNetwork: MonitorCounters?
    private let diskReader = MonitorDiskReader()
    private var selectedVolume = ""
    private var capacityTime: TimeInterval?
    private var cachedCapacity: MonitorCapacity?
    private var volume: MonitorVolume?
    private var cachedInterfaces: [(id: String, title: String)] = []
    private var interfaceTime: TimeInterval?
    private let store = SCDynamicStoreCreate(kCFAllocatorDefault, "FloatingClock" as CFString, nil, nil)

    static func volumes() -> [MonitorVolume] {
        let manager = FileManager.default
        let dataPath = "/System/Volumes/Data"
        let systemURL = URL(fileURLWithPath: manager.fileExists(atPath: dataPath) ? dataPath : "/", isDirectory: true)
        var result = [MonitorVolume(id: "system", title: "系统盘", url: systemURL)]
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsLocalKey, .volumeIsBrowsableKey]
        for url in manager.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? [] {
            guard url.path.hasPrefix("/Volumes/"), let values = try? url.resourceValues(forKeys: keys),
                  values.volumeIsLocal == true, values.volumeIsBrowsable != false else { continue }
            result.append(MonitorVolume(id: url.path, title: values.volumeName ?? url.lastPathComponent, url: url))
        }
        return [result[0]] + result.dropFirst().sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func interfaces() -> [(id: String, title: String)] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
        return interfaces.compactMap { interface in
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String?,
                  type == (kSCNetworkInterfaceTypeIEEE80211 as String) || type == (kSCNetworkInterfaceTypeEthernet as String) else { return nil }
            let title = type == (kSCNetworkInterfaceTypeIEEE80211 as String) ? "Wi-Fi" : "以太网"
            return (id: name, title: title + " · " + name)
        }.sorted { $0.id < $1.id }
    }

    func reset() {
        previousCPU = nil
        previousNetwork = nil
        capacityTime = nil
        interfaceTime = nil
        diskReader.reset()
    }

    private func cpu(at time: TimeInterval) -> Double? {
        var statistics = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard status == KERN_SUCCESS else { previousCPU = nil; return nil }
        let ticks = [statistics.cpu_ticks.0, statistics.cpu_ticks.1, statistics.cpu_ticks.2, statistics.cpu_ticks.3]
        defer { previousCPU = (ticks, time) }
        guard let previous = previousCPU, time > previous.time, time - previous.time <= 30 else { return nil }
        let deltas = zip(ticks, previous.ticks).map { UInt64($0 &- $1) }
        let total = deltas.reduce(0, +)
        guard total > 0 else { return nil }
        return min(100, max(0, Double(total - deltas[2]) / Double(total) * 100))
    }

    private func memory() -> UInt64? {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard status == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        let application = UInt64(statistics.internal_page_count) > UInt64(statistics.purgeable_count) ? UInt64(statistics.internal_page_count) - UInt64(statistics.purgeable_count) : 0
        let used = (application + UInt64(statistics.wire_count) + UInt64(statistics.compressor_page_count)) * UInt64(pageSize)
        return min(ProcessInfo.processInfo.physicalMemory, used)
    }

    private func networkCounters() -> [String: (read: UInt64, write: UInt64)] {
        var query: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&query, u_int(query.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { sysctl(&query, u_int(query.count), $0.baseAddress, &length, nil, 0) }
        guard status == 0 else { return [:] }
        var result: [String: (UInt64, UInt64)] = [:]
        var offset = 0
        while offset + 4 <= length {
            var messageLength: UInt16 = 0
            withUnsafeMutableBytes(of: &messageLength) { _ = data.copyBytes(to: $0, from: offset..<(offset + 2)) }
            let size = Int(messageLength)
            guard size >= 4, offset + size <= length else { break }
            if data[offset + 3] == UInt8(RTM_IFINFO2), size >= MemoryLayout<if_msghdr2>.size {
                var header = if_msghdr2()
                withUnsafeMutableBytes(of: &header) { _ = data.copyBytes(to: $0, from: offset..<(offset + MemoryLayout<if_msghdr2>.size)) }
                if header.ifm_flags & IFF_UP != 0 && header.ifm_flags & IFF_LOOPBACK == 0 {
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(header.ifm_index), &name) != nil {
                        result[String(cString: name)] = (header.ifm_data.ifi_ibytes, header.ifm_data.ifi_obytes)
                    }
                }
            }
            offset += size
        }
        return result
    }

    private func primaryInterface(candidates: [String: (read: UInt64, write: UInt64)], configured: String) -> String? {
        if !configured.isEmpty { return candidates[configured] == nil ? nil : configured }
        let physical = Set(cachedInterfaces.map { $0.id })
        if let store = store {
            for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
                if let values = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                   let name = values["PrimaryInterface"] as? String, physical.contains(name), candidates[name] != nil { return name }
            }
            for name in physical.sorted() where candidates[name] != nil {
                if let values = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(name)/Link" as CFString) as? [String: Any], values["Active"] as? Bool == true { return name }
            }
        }
        return nil
    }

    private func capacity(for url: URL) -> MonitorCapacity? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let values = (try? url.resourceValues(forKeys: keys)) ?? (try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]))
        guard let total = values?.volumeTotalCapacity, let free = values?.volumeAvailableCapacity else { return nil }
        return MonitorCapacity(total: Int64(total), free: Int64(free), important: values?.volumeAvailableCapacityForImportantUsage)
    }

    func sample(_ configuration: MonitorConfiguration, forceCapacity: Bool = false) -> MonitorSnapshot {
        let time = ProcessInfo.processInfo.systemUptime
        var snapshot = MonitorSnapshot()
        snapshot.sampled = true
        if configuration.enabled.contains(.cpu) { snapshot.cpu = cpu(at: time) } else { previousCPU = nil }
        if configuration.enabled.contains(.memory) { snapshot.memoryUsed = memory() }
        if configuration.enabled.contains(.network) {
            if forceCapacity || interfaceTime == nil || time - (interfaceTime ?? 0) >= 60 {
                cachedInterfaces = Self.interfaces()
                interfaceTime = time
            }
            let candidates = networkCounters()
            if let interface = primaryInterface(candidates: candidates, configured: configuration.interface), let counts = candidates[interface] {
                let current = MonitorCounters(identity: interface, time: time, read: counts.read, write: counts.write)
                snapshot.network = current.rates(since: previousNetwork)
                snapshot.networkConnected = true
                snapshot.networkName = cachedInterfaces.first { $0.id == interface }?.title.components(separatedBy: " · ").first ?? interface
                previousNetwork = current
            } else { previousNetwork = nil }
        } else { previousNetwork = nil }
        if configuration.enabled.contains(.disk) {
            if forceCapacity || selectedVolume != configuration.volumeID || capacityTime == nil || time - (capacityTime ?? 0) >= 60 {
                selectedVolume = configuration.volumeID
                volume = Self.volumes().first { $0.id == configuration.volumeID }
                cachedCapacity = volume.flatMap { capacity(for: $0.url) }
                capacityTime = time
                diskReader.bind(volume: volume)
            }
            snapshot.diskMounted = volume != nil
            snapshot.diskName = volume?.title ?? "所选磁盘"
            snapshot.capacity = cachedCapacity
            snapshot.disk = diskReader.sample(at: time)
        } else { diskReader.reset(); capacityTime = nil }
        return snapshot
    }
}

final class SystemMonitor {
    private let queue = DispatchQueue(label: "local.floatingclock.system-monitor", qos: .utility)
    private lazy var sampler = SystemSampler()
    private var timer: DispatchSourceTimer?
    private var generation = 0
    private var inFlight = false
    private var pendingCapacity = false
    private var suspended = false
    private(set) var configuration = MonitorConfiguration()
    private(set) var snapshot = MonitorSnapshot()
    var onChange: (() -> Void)?

    func configure(_ value: MonitorConfiguration) {
        guard value != configuration || (timer == nil && !value.enabled.isEmpty && !suspended) else { return }
        configuration = value
        pendingCapacity = false
        generation += 1
        timer?.cancel()
        timer = nil
        queue.async { self.sampler.reset() }
        guard !suspended, !value.enabled.isEmpty else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + value.interval, repeating: value.interval, leeway: .milliseconds(150))
        source.setEventHandler { [weak self] in self?.refresh() }
        timer = source
        source.resume()
        refresh(forceCapacity: true)
    }

    func refresh(forceCapacity: Bool = false) {
        guard !suspended, !configuration.enabled.isEmpty else { return }
        if inFlight { pendingCapacity = pendingCapacity || forceCapacity; return }
        inFlight = true
        let current = configuration
        let token = generation
        queue.async {
            let result = self.sampler.sample(current, forceCapacity: forceCapacity)
            DispatchQueue.main.async {
                self.inFlight = false
                guard token == self.generation else { self.refresh(forceCapacity: true); return }
                self.snapshot = result
                self.onChange?()
                if self.pendingCapacity {
                    self.pendingCapacity = false
                    self.refresh(forceCapacity: true)
                }
            }
        }
    }

    func useTestSnapshot(_ value: MonitorSnapshot) {
        precondition(CommandLine.arguments.contains("--monitor-ui-self-test"))
        snapshot = value
    }

    func setSuspended(_ value: Bool) {
        suspended = value
        pendingCapacity = false
        generation += 1
        timer?.cancel()
        timer = nil
        queue.async { self.sampler.reset() }
        if !value { configure(configuration) }
    }
}

import Darwin
import Foundation

final class SystemMetricCollector {
    private var previousCPUTicks: CPUTicks?
    private var previousNetworkCounters: NetworkCounters?
    private var cachedDiskPercent: Double?
    private var cachedTemperature: Double?
    private var lastDiskUptime: TimeInterval = -.infinity
    private var lastTemperatureUptime: TimeInterval = -.infinity
    private let smcReader: SMCReader
    private let hidTemperatureReader: HIDTemperatureReader

    init(
        smcReader: SMCReader = SMCReader(),
        hidTemperatureReader: HIDTemperatureReader = HIDTemperatureReader()
    ) {
        self.smcReader = smcReader
        self.hidTemperatureReader = hidTemperatureReader
    }

    func resetDeltas() {
        previousCPUTicks = nil
        previousNetworkCounters = nil
    }

    func sample(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> MetricSnapshot {
        let cpu = sampleCPU()
        let memory = sampleMemory()
        let network = sampleNetwork(uptime: uptime)

        if uptime - lastDiskUptime >= 10 {
            cachedDiskPercent = sampleDisk()
            lastDiskUptime = uptime
        }

        if uptime - lastTemperatureUptime >= 4 {
            cachedTemperature = smcReader.averageM1CPUTemperature()
                ?? hidTemperatureReader.averageM1CPUTemperature()
            lastTemperatureUptime = uptime
        }

        return MetricSnapshot(
            cpuPercent: cpu,
            memoryPercent: memory,
            diskPercent: cachedDiskPercent,
            temperatureCelsius: cachedTemperature,
            uploadBytesPerSecond: network?.upload,
            downloadBytesPerSecond: network?.download,
            sampledAt: now
        )
    }

    private func sampleCPU() -> Double? {
        guard let current = readCPUTicks() else { return nil }
        defer { previousCPUTicks = current }
        guard let previousCPUTicks else { return nil }
        return CPUTicks.usagePercent(previous: previousCPUTicks, current: current)
    }

    private func readCPUTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    private func sampleMemory() -> Double? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        let usedPages = UInt64(stats.active_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)
        let usedBytes = usedPages * UInt64(pageSize)
        return MetricMath.percent(used: usedBytes, total: ProcessInfo.processInfo.physicalMemory)
    }

    private func sampleDisk() -> Double? {
        do {
            let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey
            ])
            guard let totalValue = values.volumeTotalCapacity,
                  let availableValue = values.volumeAvailableCapacity,
                  totalValue > 0 else { return nil }
            let total = UInt64(totalValue)
            let available = UInt64(max(0, availableValue))
            return MetricMath.percent(used: total > available ? total - available : 0, total: total)
        } catch {
            return nil
        }
    }

    private func sampleNetwork(uptime: TimeInterval) -> (download: Double, upload: Double)? {
        guard let totals = readNetworkTotals() else { return nil }
        let current = NetworkCounters(
            receivedBytes: totals.received,
            sentBytes: totals.sent,
            uptime: uptime
        )
        defer { previousNetworkCounters = current }
        guard let previousNetworkCounters else { return nil }
        return NetworkCounters.rates(previous: previousNetworkCounters, current: current)
    }

    private func readNetworkTotals() -> (received: UInt64, sent: UInt64)? {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return nil }
        defer { freeifaddrs(firstAddress) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var foundInterface = false
        var address: UnsafeMutablePointer<ifaddrs>? = firstAddress

        while let current = address {
            let interface = current.pointee
            defer { address = interface.ifa_next }
            guard let socketAddress = interface.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_LINK),
                  let namePointer = interface.ifa_name,
                  let dataPointer = interface.ifa_data else {
                continue
            }

            let name = String(cString: namePointer)
            let requiredFlags = UInt32(IFF_UP | IFF_RUNNING)
            let flags = interface.ifa_flags
            guard flags & requiredFlags == requiredFlags,
                  flags & UInt32(IFF_LOOPBACK) == 0,
                  name.hasPrefix("en") else {
                continue
            }

            let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
            received += UInt64(data.ifi_ibytes)
            sent += UInt64(data.ifi_obytes)
            foundInterface = true
        }

        return foundInterface ? (received, sent) : nil
    }
}

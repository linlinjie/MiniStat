import Foundation

enum MetricModule: String, CaseIterable, Codable {
    case cpu
    case memory
    case disk
    case temperature
    case network

    var menuTitle: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "MEM"
        case .disk: return "SSD"
        case .temperature: return "TEMP"
        case .network: return "NET"
        }
    }
}

struct MetricSnapshot: Equatable {
    var cpuPercent: Double?
    var memoryPercent: Double?
    var diskPercent: Double?
    var temperatureCelsius: Double?
    var uploadBytesPerSecond: Double?
    var downloadBytesPerSecond: Double?
    var sampledAt: Date

    static let empty = MetricSnapshot(
        cpuPercent: nil,
        memoryPercent: nil,
        diskPercent: nil,
        temperatureCelsius: nil,
        uploadBytesPerSecond: nil,
        downloadBytesPerSecond: nil,
        sampledAt: Date()
    )
}

struct CPUTicks: Equatable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64

    static func usagePercent(previous: CPUTicks, current: CPUTicks) -> Double? {
        guard current.user >= previous.user,
              current.system >= previous.system,
              current.idle >= previous.idle,
              current.nice >= previous.nice else {
            return nil
        }

        let userDelta = current.user - previous.user
        let systemDelta = current.system - previous.system
        let idleDelta = current.idle - previous.idle
        let niceDelta = current.nice - previous.nice
        let total = userDelta + systemDelta + idleDelta + niceDelta
        guard total > 0 else { return nil }

        let busy = userDelta + systemDelta + niceDelta
        return min(100, max(0, Double(busy) / Double(total) * 100))
    }
}

struct NetworkCounters: Equatable {
    let receivedBytes: UInt64
    let sentBytes: UInt64
    let uptime: TimeInterval

    static func rates(previous: NetworkCounters, current: NetworkCounters) -> (download: Double, upload: Double)? {
        guard current.uptime > previous.uptime,
              current.receivedBytes >= previous.receivedBytes,
              current.sentBytes >= previous.sentBytes else {
            return nil
        }

        let elapsed = current.uptime - previous.uptime
        guard elapsed > 0 else { return nil }
        return (
            Double(current.receivedBytes - previous.receivedBytes) / elapsed,
            Double(current.sentBytes - previous.sentBytes) / elapsed
        )
    }
}

enum MetricMath {
    static func percent(used: UInt64, total: UInt64) -> Double? {
        guard total > 0 else { return nil }
        return min(100, max(0, Double(used) / Double(total) * 100))
    }

    static func validTemperature(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (10...120).contains(value) else { return nil }
        return value
    }
}

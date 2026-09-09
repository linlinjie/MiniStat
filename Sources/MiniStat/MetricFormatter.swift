import Foundation

enum MetricFormatter {
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--%" }
        return "\(Int(value.rounded()))%"
    }

    static func temperature(_ value: Double?) -> String {
        guard let value = MetricMath.validTemperature(value) else { return "--°C" }
        return "\(Int(value.rounded()))°C"
    }

    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let value = bytesPerSecond, value.isFinite, value >= 0 else { return "-- B/s" }

        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var scaled = value
        var index = 0
        while scaled >= 1024, index < units.count - 1 {
            scaled /= 1024
            index += 1
        }

        if index == 0 {
            return "\(Int(scaled.rounded())) \(units[index])"
        }
        if scaled >= 100 {
            return "\(Int(scaled.rounded())) \(units[index])"
        }
        return String(format: "%.1f %@", scaled, units[index])
    }

    static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var scaled = Double(value)
        var index = 0
        while scaled >= 1024, index < units.count - 1 {
            scaled /= 1024
            index += 1
        }

        if index == 0 || scaled >= 100 {
            return "\(Int(scaled.rounded())) \(units[index])"
        }
        return String(format: "%.1f %@", scaled, units[index])
    }
}

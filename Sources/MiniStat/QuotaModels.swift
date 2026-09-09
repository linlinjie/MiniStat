import Foundation
import CoreFoundation

enum QuotaDisplay: String, CaseIterable {
    case off, codex, cursor, both
    var title: String {
        switch self {
        case .off: return "关闭"
        case .codex: return "仅 Codex"
        case .cursor: return "仅 Cursor"
        case .both: return "Codex 和 Cursor"
        }
    }
    var providers: [String] {
        switch self {
        case .off: return []
        case .codex: return ["Codex"]
        case .cursor: return ["Cursor"]
        case .both: return ["Codex", "Cursor"]
        }
    }
}

struct QuotaWindow {
    let title: String
    let remaining: Double
    let reset: Date?
    var durationMinutes: Int? = nil
}

struct QuotaReading {
    let windows: [QuotaWindow]
    let updated: Date
    func currentWindows(at now: Date = Date()) -> [QuotaWindow] {
        guard now.timeIntervalSince(updated) < 900 else { return [] }
        return windows.filter { $0.reset.map { $0 > now } ?? true }
    }
    var text: String {
        guard let value = currentWindows().map(\.remaining).min() else { return "--%" }
        return "\(Int(value.rounded()))%"
    }

    static func statusCells(provider: String, reading: QuotaReading?, failed: Bool = false) -> [(String, String)] {
        let windows = reading?.currentWindows() ?? []
        func text(_ window: QuotaWindow?) -> String {
            guard let window else { return "--%" }
            return "\(Int(window.remaining.rounded()))%" + (failed ? "*" : "")
        }
        if provider == "Codex" {
            return [("CODEX 5H", text(windows.first { $0.durationMinutes == 300 })),
                    ("CODEX 7D", text(windows.first { $0.durationMinutes == 10080 }))]
        }
        return [("CURSOR", text(windows.first))]
    }
}

enum QuotaParsing {
    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        let result = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        return result.flatMap { $0.isFinite ? $0 : nil }
    }
    static func remaining(_ value: Any?) -> Double? {
        number(value).map { max(0, min(100, 100 - $0)) }
    }
    static func codex(_ json: [String: Any]) -> QuotaReading? {
        let byID = json["rateLimitsByLimitId"] as? [String: Any]
        guard let limits = (byID?["codex"] ?? json["rateLimits"]) as? [String: Any] else { return nil }
        let windows = ["primary", "secondary"].compactMap { key -> QuotaWindow? in
            guard let item = limits[key] as? [String: Any], let left = remaining(item["usedPercent"]) else { return nil }
            let minutes = number(item["windowDurationMins"]) ?? 0
            let label = minutes == 10080 ? "周额度" : minutes == 300 ? "5 小时" : "\(Int(minutes)) 分钟"
            return QuotaWindow(title: label, remaining: left, reset: number(item["resetsAt"]).map(Date.init(timeIntervalSince1970:)), durationMinutes: Int(minutes))
        }
        return windows.isEmpty ? nil : QuotaReading(windows: windows, updated: Date())
    }
    static func cursor(_ json: [String: Any]) -> QuotaReading? {
        guard let plan = json["planUsage"] as? [String: Any], let left = remaining(plan["totalPercentUsed"]) else { return nil }
        let raw = json["billingCycleEnd"]
        let reset: Date?
        if let value = number(raw), value > 0 {
            reset = Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
        } else {
            reset = (raw as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        }
        return QuotaReading(windows: [QuotaWindow(title: "本计费周期", remaining: left, reset: reset)], updated: Date())
    }
}

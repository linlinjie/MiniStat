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

enum CursorQuotaPool: CaseIterable {
    case cursorModels, otherModels
    var title: String { self == .cursorModels ? "Cursor Models" : "Other Models" }
    var field: String { self == .cursorModels ? "autoPercentUsed" : "apiPercentUsed" }
    var label: String { self == .cursorModels ? "CURSOR M" : "OTHER M" }
}

struct QuotaWindow {
    let title: String
    let remaining: Double
    let reset: Date?
    var durationMinutes: Int? = nil
    var cursorPool: CursorQuotaPool? = nil
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
            // Codex plans do not always expose the familiar 5-hour and 7-day
            // windows. Free plans may expose one 30-day window, for example.
            // Show the actual active windows rather than inventing a missing
            // 7-day row from a paid-plan layout.
            let ordered = windows.sorted { lhs, rhs in
                let order: [Int: Int] = [300: 0, 10080: 1]
                let lhsOrder = order[lhs.durationMinutes ?? -1] ?? 2
                let rhsOrder = order[rhs.durationMinutes ?? -1] ?? 2
                return lhsOrder == rhsOrder
                    ? (lhs.durationMinutes ?? 0) < (rhs.durationMinutes ?? 0)
                    : lhsOrder < rhsOrder
            }
            return ordered.prefix(2).map { (codexStatusLabel($0), text($0)) }
        }
        return CursorQuotaPool.allCases.map { pool in
            (pool.label, text(windows.first { $0.cursorPool == pool }))
        }
    }

    private static func codexStatusLabel(_ window: QuotaWindow) -> String {
        switch window.durationMinutes {
        case 300: return "CODEX 5H"
        case 10080: return "CODEX 7D"
        case let minutes? where minutes > 0:
            if minutes.isMultiple(of: 1440) { return "CODEX \(minutes / 1440)D" }
            if minutes.isMultiple(of: 60) { return "CODEX \(minutes / 60)H" }
            return "CODEX \(minutes)M"
        default: return "CODEX"
        }
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
            let label: String
            if minutes == 10080 { label = "周额度" }
            else if minutes == 300 { label = "5 小时" }
            else if minutes > 0, Int(minutes).isMultiple(of: 1440) { label = "\(Int(minutes) / 1440) 天" }
            else if minutes > 0, Int(minutes).isMultiple(of: 60) { label = "\(Int(minutes) / 60) 小时" }
            else if minutes > 0 { label = "\(Int(minutes)) 分钟" }
            else { label = "当前周期" }
            return QuotaWindow(title: label, remaining: left, reset: number(item["resetsAt"]).map(Date.init(timeIntervalSince1970:)), durationMinutes: Int(minutes))
        }
        return windows.isEmpty ? nil : QuotaReading(windows: windows, updated: Date())
    }
    static func cursor(_ json: [String: Any]) -> QuotaReading? {
        guard let plan = json["planUsage"] as? [String: Any] else { return nil }
        let raw = json["billingCycleEnd"]
        let reset: Date?
        if let value = number(raw), value > 0 {
            reset = Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
        } else {
            reset = (raw as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        }
        // The endpoint retains legacy auto/API names for the two dashboard pools.
        // Never substitute the aggregate percentage for a missing pool.
        let windows = CursorQuotaPool.allCases.compactMap { pool -> QuotaWindow? in
            guard let left = remaining(plan[pool.field]) else { return nil }
            return QuotaWindow(title: pool.title, remaining: left, reset: reset, cursorPool: pool)
        }
        return windows.isEmpty ? nil : QuotaReading(windows: windows, updated: Date())
    }
}

import Foundation

struct AppPreferences: Equatable {
    var visibleModules: Set<MetricModule>
    var refreshInterval: TimeInterval
    var quotaDisplay: QuotaDisplay = .both
    var quotaRefreshInterval: TimeInterval = 300
    static let metricIntervals: [TimeInterval] = [1, 2, 5, 10, 30, 60, 120, 300]
    static let quotaIntervals: [TimeInterval] = [10, 30, 60, 120, 300]

    static func intervalTitle(_ interval: TimeInterval) -> String {
        interval < 60 ? "\(Int(interval)) 秒" : "\(Int(interval / 60)) 分钟"
    }

    static let defaults = AppPreferences(
        visibleModules: Set(MetricModule.allCases),
        refreshInterval: 2
    )
}

final class SettingsStore {
    private enum Key {
        static let visibleModules = "visibleModules"
        static let refreshInterval = "refreshInterval"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppPreferences {
        let modules: Set<MetricModule>
        if let rawValues = defaults.stringArray(forKey: Key.visibleModules) {
            modules = Set(rawValues.compactMap(MetricModule.init(rawValue:)))
        } else {
            modules = AppPreferences.defaults.visibleModules
        }

        let storedInterval = defaults.double(forKey: Key.refreshInterval)
        let supportedIntervals = AppPreferences.metricIntervals
        let interval = supportedIntervals.contains(storedInterval)
            ? storedInterval
            : AppPreferences.defaults.refreshInterval

        let quotaInterval = defaults.double(forKey: "quotaRefreshInterval")
        return AppPreferences(visibleModules: modules, refreshInterval: interval,
            quotaDisplay: defaults.string(forKey: "quotaDisplay").flatMap(QuotaDisplay.init(rawValue:)) ?? .both,
            quotaRefreshInterval: AppPreferences.quotaIntervals.contains(quotaInterval) ? quotaInterval : 300)
    }

    func save(_ preferences: AppPreferences) {
        let orderedValues = MetricModule.allCases
            .filter(preferences.visibleModules.contains)
            .map(\.rawValue)
        defaults.set(orderedValues, forKey: Key.visibleModules)
        defaults.set(preferences.refreshInterval, forKey: Key.refreshInterval)
        defaults.set(preferences.quotaDisplay.rawValue, forKey: "quotaDisplay")
        defaults.set(preferences.quotaRefreshInterval, forKey: "quotaRefreshInterval")
    }
}

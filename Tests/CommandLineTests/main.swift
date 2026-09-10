import Darwin
import Foundation
import CoreGraphics

private var failures = 0

private func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        print("✓ \(name)")
    } else {
        failures += 1
        print("✗ \(name)")
    }
}

private func approximatelyEqual(_ lhs: Double?, _ rhs: Double, tolerance: Double = 0.0001) -> Bool {
    guard let lhs else { return false }
    return abs(lhs - rhs) <= tolerance
}

let oldTicks = CPUTicks(user: 100, system: 50, idle: 350, nice: 0)
let newTicks = CPUTicks(user: 120, system: 60, idle: 420, nice: 0)
check(approximatelyEqual(CPUTicks.usagePercent(previous: oldTicks, current: newTicks), 30), "CPU tick delta")
check(CPUTicks.usagePercent(previous: oldTicks, current: oldTicks) == nil, "CPU empty delta")
check(
    CPUTicks.usagePercent(
        previous: oldTicks,
        current: CPUTicks(user: 99, system: 60, idle: 360, nice: 0)
    ) == nil,
    "CPU counter rollback"
)

let oldNetwork = NetworkCounters(receivedBytes: 1_000, sentBytes: 2_000, uptime: 10)
let newNetwork = NetworkCounters(receivedBytes: 3_048, sentBytes: 3_024, uptime: 12)
let rates = NetworkCounters.rates(previous: oldNetwork, current: newNetwork)
check(approximatelyEqual(rates?.download, 1_024), "network download delta")
check(approximatelyEqual(rates?.upload, 512), "network upload delta")
check(
    NetworkCounters.rates(
        previous: newNetwork,
        current: NetworkCounters(receivedBytes: 100, sentBytes: 100, uptime: 13)
    ) == nil,
    "network counter rollback"
)

check(MetricMath.percent(used: 25, total: 100) == 25, "percentage calculation")
check(MetricMath.percent(used: 150, total: 100) == 100, "percentage clamp")
check(MetricMath.percent(used: 1, total: 0) == nil, "zero total rejected")
check(MetricMath.validTemperature(42.5) == 42.5, "valid temperature")
check(MetricMath.validTemperature(9.9) == nil, "low temperature rejected")
check(MetricMath.validTemperature(120.1) == nil, "high temperature rejected")

check(MetricFormatter.percent(69.4) == "69%", "percentage formatting")
check(MetricFormatter.temperature(58.4) == "58°C", "temperature formatting")
check(MetricFormatter.rate(512) == "512 B/s", "byte rate formatting")
check(MetricFormatter.rate(1_024) == "1.0 KB/s", "kilobyte rate formatting")
check(MetricFormatter.rate(1_572_864) == "1.5 MB/s", "megabyte rate formatting")
check(MetricFormatter.bytes(512) == "512 B", "byte total formatting")
check(MetricFormatter.bytes(1_572_864) == "1.5 MB", "megabyte total formatting")

let parsedTraffic = NettopCSVParser.parseRecord("Google Chrome H.10198,3048,3024,")
check(parsedTraffic?.processName == "Google Chrome H", "nettop process name parsing")
check(parsedTraffic?.processID == 10198, "nettop process id parsing")
check(parsedTraffic?.receivedBytes == 3_048, "nettop received bytes parsing")
check(NettopCSVParser.parseRecord(",bytes_in,bytes_out,") == nil, "nettop header rejected")
check(
    ProcessApplicationName.resolve(
        executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
        fallback: "Google Chrome H"
    ) == "Google Chrome",
    "helper grouped under outer application"
)
check(
    ProcessApplicationName.resolve(executablePath: "/usr/sbin/mDNSResponder", fallback: "mDNSResponder") == "mDNSResponder",
    "daemon keeps process name"
)

let trafficAccumulator = ProcessTrafficAccumulator()
let firstTraffic = ProcessTrafficCounter(
    processName: "Browser",
    processID: 42,
    receivedBytes: 1_000,
    sentBytes: 2_000
)
check(trafficAccumulator.ingest([firstTraffic], at: 10).isEmpty, "traffic first sample baseline")
let secondTraffic = ProcessTrafficCounter(
    processName: "Browser",
    processID: 42,
    receivedBytes: 3_048,
    sentBytes: 3_024
)
let trafficRows = trafficAccumulator.ingest([secondTraffic], at: 12)
check(trafficRows.count == 1, "traffic row created")
check(approximatelyEqual(trafficRows.first?.downloadBytesPerSecond, 1_024), "traffic download rate")
check(approximatelyEqual(trafficRows.first?.uploadBytesPerSecond, 512), "traffic upload rate")
check(trafficRows.first?.downloadedBytes == 2_048, "traffic cumulative download")
let rollbackTraffic = ProcessTrafficCounter(
    processName: "Browser",
    processID: 42,
    receivedBytes: 100,
    sentBytes: 100
)
let rollbackRows = trafficAccumulator.ingest([rollbackTraffic], at: 13)
check(rollbackRows.first?.currentRate == 0, "traffic counter rollback")
check(rollbackRows.first?.downloadedBytes == 2_048, "traffic total survives rollback")

let suiteName = "MiniStatCommandLineTests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
defaults.removePersistentDomain(forName: suiteName)
let store = SettingsStore(defaults: defaults)
check(store.load() == .defaults, "settings defaults")
let customPreferences = AppPreferences(visibleModules: [.cpu, .network], refreshInterval: 5)
store.save(customPreferences)
check(store.load() == customPreferences, "settings round trip")
let hiddenPreferences = AppPreferences(visibleModules: [], refreshInterval: 1)
store.save(hiddenPreferences)
check(store.load() == hiddenPreferences, "all modules hidden persists")
defaults.set(3.0, forKey: "refreshInterval")
check(store.load().refreshInterval == 2, "unsupported refresh fallback")
defaults.removePersistentDomain(forName: suiteName)

check(QuotaParsing.remaining(0) == 100, "quota zero used is full")
check(QuotaParsing.remaining(1) == 99, "quota one used is numeric")
check(QuotaParsing.remaining(true) == nil, "quota boolean rejected")
check(QuotaParsing.remaining("125") == 0, "quota overspend clamped")
check(QuotaParsing.remaining(nil) == nil, "missing quota is unknown")
check(QuotaParsing.cursor(["planUsage": ["includedSpend": 10, "limit": 20]]) == nil, "spending is not quota percent")
let codexQuota = QuotaParsing.codex(["rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 25, "windowDurationMins": 300]]], "rateLimits": ["primary": ["usedPercent": 99]]])
check(codexQuota?.text == "75%", "codex named bucket preferred")
let expiredQuota = QuotaReading(windows: [QuotaWindow(title: "test", remaining: 40, reset: Date(timeIntervalSinceNow: -1))], updated: Date())
check(expiredQuota.text == "--%", "expired window is unknown")
let staleQuota = QuotaReading(windows: [QuotaWindow(title: "test", remaining: 40, reset: nil)], updated: Date(timeIntervalSinceNow: -901))
check(staleQuota.text == "--%", "stale reading is unknown")
for mode in QuotaDisplay.allCases {
    var preferences = AppPreferences.defaults
    preferences.quotaDisplay = mode
    store.save(preferences)
    check(store.load().quotaDisplay == mode, "quota selection persists: \(mode.rawValue)")
}
defaults.removePersistentDomain(forName: suiteName)

for interval in AppPreferences.quotaIntervals {
    var preferences = AppPreferences.defaults
    preferences.quotaRefreshInterval = interval
    store.save(preferences)
    check(store.load().quotaRefreshInterval == interval, "quota refresh persists: \(interval)")
}
for interval in AppPreferences.metricIntervals {
    var preferences = AppPreferences.defaults
    preferences.refreshInterval = interval
    store.save(preferences)
    check(store.load().refreshInterval == interval, "metric refresh persists: \(interval)")
}
defaults.set(1, forKey: "quotaRefreshInterval")
check(store.load().quotaRefreshInterval == 300, "invalid quota refresh falls back to 5 minutes")
check(AppPreferences.intervalTitle(10) == "10 秒", "seconds interval title")
check(AppPreferences.intervalTitle(120) == "2 分钟", "minutes interval title")
let twoWindows = QuotaParsing.codex(["rateLimits": [
    "primary": ["usedPercent": 20, "windowDurationMins": 10080],
    "secondary": ["usedPercent": 5, "windowDurationMins": 300]
]])
let cells = QuotaReading.statusCells(provider: "Codex", reading: twoWindows)
check(cells.map { $0.0 } == ["CODEX 5H", "CODEX 7D"], "codex labels distinguish both windows")
check(cells.map { $0.1 } == ["95%", "80%"], "codex windows matched by duration not position")
let partialCells = QuotaReading.statusCells(provider: "Codex", reading: codexQuota)
check(partialCells.map { $0.1 } == ["75%", "--%"], "missing weekly window is unknown")
check(QuotaReading.statusCells(provider: "Codex", reading: twoWindows, failed: true).map { $0.1 } == ["95%*", "80%*"], "failed codex refresh marks both cached windows")
check(QuotaReading.statusCells(provider: "Codex", reading: staleQuota).map { $0.1 } == ["--%", "--%"], "stale split windows hidden")
check(QuotaReading.statusCells(provider: "Cursor", reading: nil).map { $0.1 } == ["--%", "--%"], "cursor missing pools unknown")
let cursorSplit = QuotaParsing.cursor(["planUsage": ["autoPercentUsed": 90.8291666667, "apiPercentUsed": 100, "totalPercentUsed": 50]])!
check(cursorSplit.windows.map(\.title) == ["Cursor Models", "Other Models"], "cursor full pool titles")
check(QuotaReading.statusCells(provider: "Cursor", reading: cursorSplit).map { $0.0 } == ["CURSOR M", "OTHER M"], "cursor split labels")
check(QuotaReading.statusCells(provider: "Cursor", reading: cursorSplit).map { $0.1 } == ["9%", "0%"], "cursor independent pools ignore aggregate")
let reversedCursor = QuotaReading(windows: cursorSplit.windows.reversed(), updated: Date())
check(QuotaReading.statusCells(provider: "Cursor", reading: reversedCursor, failed: true).map { $0.1 } == ["9%*", "0%*"], "cursor matches pool identity and marks cache")
let cursorPartial = QuotaParsing.cursor(["planUsage": ["autoPercentUsed": true, "apiPercentUsed": "1", "totalPercentUsed": 20] as [String: Any]])
check(QuotaReading.statusCells(provider: "Cursor", reading: cursorPartial).map { $0.1 } == ["--%", "99%"], "cursor invalid pool not replaced by aggregate")
check(QuotaParsing.cursor(["planUsage": ["totalPercentUsed": 20]]) == nil, "cursor aggregate only rejected")
let cursorZero = QuotaParsing.cursor(["planUsage": ["autoPercentUsed": 0, "apiPercentUsed": "NaN"] as [String: Any]])
check(QuotaReading.statusCells(provider: "Cursor", reading: cursorZero).map { $0.1 } == ["100%", "--%"], "cursor zero and nonfinite pools")
let cursorExpired = QuotaParsing.cursor(["planUsage": ["autoPercentUsed": 0, "apiPercentUsed": 0], "billingCycleEnd": 1000])
check(QuotaReading.statusCells(provider: "Cursor", reading: cursorExpired).map { $0.1 } == ["--%", "--%"], "cursor reset expires both pools")
let cursorStale = QuotaReading(windows: cursorSplit.windows, updated: Date().addingTimeInterval(-901))
check(QuotaReading.statusCells(provider: "Cursor", reading: cursorStale).map { $0.1 } == ["--%", "--%"], "cursor stale pools unknown")
do {
    let result = try BoundedCommand.run(path: "/usr/bin/printf", arguments: ["fixture-only"])
    check(result.status == 0 && String(data: result.output, encoding: .utf8) == "fixture-only", "bounded command captures stdout")
    let failure = try BoundedCommand.run(path: "/usr/bin/false", arguments: [])
    check(failure.status != 0, "bounded command preserves failure status")
} catch { check(false, "bounded command success fixtures") }
do {
    _ = try BoundedCommand.run(path: "/usr/bin/printf", arguments: ["oversized-fixture"], outputLimit: 2)
    check(false, "bounded command rejects oversized output")
} catch CommandFailure.outputTooLarge { check(true, "bounded command rejects oversized output") }
catch { check(false, "bounded command unexpected size failure") }
let timeoutStart = Date()
do {
    _ = try BoundedCommand.run(path: "/bin/sleep", arguments: ["5"], timeout: 0.05)
    check(false, "bounded command terminates on timeout")
} catch CommandFailure.timeout { check(Date().timeIntervalSince(timeoutStart) < 3, "bounded command terminates on timeout") }
catch { check(false, "bounded command unexpected timeout failure") }
defaults.removePersistentDomain(forName: suiteName)

check(ScreenshotGeometry.rect(from: CGPoint(x: 30, y: 40), to: CGPoint(x: 10, y: 5)) == CGRect(x: 10, y: 5, width: 20, height: 35), "screenshot reverse drag normalized")
let retinaCrop = ScreenshotGeometry.pixelCrop(selection: CGRect(x: 10, y: 20, width: 30, height: 40), viewSize: CGSize(width: 100, height: 100), pixels: CGSize(width: 200, height: 200))
check(retinaCrop == CGRect(x: 20, y: 80, width: 60, height: 80), "screenshot retina top-left conversion")
check(ScreenshotGeometry.pixelCrop(selection: CGRect(x: -10, y: -10, width: 30, height: 30), viewSize: CGSize(width: 100, height: 100), pixels: CGSize(width: 100, height: 100)) == CGRect(x: 0, y: 80, width: 20, height: 20), "screenshot selection clamps to screen")
check(ScreenshotGeometry.pixelCrop(selection: CGRect(x: 0, y: 0, width: 1, height: 1), viewSize: CGSize(width: 100, height: 100), pixels: CGSize(width: 200, height: 200)) == nil, "screenshot tiny selection rejected")
let fit = ScreenshotGeometry.fit(image: CGSize(width: 200, height: 100), into: CGRect(x: 10, y: 20, width: 100, height: 100))
check(fit == CGRect(x: 10, y: 45, width: 100, height: 50), "screenshot editor preserves aspect ratio")
check(ScreenshotGeometry.imagePoint(CGPoint(x: 60, y: 70), in: fit, pixels: CGSize(width: 200, height: 100)) == CGPoint(x: 100, y: 50), "screenshot editor pointer mapping")
check(ScreenshotGeometry.imagePoint(.zero, in: fit, pixels: CGSize(width: 200, height: 100)) == nil, "screenshot editor ignores letterbox margins")

if failures > 0 {
    print("\n\(failures) test(s) failed")
    exit(1)
}

print("\nAll MiniStat command-line tests passed")

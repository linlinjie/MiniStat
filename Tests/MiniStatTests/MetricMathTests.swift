import XCTest
@testable import MiniStat

final class MetricMathTests: XCTestCase {
    func testCPUUsageUsesTickDeltas() {
        let previous = CPUTicks(user: 100, system: 50, idle: 350, nice: 0)
        let current = CPUTicks(user: 120, system: 60, idle: 420, nice: 0)
        XCTAssertEqual(CPUTicks.usagePercent(previous: previous, current: current), 30, accuracy: 0.0001)
    }

    func testCPUUsageRejectsCounterRollbackAndEmptyDelta() {
        let value = CPUTicks(user: 100, system: 50, idle: 350, nice: 0)
        XCTAssertNil(CPUTicks.usagePercent(previous: value, current: value))
        XCTAssertNil(CPUTicks.usagePercent(
            previous: value,
            current: CPUTicks(user: 99, system: 60, idle: 360, nice: 0)
        ))
    }

    func testNetworkRatesAndCounterRollback() {
        let previous = NetworkCounters(receivedBytes: 1_000, sentBytes: 2_000, uptime: 10)
        let current = NetworkCounters(receivedBytes: 3_048, sentBytes: 3_024, uptime: 12)
        let rates = NetworkCounters.rates(previous: previous, current: current)
        XCTAssertEqual(rates?.download, 1_024)
        XCTAssertEqual(rates?.upload, 512)

        let rolledBack = NetworkCounters(receivedBytes: 100, sentBytes: 100, uptime: 13)
        XCTAssertNil(NetworkCounters.rates(previous: current, current: rolledBack))
    }

    func testPercentageCalculationClampsAndRejectsZeroTotal() {
        XCTAssertEqual(MetricMath.percent(used: 25, total: 100), 25)
        XCTAssertEqual(MetricMath.percent(used: 150, total: 100), 100)
        XCTAssertNil(MetricMath.percent(used: 1, total: 0))
    }

    func testTemperatureValidation() {
        XCTAssertEqual(MetricMath.validTemperature(42.5), 42.5)
        XCTAssertNil(MetricMath.validTemperature(9.9))
        XCTAssertNil(MetricMath.validTemperature(120.1))
        XCTAssertNil(MetricMath.validTemperature(.infinity))
        XCTAssertNil(MetricMath.validTemperature(nil))
    }
}

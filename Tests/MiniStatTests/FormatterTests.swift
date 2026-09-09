import XCTest
@testable import MiniStat

final class FormatterTests: XCTestCase {
    func testPercentAndTemperatureFormatting() {
        XCTAssertEqual(MetricFormatter.percent(69.4), "69%")
        XCTAssertEqual(MetricFormatter.percent(nil), "--%")
        XCTAssertEqual(MetricFormatter.temperature(58.4), "58°C")
        XCTAssertEqual(MetricFormatter.temperature(500), "--°C")
    }

    func testRateFormatting() {
        XCTAssertEqual(MetricFormatter.rate(nil), "-- B/s")
        XCTAssertEqual(MetricFormatter.rate(512), "512 B/s")
        XCTAssertEqual(MetricFormatter.rate(1_024), "1.0 KB/s")
        XCTAssertEqual(MetricFormatter.rate(153_600), "150 KB/s")
        XCTAssertEqual(MetricFormatter.rate(1_572_864), "1.5 MB/s")
    }
}

import XCTest
@testable import MiniStat

final class SettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "MiniStatTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsAreLoadedWhenNoSettingsExist() {
        XCTAssertEqual(SettingsStore(defaults: defaults).load(), .defaults)
    }

    func testSettingsRoundTripIncludingAllModulesHidden() {
        let store = SettingsStore(defaults: defaults)
        let preferences = AppPreferences(
            visibleModules: [.cpu, .network],
            refreshInterval: 5
        )
        store.save(preferences)
        XCTAssertEqual(store.load(), preferences)

        let hidden = AppPreferences(visibleModules: [], refreshInterval: 1)
        store.save(hidden)
        XCTAssertEqual(store.load(), hidden)
    }

    func testUnsupportedRefreshIntervalFallsBackToTwoSeconds() {
        defaults.set(3.0, forKey: "refreshInterval")
        XCTAssertEqual(SettingsStore(defaults: defaults).load().refreshInterval, 2)
    }
}

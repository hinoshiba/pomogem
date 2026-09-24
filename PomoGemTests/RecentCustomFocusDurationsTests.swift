import XCTest
@testable import PomoGem

final class RecentCustomFocusDurationsTests: XCTestCase {
    private let fifty = 50 * 60
    private let fortyThirty = 40 * 60 + 30
    private let twoHours = 120 * 60
    private let fifteen = 15 * 60

    func testOnlyValidProDurationsAreRemembered() {
        XCTAssertEqual(RecentCustomFocusDurations.recording(fifty, in: ""), "3000")
        for free in [25, 45, 60, 90] {
            XCTAssertEqual(RecentCustomFocusDurations.recording(free * 60, in: "3000"), "3000", "\(free)分 is a free preset")
        }
        XCTAssertEqual(RecentCustomFocusDurations.recording(0, in: "3000"), "3000")
        XCTAssertEqual(RecentCustomFocusDurations.recording(361 * 60, in: "3000"), "3000")
    }

    func testNewestFirstWithoutDuplicatesAndAtMostThree() {
        var raw = ""
        for seconds in [fifty, fortyThirty, twoHours] {
            raw = RecentCustomFocusDurations.recording(seconds, in: raw)
        }
        XCTAssertEqual(RecentCustomFocusDurations.decode(raw), [twoHours, fortyThirty, fifty])
        raw = RecentCustomFocusDurations.recording(fifty, in: raw)
        XCTAssertEqual(RecentCustomFocusDurations.decode(raw), [fifty, twoHours, fortyThirty])
        raw = RecentCustomFocusDurations.recording(fifteen, in: raw)
        XCTAssertEqual(RecentCustomFocusDurations.decode(raw), [fifteen, fifty, twoHours])
    }

    func testDecodingIgnoresAnythingThatIsNotARememberedCustomDuration() {
        XCTAssertEqual(
            RecentCustomFocusDurations.decode("abc,3000,1500,3000,,-5,999999999999999999999,2430,7200,900"),
            [fifty, fortyThirty, twoHours]
        )
    }

    func testSettingsWritesTheKeyHomeObserves() throws {
        let suite = "RecentCustomFocusDurationsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        RecentCustomFocusDurations.record(fifty, defaults: defaults)
        RecentCustomFocusDurations.record(25 * 60, defaults: defaults)
        let key = AccountScopedLocalState.defaultsKey(
            base: RecentCustomFocusDurations.storageKey, defaults: defaults
        )
        XCTAssertEqual(defaults.string(forKey: key), "3000")
    }
}

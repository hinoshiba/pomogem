import XCTest
@testable import PomoGem

/// product-04 / notify-05 phase 1: the App Shortcut only opens the app and
/// leaves Home the same request a widget tap does.
@MainActor
final class StartFocusIntentTests: XCTestCase {
    func testShortcutLengthsMapOneToOneOntoTheFreePresets() {
        XCTAssertEqual(
            FocusStartLength.allCases.map(\.preset),
            FocusStartPreset.allCases
        )
        for length in FocusStartLength.allCases {
            XCTAssertEqual(length.rawValue, String(length.preset.minutes))
        }
    }

    func testStartFocusIntentOnlyLeavesARequestForHome() async throws {
        let inbox = AppEntryInbox.shared
        inbox.discard()
        defer { inbox.discard() }

        _ = try await StartFocusIntent(length: .fortyFive).perform()
        XCTAssertEqual(inbox.pending?.route, .startFocus(.fortyFive))

        _ = try await StartFocusIntent().perform()
        XCTAssertEqual(
            inbox.pending?.route,
            .startFocus(nil),
            "An empty length uses the length selected on Home"
        )
    }
}

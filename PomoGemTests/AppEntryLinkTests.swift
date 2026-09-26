import XCTest
@testable import PomoGem

/// notify-03 / quality-03 / product-04: the `pomogem://` routes behind the
/// widgets, and the process-level inbox that carries a request to Home.
@MainActor
final class AppEntryLinkTests: XCTestCase {
    func testWidgetURLsAreTheDocumentedConstants() {
        XCTAssertEqual(AppEntryLink.homeURL.absoluteString, "pomogem://home")
        XCTAssertEqual(
            AppEntryLink.focusStartURL().absoluteString,
            "pomogem://focus/start"
        )
        XCTAssertEqual(
            AppEntryLink.focusStartURL(.twentyFive).absoluteString,
            "pomogem://focus/start?minutes=25"
        )
        XCTAssertEqual(
            AppEntryLink.focusStartURL(.ninety).absoluteString,
            "pomogem://focus/start?minutes=90"
        )
    }

    func testEveryBuiltURLParsesBackToItsRoute() {
        XCTAssertEqual(AppEntryLink.route(for: AppEntryLink.homeURL), .home)
        XCTAssertEqual(
            AppEntryLink.route(for: AppEntryLink.focusStartURL()),
            .startFocus(nil)
        )
        for preset in FocusStartPreset.allCases {
            XCTAssertEqual(
                AppEntryLink.route(for: AppEntryLink.focusStartURL(preset)),
                .startFocus(preset)
            )
        }
    }

    func testOnlyTheFreeLengthsCanBeRequestedFromOutside() {
        XCTAssertEqual(
            Set(FocusStartPreset.allCases.map(\.seconds)),
            IntegrationConstants.freeFocusDurations
        )
        for minutes in [0, 1, 5, 12, 15, 30, 50, 61, 120, 360, -25] {
            let url = URL(string: "pomogem://focus/start?minutes=\(minutes)")!
            XCTAssertNil(
                AppEntryLink.route(for: url),
                "\(minutes) minutes must never start a focus from outside"
            )
        }
    }

    func testMalformedOrForeignLinksAreIgnored() {
        let rejected = [
            "https://pomogem.hinoshiba.com/focus/start",
            "pomogem-dev://focus/start",
            "pomogem://",
            "pomogem://focus",
            "pomogem://focus/stop",
            "pomogem://focus/start/now",
            "pomogem://start",
            "pomogem://timer",
            "pomogem://wrapped?m=2026-09",
            "pomogem://home?tab=settings",
            "pomogem://home/settings",
            "pomogem://focus/start?minutes=",
            "pomogem://focus/start?minutes=abc",
            "pomogem://focus/start?minutes=25&minutes=45",
            "pomogem://focus/start?minutes=25&theme=英語",
            "pomogem://focus/start?min=25",
            "pomogem://focus/start#now",
            "pomogem://user@focus/start",
            "pomogem://focus:8080/start"
        ]
        for text in rejected {
            guard let url = URL(string: text) else { continue }
            XCTAssertNil(AppEntryLink.route(for: url), text)
        }
    }

    func testSchemeAndHostAreCaseInsensitiveAndATrailingSlashIsHome() {
        XCTAssertEqual(
            AppEntryLink.route(for: URL(string: "PomoGem://HOME")!),
            .home
        )
        XCTAssertEqual(
            AppEntryLink.route(for: URL(string: "pomogem://home/")!),
            .home
        )
        XCTAssertEqual(
            AppEntryLink.route(for: URL(string: "POMOGEM://Focus/start?minutes=45")!),
            .startFocus(.fortyFive)
        )
    }

    func testInboxKeepsOnlyTheNewestRequestAndHandsItOverOnce() {
        let inbox = AppEntryInbox()
        XCTAssertNil(inbox.pending)

        XCTAssertTrue(inbox.receive(url: AppEntryLink.homeURL, uptime: 100))
        XCTAssertTrue(inbox.receive(
            url: AppEntryLink.focusStartURL(.sixty),
            uptime: 101
        ))
        XCTAssertEqual(inbox.pending?.route, .startFocus(.sixty))

        let taken = inbox.take(uptime: 102)
        XCTAssertEqual(taken?.route, .startFocus(.sixty))
        XCTAssertEqual(taken?.receivedAtUptime, 101)
        XCTAssertNil(inbox.pending)
        XCTAssertNil(inbox.take(uptime: 103), "A request is handed over once")
    }

    func testInboxIgnoresUnknownURLsWithoutDroppingAValidRequest() {
        let inbox = AppEntryInbox()
        inbox.receive(.startFocus(nil), uptime: 10)
        XCTAssertFalse(inbox.receive(
            url: URL(string: "pomogem://focus/start?minutes=30")!,
            uptime: 11
        ))
        XCTAssertEqual(inbox.pending?.route, .startFocus(nil))
    }

    func testInboxDropsARequestOlderThanItsLifetime() {
        let inbox = AppEntryInbox()
        inbox.receive(.startFocus(nil), uptime: 1_000)
        XCTAssertNil(
            inbox.take(uptime: 1_000 + AppEntryInbox.lifetime + 0.5),
            "A start must never fire a minute after it was asked for"
        )
        XCTAssertNil(inbox.pending, "An expired request is dropped, not kept")

        inbox.receive(.home, uptime: 2_000)
        XCTAssertEqual(
            inbox.take(uptime: 2_000 + AppEntryInbox.lifetime)?.route,
            .home
        )
    }

    func testFreshnessRejectsAClockThatRunsBackwards() {
        XCTAssertTrue(AppEntryInbox.isFresh(50, at: 50))
        XCTAssertTrue(AppEntryInbox.isFresh(50, at: 50 + AppEntryInbox.lifetime))
        XCTAssertFalse(AppEntryInbox.isFresh(50, at: 49))
        XCTAssertFalse(AppEntryInbox.isFresh(50, at: .nan))
        XCTAssertFalse(AppEntryInbox.isFresh(50, at: 50 + AppEntryInbox.lifetime + 1))
    }

    func testDiscardClearsTheRequest() {
        let inbox = AppEntryInbox()
        inbox.receive(.startFocus(.fortyFive), uptime: 5)
        inbox.discard()
        XCTAssertNil(inbox.pending)
        XCTAssertNil(inbox.take(uptime: 6))
    }
}

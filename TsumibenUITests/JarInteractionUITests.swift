import XCTest

@MainActor
final class JarInteractionUITests: XCTestCase {
    private var activeApp: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIApplication().terminate()
    }

    override func tearDownWithError() throws {
        activeApp?.terminate()
        activeApp = nil
    }

    func testCompletedPebbleBouncesWithoutChangingTheRecord() throws {
        try verifyCompletedPebbleTap(
            reduceMotion: false,
            minimumRise: 60,
            attachmentName: "Aurora jar — three-diameter tap launch"
        )
    }

    func testReducedMotionTapStillMovesOnePebbleWithoutChangingTheRecord() throws {
        try verifyCompletedPebbleTap(
            reduceMotion: true,
            minimumRise: 14,
            attachmentName: "Aurora jar — reduced-motion tap lift"
        )
    }

    private func verifyCompletedPebbleTap(
        reduceMotion: Bool,
        minimumRise: Double,
        attachmentName: String
    ) throws {
        let app = XCUIApplication()
        activeApp = app
        app.launchEnvironment["TSUMIBEN_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["TSUMIBEN_UI_TEST_MODE"] = "1"
        app.launchEnvironment["TSUMIBEN_UI_TEST_REDUCE_MOTION"] = reduceMotion ? "1" : "0"
        app.launchArguments += ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 8))
        dismissStaleRewardReceiptsIfNeeded(in: app)

        XCTAssertTrue(app.otherElements["瓶"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["瓶"].exists, "An empty jar must not expose a dead button")

        app.buttons["メニュー"].tap()
        let demoDuration = app.buttons["12秒、DEMO"]
        XCTAssertTrue(demoDuration.waitForExistence(timeout: 3))
        demoDuration.tap()

        let aurora = app.buttons["オーロラ、光に包まれる"]
        XCTAssertTrue(aurora.waitForExistence(timeout: 3))
        aurora.tap()
        app.buttons["home.menu.close"].tap()

        let launcher = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "12秒集中する")
        ).firstMatch
        XCTAssertTrue(launcher.waitForExistence(timeout: 3))
        launcher.tap()

        stopCompletionAlertIfPresented(in: app)

        let dismissBreakOffer = app.buttons["休憩の提案を閉じる"]
        XCTAssertTrue(
            dismissBreakOffer.waitForExistence(timeout: 60),
            "The demo completion must land one pebble and return Home"
        )
        dismissBreakOffer.tap()

        let jar = app.buttons["瓶"]
        XCTAssertTrue(jar.waitForExistence(timeout: 3))
        XCTAssertTrue((jar.value as? String)?.contains("1粒") == true)
        XCTAssertTrue((jar.value as? String)?.contains("250グラム") == true)

        let presentationProbe = app.descendants(matching: .any)["jar.presentation.probe"]
        XCTAssertTrue(
            presentationProbe.waitForExistence(timeout: 3),
            "The test-only presentation probe must be available in explicit UI-test mode"
        )
        let beforeTap = try waitForPresentationCount(
            1,
            from: presentationProbe,
            timeout: 3
        )

        // Resolve the live SpriteKit position and tap that exact gem. A fixed
        // lower-jar coordinate can land beside a randomly settled pebble and
        // would test the edge of the falloff instead of the local impact peak.
        jar.coordinate(withNormalizedOffset: CGVector(
            dx: CGFloat(beforeTap.targetX),
            dy: CGFloat(beforeTap.targetY)
        )).tap()
        let bounced = try waitForVisibleBounce(
            from: presentationProbe,
            after: beforeTap,
            minimumRise: minimumRise,
            timeout: 1.2
        )
        XCTAssertGreaterThan(
            bounced.bounceSequence,
            beforeTap.bounceSequence,
            "A no-op tap must not satisfy the bounce presentation assertion"
        )
        XCTAssertGreaterThanOrEqual(
            bounced.bounceRise,
            minimumRise,
            reduceMotion
                ? "Reduce Motion must retain a compact but visible direct-tap response"
                : "An unobstructed tapped gem must travel about three of its own diameters"
        )

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = attachmentName
        attachment.lifetime = .keepAlways
        add(attachment)

        usleep(900_000)
        let afterTap = try presentationSample(from: presentationProbe)
        XCTAssertEqual(afterTap.count, beforeTap.count)
        XCTAssertEqual(
            afterTap.records,
            beforeTap.records,
            "Tap presentation must preserve the represented record IDs and grams"
        )
        XCTAssertTrue((jar.value as? String)?.contains("1粒") == true)
        XCTAssertTrue((jar.value as? String)?.contains("250グラム") == true)
    }

    @discardableResult
    private func stopCompletionAlertIfPresented(
        in app: XCUIApplication,
        timeout: TimeInterval = 25
    ) -> Bool {
        let stop = app.buttons["focus.completion-alert.stop"]
        guard stop.waitForExistence(timeout: timeout) else { return false }
        XCTAssertEqual(stop.label, "終了アラートを止める")
        XCTAssertTrue(stop.isHittable)
        stop.tap()
        return true
    }

    private func dismissStaleRewardReceiptsIfNeeded(in app: XCUIApplication) {
        for _ in 0..<4 {
            let bridge = app.descendants(matching: .any)["reward.bridge"]
            guard bridge.waitForExistence(timeout: 1) else { return }
            let dismiss = app.buttons["休憩の提案を閉じる"]
            XCTAssertTrue(dismiss.waitForExistence(timeout: 3))
            dismiss.tap()
            XCTAssertTrue(waitForNonExistence(bridge, timeout: 3))
            app.terminate()
            app.launch()
            XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 12))
        }
        XCTAssertFalse(app.descendants(matching: .any)["reward.bridge"].exists)
    }

    private func waitForNonExistence(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return !element.exists
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForVisibleBounce(
        from probe: XCUIElement,
        after baseline: PresentationSample,
        minimumRise: Double,
        timeout: TimeInterval
    ) throws -> PresentationSample {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = baseline
        repeat {
            latest = try presentationSample(from: probe)
            if latest.bounceSequence > baseline.bounceSequence,
               latest.bounceRise >= minimumRise {
                return latest
            }
            usleep(25_000)
        } while Date() < deadline
        return latest
    }

    private func waitForPresentationCount(
        _ expectedCount: Int,
        from probe: XCUIElement,
        timeout: TimeInterval
    ) throws -> PresentationSample {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = try presentationSample(from: probe)
        while latest.count != expectedCount, Date() < deadline {
            usleep(25_000)
            latest = try presentationSample(from: probe)
        }
        XCTAssertEqual(
            latest.count,
            expectedCount,
            "The presentation probe must observe the completed pebble before interaction"
        )
        return latest
    }

    private func presentationSample(from probe: XCUIElement) throws -> PresentationSample {
        guard let rawValue = probe.value as? String else {
            throw PresentationProbeError.missingValue
        }
        let fields = Dictionary(uniqueKeysWithValues: rawValue.split(separator: ";").compactMap {
            field -> (String, String)? in
            let parts = field.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).map(String.init)
            guard parts.count == 2 else { return nil }
            return (parts[0], parts[1])
        })
        guard let countRaw = fields["count"],
              let count = Int(countRaw),
              let maximumYRaw = fields["maxY"],
              let maximumY = Double(maximumYRaw),
              let records = fields["records"],
              let bounceSequenceRaw = fields["bounceSequence"],
              let bounceSequence = Int(bounceSequenceRaw),
              let bounceRiseRaw = fields["bounceRise"],
              let bounceRise = Double(bounceRiseRaw),
              let targetXRaw = fields["targetX"],
              let targetX = Double(targetXRaw),
              let targetYRaw = fields["targetY"],
              let targetY = Double(targetYRaw)
        else {
            throw PresentationProbeError.malformedValue(rawValue)
        }
        return PresentationSample(
            count: count,
            maximumY: maximumY,
            records: records,
            bounceSequence: bounceSequence,
            bounceRise: bounceRise,
            targetX: targetX,
            targetY: targetY
        )
    }
}

private struct PresentationSample {
    let count: Int
    let maximumY: Double
    let records: String
    let bounceSequence: Int
    let bounceRise: Double
    let targetX: Double
    let targetY: Double
}

private enum PresentationProbeError: Error {
    case missingValue
    case malformedValue(String)
}

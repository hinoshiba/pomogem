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
            attachmentName: "Aurora jar — physical tap bounce"
        )
    }

    func testReducedMotionTapHasTheSameBounceWithoutChangingTheRecord() throws {
        try verifyCompletedPebbleTap(
            reduceMotion: true,
            attachmentName: "Aurora jar — Reduce Motion physical tap bounce"
        )
    }

    private func verifyCompletedPebbleTap(
        reduceMotion: Bool,
        attachmentName: String
    ) throws {
        // The probe measures vertical rise; the former 60 pt threshold measured
        // total two-dimensional travel. Require two normal gem diameters upward
        // using the same criterion for both system motion preferences.
        let minimumRise = 46.0
        let app = XCUIApplication()
        activeApp = app
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_REDUCE_MOTION"] = reduceMotion ? "1" : "0"
        PomoGemUITestLanguage.configureJapanese(app)
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 8))
        assertNoRewardCardFromAnEarlierTest(in: app)

        XCTAssertTrue(app.otherElements["瓶"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["瓶"].exists, "An empty jar must not expose a dead button")

        app.buttons["home.duration-picker"].tap()
        let demoDuration = app.buttons["12秒、DEMO"]
        XCTAssertTrue(demoDuration.waitForExistence(timeout: 3))
        demoDuration.tap()

        app.buttons["メニュー"].tap()
        let aurora = app.buttons["オーロラ、光に包まれる"]
        // 集中する空間 is the menu's last section, below its destinations.
        for _ in 0..<8 where !(aurora.exists && aurora.isHittable) {
            app.swipeUp()
        }
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
            "The demo completion must return Home with its reward card"
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
            timeout: 10
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
            "An unobstructed tapped gem must rise at least two diameters upward in either motion setting"
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

    /// The app drops the reward receipts an earlier test's store left in
    /// UserDefaults whenever it opens a new or cleaned store
    /// (`UITestLocalStateIsolation`). Draining them here used to acknowledge
    /// a gem that could never land, which left the start button disabled.
    private func assertNoRewardCardFromAnEarlierTest(in app: XCUIApplication) {
        XCTAssertFalse(
            app.descendants(matching: .any)["reward.bridge"].waitForExistence(timeout: 1),
            "A new store must not show another test's completion card"
        )
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
        while (latest.count != expectedCount || !latest.dropLanded), Date() < deadline {
            usleep(25_000)
            latest = try presentationSample(from: probe)
        }
        XCTAssertEqual(
            latest.count,
            expectedCount,
            "The presentation probe must observe the completed pebble before interaction"
        )
        XCTAssertTrue(latest.dropLanded, "The earned pebble must land before its tap target is sampled")
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
              let dropLandedRaw = fields["dropLanded"],
              ["0", "1"].contains(dropLandedRaw),
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
            dropLanded: dropLandedRaw == "1",
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
    let dropLanded: Bool
    let targetX: Double
    let targetY: Double
}

private enum PresentationProbeError: Error {
    case missingValue
    case malformedValue(String)
}

import XCTest

/// Proves the first decimal fusion through the real UI and persistence path.
///
/// The first nine demo focuses are deliberately completed instead of inserting
/// model objects from the test runner. That keeps the seed on the same path as
/// a user's measured focus, while DEBUG's 12-second duration makes every source
/// a deterministic 250g pebble. The tenth completion then exercises SpriteKit
/// landing, aggregate persistence, celebration, scoped sharing and overview.
@MainActor
final class DecimalFusionEndToEndUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 360

        app = XCUIApplication()
        app.launchEnvironment["TSUMIBEN_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["TSUMIBEN_UI_TEST_MODE"] = "1"
        app.launchArguments += [
            "-AppleLanguages", "(ja)",
            "-AppleLocale", "ja_JP",
            // Ten completions intentionally cross the review threshold. Keep
            // the App Store review controller outside this aggregation test.
            "-review.requested-version", "1.0"
        ]
        app.launch()

        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 8))
        selectDemoDuration()
    }

    func testTenthMeasuredPebbleBecomesOneReversibleDecimalCrystal() throws {
        let presentationProbe = app.descendants(matching: .any)["jar.presentation.probe"]
        XCTAssertTrue(presentationProbe.waitForExistence(timeout: 4))

        for expectedCount in 1 ... 9 {
            completeDemoFocusAndDismissBreak()
            let sample = try waitForPresentationCount(
                expectedCount,
                from: presentationProbe,
                timeout: 5
            )
            assertLooseMeasuredPebbles(sample, expectedCount: expectedCount)
        }

        let seeded = try presentationSample(from: presentationProbe)
        let sourceIDs = try parsedSourceIDs(from: seeded)
        XCTAssertEqual(sourceIDs.count, 9)
        XCTAssertEqual(Set(sourceIDs).count, 9, "The nine source records must be unique")
        XCTAssertTrue((app.buttons["瓶"].value as? String)?.contains("9粒") == true)

        startDemoFocus()
        stopCompletionAlertIfPresented(in: app)
        let celebrationTitle = app.staticTexts["10粒を、ひとつに整理した"]
        let dismissBreak = app.buttons["休憩の提案を閉じる"]

        XCTAssertTrue(
            dismissBreak.waitForExistence(timeout: 28),
            "The tenth effort must present its immediate reward before the larger fusion beat"
        )
        XCTAssertFalse(
            celebrationTitle.exists,
            "The fusion sheet must wait until the immediate completion reward is acknowledged"
        )
        let completedFusion = app.descendants(matching: .any)["reward.fusion-progress"]
        XCTAssertTrue(completedFusion.waitForExistence(timeout: 3))
        XCTAssertTrue(
            completedFusion.label.contains("×10完成 10/10"),
            "The tenth effort must hold the completed 10/10 beat before advancing: \(completedFusion.label)"
        )
        dismissBreak.tap()

        XCTAssertTrue(
            celebrationTitle.waitForExistence(timeout: 10),
            "Ten landed level-zero pebbles must present the first decimal-fusion celebration"
        )
        XCTAssertTrue(app.staticTexts["2.5kg"].waitForExistence(timeout: 3))
        let continuityCopy = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@",
                "一粒ずつの時間",
                "2.5kg",
                "急ぐ必要はありません"
            )
        ).firstMatch
        XCTAssertTrue(
            continuityCopy.waitForExistence(timeout: 3),
            "The fusion explanation must preserve each effort, exact mass, and an unhurried next step"
        )

        app.buttons["この結晶をカードにする"].tap()
        XCTAssertTrue(app.navigationBars["カードにする"].waitForExistence(timeout: 8))
        let scopedShareCard = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@",
                "2,500グラム",
                "10粒",
                "実測10回",
                "まとまり粒1個"
            )
        ).firstMatch
        XCTAssertTrue(
            scopedShareCard.waitForExistence(timeout: 12),
            "The celebration share route must preserve the aggregate's exact mass and source counts"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["share.partial-coverage-notice"].exists,
            "A ten-source aggregate must be fully reconstructable"
        )

        let shareAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shareAttachment.name = "First ×10 crystal — scoped 2500g share card"
        shareAttachment.lifetime = .keepAlways
        add(shareAttachment)

        app.navigationBars["カードにする"].buttons["閉じる"].tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 6))
        dismissBreakOfferIfPresent()

        let fused = try waitForPresentationCount(1, from: presentationProbe, timeout: 8)
        XCTAssertEqual(fused.recordEntries.count, 1)
        let aggregateEntry = try XCTUnwrap(fused.recordEntries.first)
        XCTAssertEqual(aggregateEntry.grams, 2_500)
        let aggregateID = try XCTUnwrap(UUID(uuidString: aggregateEntry.id))
        XCTAssertFalse(
            Set(sourceIDs).contains(aggregateID),
            "The aggregate must have its own identity rather than reusing a source ID"
        )

        let jarValue = try XCTUnwrap(app.buttons["瓶"].value as? String)
        XCTAssertTrue(jarValue.contains("0粒"), jarValue)
        XCTAssertTrue(jarValue.contains("まとまり粒1個"), jarValue)
        XCTAssertTrue(jarValue.contains("合計10粒分"), jarValue)
        XCTAssertTrue(jarValue.contains("2.50キログラム"), jarValue)
        XCTAssertTrue(
            jarValue.contains("×100へ 1/10"),
            "After ×10 forms, the durable ×100 horizon must remain explicit: \(jarValue)"
        )
        XCTAssertTrue(
            jarValue.contains("次の結晶まであと10粒"),
            "The next reachable crystal must remain explicit beside the long horizon: \(jarValue)"
        )

        let jar = app.buttons["瓶"]
        jar.coordinate(withNormalizedOffset: CGVector(
            dx: CGFloat(fused.targetX),
            dy: CGFloat(fused.targetY)
        )).tap()
        let inspectAggregate = app.buttons["jar.aggregate.inspect"]
        XCTAssertTrue(
            inspectAggregate.waitForExistence(timeout: 3),
            "Tapping the physical aggregate must reveal its non-obstructing detail affordance"
        )
        inspectAggregate.tap()
        XCTAssertTrue(app.navigationBars["まとまり粒"].waitForExistence(timeout: 4))
        XCTAssertTrue(
            app.descendants(matching: .any)["overview.cluster.preservation"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["10粒分の積み重ね"].exists)
        app.buttons["overview.cluster.close"].tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 4))

        let afterDirectInspection = try waitForPresentationCount(
            1,
            from: presentationProbe,
            timeout: 3
        )
        XCTAssertEqual(afterDirectInspection.rawRecords, fused.rawRecords)
        XCTAssertEqual(afterDirectInspection.recordEntries.first?.grams, 2_500)

        openMenuAction(containing: "積み上がりを見る")
        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 8))
        let lenses = app.segmentedControls["overview.lens"]
        XCTAssertTrue(lenses.waitForExistence(timeout: 4))
        lenses.buttons["結晶"].tap()

        let lifetimeCore = app.descendants(matching: .any)["overview.constellation.core"]
        XCTAssertTrue(
            lifetimeCore.waitForExistence(timeout: 4),
            "The lifetime core must first materialize after the tenth persisted effort"
        )
        XCTAssertEqual(lifetimeCore.label, "時間の核")
        let lifetimeCoreValue = try XCTUnwrap(lifetimeCore.value as? String)
        XCTAssertTrue(lifetimeCoreValue.contains("集中2.50kg"), lifetimeCoreValue)
        XCTAssertTrue(lifetimeCoreValue.contains("10.0標準単位"), lifetimeCoreValue)
        XCTAssertTrue(lifetimeCoreValue.contains("物理履歴10粒"), lifetimeCoreValue)
        XCTAssertTrue(
            lifetimeCoreValue.contains("瓶の物理整理：集中10粒"),
            lifetimeCoreValue
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["overview.constellation.destination"].exists
        )

        let aggregateSummary = app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@",
                "まとまり粒",
                "10粒",
                "2.5キログラム"
            )
        ).firstMatch
        XCTAssertTrue(
            scrollUntilHittable(aggregateSummary),
            "The overview must expose exactly one ×10 aggregate with the conserved 2500g mass"
        )
        aggregateSummary.tap()

        XCTAssertTrue(app.navigationBars["まとまり粒"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["10粒分の積み重ね"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["2.5kg"].exists)
        XCTAssertTrue(app.staticTexts["タイマー"].exists)
        XCTAssertTrue(app.staticTexts["手動"].exists)
        XCTAssertTrue(app.staticTexts["0粒"].exists)

        let overviewAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        overviewAttachment.name = "First ×10 crystal — reversible overview detail"
        overviewAttachment.lifetime = .keepAlways
        add(overviewAttachment)
    }

    private func selectDemoDuration() {
        app.buttons["home.duration-picker"].tap()
        let demoDuration = app.buttons["12秒、DEMO"]
        XCTAssertTrue(demoDuration.waitForExistence(timeout: 4))
        demoDuration.tap()
        XCTAssertTrue(demoLauncher.waitForExistence(timeout: 4))
    }

    private var demoLauncher: XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "12秒集中する")
        ).firstMatch
    }

    private func startDemoFocus() {
        XCTAssertTrue(demoLauncher.waitForExistence(timeout: 5))
        XCTAssertTrue(demoLauncher.isHittable)
        demoLauncher.tap()
    }

    private func completeDemoFocusAndDismissBreak() {
        startDemoFocus()
        stopCompletionAlertIfPresented(in: app)
        let dismissBreak = app.buttons["休憩の提案を閉じる"]
        XCTAssertTrue(
            dismissBreak.waitForExistence(timeout: 25),
            "Each deterministic seed focus must commit, land and return Home"
        )
        dismissBreak.tap()
        if !demoLauncher.waitForExistence(timeout: 2) {
            // The debug-only duration menu intentionally isn't a persisted
            // product preference. Re-select it after a process/UI refresh so
            // this end-to-end test remains about aggregation, not demo state.
            selectDemoDuration()
        }
        XCTAssertTrue(demoLauncher.waitForExistence(timeout: 5))
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

    private func dismissBreakOfferIfPresent() {
        let dismissBreak = app.buttons["休憩の提案を閉じる"]
        guard dismissBreak.waitForExistence(timeout: 3) else { return }
        if dismissBreak.isHittable {
            dismissBreak.tap()
        }
    }

    private func openMenuAction(containing title: String) {
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))
        app.buttons["メニュー"].tap()
        let action = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", title)
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(action), "Missing menu action: \(title)")
        action.tap()
    }

    private func scrollUntilHittable(
        _ element: XCUIElement,
        attempts: Int = 8
    ) -> Bool {
        for _ in 0 ..< attempts {
            if element.exists, element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    private func waitForPresentationCount(
        _ expectedCount: Int,
        from probe: XCUIElement,
        timeout: TimeInterval
    ) throws -> PresentationSample {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = try presentationSample(from: probe)
        while latest.count != expectedCount, Date() < deadline {
            usleep(50_000)
            latest = try presentationSample(from: probe)
        }
        XCTAssertEqual(
            latest.count,
            expectedCount,
            "Expected \(expectedCount) live jar bodies; latest records=\(latest.rawRecords)"
        )
        return latest
    }

    private func assertLooseMeasuredPebbles(
        _ sample: PresentationSample,
        expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(sample.recordEntries.count, expectedCount, file: file, line: line)
        XCTAssertEqual(Set(sample.recordEntries.map(\.id)).count, expectedCount, file: file, line: line)
        XCTAssertTrue(sample.recordEntries.allSatisfy { $0.grams == 250 }, file: file, line: line)
    }

    private func parsedSourceIDs(from sample: PresentationSample) throws -> [UUID] {
        try sample.recordEntries.map { entry in
            guard let id = UUID(uuidString: entry.id) else {
                throw PresentationProbeError.malformedRecord(entry.id)
            }
            return id
        }
    }

    private func presentationSample(from probe: XCUIElement) throws -> PresentationSample {
        guard let rawValue = probe.value as? String else {
            throw PresentationProbeError.missingValue
        }
        let fields = Dictionary(uniqueKeysWithValues: rawValue.split(separator: ";").compactMap {
            field -> (String, String)? in
            let pieces = field.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).map(String.init)
            guard pieces.count == 2 else { return nil }
            return (pieces[0], pieces[1])
        })
        guard let countRaw = fields["count"],
              let count = Int(countRaw),
              let rawRecords = fields["records"],
              let targetXRaw = fields["targetX"],
              let targetX = Double(targetXRaw),
              let targetYRaw = fields["targetY"],
              let targetY = Double(targetYRaw)
        else {
            throw PresentationProbeError.malformedValue(rawValue)
        }

        let entries = try rawRecords.split(separator: ",").map { rawEntry -> RecordEntry in
            let pieces = rawEntry.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2, let grams = Int(pieces[1]) else {
                throw PresentationProbeError.malformedRecord(String(rawEntry))
            }
            return RecordEntry(id: pieces[0], grams: grams)
        }
        return PresentationSample(
            count: count,
            rawRecords: rawRecords,
            recordEntries: entries,
            targetX: targetX,
            targetY: targetY
        )
    }
}

private struct PresentationSample {
    let count: Int
    let rawRecords: String
    let recordEntries: [RecordEntry]
    let targetX: Double
    let targetY: Double
}

private struct RecordEntry: Hashable {
    let id: String
    let grams: Int
}

private enum PresentationProbeError: Error {
    case missingValue
    case malformedValue(String)
    case malformedRecord(String)
}

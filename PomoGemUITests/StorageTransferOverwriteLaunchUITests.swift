import XCTest

/// The launch-host screens a device that was fenced out of the current iCloud
/// generation actually lands on. These tests drive the shipping
/// `PersistenceLaunchStatusView` through a Debug simulator-only recorder: no
/// journal, container, account or CloudKit call exists in the process, so a
/// passing run is also evidence that reading these screens starts nothing.
@MainActor
final class StorageTransferOverwriteLaunchUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0, let app {
            attach("Overwrite launch UI failure")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Overwrite launch failure accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app?.terminate()
    }

    // MARK: - 1. Two symmetric doors, two independent consents

    func testBothDirectionsAreOfferedWithIndependentConsentsAndNeitherStartsAnything() {
        launch("datasetRefreshChoice")
        let refresh = app.buttons["storage-refresh-confirm"]
        let overwrite = app.buttons["storage-overwrite-confirm"]
        XCTAssertTrue(reveal(refresh))
        XCTAssertTrue(reveal(overwrite, upwards: false))
        XCTAssertFalse(refresh.isEnabled, "The iCloud → device door starts unconsented")
        XCTAssertFalse(overwrite.isEnabled, "The device → iCloud door starts unconsented")

        // Ticking one direction's acknowledgement must never enable the other.
        acknowledge("storage-refresh-confirm-data-loss")
        XCTAssertTrue(reveal(refresh))
        XCTAssertTrue(refresh.isEnabled)
        XCTAssertTrue(reveal(overwrite, upwards: false))
        XCTAssertFalse(overwrite.isEnabled,
            "One acknowledgement must not authorize the opposite, destructive direction")

        // The overwrite door never acts on tap; it opens a second confirmation.
        overwrite.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(app.navigationBars["最後の確認"].exists)
        attach("Dataset refresh — both doors with separate acknowledgements")
        assertNoOperation()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 0)
    }

    // MARK: - 2. The comparison, and the read that gates the destructive door

    func testComparisonShowsBothSidesAndDisclosesOtherDevicesAsEvidence() {
        launch("datasetRefreshOtherDevices")
        let comparison = app.staticTexts["storage-overwrite-comparison"]
        XCTAssertTrue(reveal(comparison))
        XCTAssertTrue(comparison.label.contains("このiPhone"))
        XCTAssertTrue(comparison.label.contains("iCloud"))
        XCTAssertTrue(comparison.label.contains("テーマ"))
        XCTAssertTrue(comparison.label.contains("記録"))

        let evidence = app.staticTexts["storage-overwrite-other-devices"]
        XCTAssertTrue(reveal(evidence))
        XCTAssertTrue(evidence.label.contains("このiPhone以外の端末"))
        XCTAssertTrue(evidence.label.contains("未送信"))

        let warning = app.staticTexts["storage-overwrite-data-loss-warning"]
        XCTAssertTrue(reveal(warning))
        XCTAssertTrue(warning.label.contains("2つのデータは結合しません"))
        XCTAssertTrue(warning.label.contains("元に戻すことはできません"))
        attach("Dataset refresh — comparison and other-device evidence")
        assertNoOperation()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 0)
    }

    func testNoOtherDeviceIsStatedAsAbsenceOfEvidenceNotAsAGuarantee() {
        launch("datasetRefreshChoice")
        let evidence = app.staticTexts["storage-overwrite-other-devices"]
        XCTAssertTrue(reveal(evidence))
        XCTAssertTrue(evidence.label.contains("見つかりませんでした"))
        XCTAssertTrue(evidence.label.contains("証明ではありません"),
            "Absence of evidence must never be phrased as proof that no other device exists")
        attach("Dataset refresh — no witnessed device, stated as absence of evidence")
        assertNoOperation()
    }

    func testPreviewFailureKeepsTheOverwriteDoorDisabledAndSaysNothingWasDeleted() {
        launch("datasetRefreshPreviewFailed")
        let comparison = app.staticTexts["storage-overwrite-comparison"]
        XCTAssertTrue(reveal(comparison))
        XCTAssertTrue(comparison.label.contains("iCloudの内容を確認できませんでした"))
        XCTAssertTrue(comparison.label.contains("どちらの記録も削除していません"))
        let overwrite = app.buttons["storage-overwrite-confirm"]
        XCTAssertTrue(reveal(overwrite, upwards: false))
        XCTAssertFalse(overwrite.isEnabled,
            "Nobody may authorize deleting contents the app failed to enumerate")
        overwrite.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(app.navigationBars["最後の確認"].exists)
        // The non-destructive direction is unaffected by a failed server read.
        XCTAssertTrue(reveal(app.buttons["storage-refresh-confirm"]))
        attach("Dataset refresh — unreadable iCloud keeps the overwrite closed")
        assertNoOperation()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 0)
    }

    // MARK: - 3. The final confirmation sheet

    func testFinalConfirmationNeedsItsOwnAcknowledgementAndBackStartsNothing() {
        launch("datasetRefreshOtherDevices")
        openOverwriteSheet()
        XCTAssertTrue(reveal(app.staticTexts["storage-overwrite-warning"]))
        let recoveryCopy = app.staticTexts["storage-overwrite-recovery-copy"]
        XCTAssertTrue(reveal(recoveryCopy))
        XCTAssertTrue(recoveryCopy.label.contains("復旧用コピー"))
        let relaunch = app.staticTexts["storage-overwrite-relaunch"]
        XCTAssertTrue(reveal(relaunch))
        XCTAssertTrue(relaunch.label.contains("アプリ自体は削除しないでください"))
        let notCancellable = app.staticTexts["storage-overwrite-not-cancellable"]
        XCTAssertTrue(reveal(notCancellable))
        XCTAssertTrue(notCancellable.label.contains("取り消せません"))
        XCTAssertTrue(reveal(app.staticTexts["storage-overwrite-screen-time"]))
        let sheetEvidence = app.staticTexts["storage-overwrite-sheet-other-devices"]
        XCTAssertTrue(reveal(sheetEvidence))
        XCTAssertTrue(sheetEvidence.label.contains("2台"),
            "The last screen before deletion must restate how many other devices wrote here")

        let confirm = app.buttons["storage-overwrite-sheet-confirm"]
        let toggle = app.switches["storage-overwrite-confirm-data-loss"]
        XCTAssertTrue(reveal(toggle))
        XCTAssertEqual(toggle.value as? String, "0",
            "Reading the explanation is never consent")
        XCTAssertTrue(reveal(confirm, upwards: false))
        XCTAssertFalse(confirm.isEnabled)
        attach("Final confirmation — unchecked acknowledgement")

        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        XCTAssertTrue(app.buttons["storage-overwrite-confirm"].waitForExistence(timeout: 4))
        assertNoOperation()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 0)

        // Re-opening must not remember the previous screen's acknowledgement.
        openOverwriteSheet()
        XCTAssertTrue(reveal(app.switches["storage-overwrite-confirm-data-loss"]))
        XCTAssertEqual(app.switches["storage-overwrite-confirm-data-loss"].value as? String, "0")
        acknowledge("storage-overwrite-confirm-data-loss")
        let armed = app.buttons["storage-overwrite-sheet-confirm"]
        XCTAssertTrue(reveal(armed, upwards: false))
        XCTAssertTrue(armed.isEnabled)
        attach("Final confirmation — explicit acknowledgement arms the replacement")
        armed.tap()
        assertOverwriteFixture(refresh: 0, overwrite: 1, export: 0)
    }

    // MARK: - 4. `.blocked` explains, it does not offer

    func testBlockedOffersNoDestructiveActionButExplainsWhatComesNext() {
        launch("datasetRefreshBlocked")
        XCTAssertTrue(app.staticTexts["保存領域を確認できません"].waitForExistence(timeout: 8))
        let explanation = app.staticTexts["storage-refresh-blocked-explanation"]
        XCTAssertTrue(reveal(explanation))
        XCTAssertTrue(explanation.label.contains("もう一度試す"))
        XCTAssertTrue(explanation.label.contains("どちらの記録も削除していません"))
        XCTAssertFalse(app.buttons["storage-refresh-confirm"].exists,
            "A screen that could not read the terminal control record has no lineage to act on")
        XCTAssertFalse(app.buttons["storage-overwrite-confirm"].exists)
        XCTAssertFalse(app.switches["storage-overwrite-confirm-data-loss"].exists)
        XCTAssertTrue(reveal(app.buttons["もう一度試す"]))
        attach("Blocked — explanation without any destructive affordance")
        assertNoOperation()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 0)
    }

    // MARK: - 5. The non-destructive rescue door

    func testExportBeforeReplacingIsOfferedAndIsNonDestructive() {
        launch("datasetRefreshChoice")
        let export = app.buttons["storage-refresh-export"]
        XCTAssertTrue(reveal(export, upwards: false))
        XCTAssertTrue(export.isEnabled, "The rescue door must not require a data-loss acknowledgement")
        let note = app.staticTexts["storage-refresh-export-note"]
        XCTAssertTrue(reveal(note))
        XCTAssertTrue(note.label.contains("PomoGemに読み込めません"))
        attach("Dataset refresh — non-destructive export before either replacement")
        XCTAssertTrue(reveal(export, upwards: false))
        export.tap()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 1)
        // Writing a copy out is not a transfer: no storage operation is recorded.
        assertNoOperation()
    }

    // MARK: - 6. While the replacement runs

    func testReplacementInProgressShowsPhaseCopyAndNoCancelControl() {
        launch("overwriteInProgress")
        let progress = app.staticTexts["storage-overwrite-progress"]
        XCTAssertTrue(reveal(progress))
        XCTAssertTrue(progress.label.contains("iCloudのデータを置き換えています"))
        XCTAssertTrue(progress.label.contains("続きから再開します"))
        let notCancellable = app.staticTexts["storage-overwrite-not-cancellable"]
        XCTAssertTrue(reveal(notCancellable))
        XCTAssertTrue(notCancellable.label.contains("取り消せません"))
        XCTAssertFalse(app.buttons["storage-transfer-cancel-local"].exists,
            "Past preparingDestination the operation is not cancellable")
        XCTAssertFalse(app.buttons["storage-overwrite-confirm"].exists)
        XCTAssertFalse(app.buttons["storage-refresh-confirm"].exists)
        attach("Replacement in progress — phase copy without a cancel control")
        assertNoOperation()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 0)
    }

    // MARK: - 7. AX5

    func testAX5OverwriteDoorsAndFinalConfirmationRemainReachableAndDescribed() throws {
        launch("datasetRefreshOtherDevices", accessibility5: true)
        let comparison = app.staticTexts["storage-overwrite-comparison"]
        XCTAssertTrue(reveal(comparison))
        XCTAssertGreaterThan(comparison.frame.width,
            app.windows.firstMatch.frame.width * 0.65,
            "The comparison must keep a readable line width instead of collapsing")
        attach("AX5 dataset refresh — comparison")

        let refresh = app.buttons["storage-refresh-confirm"]
        XCTAssertTrue(reveal(refresh))
        assertTouchTarget(refresh)
        let overwrite = app.buttons["storage-overwrite-confirm"]
        XCTAssertTrue(reveal(overwrite, upwards: false))
        assertTouchTarget(overwrite)
        let export = app.buttons["storage-refresh-export"]
        XCTAssertTrue(reveal(export))
        assertTouchTarget(export)
        attach("AX5 dataset refresh — both doors and the rescue door reachable")
        try auditDescriptionsAndTraits()

        openOverwriteSheet(upwards: false)
        let toggle = app.switches["storage-overwrite-confirm-data-loss"]
        XCTAssertTrue(reveal(toggle))
        assertTouchTarget(toggle)
        XCTAssertGreaterThan(toggle.frame.height, 100,
            "The confirmation must actually inherit AX5, not silently reset to normal text")
        XCTAssertEqual(toggle.value as? String, "0")
        acknowledge("storage-overwrite-confirm-data-loss")
        let confirm = app.buttons["storage-overwrite-sheet-confirm"]
        XCTAssertTrue(reveal(confirm, upwards: false))
        assertTouchTarget(confirm)
        XCTAssertTrue(confirm.isEnabled)
        attach("AX5 final confirmation — acknowledgement and action reachable")
        try auditDescriptionsAndTraits()
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        XCTAssertTrue(app.buttons["storage-overwrite-confirm"].waitForExistence(timeout: 4))
        assertNoOperation()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 0)
    }

    // MARK: - Helpers

    private func launch(_ scenario: String, accessibility5: Bool = false) {
        app?.terminate()
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_STORAGE_TRANSFER"] = scenario
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = accessibility5 ? "1" : "0"
        app.launchArguments += ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        XCTAssertTrue(state.waitForExistence(timeout: 12), "The explicit Debug-only fixture must be selected")
    }

    private var state: XCUIElement { app.staticTexts["storage-switch.fixture-state"] }
    private var overwriteState: XCUIElement { app.staticTexts["storage-overwrite.fixture-state"] }

    private func openOverwriteSheet(upwards: Bool = false) {
        let overwrite = app.buttons["storage-overwrite-confirm"]
        if !reveal(overwrite, upwards: upwards) { XCTAssertTrue(reveal(overwrite, upwards: !upwards)) }
        overwrite.tap()
        XCTAssertTrue(app.navigationBars["最後の確認"].waitForExistence(timeout: 4))
    }

    private func acknowledge(_ identifier: String) {
        let checkbox = app.switches[identifier]
        if !reveal(checkbox) { XCTAssertTrue(reveal(checkbox, upwards: false)) }
        // SwiftUI exposes the label and trailing switch as one wide AX node;
        // its center is noninteractive text. Exercise the real switch control.
        checkbox.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let checked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: checkbox)
        XCTAssertEqual(XCTWaiter.wait(for: [checked], timeout: 3), .completed)
    }

    private func assertNoOperation() {
        XCTAssertTrue(reveal(state, upwards: false))
        XCTAssertEqual(state.label, "calls=0;choice=none;starting=false")
    }

    private func assertOverwriteFixture(refresh: Int, overwrite: Int, export: Int) {
        let expected = "refresh=\(refresh);overwrite=\(overwrite);export=\(export)"
        let matched = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", expected), object: overwriteState)
        XCTAssertEqual(XCTWaiter.wait(for: [matched], timeout: 5), .completed,
            "Expected \(expected), saw \(overwriteState.label)")
    }

    /// `upwards` is only the first guess at which way this element lies. The
    /// two doors sit above and below one another in one scroll view, so a test
    /// that asserts on both must not depend on knowing the order; a miss is
    /// retried in the opposite direction before it is reported as a failure.
    @discardableResult
    private func reveal(_ element: XCUIElement, upwards: Bool = true) -> Bool {
        if scan(element, upwards: upwards) { return true }
        return scan(element, upwards: !upwards)
    }

    private func scan(_ element: XCUIElement, upwards: Bool) -> Bool {
        for _ in 0..<14 {
            if element.exists, element.isHittable {
                if element.elementType != .button && element.elementType != .switch { return true }
                let frame = element.frame
                let top = app.navigationBars.allElementsBoundByIndex.filter(\.isHittable).map(\.frame.maxY).max() ?? 0
                let bottom = app.windows.firstMatch.frame.maxY - 40
                if frame.minY >= top && frame.maxY <= bottom { return true }
                let correction = frame.minY < top ? top - frame.minY + 12 : bottom - frame.maxY - 12
                let distance = min(160, max(60, abs(correction))) * (correction < 0 ? -1 : 1)
                let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)))
                continue
            }
            if upwards { app.swipeUp() } else { app.swipeDown() }
        }
        return element.exists && element.isHittable
    }

    private func assertTouchTarget(_ element: XCUIElement, line: UInt = #line) {
        let described = element.identifier.isEmpty ? element.label : element.identifier
        XCTAssertGreaterThanOrEqual(element.frame.height, 43.5,
            "\(described) is \(element.frame.height) pt tall", line: line)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(element.frame.minX, window.minX, described, line: line)
        XCTAssertLessThanOrEqual(element.frame.maxX, window.maxX, described, line: line)
    }

    private func auditDescriptionsAndTraits() throws {
        if #available(iOS 17.0, *) {
            try app.performAccessibilityAudit(for: .sufficientElementDescription)
            try app.performAccessibilityAudit(for: .trait)
        }
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

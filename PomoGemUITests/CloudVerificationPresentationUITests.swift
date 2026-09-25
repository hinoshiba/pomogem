import XCTest

/// sync-03 (owner-approved, 2026-09-24; narrowed after review of PR #40).
/// While iCloud verification is pending Home shows a mass this device can
/// stand behind — its own sum when that covers every session, or the last
/// verified total — captioned 「iCloudを確認中」, and 「再集計中」 otherwise.
/// The reward card shows the progress it froze at completion when that
/// total was one this device could stand behind; after verification the
/// card re-stamps itself. The Debug-only fixture forces a pending
/// presentation context in the in-memory preview (and can seed earlier
/// focus records into it) — no account or CloudKit call is involved.
@MainActor
final class CloudVerificationPresentationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    private func launch(verification: String, accessibility5: Bool = false, history: Int? = nil) {
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = accessibility5 ? "1" : "0"
        app.launchEnvironment["POMOGEM_UI_TEST_CLOUD_VERIFICATION"] = verification
        if let history {
            app.launchEnvironment["POMOGEM_UI_TEST_CLOUD_VERIFICATION_HISTORY"] = String(history)
        }
        app.launchArguments += ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP",
                                "-review.requested-version", "1.0"]
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 10))
    }

    func testPendingVerificationShowsTheDeviceMassAndTheFrozenProgress() {
        launch(verification: "pending")
        completeDemoFocus()

        // The reward card: frozen, device-confirmed progress plus the caption.
        let caption = app.descendants(matching: .any)["reward.projection-verification-caption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 6), "The card carries the caption while iCloud is checked")
        XCTAssertTrue(caption.label.contains("iCloudを確認中"), caption.label)
        XCTAssertFalse(app.descendants(matching: .any)["reward.projection-verification-pending"].exists,
                       "A receipt with frozen progress is shown, not replaced by a pending card")
        let heading = app.descendants(matching: .any)["reward.heading"]
        XCTAssertTrue(heading.exists)
        XCTAssertTrue((heading.value as? String)?.contains("今週記録した集中時間の質量") == true,
                      "The weekly figure is shown instead of 「今回の記録は保存済みです」: \(String(describing: heading.value))")
        // A one-session jar is a total this device can stand behind: the card
        // shows a real position, not 「時間の核を整理中」 beside a spinner.
        let progress = app.descendants(matching: .any)["reward.fusion-progress"]
        XCTAssertTrue(progress.exists)
        XCTAssertTrue(progress.label.contains("時間の核"), progress.label)
        XCTAssertFalse(progress.label.contains("整理中"), progress.label)
        saveScreenshot("pending-reward-card")
        dismissBreak()

        // Home: the jar says the confirmed mass instead of hiding it.
        let jar = app.descendants(matching: .any)["瓶"]
        XCTAssertTrue(jar.waitForExistence(timeout: 5))
        let confirmed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "iCloudを確認中。この端末で確認済みの集中時間の質量："),
            object: jar)
        XCTAssertEqual(XCTWaiter.wait(for: [confirmed], timeout: 8), .completed, String(describing: jar.value))
        XCTAssertFalse((jar.value as? String)?.contains("再集計中") == true)
        saveScreenshot("pending-home")

        app.buttons["メニュー"].tap()
        let metrics = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "iCloudを確認中。累計")).firstMatch
        XCTAssertTrue(metrics.waitForExistence(timeout: 5), "The menu shows the same captioned mass")
        XCTAssertFalse(metrics.label.contains("確認済み 250"), "No 「確認済み」 prefix that reads as a verified total")
        saveScreenshot("pending-menu")
    }

    /// Review of PR #40. More history than pending Home holds (it keeps the
    /// newest 128 sessions and no aggregate): without a verified total the
    /// jar says 「再集計中」 instead of presenting its newest sessions as the
    /// lifetime total, and once a verified total exists, the next pending
    /// phase keeps showing it.
    func testAPendingJarWithMoreHistoryThanHomeHoldsNeverShrinksItsTotal() {
        launch(verification: "cycle-25", history: 200)
        let jar = app.descendants(matching: .any)["瓶"]
        XCTAssertTrue(jar.waitForExistence(timeout: 8))
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "iCloudを確認中。これまでの合計は確認が済むと表示します"),
            object: jar)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 15), .completed, String(describing: jar.value))
        saveScreenshot("pending-history-hidden")

        let verified = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "集中時間の質量：") ,
            object: jar)
        let verifiedValue = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "NOT (value CONTAINS %@)", "iCloudを確認中"), object: jar)
        XCTAssertEqual(XCTWaiter.wait(for: [verified, verifiedValue], timeout: 40), .completed,
                       String(describing: jar.value))
        let verifiedText = (jar.value as? String) ?? ""
        guard let massRange = verifiedText.range(of: "質量："),
              let end = verifiedText[massRange.upperBound...].range(of: "グラム") else {
            return XCTFail("No verified mass in \(verifiedText)")
        }
        let mass = String(verifiedText[massRange.upperBound..<end.upperBound])
        saveScreenshot("pending-history-verified")

        let lastVerified = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "iCloudを確認中。この端末で確認済みの集中時間の質量：\(mass)"),
            object: jar)
        XCTAssertEqual(XCTWaiter.wait(for: [lastVerified], timeout: 40), .completed,
                       "Pending again, the jar keeps the verified \(mass): \(String(describing: jar.value))")
        saveScreenshot("pending-history-last-verified")
    }

    func testTheRewardCardReStampsWhenVerificationCompletes() {
        launch(verification: "verify-after-45")
        completeDemoFocus()
        let caption = app.descendants(matching: .any)["reward.projection-verification-caption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 6))
        saveScreenshot("restamp-before")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: caption)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 50), .completed,
                       "Verification completes while the card is open and the card re-stamps itself")
        let progress = app.descendants(matching: .any)["reward.fusion-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertTrue(progress.label.contains("時間の核"), progress.label)
        // The weekly heading is re-derived with the progress, not left frozen.
        let heading = app.descendants(matching: .any)["reward.heading"]
        XCTAssertTrue((heading.value as? String)?.contains("今週記録した集中時間の質量") == true,
                      String(describing: heading.value))
        saveScreenshot("restamp-after")
        let jar = app.descendants(matching: .any)["瓶"]
        dismissBreak()
        let verified = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "記録した集中時間の質量："), object: jar)
        XCTAssertEqual(XCTWaiter.wait(for: [verified], timeout: 8), .completed, String(describing: jar.value))
    }

    func testAX5PendingHomeStaysReadable() {
        launch(verification: "pending", accessibility5: true)
        let jar = app.descendants(matching: .any)["瓶"]
        XCTAssertTrue(jar.waitForExistence(timeout: 8))
        saveScreenshot("pending-home-ax5")
    }

    // MARK: Helpers

    private var demoLauncher: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "12秒集中する")).firstMatch
    }

    private func completeDemoFocus() {
        // The menu can still be animating in when the first tap lands.
        for _ in 0..<3 where !demoLauncher.exists {
            app.buttons["home.duration-picker"].tap()
            let demo = app.buttons["12秒、DEMO"]
            XCTAssertTrue(demo.waitForExistence(timeout: 4))
            demo.tap()
            _ = demoLauncher.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(demoLauncher.waitForExistence(timeout: 5))
        demoLauncher.tap()
        let stop = app.buttons["focus.completion-alert.stop"]
        if stop.waitForExistence(timeout: 25) { stop.tap() }
        XCTAssertTrue(app.buttons["休憩の提案を閉じる"].waitForExistence(timeout: 25),
                      "The demo focus commits, lands and offers its reward")
    }

    private func dismissBreak() {
        let dismiss = app.buttons["休憩の提案を閉じる"]
        if dismiss.exists, dismiss.isHittable { dismiss.tap() }
    }

    private func saveScreenshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["POMOGEM_SHOTS_DIR"] else { return }
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}

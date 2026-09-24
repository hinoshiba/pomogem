import XCTest

/// sync-03 (owner-approved, 2026-09-24). While iCloud verification is pending
/// Home keeps showing the mass this device has confirmed, captioned
/// 「iCloudを確認中」, and the reward card shows the progress it froze at
/// completion; after verification the card re-stamps itself. The Debug-only
/// fixture forces a pending presentation context in the in-memory preview —
/// no store, account or CloudKit call is involved.
@MainActor
final class CloudVerificationPresentationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    private func launch(verification: String, accessibility5: Bool = false) {
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = accessibility5 ? "1" : "0"
        app.launchEnvironment["POMOGEM_UI_TEST_CLOUD_VERIFICATION"] = verification
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
            NSPredicate(format: "label BEGINSWITH %@", "iCloudを確認中。この端末で確認済みの累計")).firstMatch
        XCTAssertTrue(metrics.waitForExistence(timeout: 5), "The menu names whose confirmation the mass carries")
        saveScreenshot("pending-menu")
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

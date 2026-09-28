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

    private func launch(verification: String, accessibility5: Bool = false, history: Int? = nil,
                        rereadDelay: Int? = nil) {
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = accessibility5 ? "1" : "0"
        app.launchEnvironment["POMOGEM_UI_TEST_CLOUD_VERIFICATION"] = verification
        if let history {
            app.launchEnvironment["POMOGEM_UI_TEST_CLOUD_VERIFICATION_HISTORY"] = String(history)
        }
        if let rereadDelay {
            app.launchEnvironment["POMOGEM_UI_TEST_CLOUD_VERIFICATION_REREAD_DELAY"] = String(rereadDelay)
        }
        app.launchArguments += ["-review.requested-version", "1.0"]
        PomoGemUITestLanguage.configureJapanese(app)
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
        XCTAssertTrue((heading.value as? String)?.contains("今週の実測は") == true,
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
        XCTAssertTrue((heading.value as? String)?.contains("今週の実測は") == true,
                      String(describing: heading.value))
        saveScreenshot("restamp-after")
        let jar = app.descendants(matching: .any)["瓶"]
        dismissBreak()
        let verified = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "記録した集中時間の質量："), object: jar)
        XCTAssertEqual(XCTWaiter.wait(for: [verified], timeout: 8), .completed, String(describing: jar.value))
    }

    /// device-verify-2 P2. On the phone every return inside the 15 s
    /// background grace — 5 s, 10 s — put Home back to about 65 s of
    /// 「iCloudを確認中」. A short absence now keeps the verified jar. (The
    /// fixture never verifies twice, so a revoked presentation would stay.)
    func testAShortAbsenceKeepsTheVerifiedJar() {
        launch(verification: "verify-after-3", history: 3)
        let jar = app.descendants(matching: .any)["瓶"]
        XCTAssertTrue(jar.waitForExistence(timeout: 8))
        let verified = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "記録した集中時間の質量："), object: jar)
        XCTAssertEqual(XCTWaiter.wait(for: [verified], timeout: 15), .completed, String(describing: jar.value))
        let verifiedValue = (jar.value as? String) ?? ""
        for seconds in [5.0, 10.0] {
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: seconds)
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            XCTAssertTrue(jar.waitForExistence(timeout: 5))
            let seen = sampledValues(of: jar, for: 4)
            XCTAssertFalse(seen.contains { $0.contains("iCloudを確認中") },
                           "Back after \(Int(seconds)) s, the jar stays verified: \(seen)")
            XCTAssertEqual(seen.last, verifiedValue)
            saveScreenshot("short-absence-\(Int(seconds))s")
        }
    }

    /// The other side of the same rule: a longer absence is a new foreground
    /// epoch, so trust is revoked and iCloud is checked again.
    func testALongerAbsenceStillChecksICloudAgain() {
        launch(verification: "verify-after-3", history: 3)
        let jar = app.descendants(matching: .any)["瓶"]
        XCTAssertTrue(jar.waitForExistence(timeout: 8))
        let verified = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "記録した集中時間の質量："), object: jar)
        XCTAssertEqual(XCTWaiter.wait(for: [verified], timeout: 15), .completed, String(describing: jar.value))
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 20)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let pending = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "iCloudを確認中。この端末で確認済みの集中時間の質量："),
            object: jar)
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 8), .completed, String(describing: jar.value))
        saveScreenshot("long-absence-pending")
    }

    /// device-verify-2 P2. Whenever the presentation changes generation —
    /// iCloud checked again after an import, the app's own save or the
    /// rolling check, or verification completing — Home re-reads its page.
    /// On the phone that read took about a second, and meanwhile the jar said
    /// 「再集計中」 over 「この端末で確認済み 0粒」 with no time core. The fixture
    /// slows each read to two seconds: the jar keeps what it showed.
    func testTheJarKeepsItsTotalWhileHomeReReadsItsPage() {
        launch(verification: "cycle-12", history: 200, rereadDelay: 2)
        let jar = app.descendants(matching: .any)["瓶"]
        XCTAssertTrue(jar.waitForExistence(timeout: 10))
        // Pending without a verified total, then verified (after a re-read),
        // then pending again (a re-read again).
        let isVerified = { (value: String) in
            !value.contains("iCloudを確認中") && !value.hasPrefix(Self.loadingValue)
        }
        var timeline = sampledValues(of: jar, until: isVerified, timeout: 30)
        XCTAssertEqual(timeline.last.map(isVerified), true, "Never verified: \(timeline)")
        timeline += sampledValues(of: jar, until: { $0.contains("iCloudを確認中") }, timeout: 25)
        XCTAssertEqual(timeline.last?.contains("iCloudを確認中"), true, "Never pending again: \(timeline)")
        saveScreenshot("reread-pending-again")
        timeline += sampledValues(of: jar, for: 4)
        saveScreenshot("reread-pending-settled")
        attachTimeline("reread", timeline)

        guard let firstVerified = timeline.firstIndex(where: isVerified),
              let pendingAgain = timeline[firstVerified...].firstIndex(where: { $0.contains("iCloudを確認中") }) else {
            return XCTFail("No verified phase followed by a pending one: \(timeline)")
        }
        // From the first frame on (before its first read Home says it is
        // loading), no re-read ever makes the jar read empty. (0 loose gems
        // beside crystals is a fused jar, not an empty one.)
        XCTAssertFalse(timeline.contains { $0.contains("質量：0グラム") || $0.contains("瓶の整理：0粒。") },
                       "The jar never reads empty while Home reads its page: \(timeline)")
        // The total on screen when iCloud is checked again.
        let verifiedText = timeline[pendingAgain - 1]
        guard let massRange = verifiedText.range(of: "質量："),
              let end = verifiedText[massRange.upperBound...].range(of: "グラム") else {
            return XCTFail("No verified mass in \(verifiedText)")
        }
        let mass = String(verifiedText[massRange.upperBound..<end.upperBound])
        // Review of #56. Verification completing retires the page too. The
        // pending readout held across it lost 「iCloudを確認中」, and its 128
        // newest gems read as a verified lower bound (「32.00キログラム以上、
        // 集計整理中」). Now the verified wording only ever carries the verified
        // total: it first appears when the new page lands.
        let verifiedPhase = timeline[firstVerified..<pendingAgain]
        XCTAssertTrue(verifiedPhase.allSatisfy { $0.hasPrefix("記録した集中時間の質量：\(mass)。") },
                      "Only the verified \(mass) in the verified wording: \(verifiedPhase)")
        let afterVerified = timeline[pendingAgain...]
        XCTAssertFalse(afterVerified.contains { $0.contains("これまでの合計は確認が済むと表示します") },
                       "A verified total exists: never 「再集計中」 while Home re-reads: \(afterVerified)")
        XCTAssertTrue(afterVerified.allSatisfy { $0.contains("iCloudを確認中。この端末で確認済みの集中時間の質量：\(mass)") },
                      "Pending again, the jar keeps the verified \(mass): \(afterVerified)")
    }

    /// Review of #56. Before its first read Home has no readout to hold: on
    /// every launch, and every remount after the background grace, it said
    /// 「再集計中」 over 「この端末で確認済み 0粒」 with an empty jar until the
    /// read landed (about a second on the phone). The fixture slows that read
    /// to six seconds, sampled from the first frame the test sees: Home says
    /// it is loading and shows no number, and then its total.
    func testHomeShowsNoNumberBeforeItsFirstRead() {
        launch(verification: "pending", history: 3, rereadDelay: 6)
        let jar = app.descendants(matching: .any)["瓶"]
        XCTAssertTrue(jar.waitForExistence(timeout: 5))
        let first = (jar.value as? String) ?? ""
        XCTAssertTrue(first.hasPrefix(Self.loadingValue), "Before the first read: \(first)")
        // The in-jar 「iCloudを確認中」 message is an empty jar's; this one is
        // only still loading.
        let emptyMessage = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "iCloudを確認中。この端末で確認できた記録")).firstMatch
        XCTAssertFalse(emptyMessage.exists, "No empty-jar message before the first read")
        saveScreenshot("first-read-loading")

        let timeline = [first] + sampledValues(of: jar, until: { $0.contains("質量：") }, timeout: 15)
        attachTimeline("first-read", timeline)
        XCTAssertEqual(timeline.last?.contains("iCloudを確認中。この端末で確認済みの集中時間の質量：750グラム"), true,
                       "\(timeline)")
        XCTAssertFalse(timeline.contains {
            $0.contains("質量：0グラム") || $0.contains("瓶の整理：0粒")
                || $0.contains("これまでの合計は確認が済むと表示します")
        }, "Never 0粒 or 「再集計中」 while Home reads its page: \(timeline)")
        XCTAssertTrue(timeline.dropLast().allSatisfy { $0.hasPrefix(Self.loadingValue) },
                      "Loading, then the total, with nothing in between: \(timeline)")
        saveScreenshot("first-read-settled")
    }

    func testAX5PendingHomeStaysReadable() {
        launch(verification: "pending", accessibility5: true)
        let jar = app.descendants(matching: .any)["瓶"]
        XCTAssertTrue(jar.waitForExistence(timeout: 8))
        saveScreenshot("pending-home-ax5")
    }

    // MARK: Helpers

    /// The jar's VoiceOver value before Home has read its records.
    private static let loadingValue = "これまでの記録を読み込み中"

    /// Keeps a sampled timeline with the run, and beside the screenshots.
    private func attachTimeline(_ name: String, _ timeline: [String]) {
        let text = timeline.enumerated().map { "\($0.offset)\t\($0.element)" }.joined(separator: "\n")
        let attachment = XCTAttachment(string: text)
        attachment.name = "timeline-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["POMOGEM_SHOTS_DIR"] else { return }
        try? text.write(to: URL(fileURLWithPath: directory).appendingPathComponent("timeline-\(name).txt"),
                        atomically: true, encoding: .utf8)
    }

    private var demoLauncher: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "12秒集中する")).firstMatch
    }

    private func completeDemoFocus() {
        // The menu can still be animating in when the first tap lands. The
        // menu then stays open over the picker, so pick the item again
        // instead of tapping the covered picker (which failed the test).
        let demo = app.buttons["12秒、DEMO"]
        for _ in 0..<3 where !demoLauncher.exists {
            if !demo.exists {
                app.buttons["home.duration-picker"].tap()
                XCTAssertTrue(demo.waitForExistence(timeout: 4))
            }
            _ = waitUntilFrameSettles(demo, timeout: 3)
            demo.tap()
            _ = demoLauncher.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(demoLauncher.waitForExistence(timeout: 5))
        demoLauncher.tap()
        stopCompletionAlertIfPresented(in: app)
        XCTAssertTrue(app.buttons["休憩の提案を閉じる"].waitForExistence(timeout: 25),
                      "The demo focus commits, lands and offers its reward")
    }

    /// Every accessibility value `element` reports until one satisfies
    /// `condition` (inclusive) or `timeout` passes, in order.
    private func sampledValues(of element: XCUIElement, until condition: (String) -> Bool,
                               timeout: TimeInterval) -> [String] {
        var values: [String] = []
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let value = element.value as? String, values.last != value {
                values.append(value)
                if condition(value) { break }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return values
    }

    /// Every accessibility value `element` reports over `seconds`, in order.
    private func sampledValues(of element: XCUIElement, for seconds: TimeInterval) -> [String] {
        var values: [String] = []
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let value = element.value as? String, values.last != value { values.append(value) }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return values
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

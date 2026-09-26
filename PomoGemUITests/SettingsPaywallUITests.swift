import XCTest

/// settings-04 / -05 / -06 / -07, product-08. Settings' order, the About
/// page, the support rows and the paywall's context-first layout, in the
/// Simulator's local preview. No purchase, restore or App Store sign-in is
/// ever attempted: the paywall is only opened, read and closed.
@MainActor
final class SettingsPaywallUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        PomoGemUITestLanguage.configureJapanese(app)
    }

    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0, let app {
            attach("Settings/paywall failure")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Settings/paywall accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app?.terminate()
        app = nil
    }

    func testSettingsKeepsSupportPrivacyAndTheAboutPageTogether() {
        checkSettingsLayout(accessibility5: false)
    }

    func testSettingsLayoutStaysReachableAtAccessibilitySize() {
        checkSettingsLayout(accessibility5: true)
    }

    /// settings-04. From the 「カスタム」 tile the paywall leads with the timer,
    /// marks it, and says what stays free.
    func testTheCustomTileOpensAPaywallThatLeadsWithTheTimer() {
        launchAndOpenSettings()
        let custom = app.buttons["settings.custom-timer"]
        XCTAssertTrue(reveal(custom))
        custom.tap()
        XCTAssertTrue(app.buttons["paywall.close"].waitForExistence(timeout: 8))

        let timer = element("paywall.feature.customDuration")
        let month = element("paywall.feature.monthLabel")
        let apps = element("paywall.feature.studyApps")
        XCTAssertTrue(timer.waitForExistence(timeout: 4))
        XCTAssertTrue(month.exists && apps.exists)
        XCTAssertLessThan(timer.frame.minY, month.frame.minY, "The entry point's feature comes first")
        XCTAssertLessThan(month.frame.minY, apps.frame.minY)
        XCTAssertTrue(timer.label.contains("無料の25・45・60・90分"), timer.label)
        XCTAssertTrue(month.label.contains("結晶に月を刻む"), month.label)
        XCTAssertTrue(element("paywall.free-note").exists)
        waitForCatalogAnswer()
        attach("Paywall — opened from Settings' custom tile")

        app.buttons["paywall.close"].tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 6))
        XCTAssertFalse(
            app.buttons["custom-timer.confirm"].waitForExistence(timeout: 2),
            "Closing without buying must not open the duration editor"
        )
    }

    func testThePaywallFromSettingsAtAccessibilitySize() {
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1"
        launchAndOpenSettings()
        let pro = app.buttons["settings.pro"]
        XCTAssertTrue(reveal(pro))
        pro.tap()
        XCTAssertTrue(app.buttons["paywall.close"].waitForExistence(timeout: 8))
        XCTAssertTrue(element("paywall.feature.customDuration").waitForExistence(timeout: 4))
        waitForCatalogAnswer()
        attach("Paywall AX5 — top")
        app.swipeUp()
        attach("Paywall AX5 — features")
        app.swipeUp()
        attach("Paywall AX5 — price")
    }

    /// settings-05. An open Ask to Buy request (seeded through the argument
    /// domain, as StoreKit's own .pending cannot be produced here) reads as
    /// 承認待ち in Settings and, once the catalog loads, on the paywall.
    func testAnOpenApprovalRequestReadsAsWaiting() throws {
        app.launchArguments += [
            "-pomogem.pro.approval-requested-at",
            String(Date().timeIntervalSince1970 - 60)
        ]
        launchAndOpenSettings()
        let pro = app.buttons["settings.pro"]
        XCTAssertTrue(reveal(pro))
        XCTAssertTrue(pro.label.contains("承認待ち"), pro.label)
        attach("Settings — Pro row while approval is pending")
        pro.tap()
        XCTAssertTrue(app.buttons["paywall.close"].waitForExistence(timeout: 8))
        let purchase = app.buttons["paywall.purchase"]
        guard purchase.waitForExistence(timeout: 30) else {
            attach("Paywall — catalog unavailable, pending card not reachable")
            throw XCTSkip("The App Store catalog did not load in this Simulator; the pending card needs a product.")
        }
        XCTAssertTrue(reveal(purchase))
        XCTAssertTrue(purchase.label.contains("もう一度リクエスト"), purchase.label)
        XCTAssertTrue(purchase.isEnabled, "A pending request never blocks asking again")
        let notice = element("paywall.approval-pending")
        XCTAssertTrue(notice.exists)
        XCTAssertTrue(notice.label.contains("承認待ち"), notice.label)
        attach("Paywall — approval pending")
    }

    // MARK: - Helpers

    private func checkSettingsLayout(accessibility5: Bool) {
        if accessibility5 { app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1" }
        let prefix = accessibility5 ? "Settings AX5" : "Settings"
        launchAndOpenSettings()
        attach("\(prefix) — top")

        let liveActivity = app.switches["settings.live-activity"]
        XCTAssertTrue(reveal(liveActivity))
        let returnReminder = app.switches["settings.focus-return-reminder"]
        XCTAssertTrue(reveal(returnReminder))
        XCTAssertTrue(reveal(text(containing: "タイマーはバックグラウンドでも止まりません")))
        attach("\(prefix) — timer notices and their footer")

        let pro = app.buttons["settings.pro"]
        XCTAssertTrue(reveal(pro))
        XCTAssertTrue(pro.label.contains("ポモジェムPro"), pro.label)
        XCTAssertTrue(pro.label.contains("自由な集中時間"), pro.label)
        XCTAssertTrue(reveal(text(containing: "Proは1回だけの買い切りです")))
        attach("\(prefix) — Pro beside the timer")

        let export = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "データを書き出す")).firstMatch
        XCTAssertTrue(reveal(export))
        let exportValue = export.value as? String ?? ""
        XCTAssertTrue(exportValue.contains("読み込みには非対応"), exportValue)
        XCTAssertTrue(reveal(text(containing: "タイマーの同期に使うランダムな端末ID")))
        attach("\(prefix) — records export and its footer")

        let mail = app.buttons["settings.support-mail"]
        XCTAssertTrue(reveal(mail))
        XCTAssertTrue(mail.label.contains("メールで問い合わせる"), mail.label)
        let review = element("settings.write-review")
        XCTAssertTrue(reveal(review))
        XCTAssertTrue(review.label.contains("App Storeで評価・レビューする"), review.label)
        let footer = app.staticTexts["settings.privacy-footer"]
        XCTAssertTrue(reveal(footer))
        XCTAssertTrue(footer.label.contains("開発者が記録を受け取ることはありません"), footer.label)
        let about = app.buttons["settings.about"]
        XCTAssertTrue(reveal(about))
        XCTAssertTrue(about.label.contains("バージョン"), about.label)
        // At AX5 the List has already unloaded the review row by the time
        // the About row scrolls in; compare only while both are on screen.
        if review.exists {
            XCTAssertLessThan(review.frame.minY, about.frame.minY)
        }
        XCTAssertFalse(app.staticTexts["あなたのプライベートデータベースのみ"].exists)
        XCTAssertFalse(text(containing: "出荷対象").exists)
        attach("\(prefix) — support, privacy and About")

        about.tap()
        XCTAssertTrue(app.navigationBars["このアプリについて"].waitForExistence(timeout: 6))
        let version = element("about.version")
        XCTAssertTrue(version.waitForExistence(timeout: 3))
        XCTAssertTrue(version.label.contains("バージョン"), version.label)
        XCTAssertTrue(reveal(element("about.font-license")))
        attach("\(prefix) — About page")
        element("about.font-license").tap()
        let close = app.buttons["font-license.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 6))
        close.tap()
        XCTAssertTrue(app.navigationBars["このアプリについて"].waitForExistence(timeout: 6))
    }

    private func launchAndOpenSettings() {
        app.launch()
        let menu = app.buttons["メニュー"]
        XCTAssertTrue(menu.waitForExistence(timeout: 12))
        menu.tap()
        let settings = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "設定")).firstMatch
        XCTAssertTrue(reveal(settings))
        settings.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 8))
    }

    /// The catalog answers from the App Store (or not at all offline); wait
    /// for either the price card or the reload card before a screenshot.
    private func waitForCatalogAnswer() {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if app.buttons["paywall.purchase"].exists
                || text(containing: "商品情報を読み込めませんでした").exists {
                return
            }
            usleep(250_000)
        }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func text(containing value: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    private func reveal(_ element: XCUIElement) -> Bool {
        for _ in 0..<20 {
            if element.exists {
                let top = app.navigationBars.allElementsBoundByIndex
                    .filter(\.isHittable).map(\.frame.maxY).max() ?? 0
                let bottom = app.windows.firstMatch.frame.maxY - 36
                let frame = settledFrame(of: element)
                if frame.height > 0, frame.width > 0 {
                    if frame.minY >= top, frame.maxY <= bottom { return true }
                    if frame.height > bottom - top, element.isHittable { return true }
                    let correction = frame.minY < top
                        ? top - frame.minY + 12 : bottom - frame.maxY - 12
                    let distance = min(220, max(60, abs(correction))) * (correction < 0 ? -1 : 1)
                    let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)))
                    continue
                }
            }
            app.swipeUp(velocity: .fast)
        }
        return element.exists && element.isHittable
    }

    private func settledFrame(of element: XCUIElement) -> CGRect {
        var frame = element.frame
        for _ in 0..<10 {
            let next = element.frame
            if next == frame { return next }
            frame = next
        }
        return frame
    }

    private func attach(_ name: String) {
        usleep(400_000)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

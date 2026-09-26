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
        // The system text size itself: the paywall is a root sheet, and a
        // sheet does not inherit the POMOGEM_UI_TEST_AX5 size set below it.
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
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
        let purchase = app.buttons["paywall.purchase"]
        if purchase.exists {
            XCTAssertTrue(reveal(purchase), "The price and the buy button stay reachable at AX5")
        }
        attach("Paywall AX5 — price")
        let restore = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "購入を復元")).firstMatch
        XCTAssertTrue(reveal(restore))
        attach("Paywall AX5 — restore and legal links")
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

    /// settings-05. An approval that lands while the focus timer covers the
    /// root is told once the timer has closed, not spent beneath it (the
    /// toast is drawn under every cover). StoreKit cannot approve anything
    /// here, so a Debug-only fixture records what `Transaction.updates` would
    /// two seconds into the focus. It grants no entitlement.
    func testAnApprovalThatLandsDuringAFocusIsToldAfterTheTimerCloses() {
        app.launchEnvironment["POMOGEM_UI_TEST_APPROVAL_ARRIVES_DURING_FOCUS"] = "1"
        app.launch()
        let menu = app.buttons["メニュー"]
        XCTAssertTrue(menu.waitForExistence(timeout: 12))
        let launcher = app.buttons["home.focus-launcher"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 6))
        launcher.tap()
        let giveUp = app.buttons["今日はここまで"].firstMatch
        XCTAssertTrue(giveUp.waitForExistence(timeout: 8))

        let notice = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "app.toast", "ポモジェムProが使えるようになりました")
        ).firstMatch
        // Well past the arrival and past a 3-second toast: had the notice been
        // spent under the timer, it would be gone by the time the timer closes.
        sleep(7)
        XCTAssertTrue(giveUp.exists, "The focus timer is still up")
        attach("Approval notice — owed while the focus timer is up")

        XCTAssertTrue(reveal(giveUp))
        giveUp.tap()
        let confirmation = app.alerts["今日はここまで"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 4))
        confirmation.buttons["今日はここまで"].tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        XCTAssertTrue(notice.waitForExistence(timeout: 15), "The notice is told once Home can be seen")
        attach("Approval notice — told on Home after the timer closed")
        XCTAssertTrue(app.buttons["home.focus-launcher"].exists)
        XCTAssertTrue(waitForAbsence(notice, timeout: 8))
        sleep(3)
        XCTAssertFalse(notice.exists, "Told once")
    }

    /// F4 (Docs/FocusMusic.md). 設定 → 集中 → 「集中用の音楽」 names the chosen
    /// music and opens the timer's music sheet. The choice is seeded through
    /// the argument domain. Nothing here needs an Apple Music account: the
    /// row and the sheet only read the MusicKit status, and the access
    /// button a fresh Simulator shows is never tapped.
    func testTheFocusMusicRowOpensTheMusicSheet() {
        let classical = "pl.cf8514b686374fadbe6807a6339dfd89"
        app.launchArguments += ["-music.focus.source", classical]
        launchAndOpenSettings()

        let row = app.buttons["settings.focus-music"]
        XCTAssertTrue(reveal(row))
        XCTAssertEqual(row.label, "集中用の音楽")
        let value = row.value as? String ?? ""
        XCTAssertTrue(value.contains("作業用BGM：クラシック"), value)
        // In the 集中 card, after the timer's own rows.
        let orientation = app.buttons["settings.timer-default-orientation"]
        if orientation.exists {
            XCTAssertLessThan(orientation.frame.minY, row.frame.minY)
        }
        let liveActivity = app.switches["settings.live-activity"]
        if liveActivity.exists {
            XCTAssertLessThan(row.frame.maxY, liveActivity.frame.minY)
        }
        attach("Settings — focus music row")

        row.tap()
        let close = app.buttons["focus-music.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        XCTAssertTrue(app.navigationBars["集中用の音楽"].exists)
        let chosen = element("focus-music.source.\(classical)")
        XCTAssertTrue(chosen.waitForExistence(timeout: 4))
        XCTAssertEqual(chosen.value as? String, "選択中")
        for source in [
            "ra.985486574",
            "pl.cb4d1c09a2df4230a78d0395fe1f8fde",
            "pl.f6ab843650ff4d6aafbd96de3a0b8a13",
            "pl.9b8a976ba78741d9925e6e9a050703de"
        ] {
            let other = element("focus-music.source.\(source)")
            XCTAssertTrue(other.exists, source)
            XCTAssertEqual(other.value as? String, "未選択", source)
        }
        XCTAssertTrue(element("focus-music.autoplay").exists)
        // Opening the sheet reads the status only; the MusicKit prompt
        // appears solely from a tap on 「Apple Musicへのアクセスを許可」.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let musicPrompt = springboard.alerts.matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS %@", "Apple Music", "メディア")
        ).firstMatch
        XCTAssertFalse(musicPrompt.waitForExistence(timeout: 2), "No MusicKit prompt without a tap")
        attach("Focus music sheet — opened from Settings")

        close.tap()
        XCTAssertTrue(waitForAbsence(close, timeout: 6))
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 6))
        XCTAssertTrue(row.exists)
    }

    // MARK: - Helpers

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            usleep(250_000)
        }
        return !element.exists
    }

    private func checkSettingsLayout(accessibility5: Bool) {
        if accessibility5 { app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1" }
        let prefix = accessibility5 ? "Settings AX5" : "Settings"
        launchAndOpenSettings()
        attach("\(prefix) — top")

        // F4. The 集中 card's music row keeps its 44 pt target and its name;
        // at AX5 the sheet it opens stays closable and scrolls to its end.
        let music = app.buttons["settings.focus-music"]
        XCTAssertTrue(reveal(music))
        XCTAssertGreaterThanOrEqual(music.frame.height, 43.5)
        XCTAssertEqual(music.label, "集中用の音楽")
        XCTAssertFalse((music.value as? String ?? "").isEmpty, "The row names the chosen music or 未選択")
        attach("\(prefix) — focus music row")
        if accessibility5 {
            checkFocusMusicSheetAtAccessibilitySize(from: music)
        }

        // F1. UI-test processes start with the leave pause off (shared
        // Simulators background many focuses); FocusLeaveSettingsUITests
        // covers the product default, on.
        let leavePause = app.switches["settings.focus-leave-pause"]
        XCTAssertTrue(reveal(leavePause))
        XCTAssertTrue(leavePause.label.contains("アプリを離れたら一時停止"), leavePause.label)
        XCTAssertEqual(leavePause.value as? String, "0")
        XCTAssertFalse(app.switches["settings.focus-leave-nudges"].exists,
                       "The series exists only while the leave pause is on")
        XCTAssertTrue(reveal(text(containing: "パスコードがないiPhoneでは、ロックとアプリの切り替えを区別できないため")))
        XCTAssertTrue(reveal(text(containing: "オフのときは、アプリを離れてもタイマーは止まりません")))
        attach("\(prefix) — leave pause and its footer")
        if music.exists, music.isHittable, leavePause.isHittable {
            XCTAssertLessThan(music.frame.minY, leavePause.frame.minY,
                              "The 集中 card ends with 集中用の音楽; the leave pause card follows it")
        }

        // The leave pause sits with the timer, above the Live Activity. Its
        // card's last footer paragraph and the Live Activity row are
        // compared while both are on screen, at every text size.
        let liveActivity = app.switches["settings.live-activity"]
        let resumeFooter = element("settings.focus-leave-footer.resume")
        XCTAssertTrue(reveal(liveActivity))
        XCTAssertTrue(resumeFooter.exists, "The leave-pause card ends right above the Live Activity card")
        XCTAssertLessThanOrEqual(resumeFooter.frame.maxY, liveActivity.frame.minY + 1,
                                 "The leave pause sits with the timer, above the Live Activity")
        if !accessibility5 {
            XCTAssertTrue(leavePause.exists)
            XCTAssertLessThan(leavePause.frame.minY, liveActivity.frame.minY,
                              "The leave pause sits with the timer, above the Live Activity")
        }
        let returnReminder = app.switches["settings.focus-return-reminder"]
        XCTAssertTrue(reveal(returnReminder), "With the leave pause off the return reminder is offered as before")
        XCTAssertTrue(reveal(text(containing: "「アプリを離れたら一時停止」の設定に従います")))
        XCTAssertFalse(text(containing: "タイマーはバックグラウンドでも止まりません").exists)
        attach("\(prefix) — timer notices and their footer")

        let pro = app.buttons["settings.pro"]
        XCTAssertTrue(reveal(pro))
        XCTAssertTrue(pro.label.contains("ポモジェムPro"), pro.label)
        XCTAssertTrue(pro.label.contains("自由な集中時間"), pro.label)
        XCTAssertTrue(reveal(text(containing: "Proは1回だけの買い切りです")))
        attach("\(prefix) — Pro beside the timer")

        // Only this card's switches are off by default: the leave-pause
        // series in the Focus card is on by default.
        let notificationsFooter = element("settings.notifications-footer")
        XCTAssertTrue(reveal(notificationsFooter))
        XCTAssertTrue(notificationsFooter.label.contains("「毎日のリマインダー」と「先月の瓶のお知らせ」は既定でオフです"),
                      notificationsFooter.label)
        XCTAssertFalse(notificationsFooter.label.hasPrefix("既定はオフ。"), notificationsFooter.label)
        attach("\(prefix) — notifications footer")

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

    /// Settings hands its Dynamic Type size to the music sheet, which opens
    /// at the medium detent. Nothing in the sheet is tapped except 閉じる:
    /// the access button would show the MusicKit prompt and a list row
    /// would start playback.
    private func checkFocusMusicSheetAtAccessibilitySize(from row: XCUIElement) {
        row.tap()
        let close = app.buttons["focus-music.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        XCTAssertTrue(close.isHittable)
        let bar = app.navigationBars["集中用の音楽"]
        XCTAssertTrue(bar.exists)
        // iOS 26 draws a sheet at its medium detent slightly scaled down: the
        // bar, laid out at the window's width, shows about 96% of it. The
        // 44 pt target is compared in that scale here, and at full size once
        // the sheet has grown to its large detent below.
        let window = app.windows.firstMatch.frame
        let mediumScale = min(1, settledFrame(of: bar).width / window.width)
        XCTAssertGreaterThanOrEqual(settledFrame(of: close).height, 43.5 * mediumScale)
        XCTAssertTrue(element("focus-music.source.pl.cf8514b686374fadbe6807a6339dfd89").waitForExistence(timeout: 4))
        attach("Settings AX5 — focus music sheet, medium detent")

        let autoplay = element("focus-music.autoplay")
        XCTAssertTrue(autoplay.waitForExistence(timeout: 4))
        let sheetScroll = app.scrollViews
            .containing(NSPredicate(format: "identifier == %@", "focus-music.autoplay"))
            .firstMatch
        let bottom = window.maxY - 20
        for _ in 0..<10 {
            if autoplay.isHittable, autoplay.frame.maxY <= bottom { break }
            sheetScroll.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(autoplay.isHittable, "The sheet scrolls to its last row at AX5")
        XCTAssertLessThanOrEqual(autoplay.frame.maxY, bottom)
        XCTAssertTrue(close.isHittable, "閉じる stays reachable after scrolling")
        // Scrolling up from the medium detent grows the sheet first.
        XCTAssertEqual(settledFrame(of: bar).width, window.width, accuracy: 0.5, "The sheet reached its large detent")
        XCTAssertGreaterThanOrEqual(settledFrame(of: close).height, 43.5)
        attach("Settings AX5 — focus music sheet, scrolled to the end")

        close.tap()
        XCTAssertTrue(waitForAbsence(close, timeout: 6))
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 6))
        XCTAssertTrue(row.exists)
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

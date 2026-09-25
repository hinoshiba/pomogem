import XCTest

/// Simulator navigation and accessibility coverage only. These tests never
/// grant permission, simulate a successful callback, or operate the app picker.
///
/// One of them opts into a DEBUG-only Simulator fixture
/// (`ScreenTimeSettingsUITestFixture`) so the unbound -> bound draft re-seed
/// can be exercised at all: it stubs the authorization STATUS on a private
/// controller over a temporary-directory ledger and replaces
/// `ScreenTimeMonitoring` with a recorder. That is a test of the settings
/// screen's own logic, never evidence about real Family Controls
/// authorization, DeviceActivity registration, or callback delivery — those
/// stay on the signed-device checklist.
@MainActor
final class ScreenTimeSettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("This suite checks the real unavailable Simulator state; use the signed-device checklist for Screen Time.")
#endif
        continueAfterFailure = false
        executionTimeAllowance = 180
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
    }

    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0, let app {
            attach("Screen Time failure")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Screen Time accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app?.terminate()
        app = nil
    }

    func testSettingsExposeRealAuthorizationStateAndResetConsequences() {
        launchAndOpenSettings()
        assertAuthorizationHasNotBeenInvented()
        attach("Screen Time — permission required")

        let learning = app.buttons["screen-time.learning-apps"]
        XCTAssertTrue(reveal(learning))
        XCTAssertFalse(learning.isEnabled)
        XCTAssertEqual(learning.value as? String, "0アプリ選択中")
        let negative = app.buttons["screen-time.distraction-apps"]
        XCTAssertTrue(reveal(negative))
        XCTAssertFalse(negative.isEnabled)
        XCTAssertEqual(negative.value as? String, "0アプリ選択中")
        XCTAssertTrue(reveal(text(containing: "無料でもアプリ数は無制限")))

        let total = app.staticTexts["screen-time.negative-total"]
        XCTAssertTrue(reveal(total, upwards: false))
        let originalTotal = total.label
        XCTAssertTrue(originalTotal.contains("黒い石"))
        XCTAssertTrue(originalTotal.contains("0"))
        XCTAssertTrue(reveal(text(containing: "JSON書き出しや保存先の切り替えでは引き継ぎません")))
        assertResetConfirmationCanBeCancelled()
        XCTAssertTrue(reveal(total, upwards: false))
        XCTAssertEqual(total.label, originalTotal)
        attach("Screen Time — local black gems and retained learning")
    }

    func testAX5ControlsAndLocalDataExplanationRemainReachable() {
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1"
        launchAndOpenSettings()
        assertAuthorizationHasNotBeenInvented()
        attach("Screen Time AX5 — authorization and stopped recording")

        for identifier in ["screen-time.learning-apps", "screen-time.distraction-apps"] {
            let button = app.buttons[identifier]
            XCTAssertTrue(reveal(button))
            XCTAssertGreaterThanOrEqual(button.frame.height, 43.5)
            XCTAssertFalse(button.label.isEmpty)
            XCTAssertFalse(button.isEnabled)
            attach("Screen Time AX5 — \(identifier)")
        }
        let explanation = text(containing: "JSON書き出しや保存先の切り替えでは引き継ぎません")
        XCTAssertTrue(reveal(explanation))
        XCTAssertGreaterThan(explanation.frame.height, 70,
                             "The settings must actually inherit the largest text size")
        attach("Screen Time AX5 — device-local disclosure")
        assertResetConfirmationCanBeCancelled()
    }

    /// The Simulator build carries no entitlements, so the App Group container
    /// is nil and the Screen Time ledger can never bind. That must be explained
    /// on screen, and 保存 stays pressable so the user is told why — the button
    /// is an explanation, not a save that will succeed, and the footer has to
    /// say so: `ScreenTimeController.save` refuses EVERY save while unbound,
    /// including one that only switches recording off.
    ///
    /// The premise is a BUILD property, not a property of the Simulator: on
    /// this Xcode's runtime the container only stays nil when the build passed
    /// `CODE_SIGNING_ALLOWED=NO`. CI does (`.github/workflows/ci.yml`); a plain
    /// `xcodebuild test -scheme PomoGem -destination 'platform=iOS
    /// Simulator,…'` does not, and this test used to go red there with a
    /// message that pointed at the settings UI instead of at the flag. It now
    /// says so and skips.
    func testUnavailableContextIsExplainedAndSaveStatesWhyItCannotComplete() throws {
        launchAndOpenSettings()
        let reason = app.staticTexts["screen-time.monitoring-error"]
        if !reveal(reason) {
            try skipIfTheLedgerBound()
            XCTFail("An unbound context must state a reason, not only grey 保存 out")
            return
        }
        XCTAssertTrue(reason.label.contains("スクリーンタイム"))
        XCTAssertTrue(reveal(text(containing: "いまは変更を保存できません")),
                      "The footer must not promise a save the controller always refuses")
        attach("Screen Time — unavailable context is explained")

        let save = app.buttons["screen-time.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 6))
        XCTAssertTrue(save.isEnabled, "保存 stays pressable so the reason can be shown")
        save.tap()
        let alert = app.alerts["設定を完了できませんでした"]
        XCTAssertTrue(alert.waitForExistence(timeout: 6))
        attach("Screen Time — save reports the unbound context")
        alert.buttons["閉じる"].tap()
        XCTAssertTrue(app.navigationBars["スクリーンタイム"].waitForExistence(timeout: 4))
    }

    /// The load-bearing half of F4: the settings screen is opened while the
    /// controller is still unbound, and the ledger admits the owner only
    /// afterwards. The shipping Simulator path can never reach it — without
    /// entitlements the App Group container is nil, so `isBoundToContext`
    /// stays false forever — hence the DEBUG-only fixture, which points ONE
    /// settings screen at a temporary-directory ledger with the authorization
    /// status stubbed and a recording double instead of DeviceActivity. The
    /// monitor extension is not involved and `ScreenTimeController.shared` is
    /// not touched.
    func testALateContextBindingSeedsTheStoredSelectionInsteadOfAnEmptyDraft() {
        app.launchEnvironment["POMOGEM_UI_TEST_SCREEN_TIME"] = "late-binding"
        app.launch()
        XCTAssertTrue(app.navigationBars["スクリーンタイム"].waitForExistence(timeout: 20))

        let ledger = app.staticTexts["screen-time.fixture-ledger"]
        XCTAssertTrue(ledger.waitForExistence(timeout: 10))
        // The ledger the fixture wrote before the screen mounted.
        for expected in ["learning=2", "distraction=1", "enabled=1", "theme=seed",
                         "matchesSeed=true", "sync=0", "boundToContext=false"] {
            XCTAssertTrue(ledger.label.contains(expected), "ledger row was \(ledger.label)")
        }

        // Unbound: the controller publishes an EMPTY configuration, so the
        // draft must show placeholders rather than the stored selection. The
        // rows are visited top to bottom, which is the direction `reveal`
        // scrolls by default.
        XCTAssertTrue(reveal(text(containing: "いまは変更を保存できません")),
                      "An unbound context must say that a save cannot complete")
        let learning = app.buttons["screen-time.learning-apps"]
        XCTAssertTrue(reveal(learning))
        XCTAssertEqual(learning.value as? String, "0アプリ選択中")
        let distraction = app.buttons["screen-time.distraction-apps"]
        XCTAssertTrue(reveal(distraction))
        XCTAssertEqual(distraction.value as? String, "0アプリ選択中")
        let total = app.staticTexts["screen-time.negative-total"]
        XCTAssertTrue(reveal(total))
        XCTAssertTrue(total.label.contains("0個ぶん"), "negative total was \(total.label)")
        attach("Screen Time — unbound draft shows placeholders")

        // A 保存 attempted from that placeholder draft must not reach the
        // ledger: it is refused, and the stored opaque selection survives.
        let save = app.buttons["screen-time.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 6))
        save.tap()
        let refusal = app.alerts["設定を完了できませんでした"]
        XCTAssertTrue(refusal.waitForExistence(timeout: 6))
        XCTAssertTrue(refusal.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "データの準備が完了して"
        )).firstMatch.exists, "\(refusal.debugDescription)")
        attach("Screen Time — an unbound save is refused")
        refusal.buttons["閉じる"].tap()
        XCTAssertTrue(ledger.label.contains("matchesSeed=true"),
                      "A refused save must leave the stored selection untouched: \(ledger.label)")

        // The ledger admits the owner while the screen is already visible.
        let bind = app.buttons["screen-time.fixture-bind"]
        XCTAssertTrue(bind.waitForExistence(timeout: 6))
        bind.tap()
        expectLedger(ledger, contains: "boundToContext=true", timeout: 20)

        // The refusal left the list at the bottom, so the footer is above.
        XCTAssertTrue(reveal(text(containing: "変更は右上の「保存」で反映します"), upwards: false),
                      "A bound context must stop warning that a save cannot complete")
        XCTAssertTrue(reveal(learning))
        XCTAssertEqual(learning.value as? String, "2アプリ選択中",
                       "The unbound -> bound transition must re-seed the draft")
        // The theme picker sits directly under the learning row.
        let theme = app.descendants(matching: .any)["screen-time.theme"].firstMatch
        XCTAssertTrue(reveal(theme))
        XCTAssertTrue("\(theme.value ?? "")\(theme.label)".contains("スクリーンタイム検証テーマ"),
                      "The re-seeded draft must carry the stored theme: \(theme.debugDescription)")
        XCTAssertTrue(reveal(distraction))
        XCTAssertEqual(distraction.value as? String, "1アプリ選択中")
        XCTAssertTrue(reveal(total))
        XCTAssertTrue(total.label.contains("3個ぶん"), "negative total was \(total.label)")
        XCTAssertTrue(total.label.contains("30分"), "negative total was \(total.label)")
        attach("Screen Time — bound draft shows the stored selection")

        // Only now may 保存 complete, and it must write the stored
        // configuration back unchanged.
        XCTAssertTrue(save.isEnabled, "保存 must become available once the context is bound")
        save.tap()
        expectLedger(ledger, contains: "sync=1", timeout: 20)
        for expected in ["learning=2", "distraction=1", "enabled=1", "theme=seed", "matchesSeed=true"] {
            XCTAssertTrue(ledger.label.contains(expected),
                          "A save from the re-seeded draft must not change the ledger: \(ledger.label)")
        }
        attach("Screen Time — save preserves the stored configuration")

        // screentime-08: the black stones alone can be cleared, keeping the
        // app choices and recording exactly as they were.
        let clear = app.buttons["screen-time.clear-black-stones"]
        XCTAssertTrue(reveal(clear))
        clear.tap()
        let confirm = app.alerts["黒い石を片付けますか？"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 6))
        attach("Screen Time — clear black stones confirmation")
        confirm.buttons["片付ける"].tap()
        XCTAssertTrue(reveal(total))
        let cleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "0個ぶん"), object: total)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 8), .completed, "total was \(total.label)")
        XCTAssertFalse(clear.exists, "Nothing left to clear")
        for expected in ["learning=2", "distraction=1", "enabled=1", "theme=seed", "matchesSeed=true"] {
            XCTAssertTrue(ledger.label.contains(expected),
                          "Clearing black stones must keep the setup: \(ledger.label)")
        }
        attach("Screen Time — black stones cleared, setup kept")
    }

    /// screentime-02 through the same DEBUG fixture, as a bound owner who has
    /// set nothing up yet. Picking apps on a first setup switches recording on
    /// (off by default, a save that kept it off recorded nothing), going back
    /// with unsaved edits asks first instead of dropping picks only Apple's
    /// picker can rebuild, and the save toast states the resulting status.
    func testFirstSetupSwitchesRecordingOnAndBackAsksBeforeDroppingEdits() {
        app.launchEnvironment["POMOGEM_UI_TEST_SCREEN_TIME"] = "first-setup"
        app.launch()
        let ledger = app.staticTexts["screen-time.fixture-ledger"]
        XCTAssertTrue(ledger.waitForExistence(timeout: 20))
        expectLedger(ledger, contains: "boundToContext=true", timeout: 20)
        XCTAssertTrue(ledger.label.contains("enabled=0"), ledger.label)
        XCTAssertTrue(ledger.label.contains("learning=0"), ledger.label)

        openFixtureSettings()
        let enabled = app.switches["screen-time.enabled"]
        XCTAssertTrue(reveal(enabled))
        XCTAssertEqual(enabled.value as? String, "0")
        XCTAssertFalse(app.buttons["screen-time.back"].exists, "Nothing to lose yet: the system back button stays")

        let learning = app.buttons["screen-time.learning-apps"]
        XCTAssertTrue(reveal(learning))
        learning.tap()
        // The fixture's two apps leave the sheet through 反映's own path the
        // moment it is tapped: Apple's picker loads seconds late on a cold
        // Simulator and drops any tokens still sitting in the sheet.
        let pick = app.buttons["screen-time.fixture-pick-apps"]
        XCTAssertTrue(pick.waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["screen-time.picker-apply"].exists)
        attach("Screen Time — app picker open")
        pick.tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: pick)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 10), .completed, "The pick must close the sheet")
        XCTAssertTrue(app.navigationBars["スクリーンタイム"].waitForExistence(timeout: 6))
        XCTAssertTrue(reveal(learning))
        XCTAssertEqual(learning.value as? String, "2アプリ選択中", "Both picked apps must reach the page")

        XCTAssertTrue(reveal(enabled))
        XCTAssertEqual(enabled.value as? String, "1", "A first pick must switch recording on")
        let theme = app.descendants(matching: .any)["screen-time.theme"].firstMatch
        XCTAssertTrue(reveal(theme))
        XCTAssertTrue("\(theme.value ?? "")\(theme.label)".contains("スクリーンタイム検証テーマ"),
                      "The only theme becomes the destination: \(theme.debugDescription)")
        XCTAssertTrue(ledger.label.contains("enabled=0"), "Nothing is saved before 保存: \(ledger.label)")
        attach("Screen Time — first pick switched recording on")

        // Unsaved: back asks, and staying keeps everything.
        let back = app.buttons["screen-time.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 6))
        back.tap()
        XCTAssertTrue(app.buttons["保存して戻る"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["変更を破棄して戻る"].exists)
        attach("Screen Time — unsaved changes question")
        keepEditing()
        XCTAssertFalse(app.buttons["変更を破棄して戻る"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.navigationBars["スクリーンタイム"].waitForExistence(timeout: 4))
        XCTAssertTrue(reveal(enabled))
        XCTAssertEqual(enabled.value as? String, "1")

        // 保存 applies it and says what it switched on. The toast lasts three
        // seconds, so look for it first: every ledger query before it can
        // take long enough on a loaded machine to miss it entirely.
        let save = app.buttons["screen-time.save"]
        XCTAssertTrue(save.isEnabled)
        let toast = text(containing: "保存しました。自動記録中です")
        save.tap()
        XCTAssertTrue(toast.waitForExistence(timeout: 20), "The toast must state the resulting status")
        attach("Screen Time — saved with recording on")
        expectLedger(ledger, contains: "enabled=1", timeout: 20)
        XCTAssertTrue(ledger.label.contains("learning=2"), ledger.label)
        XCTAssertFalse(app.buttons["screen-time.back"].waitForExistence(timeout: 2))

        // Nothing unsaved: the ordinary back button leaves at once.
        app.navigationBars["スクリーンタイム"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["fixture-root"].waitForExistence(timeout: 6))

        // Discarding really discards.
        openFixtureSettings()
        XCTAssertTrue(reveal(enabled))
        flip(enabled)
        XCTAssertEqual(enabled.value as? String, "0")
        XCTAssertTrue(back.waitForExistence(timeout: 6))
        back.tap()
        let discard = app.buttons["変更を破棄して戻る"]
        XCTAssertTrue(discard.waitForExistence(timeout: 6))
        discard.tap()
        XCTAssertTrue(app.navigationBars["fixture-root"].waitForExistence(timeout: 6))
        XCTAssertTrue(ledger.label.contains("enabled=1"), "A discarded edit must not reach the ledger: \(ledger.label)")
    }

    /// screentime-10: Home's menu reaches the Screen Time page directly, next
    /// to the other two ways to add to the jar, and back returns to Home.
    func testTheHomeMenuOpensScreenTimeDirectly() {
        app.launch()
        let entry = openHomeMenuEntry()
        attach("Home menu — Screen Time entry")
        entry.tap()
        XCTAssertTrue(app.navigationBars["スクリーンタイム"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["screen-time.authorization-status"].waitForExistence(timeout: 6))
        attach("Screen Time opened from the Home menu")
        app.navigationBars["スクリーンタイム"].buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 8), "Back returns to Home")
    }

    /// critic-02: a refused request names its own fix, and the shortcut says
    /// where it lands: the only public link opens PomoGem's own page in the
    /// Settings app, below the first screen the message starts from. The
    /// fixture stubs Family Controls to refuse for want of a passcode; the
    /// Simulator cannot produce a refusal itself.
    func testARefusedAccessRequestSaysWhereTheSettingsShortcutLands() {
        checkRefusedAccessRequest(accessibility5: false)
    }

    func testARefusedAccessRequestStaysReadableAtAccessibilitySize() {
        checkRefusedAccessRequest(accessibility5: true)
    }

    private func checkRefusedAccessRequest(accessibility5: Bool) {
        if accessibility5 { app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1" }
        app.launchEnvironment["POMOGEM_UI_TEST_SCREEN_TIME"] = "authorization-refused"
        app.launch()
        let ledger = app.staticTexts["screen-time.fixture-ledger"]
        XCTAssertTrue(ledger.waitForExistence(timeout: 12))
        expectLedger(ledger, contains: "boundToContext=true", timeout: 20)
        let authorize = app.buttons["screen-time.authorize"]
        XCTAssertTrue(revealAboveFixtureBar(authorize))
        authorize.tap()
        let failure = app.staticTexts["screen-time.authorization-failure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 8))
        XCTAssertTrue(failure.label.contains("設定アプリの最初の画面にある「Face IDとパスコード」"), failure.label)
        let open = app.buttons["screen-time.open-settings-app"]
        XCTAssertTrue(revealAboveFixtureBar(open))
        XCTAssertGreaterThanOrEqual(open.frame.height, 43.5)
        let route = app.staticTexts["screen-time.open-settings-app-route"]
        XCTAssertTrue(revealAboveFixtureBar(route))
        XCTAssertTrue(route.label.contains("ポモジェムの設定ページ"), route.label)
        XCTAssertTrue(route.label.contains("設定の最初の画面まで戻って"), route.label)
        attach(accessibility5
               ? "Screen Time AX5 — refused access and where the Settings shortcut lands"
               : "Screen Time — refused access and where the Settings shortcut lands")
    }

    /// `reveal` treats anything above the window's bottom inset as on screen,
    /// but the fixture's ledger bar covers the bottom of the page; lift an
    /// element that is only hidden under it.
    private func revealAboveFixtureBar(_ element: XCUIElement) -> Bool {
        for _ in 0..<6 {
            if reveal(element) { return true }
            let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -120)))
        }
        return false
    }

    /// The same row at the largest text size: reachable, a full-size target,
    /// and still saying which apps count.
    func testTheHomeMenuEntryStaysReachableAtAccessibilitySize() {
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1"
        app.launch()
        let entry = openHomeMenuEntry()
        XCTAssertGreaterThanOrEqual(entry.frame.height, 43.5)
        attach("Home menu AX5 — Screen Time entry")
        entry.tap()
        XCTAssertTrue(app.navigationBars["スクリーンタイム"].waitForExistence(timeout: 8))
    }

    private func openHomeMenuEntry() -> XCUIElement {
        let menu = app.buttons["メニュー"]
        XCTAssertTrue(menu.waitForExistence(timeout: 12))
        menu.tap()
        let entry = app.buttons["home.menu.screen-time"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        XCTAssertTrue(reveal(entry))
        XCTAssertTrue(entry.label.contains("アプリの時間を積む"), entry.label)
        XCTAssertTrue(entry.label.contains("勉強アプリ10分ごとに1粒"), "The detail names the apps that count: \(entry.label)")
        return entry
    }

    /// `screen-time.enabled` is the whole row; a tap on its centre lands on
    /// the label and changes nothing, so aim at the switch itself.
    private func flip(_ toggle: XCUIElement) {
        let inner = toggle.switches.firstMatch
        if inner.exists && inner.isHittable {
            inner.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
    }

    /// iOS 26 shows the question as a popover on the back button, whose
    /// cancel is a tap outside rather than a button; older layouts show one.
    private func keepEditing() {
        let cancel = app.buttons["編集を続ける"]
        if cancel.exists && cancel.isHittable {
            cancel.tap()
            return
        }
        let outside = app.otherElements["PopoverDismissRegion"]
        if outside.exists {
            outside.tap()
        } else {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        }
    }

    private func openFixtureSettings() {
        let open = app.descendants(matching: .any)["screen-time.fixture-open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(app.navigationBars["スクリーンタイム"].waitForExistence(timeout: 8))
    }

    private func expectLedger(_ ledger: XCUIElement, contains fragment: String, timeout: TimeInterval) {
        let matched = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", fragment), object: ledger)
        guard XCTWaiter.wait(for: [matched], timeout: timeout) == .completed else {
            XCTFail("ledger row never reported \(fragment); last value: \(ledger.label)")
            return
        }
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
        let entry = app.descendants(matching: .any)["settings.screen-time"].firstMatch
        XCTAssertTrue(reveal(entry))
        entry.tap()
        XCTAssertTrue(app.navigationBars["スクリーンタイム"].waitForExistence(timeout: 6))
    }

    private func assertAuthorizationHasNotBeenInvented() {
        let status = app.staticTexts["screen-time.authorization-status"]
        XCTAssertTrue(reveal(status))
        XCTAssertTrue(status.label.contains("許可が必要"))
        let authorize = app.buttons["screen-time.authorize"]
        XCTAssertTrue(reveal(authorize))
        XCTAssertTrue(authorize.isEnabled)
        // Do not tap: Simulator UI is no proof of real-device authorization.
        let enabled = app.switches["screen-time.enabled"]
        XCTAssertTrue(reveal(enabled))
        XCTAssertFalse(enabled.isEnabled)
        XCTAssertEqual(enabled.value as? String, "0")
        XCTAssertFalse(app.staticTexts["自動記録中"].exists)
    }

    private func assertResetConfirmationCanBeCancelled() {
        let reset = app.buttons["screen-time.reset"]
        XCTAssertTrue(reveal(reset))
        XCTAssertGreaterThanOrEqual(reset.frame.height, 43.5)
        reset.tap()
        let alert = app.alerts["スクリーンタイムの内容をリセット"]
        XCTAssertTrue(alert.waitForExistence(timeout: 4))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "保存済みの勉強時間と粒は残ります"
        )).firstMatch.exists)
        XCTAssertTrue(alert.buttons["リセット"].exists)
        attach("Screen Time — explicit local reset confirmation")
        alert.buttons["キャンセル"].tap()
        XCTAssertFalse(alert.exists)
        XCTAssertTrue(app.navigationBars["スクリーンタイム"].exists)
    }

    /// The footer the settings screen shows once the ledger IS bound. It is
    /// the only positive, on-screen evidence this suite can read that the App
    /// Group container resolved, so the skip below never hides a real
    /// regression in the unbound explanation — it fires only when the opposite
    /// state is actually on screen.
    private static let boundFooter = "変更は右上の「保存」で反映します"

    private func skipIfTheLedgerBound() throws {
        // A failed `reveal` leaves the list scrolled to the bottom and this
        // footer sits above the reset section, so look upwards first.
        let footer = text(containing: Self.boundFooter)
        guard reveal(footer, upwards: false) || reveal(footer) else { return }
        attach("Screen Time — the ledger bound, so the unavailable case is unreachable")
        throw XCTSkip(
            "This build's App Group container resolves, so the Screen Time ledger binds and the "
            + "unavailable-context case cannot be reached at all. The premise holds only for a "
            + "build with no entitlements: pass CODE_SIGNING_ALLOWED=NO, as CI does "
            + "(.github/workflows/ci.yml)."
        )
    }

    private func text(containing fragment: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    @discardableResult
    private func reveal(_ element: XCUIElement, upwards: Bool = true) -> Bool {
        for _ in 0..<16 {
            if element.exists {
                let top = app.navigationBars.allElementsBoundByIndex
                    .filter(\.isHittable).map(\.frame.maxY).max() ?? 0
                let bottom = app.windows.firstMatch.frame.maxY - 36
                let frame = element.frame
                if frame.height > 0 && frame.width > 0 {
                    if frame.minY >= top && frame.maxY <= bottom {
                        // Disabled controls still need to be visibly explained;
                        // the test never attempts to tap those controls.
                        return element.isHittable || !element.isEnabled
                    }
                    if frame.maxY <= top {
                        app.swipeDown(velocity: .fast)
                        continue
                    }
                    if frame.minY >= bottom {
                        app.swipeUp(velocity: .fast)
                        continue
                    }
                    if frame.height > bottom - top && element.isHittable {
                        return true
                    }
                }
                // Small corrections keep a tall AX5 row from being skipped by
                // alternating full-screen swipes near a viewport edge.
                let correction = frame.minY < top
                    ? top - frame.minY + 12 : bottom - frame.maxY - 12
                let distance = min(160, max(60, abs(correction))) * (correction < 0 ? -1 : 1)
                let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)))
            } else if upwards {
                app.swipeUp(velocity: .fast)
            } else {
                app.swipeDown(velocity: .fast)
            }
        }
        return element.exists && element.isHittable
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

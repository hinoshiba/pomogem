import UIKit
import XCTest

/// The first minutes of a new install: the storage choice every new user
/// sees first, then onboarding. Each screen is rendered by an explicit
/// Debug-only fixture or the in-memory UI-test store, so no storage mode is
/// recorded and no account or CloudKit call is made.
@MainActor
final class FirstRunUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Storage choice (launch-03 / product-01)

    func testStorageChoiceLeadsWithTheBrandAndOffersTwoEqualOptions() {
        launchStorageChoice()

        XCTAssertTrue(app.staticTexts["記録の保存先を選んでください"].waitForExistence(timeout: 4),
                      "The question must be neutral, not a yes/no about iCloud")
        XCTAssertFalse(app.staticTexts["iCloud同期を有効にしますか？"].exists)
        XCTAssertTrue(element(labelled: "ポモジェム").exists, "The first screen must carry the brand")
        let value = app.staticTexts["storage-choice.value"]
        XCTAssertTrue(value.exists)
        XCTAssertEqual(value.label, "集中した時間が、粒になって瓶にたまっていきます。")

        let cloud = app.buttons["iCloudに保存して同期"]
        let local = app.buttons["このiPhoneだけに保存"]
        XCTAssertTrue(cloud.waitForExistence(timeout: 4))
        XCTAssertTrue(local.exists)
        XCTAssertEqual(cloud.identifier, "storage-choice.cloud")
        XCTAssertEqual(local.identifier, "storage-choice.local")
        XCTAssertTrue(cloud.isHittable)
        XCTAssertTrue(local.isHittable)
        // configuration.yml `equal_neither_recommended`: the same shape at
        // the same width, one line each, and neither drawn as the default.
        XCTAssertEqual(cloud.frame.width, local.frame.width, accuracy: 0.5)
        XCTAssertEqual(cloud.frame.height, local.frame.height, accuracy: 20)
        XCTAssertFalse(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "おすすめ")).firstMatch.exists)
        XCTAssertGreaterThanOrEqual(cloud.frame.height, 44)
        XCTAssertGreaterThanOrEqual(local.frame.height, 44)
        attachScreenshot("storage-choice-default")
    }

    func testEachStorageOptionStillCommitsOnlyThroughItsOwnConfirmation() {
        launchStorageChoice()
        let cloud = app.buttons["iCloudに保存して同期"]
        let local = app.buttons["このiPhoneだけに保存"]
        XCTAssertTrue(cloud.waitForExistence(timeout: 4))

        cloud.tap()
        let cloudAlert = app.alerts["iCloudに保存して同期しますか？"]
        XCTAssertTrue(cloudAlert.waitForExistence(timeout: 4))
        XCTAssertTrue(alertMessage(cloudAlert, contains: "プライベートiCloudへ送信します"))
        XCTAssertTrue(cloudAlert.buttons["確認して続ける"].exists)
        attachScreenshot("storage-choice-cloud-confirmation")
        cloudAlert.buttons["キャンセル"].tap()
        XCTAssertTrue(waitForFixtureState("cloud=0;local=0"))

        local.tap()
        let localAlert = app.alerts["このiPhoneだけに保存しますか？"]
        XCTAssertTrue(localAlert.waitForExistence(timeout: 4))
        XCTAssertTrue(alertMessage(localAlert, contains: "アプリを削除すると"))
        // launch-04: the confirmation that commits local-only says plainly
        // that a later switch to iCloud replaces this iPhone's records.
        XCTAssertTrue(alertMessage(localAlert, contains: "このiPhoneの記録はiCloudの記録に置き換わります"))
        XCTAssertFalse(alertMessage(localAlert, contains: "後で設定から"))
        attachScreenshot("storage-choice-local-confirmation")
        localAlert.buttons["キャンセル"].tap()
        XCTAssertTrue(waitForFixtureState("cloud=0;local=0"),
                      "Reading either option must not choose it")

        local.tap()
        XCTAssertTrue(localAlert.waitForExistence(timeout: 4))
        localAlert.buttons["このiPhoneだけで始める"].tap()
        XCTAssertTrue(waitForFixtureState("cloud=0;local=1"))

        cloud.tap()
        XCTAssertTrue(cloudAlert.waitForExistence(timeout: 4))
        cloudAlert.buttons["確認して続ける"].tap()
        XCTAssertTrue(waitForFixtureState("cloud=1;local=1"))
    }

    func testStorageChoiceStaysReachableAtTheLargestTextSize() {
        launchStorageChoice(accessibility5: true)
        let title = app.staticTexts["記録の保存先を選んでください"]
        XCTAssertTrue(title.waitForExistence(timeout: 4))
        attachScreenshot("storage-choice-ax5-top")
        for label in ["iCloudに保存して同期", "このiPhoneだけに保存"] {
            let option = app.buttons[label]
            XCTAssertTrue(option.waitForExistence(timeout: 4))
            XCTAssertTrue(scrollUntilHittable(option), "\(label) must be reachable at AX5")
            XCTAssertEqual(option.label, label)
        }
        attachScreenshot("storage-choice-ax5-options")
        app.buttons["このiPhoneだけに保存"].tap()
        let localAlert = app.alerts["このiPhoneだけに保存しますか？"]
        XCTAssertTrue(localAlert.waitForExistence(timeout: 4))
        localAlert.buttons["キャンセル"].tap()
        XCTAssertTrue(waitForFixtureState("cloud=0;local=0"))
    }

    // MARK: - Onboarding (launch-07)

    func testTypedThemeNameOpensTheJarWithoutTappingSelect() {
        launchOnboarding()
        let next = app.buttons["onboarding.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 8))
        next.tap()
        XCTAssertTrue(waitUntilEnabled(next))
        next.tap()
        XCTAssertTrue(app.staticTexts["最初のテーマを選ぶ"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts.containing(
            NSPredicate(format: "label BEGINSWITH %@", "新しく追加できるのはあと")).firstMatch.exists,
            "A one-theme step must not show a quota line")

        let english = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "英語")).firstMatch
        XCTAssertTrue(english.waitForExistence(timeout: 4))
        english.tap()
        let summary = app.descendants(matching: .any)["onboarding.selection-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 4))
        XCTAssertTrue(summary.label.contains("英語"))

        let field = app.textFields.firstMatch
        XCTAssertTrue(scrollUntilHittable(field))
        field.tap()
        field.typeText("TOEIC")
        // Neither 「選択」 nor Return: the typed name is what the user means.
        XCTAssertTrue(waitForLabel(summary, containing: "TOEIC"),
                      "The summary must name the typed theme, not the earlier chip")
        // The suggestion grid is lazy: on a small screen the chip may have
        // scrolled out of the hierarchy while the field is in view.
        if english.exists {
            XCTAssertEqual(english.value as? String, "未選択",
                           "Only the theme the button will create looks chosen")
        }
        attachScreenshot("onboarding-typed-theme")
        let finish = app.buttons["瓶をひらく"]
        XCTAssertTrue(finish.isEnabled)
        finish.tap()

        let picker = app.buttons["home.subject-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForLabel(picker, containing: "TOEIC"),
                      "Opening the jar must create the typed theme, not the chip tapped before typing")
    }

    func testTypedThemeNameAloneEnablesOpeningTheJar() {
        launchOnboarding()
        let next = app.buttons["onboarding.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 8))
        next.tap()
        XCTAssertTrue(waitUntilEnabled(next))
        next.tap()
        let finish = app.buttons["瓶をひらく"]
        XCTAssertTrue(finish.waitForExistence(timeout: 4))
        XCTAssertFalse(finish.isEnabled)
        let field = app.textFields.firstMatch
        XCTAssertTrue(scrollUntilHittable(field))
        field.tap()
        field.typeText("簿記2級")
        XCTAssertTrue(waitUntilEnabled(finish), "A valid typed name is a chosen theme")
        finish.tap()
        let picker = app.buttons["home.subject-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForLabel(picker, containing: "簿記2級"))
    }

    // MARK: - Onboarding at the largest text size (walk-edge-04 / walk-edge-10)

    func testOnboardingAtAX5KeepsEachPagesPointAboveThePinnedButton() {
        launchOnboarding(accessibility5: true)
        let next = app.buttons["onboarding.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 8))
        let step = app.descendants(matching: .any)["onboarding.step"]
        XCTAssertEqual(step.label, "全3ページ中、1ページ。集中が残るしくみ")
        let headline = app.staticTexts["onboarding.value-headline"]
        XCTAssertTrue(headline.waitForExistence(timeout: 4))
        XCTAssertTrue(headline.isHittable)
        XCTAssertLessThanOrEqual(headline.frame.maxY, next.frame.minY,
                                 "The promise must be on the first screen, not below the fold")
        attachScreenshot("onboarding-ax5-page1")
        next.tap()

        let back = app.buttons["onboarding.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 4))
        XCTAssertEqual(back.label, "戻る")
        XCTAssertTrue(back.isHittable)
        XCTAssertGreaterThanOrEqual(back.frame.height, 44)
        XCTAssertGreaterThanOrEqual(back.frame.width, 44)
        XCTAssertLessThanOrEqual(back.frame.height, 100, "The pinned header must not grow into the page")
        XCTAssertEqual(step.label, "全3ページ中、2ページ。一粒を体験（任意）")
        attachScreenshot("onboarding-ax5-page2")
        XCTAssertTrue(waitUntilEnabled(next))
        next.tap()

        let heading = app.staticTexts["最初のテーマを選ぶ"]
        XCTAssertTrue(heading.waitForExistence(timeout: 4))
        XCTAssertLessThanOrEqual(heading.frame.maxY, next.frame.minY,
                                 "The page heading must not be cut by the pinned button")
        XCTAssertEqual(step.label, "全3ページ中、3ページ。最初のテーマ")
        attachScreenshot("onboarding-ax5-page3")
        let english = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "英語")).firstMatch
        XCTAssertTrue(scrollUntilHittable(english))
        english.tap()
        let summary = app.descendants(matching: .any)["onboarding.selection-summary"]
        XCTAssertTrue(waitForLabel(summary, containing: "英語"),
                      "At AX sizes the theme summary lives in the page")
        XCTAssertTrue(waitUntilEnabled(next))
        next.tap()
        XCTAssertTrue(app.buttons["home.subject-picker"].waitForExistence(timeout: 8))
    }

    // MARK: - Trial drop (walk-std-12)

    func testTrialDropSaysWhatTheGemStandsFor() {
        launchOnboarding()
        let next = app.buttons["onboarding.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 8))
        next.tap()
        let trialDrop = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "ためしに一粒")).firstMatch
        XCTAssertTrue(trialDrop.waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["onboarding.trial-meaning"].exists)
        trialDrop.tap()
        let meaning = app.staticTexts["onboarding.trial-meaning"]
        XCTAssertTrue(meaning.waitForExistence(timeout: 4), "The landing must be explained")
        XCTAssertEqual(meaning.label, "25分の集中を終えると、こんな一粒（250g）が瓶に残ります。")
        attachScreenshot("onboarding-trial-landed")
        XCTAssertTrue(waitUntilEnabled(next))
    }

    // MARK: - Helpers

    private func launchOnboarding(accessibility5: Bool = false, extraEnvironment: [String: String] = [:]) {
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_RARE_REWARD_UNSELECTED"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_RARE_REWARD_ONBOARDING"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = accessibility5 ? "1" : "0"
        for (key, value) in extraEnvironment { app.launchEnvironment[key] = value }
        app.launchArguments += ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval = 4) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String,
                              timeout: TimeInterval = 4) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func launchStorageChoice(accessibility5: Bool = false) {
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_STORAGE_TRANSFER"] = "firstRunStorageChoice"
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = accessibility5 ? "1" : "0"
        app.launchArguments += ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        XCTAssertTrue(app.staticTexts["storage-choice.fixture-state"].waitForExistence(timeout: 12),
                      "The explicit Debug-only fixture must be selected")
    }

    private func waitForFixtureState(_ expected: String, timeout: TimeInterval = 4) -> Bool {
        let state = app.staticTexts["storage-choice.fixture-state"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state.exists, state.label == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return state.exists && state.label == expected
    }

    private func alertMessage(_ alert: XCUIElement, contains text: String) -> Bool {
        alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
    }

    private func element(labelled label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func scrollUntilHittable(_ element: XCUIElement, attempts: Int = 12) -> Bool {
        for _ in 0 ..< attempts {
            if element.exists, element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    /// Kept on success too: these screens are reviewed by eye in the PR.
    /// Optionally also written to `POMOGEM_SHOTS_DIR` (set through
    /// `TEST_RUNNER_POMOGEM_SHOTS_DIR`) for a local review folder.
    private func attachScreenshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["POMOGEM_SHOTS_DIR"], !directory.isEmpty {
            let device = UIDevice.current.name.replacingOccurrences(of: " ", with: "_")
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(device)-\(name).png")
            try? screenshot.pngRepresentation.write(to: url)
        }
    }
}

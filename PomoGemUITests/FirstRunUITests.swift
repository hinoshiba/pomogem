import UIKit
import XCTest

/// The first minutes of a new install: the storage choice every new user
/// sees first. Each screen is rendered by an explicit Debug-only fixture, so
/// no storage mode is recorded and no account or CloudKit call is made.
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

    // MARK: - Helpers

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

import XCTest

/// F1's two Settings rows in the product-default configuration (the leave
/// pause on). 「集中が切れたらお知らせ」 exists only while
/// 「アプリを離れたら一時停止」 is on, and 集中に戻るお知らせ is shown only
/// while it is off, so the two notices never contradict. Every UI-test
/// process starts from its own default (`FocusLeavePreferences`), so the
/// switches flipped here never leak into another suite on the same Simulator.
///
/// Every test reads this iPhone's notification permission as never asked
/// (`POMOGEM_UI_TEST_NOTIFICATIONS_UNASKED`), as on a new iPhone, and a test
/// that asks fixes iOS's answer (`POMOGEM_UI_TEST_NOTIFICATIONS_ANSWER`), so
/// neither branch depends on what the shared Simulator answered before.
@MainActor
final class FocusLeaveSettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    /// The older 集中に戻るお知らせ opt-in. Someone who turned it on chose to
    /// be told when they drift, so the series counts as chosen for them.
    private let returnReminderKey = "notifications.focus-return-reminder.enabled"
    private let unaskedNotice = "オンにしている通知は、このiPhoneではまだ許可されていないため届きません"
    private let deniedNotice = "オンにしている通知は、このiPhoneの設定でオフになっているため届きません"

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 600

        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_FOCUS_LEAVE_PAUSE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_NOTIFICATIONS_UNASKED"] = "1"
    }

    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0, let app {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Leave pause Settings accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app?.terminate()
        app = nil
    }

    /// The product default for someone who never touched either switch: both
    /// on, and no permission notice with a call to action under a switch they
    /// did not choose. The footer says plainly that nothing arrives without
    /// permission. An ON the person makes then goes through the permission
    /// request (answered "granted" here).
    func testTheLeavePauseRowsSwapWithTheReturnReminderAndKeepTheirChoice() throws {
        launch(permissionAnswer: "granted")
        openSettings()

        let leavePause = app.switches["settings.focus-leave-pause"]
        let nudges = app.switches["settings.focus-leave-nudges"]
        let permission = element("settings.focus-leave-nudges-permission")
        let returnReminder = app.switches["settings.focus-return-reminder"]
        let liveActivity = app.switches["settings.live-activity"]
        let behavior = element("settings.focus-leave-footer.behavior")
        let resume = element("settings.focus-leave-footer.resume")
        let nudgesFooter = element("settings.focus-leave-footer.nudges")

        // Product default: both on, the older reminder superseded.
        XCTAssertTrue(scrollUntilHittable(leavePause, attempts: 12))
        XCTAssertTrue(leavePause.label.contains("アプリを離れたら一時停止"), leavePause.label)
        XCTAssertEqual(leavePause.value as? String, "1")
        XCTAssertTrue(nudges.waitForExistence(timeout: 3))
        XCTAssertTrue(nudges.label.contains("集中が切れたらお知らせ"), nudges.label)
        XCTAssertTrue(nudges.label.contains("離れてから20分までに最大5回"), nudges.label)
        XCTAssertEqual(nudges.value as? String, "1")
        XCTAssertGreaterThan(nudges.frame.minY, leavePause.frame.minY)
        // Settings has read "not asked" by now (the chosen-ON test shows the
        // notice within this time), yet the default alone raises nothing.
        XCTAssertFalse(permission.waitForExistence(timeout: 4),
                       "No permission call to action under a switch the person never turned on")

        XCTAssertTrue(reveal(behavior))
        XCTAssertTrue(behavior.label.contains("20秒以内に戻れば止まりません"), behavior.label)
        XCTAssertTrue(
            behavior.label.contains("パスコードを設定しているiPhoneでは、画面をロックしても、通常はタイマーが進みます"),
            behavior.label
        )
        XCTAssertTrue(
            behavior.label.contains("ロックを解除した直後にまたロックすると一時停止したり"),
            "The lock promise must carry the limits of the lock detection: \(behavior.label)"
        )
        XCTAssertTrue(
            behavior.label.contains("パスコードがないiPhoneでは、ロックとアプリの切り替えを区別できないため、画面ロックでも一時停止します"),
            behavior.label
        )
        XCTAssertTrue(reveal(resume))
        XCTAssertTrue(resume.label.contains("自動では再開しません"), resume.label)
        XCTAssertTrue(resume.label.contains("「再開する」をタップすると"), resume.label)
        XCTAssertTrue(reveal(nudgesFooter))
        XCTAssertTrue(nudgesFooter.label.contains("このiPhoneで通知を許可していない場合は届きません"),
                      nudgesFooter.label)
        XCTAssertTrue(nudgesFooter.label.contains("「集中に戻るお知らせ」の代わりに"), nudgesFooter.label)

        XCTAssertTrue(scrollUntilHittable(liveActivity, attempts: 6))
        XCTAssertFalse(returnReminder.exists, "Superseded while the leave pause is on")
        XCTAssertFalse(element("settings.focus-return-permission").exists)
        let liveActivityFooter = element("settings.live-activity-footer")
        XCTAssertTrue(scrollUntilHittable(liveActivityFooter, attempts: 4))
        XCTAssertTrue(liveActivityFooter.label.contains("「アプリを離れたら一時停止」の設定に従います"),
                      liveActivityFooter.label)
        XCTAssertFalse(text(containing: "タイマーはバックグラウンドでも止まりません").exists,
                       "That promise is false while the leave pause is on")
        XCTAssertFalse(text(containing: "30秒後に一度通知し").exists)
        retainScreenshot(named: "Settings — leave pause on (product default)")
        try auditLeavePauseRows(named: "Settings — Live Activity footer")

        // Apple's audits with the feature's rows and footers on screen.
        XCTAssertTrue(reveal(leavePause, swipingDown: true))
        try auditLeavePauseRows(named: "Settings — leave pause on, rows", includingDynamicType: true)
        XCTAssertTrue(reveal(nudgesFooter))
        try auditLeavePauseRows(named: "Settings — leave pause on, footers")

        // The series off: nothing is left under it.
        XCTAssertTrue(reveal(nudges, swipingDown: true))
        XCTAssertTrue(toggle(nudges, to: "0"))
        XCTAssertFalse(permission.exists)

        // The leave pause off: 集中に戻るお知らせ is back, exactly as before.
        XCTAssertTrue(reveal(leavePause, swipingDown: true))
        XCTAssertTrue(toggle(leavePause, to: "0"))
        XCTAssertTrue(waitForAbsence(nudges, timeout: 3), "The series exists only with the leave pause")
        XCTAssertTrue(waitForAbsence(nudgesFooter, timeout: 3))
        XCTAssertTrue(behavior.exists, "The footer says what happens with the switch off as well")
        XCTAssertTrue(resume.exists)
        XCTAssertTrue(resume.label.contains("オフのときは、アプリを離れてもタイマーは止まりません"), resume.label)
        XCTAssertTrue(scrollUntilHittable(returnReminder, attempts: 6))
        XCTAssertEqual(returnReminder.value as? String, "0", "Its own choice is untouched")
        XCTAssertTrue(scrollUntilHittable(text(containing: "30秒後に一度通知し"), attempts: 4))
        retainScreenshot(named: "Settings — leave pause off, return reminder back")

        // Back on: the series keeps the explicit off chosen above.
        XCTAssertTrue(reveal(leavePause, swipingDown: true))
        XCTAssertTrue(toggle(leavePause, to: "1"))
        XCTAssertTrue(nudges.waitForExistence(timeout: 3))
        XCTAssertEqual(nudges.value as? String, "0")
        XCTAssertTrue(waitForAbsence(returnReminder, timeout: 3))
        XCTAssertTrue(reveal(nudges))

        // Turning the series on asks for this iPhone's permission, like every
        // notification switch. This process reads "not asked" until it asks
        // and the ask is answered "granted": the switch is saved ON and no
        // notice follows. Had the ON been saved without asking, the status
        // would still read "not asked" and the chosen ON would show the notice.
        settle(nudges)
        tapSwitch(nudges)
        XCTAssertTrue(waitForSwitch(nudges, value: "1", timeout: 8))
        XCTAssertFalse(app.alerts["通知を設定できませんでした"].waitForExistence(timeout: 2))
        XCTAssertFalse(permission.waitForExistence(timeout: 3),
                       "The ON went through the permission request, which was granted")

        // Settings reads the choices back when it opens again.
        let back = app.navigationBars["設定"].buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        back.tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 6))
        openSettings()
        XCTAssertTrue(scrollUntilHittable(leavePause, attempts: 12))
        XCTAssertEqual(leavePause.value as? String, "1")
        XCTAssertTrue(nudges.waitForExistence(timeout: 3))
        XCTAssertEqual(nudges.value as? String, "1")
        XCTAssertFalse(returnReminder.exists)
    }

    /// Someone who chose the series (here through the older 集中に戻るお知らせ
    /// opt-in) and whose iPhone never allowed notifications is told so right
    /// under the switch, with the one step that fixes it. A refused ask then
    /// leads to iOS Settings, and a refused ON saves nothing.
    func testAChosenSeriesWithoutPermissionSaysSoAndARefusedOnSavesNothing() throws {
        launch(permissionAnswer: "refused", arguments: ["-\(returnReminderKey)", "YES"])
        openSettings()

        let leavePause = app.switches["settings.focus-leave-pause"]
        let nudges = app.switches["settings.focus-leave-nudges"]
        let permission = element("settings.focus-leave-nudges-permission")
        let permissionAction = app.buttons["settings.focus-leave-nudges-permission.action"]
        let behavior = element("settings.focus-leave-footer.behavior")
        let nudgesFooter = element("settings.focus-leave-footer.nudges")
        let liveActivity = app.switches["settings.live-activity"]

        XCTAssertTrue(scrollUntilHittable(leavePause, attempts: 12))
        XCTAssertEqual(leavePause.value as? String, "1")
        XCTAssertTrue(nudges.waitForExistence(timeout: 3))
        XCTAssertEqual(nudges.value as? String, "1")
        XCTAssertTrue(permission.waitForExistence(timeout: 6),
                      "A series the person chose that cannot arrive here must say so")
        XCTAssertTrue(reveal(permissionAction))
        XCTAssertTrue(permission.label.contains(unaskedNotice), permission.label)
        XCTAssertEqual(permissionAction.label, "許可する")
        XCTAssertFalse(app.alerts["通知を設定できませんでした"].exists,
                       "Opening Settings must not raise an unprompted permission error")

        // Directly under the series and inside the leave-pause card: above
        // the card's footer, which sits above the Live Activity card.
        assertAbove(nudges, permission, "The notice sits under the switch it is about")
        assertAbove(permissionAction, behavior, "The notice stays inside the leave-pause card")
        assertAbove(nudgesFooter, liveActivity, "The Live Activity card follows the leave-pause card")
        retainScreenshot(named: "Settings — chosen series, not yet allowed on this iPhone")

        XCTAssertTrue(reveal(nudges, swipingDown: true))
        try auditLeavePauseRows(
            named: "Settings — chosen series without permission",
            includingDynamicType: true
        )

        // Asking is refused: the notice now leads to iOS Settings.
        XCTAssertTrue(reveal(permissionAction))
        permissionAction.tap()
        XCTAssertTrue(waitForLabel(of: permission, containing: deniedNotice, timeout: 6), permission.label)
        XCTAssertEqual(permissionAction.label, "設定を開く")
        XCTAssertFalse(app.alerts["通知を設定できませんでした"].waitForExistence(timeout: 2))
        XCTAssertEqual(nudges.value as? String, "1", "A refused ask never switches the choice off")
        retainScreenshot(named: "Settings — chosen series, refused on this iPhone")

        // Off: the notice goes with the switch.
        XCTAssertTrue(reveal(nudges, swipingDown: true))
        XCTAssertTrue(toggle(nudges, to: "0"))
        XCTAssertTrue(waitForAbsence(permission, timeout: 3))

        // On again: the ask is refused, the alert leads to Settings, and the
        // switch stays off with nothing saved.
        XCTAssertTrue(reveal(nudges))
        settle(nudges)
        tapSwitch(nudges)
        let permissionError = app.alerts["通知を設定できませんでした"]
        XCTAssertTrue(permissionError.waitForExistence(timeout: 6), "A refused ON must say why")
        XCTAssertTrue(permissionError.buttons["設定を開く"].exists)
        retainScreenshot(named: "Settings — refused ON offers iOS Settings")
        permissionError.buttons["閉じる"].tap()
        XCTAssertTrue(waitForSwitch(nudges, value: "0", timeout: 4), "A refused ON must save nothing")
        XCTAssertFalse(permission.exists)

        let back = app.navigationBars["設定"].buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        back.tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 6))
        openSettings()
        XCTAssertTrue(scrollUntilHittable(leavePause, attempts: 12))
        XCTAssertTrue(nudges.waitForExistence(timeout: 3))
        XCTAssertEqual(nudges.value as? String, "0", "The refused ON left the explicit off in place")
    }

    /// The largest text size with everything the leave pause can show at
    /// once: both switches, the three footer paragraphs and the permission
    /// notice. Each must be reachable and whole.
    func testAX5LeavePauseRowsFootersAndNoticeStayReachableAndUnclipped() throws {
        launch(accessibility5: true, arguments: ["-\(returnReminderKey)", "YES"])
        openSettings()

        let leavePause = app.switches["settings.focus-leave-pause"]
        let nudges = app.switches["settings.focus-leave-nudges"]
        let permission = element("settings.focus-leave-nudges-permission")
        let permissionAction = app.buttons["settings.focus-leave-nudges-permission.action"]
        let behavior = element("settings.focus-leave-footer.behavior")
        let resume = element("settings.focus-leave-footer.resume")
        let nudgesFooter = element("settings.focus-leave-footer.nudges")
        let liveActivity = app.switches["settings.live-activity"]

        XCTAssertTrue(reveal(leavePause))
        XCTAssertEqual(leavePause.value as? String, "1")
        XCTAssertTrue(leavePause.isHittable)
        retainScreenshot(named: "AX5 Settings — leave pause")
        try auditLeavePauseRows(named: "AX5 Settings — leave pause")

        assertAbove(leavePause, nudges, "The series sits under the leave pause")
        XCTAssertTrue(reveal(nudges))
        XCTAssertTrue(nudges.isHittable)
        XCTAssertEqual(nudges.value as? String, "1")
        XCTAssertTrue(nudges.label.contains("離れてから20分までに最大5回"), nudges.label)
        retainScreenshot(named: "AX5 Settings — series")
        try auditLeavePauseRows(named: "AX5 Settings — series")

        assertAbove(nudges, permission, "The notice sits under the switch it is about")
        XCTAssertTrue(reveal(permission))
        XCTAssertTrue(permission.label.contains(unaskedNotice), permission.label)
        XCTAssertTrue(reveal(permissionAction))
        XCTAssertTrue(permissionAction.isHittable)
        XCTAssertGreaterThanOrEqual(permissionAction.frame.height, 43.5)
        retainScreenshot(named: "AX5 Settings — permission notice")
        try auditLeavePauseRows(named: "AX5 Settings — permission notice")

        assertAbove(permissionAction, behavior, "The notice stays inside the leave-pause card")
        for (name, footer) in [("behavior", behavior), ("resume", resume), ("series", nudgesFooter)] {
            XCTAssertTrue(reveal(footer), "AX5 footer \(name) must be reachable")
            retainScreenshot(named: "AX5 Settings — footer \(name)")
            try auditLeavePauseRows(named: "AX5 Settings — footer \(name)")
        }
        XCTAssertTrue(behavior.label.contains("通常はタイマーが進みます"), behavior.label)
        assertAbove(nudgesFooter, liveActivity, "The Live Activity card follows the leave-pause card")
    }

    // MARK: - Helpers

    private func launch(
        permissionAnswer: String? = nil,
        accessibility5: Bool = false,
        arguments: [String] = []
    ) {
        if let permissionAnswer {
            app.launchEnvironment["POMOGEM_UI_TEST_NOTIFICATIONS_ANSWER"] = permissionAnswer
        }
        if accessibility5 {
            app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1"
        }
        app.launchArguments += arguments
        PomoGemUITestLanguage.configureJapanese(app)
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 12))
    }

    private func openSettings() {
        let menu = app.buttons["メニュー"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        menu.tap()
        let settings = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "設定")).firstMatch
        XCTAssertTrue(scrollUntilHittable(settings))
        settings.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 8))
    }

    /// Apple's audits, run while this feature's rows are on screen and scoped
    /// to them; the rest of Settings is owned by `SettingsPaywallUITests` and
    /// `AccessibilityAdversarialUITests`. Dynamic Type is audited only at the
    /// system size: the AX5 fixture pins the size, which that audit would read
    /// as text that does not scale.
    ///
    /// Every issue XCTest attributes to one of these identifiers fails the
    /// test; the footers are plain texts, so their clipping is always
    /// attributed. An issue XCTest cannot attribute to any element (its
    /// element, and even its private `axElement`, is nil) is kept as an
    /// attachment (count and screen) but does not fail here. That class of
    /// report predates this card: on the branch base (b1cb91c, none of these
    /// rows) the text-clipping audit reported 6, 6, 9 and 7 such issues at
    /// the system size in four runs. Started from the same row just above
    /// this card, it reported 7 there and 3 on this branch at the system
    /// size, and 0 on both at AX5, also with the permission notice shown.
    /// The Dynamic Type audit from that row found only unattributed issues on
    /// both: 4 to 6 on the base and 1 to 7 here, none naming an element
    /// (checked 2026-09-27). The counts move with the scroll position the
    /// audit starts from, so they are recorded, not asserted.
    private func auditLeavePauseRows(
        named name: String,
        includingDynamicType: Bool = false
    ) throws {
        let identifiers: Set<String> = [
            "settings.focus-leave-pause",
            "settings.focus-leave-nudges",
            "settings.focus-leave-nudges-permission",
            "settings.focus-leave-nudges-permission.action",
            "settings.focus-leave-footer.behavior",
            "settings.focus-leave-footer.resume",
            "settings.focus-leave-footer.nudges",
            "settings.live-activity-footer"
        ]
        var audits: [(String, XCUIAccessibilityAuditType)] = [
            ("hit region", .hitRegion),
            ("text clipping", .textClipped)
        ]
        if includingDynamicType {
            audits.append(("Dynamic Type", .dynamicType))
        }
        for (auditName, auditType) in audits {
            try XCTContext.runActivity(named: "\(name) — \(auditName)") { activity in
                var unattributed: [String] = []
                try app.performAccessibilityAudit(for: auditType) { issue in
                    guard let element = issue.element else {
                        unattributed.append(issue.detailedDescription)
                        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                        screen.name = "Screen at unattributed \(auditName) issue \(unattributed.count)"
                        screen.lifetime = .keepAlways
                        activity.add(screen)
                        return true
                    }
                    return !identifiers.contains(element.identifier)
                }
                if !unattributed.isEmpty {
                    let details = XCTAttachment(string: "count=\(unattributed.count)\n"
                        + unattributed.joined(separator: "\n"))
                    details.name = "Unattributed \(auditName) issues (\(unattributed.count))"
                    details.lifetime = .keepAlways
                    activity.add(details)
                }
            }
        }
    }

    /// Asserts `upper` sits above `lower`, comparing them while both are on
    /// screen: `upper` is brought into view, then the List moves up in small
    /// steps until `lower` appears, so neither leaves the hierarchy between
    /// the two readings, even at AX5.
    private func assertAbove(
        _ upper: XCUIElement,
        _ lower: XCUIElement,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(reveal(upper, swipingDown: !upper.exists), message, file: file, line: line)
        for _ in 0 ..< 30 {
            if lower.exists, lower.frame.height > 0 { break }
            let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -60)))
        }
        settle(lower)
        XCTAssertTrue(upper.exists && lower.exists, message, file: file, line: line)
        XCTAssertLessThanOrEqual(upper.frame.maxY, lower.frame.minY + 1, message, file: file, line: line)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func text(containing value: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    private func tapSwitch(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    /// Brings `element` fully into the content area below the navigation
    /// bar; a row whose centre is hittable can still sit half under the bar,
    /// which then takes the tap. An element taller than that area (a footer
    /// at AX5) counts once it is hittable. An audit leaves the List wherever
    /// it last scrolled, so a search that runs out in one direction turns
    /// back and tries the other.
    private func reveal(_ element: XCUIElement, swipingDown: Bool = false) -> Bool {
        var swipingDown = swipingDown
        var swipesThisWay = 0
        for _ in 0 ..< 72 {
            if element.exists {
                settle(element)
                let top = app.navigationBars.allElementsBoundByIndex
                    .filter(\.isHittable).map(\.frame.maxY).max() ?? 0
                let bottom = app.windows.firstMatch.frame.maxY - 36
                let frame = element.frame
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
            if swipesThisWay == 24 {
                swipingDown.toggle()
                swipesThisWay = 0
            }
            swipesThisWay += 1
            if swipingDown {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        return false
    }

    /// A tap while the List still decelerates after a swipe only stops the
    /// scroll. Wait for the row to come to rest before tapping.
    private func settle(_ element: XCUIElement) {
        var frame = element.frame
        for _ in 0 ..< 20 {
            usleep(150_000)
            let next = element.frame
            if next == frame { return }
            frame = next
        }
    }

    /// Flips a switch whose change needs no permission. A second tap is made
    /// only if the first one left the value unchanged (swallowed by the scroll).
    private func toggle(_ element: XCUIElement, to value: String) -> Bool {
        for _ in 0 ..< 2 {
            settle(element)
            tapSwitch(element)
            if waitForSwitch(element, value: value, timeout: 4) { return true }
        }
        return false
    }

    private func waitForSwitch(_ element: XCUIElement, value: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.value as? String == value { return true }
            usleep(50_000)
        } while Date() < deadline
        return element.value as? String == value
    }

    private func waitForLabel(of element: XCUIElement, containing value: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, element.label.contains(value) { return true }
            usleep(100_000)
        } while Date() < deadline
        return element.exists && element.label.contains(value)
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            usleep(250_000)
        }
        return !element.exists
    }

    private func scrollUntilHittable(
        _ element: XCUIElement,
        attempts: Int = 10,
        swipingDown: Bool = false
    ) -> Bool {
        for _ in 0 ..< attempts {
            if element.exists, element.isHittable { return true }
            if swipingDown {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        return element.exists && element.isHittable
    }

    private func retainScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

import XCTest

/// Music is reachable beside the next focus's theme and keeps that theme as
/// its settings context. These checks never request Music access or playback.
@MainActor
final class FocusMusicEntryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_REDUCE_MOTION"] = "1"
        PomoGemUITestLanguage.configureJapanese(app)
    }

    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Home music entry"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Home music entry accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app?.terminate()
    }

    func testHomeMusicIsVisibleAndReopensForTheSelectedTheme() {
        app.launch()
        let music = app.buttons["home.focus-music"]
        XCTAssertTrue(music.waitForExistence(timeout: 12))
        XCTAssertTrue(music.isHittable, "Music must be visible without opening Settings or scrolling")
        XCTAssertEqual(music.label, "音楽")
        let homeTheme = app.buttons["home.subject-picker"]
        XCTAssertTrue(homeTheme.label.contains("英語"), homeTheme.label)
        retainScreenshot(named: "Home — visible music entry")
        music.tap()

        let context = app.descendants(matching: .any)
            .matching(identifier: "focus-music.subject").firstMatch
        XCTAssertTrue(context.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForContext(context, containing: "英語"), context.label)
        XCTAssertEqual(app.alerts.count, 0, "Opening music settings must not ask for Music access")
        retainScreenshot(named: "Music — selected theme context")
        context.tap()
        let commonMusic = app.buttons["共通の音楽"].firstMatch
        XCTAssertTrue(commonMusic.waitForExistence(timeout: 4))
        commonMusic.tap()
        XCTAssertTrue(waitForContext(context, containing: "共通の音楽"))
        app.buttons["focus-music.close"].tap()

        XCTAssertTrue(music.waitForExistence(timeout: 5))
        XCTAssertTrue(homeTheme.label.contains("英語"), "Changing music's context must not change the next focus's theme")
        music.tap()
        XCTAssertTrue(context.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForContext(context, containing: "英語"), "Reopening music should follow Home's selected theme")
    }

    func testMusicAndThemeContextRemainReachableAtLargestTextSize() {
        executionTimeAllowance = 300
        // Persist the same longer playlist name that made the narrow AX5
        // value column taller than Home's scrollable viewport. Do not depend
        // on another test having selected it first.
        app.launch()
        openActivitySettings()
        openEnglishActivityEditor()
        let source = app.buttons["subject-editor.music.source"]
        XCTAssertTrue(reveal(source))
        source.tap()
        let classical = app.buttons["focus-music.source.pl.cf8514b686374fadbe6807a6339dfd89"]
        XCTAssertTrue(reveal(classical))
        classical.tap()
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(source.label.contains("作業用BGM：クラシック"), source.label)
        app.buttons["subject-editor.save"].tap()
        XCTAssertTrue(app.navigationBars["取り組み"].waitForExistence(timeout: 5))
        app.terminate()

        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1"
        app.launch()
        let music = app.buttons["home.focus-music"]
        let homeScroll = app.scrollViews.containing(.button, identifier: "home.focus-music").firstMatch
        XCTAssertTrue(music.waitForExistence(timeout: 12))
        XCTAssertTrue(homeScroll.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForContext(music, containing: "作業用BGM：クラシック"))
        XCTAssertTrue(reveal(music, in: homeScroll),
                      "The selected playlist must fit completely inside Home's actual scroll viewport")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(music.frame.minX, window.minX)
        XCTAssertLessThanOrEqual(music.frame.maxX, window.maxX)
        retainScreenshot(named: "Home — selected classical playlist fully visible at AX5")
        music.tap()
        let context = app.descendants(matching: .any)
            .matching(identifier: "focus-music.subject").firstMatch
        XCTAssertTrue(context.waitForExistence(timeout: 5))
        XCTAssertTrue(reveal(context))
        XCTAssertTrue(waitForContext(context, containing: "英語"), context.label)
        XCTAssertTrue(app.buttons["focus-music.close"].isHittable)
        retainScreenshot(named: "Music — theme context at AX5")
    }

    func testFavoriteStationLinkValidationPersistsAcrossRelaunch() {
        executionTimeAllowance = 300
        app.launch()
        openMusicFromHome()
        let addMusic = app.descendants(matching: .any)
            .matching(identifier: "focus-music.add-music").firstMatch
        XCTAssertTrue(reveal(addMusic))
        addMusic.tap()
        let linkMethod = app.buttons["リンク"].firstMatch
        XCTAssertTrue(reveal(linkMethod))
        linkMethod.tap()

        let link = app.textFields["focus-music.link"]
        XCTAssertTrue(reveal(link))
        link.tap()
        let invalidLink = "https://example.com/music"
        link.typeText(invalidLink)
        XCTAssertTrue(waitForValue(link, equalTo: invalidLink))
        let addLink = app.buttons["focus-music.add-link"]
        XCTAssertTrue(reveal(addLink))
        addLink.tap()
        let error = app.staticTexts["focus-music.link-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5), "An unrelated URL must show an inline validation error")
        XCTAssertEqual(app.alerts.count, 0)

        // Reopen with an empty draft. Tapping a long URL positions its
        // cursor in the middle, so repeated deletes are not a reliable
        // way for UI automation to replace the complete field value.
        app.buttons["focus-music.close"].tap()
        openMusicFromHome()
        XCTAssertTrue(reveal(addMusic))
        addMusic.tap()
        XCTAssertTrue(reveal(linkMethod))
        linkMethod.tap()
        XCTAssertTrue(reveal(link))
        link.tap()
        let stationLink = "https://music.apple.com/jp/station/classical-station/ra.985486574"
        link.typeText(stationLink)
        XCTAssertTrue(waitForValue(link, equalTo: stationLink))
        let name = app.textFields["focus-music.link-name"]
        XCTAssertTrue(reveal(name))
        name.tap()
        name.typeText("Radio")
        XCTAssertTrue(waitForValue(name, equalTo: "Radio"))
        XCTAssertTrue(reveal(addLink))
        addLink.tap()

        let savedStation = app.buttons["focus-music.source.ra.985486574"]
        let favorite = app.buttons["focus-music.favorite.ra.985486574"]
        XCTAssertTrue(reveal(savedStation))
        XCTAssertTrue(savedStation.label.contains("Radio"), savedStation.label)
        XCTAssertTrue(favorite.label.contains("お気に入りから削除"), favorite.label)
        XCTAssertGreaterThanOrEqual(favorite.frame.width, 44)
        XCTAssertGreaterThanOrEqual(favorite.frame.height, 44)
        XCTAssertFalse(error.exists)
        XCTAssertEqual(app.alerts.count, 0, "Saving a favorite must not ask for Music access")
        retainScreenshot(named: "Music — station saved from a shared link")
        app.buttons["focus-music.close"].tap()

        openMusicFromHome()
        XCTAssertTrue(reveal(savedStation))
        XCTAssertTrue(savedStation.label.contains("Radio"), "The display name must survive closing music settings")
        XCTAssertTrue(favorite.label.contains("お気に入りから削除"), favorite.label)
        app.buttons["focus-music.close"].tap()
        app.terminate()
        app.launch()

        openMusicFromHome()
        XCTAssertTrue(reveal(savedStation))
        XCTAssertTrue(savedStation.label.contains("Radio"), "The favorite and display name must survive an app relaunch")
        XCTAssertTrue(favorite.label.contains("お気に入りから削除"), favorite.label)
        XCTAssertEqual(app.alerts.count, 0)
        retainScreenshot(named: "Music — saved station after relaunch")
        XCTAssertTrue(reveal(favorite))
        favorite.tap()
        XCTAssertTrue(waitForContext(favorite, containing: "お気に入りに追加"),
                      "Removing a saved curated station returns its heart to Add without playing it")
        XCTAssertEqual(app.alerts.count, 0)
    }

    func testActivityMusicDraftCancelsAndSavesWithoutPlaying() {
        executionTimeAllowance = 300
        app.launch()
        openActivitySettings()
        openEnglishActivityEditor()
        let source = app.buttons["subject-editor.music.source"]
        let autoplay = app.switches["subject-editor.music.autoplay"]
        XCTAssertTrue(reveal(autoplay))
        let originalAutoplay = autoplay.value as? String
        toggleAutoplay(autoplay)
        let draftAutoplay = autoplay.value as? String
        XCTAssertNotEqual(draftAutoplay, originalAutoplay)
        XCTAssertTrue(reveal(source))
        let originalSource = source.label
        source.tap()
        XCTAssertTrue(app.buttons["focus-music.close"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["focus-music.play-pause"].exists)
        XCTAssertFalse(app.switches["focus-music.autoplay"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "focus-music.favorite.")).firstMatch.exists)
        retainScreenshot(named: "Activity music picker — initial choices")
        let classical = app.buttons["focus-music.source.pl.cf8514b686374fadbe6807a6339dfd89"]
        XCTAssertTrue(reveal(classical))
        retainScreenshot(named: "Activity music picker — standard playlists")
        classical.tap()
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(source.label.contains("クラシック"), source.label)
        XCTAssertEqual(app.alerts.count, 0, "Selecting music in the editor must not request playback permission")
        app.buttons["subject-editor.cancel"].tap()

        openEnglishActivityEditor()
        XCTAssertTrue(reveal(autoplay))
        XCTAssertEqual(autoplay.value as? String, originalAutoplay)
        XCTAssertTrue(reveal(source))
        XCTAssertEqual(source.label, originalSource, "Cancel must discard the music choice too")
        XCTAssertTrue(reveal(autoplay))
        toggleAutoplay(autoplay)
        XCTAssertTrue(reveal(source))
        source.tap()
        XCTAssertTrue(reveal(classical))
        classical.tap()
        app.buttons["subject-editor.save"].tap()

        openEnglishActivityEditor()
        XCTAssertTrue(reveal(autoplay))
        XCTAssertEqual(autoplay.value as? String, draftAutoplay)
        XCTAssertTrue(reveal(source))
        XCTAssertTrue(source.label.contains("クラシック"), source.label)
        XCTAssertEqual(app.alerts.count, 0)
        retainScreenshot(named: "Activity — saved music and autoplay")
        app.buttons["subject-editor.cancel"].tap()
    }

    func testActivityMusicSupportsAPlaylistLinkAndLibraryEntryAtLargestTextSize() {
        executionTimeAllowance = 300
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1"
        app.launch()
        openActivitySettings()
        openEnglishActivityEditor()
        let source = app.buttons["subject-editor.music.source"]
        XCTAssertTrue(reveal(source))
        source.tap()
        XCTAssertTrue(app.buttons["focus-music.close"].waitForExistence(timeout: 5))
        retainScreenshot(named: "Activity music picker — initial AX5")
        let library = app.buttons["focus-music.library"]
        XCTAssertTrue(reveal(library))
        retainScreenshot(named: "Activity music picker — library entry AX5")
        XCTAssertEqual(app.alerts.count, 0, "Opening the picker must not read the library or ask for permission")
        let addMusic = app.descendants(matching: .any).matching(identifier: "focus-music.add-music").firstMatch
        XCTAssertTrue(reveal(addMusic))
        addMusic.tap()
        let linkMethod = app.buttons["リンク"].firstMatch
        XCTAssertTrue(reveal(linkMethod))
        linkMethod.tap()
        let link = app.textFields["focus-music.link"]
        XCTAssertTrue(reveal(link))
        retainScreenshot(named: "Activity music picker — link form AX5")
        link.tap()
        let playlistLink = "https://music.apple.com/jp/playlist/study/pl.cf8514b686374fadbe6807a6339dfd89"
        link.typeText(playlistLink)
        XCTAssertTrue(waitForValue(link, equalTo: playlistLink))
        let name = app.textFields["focus-music.link-name"]
        XCTAssertTrue(reveal(name))
        name.tap()
        name.typeText("Study List")
        XCTAssertTrue(waitForValue(name, equalTo: "Study List"))
        let choose = app.buttons["focus-music.add-link"]
        XCTAssertTrue(reveal(choose))
        retainScreenshot(named: "Activity music picker — filled link form AX5")
        XCTAssertEqual(choose.label, "この音楽を選ぶ")
        choose.tap()
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(reveal(source))
        XCTAssertTrue(source.label.contains("Study List"), source.label)
        XCTAssertEqual(app.alerts.count, 0)
        retainScreenshot(named: "Activity — playlist draft at AX5")
        app.buttons["subject-editor.cancel"].tap()
    }

    private func openActivitySettings() {
        let menu = app.buttons["home.menu.open"]
        if !menu.waitForExistence(timeout: 3) {
            let overflow = app.buttons["OverflowBarButtonItem"]
            XCTAssertTrue(overflow.waitForExistence(timeout: 5))
            overflow.tap()
        }
        // UIKit's overflow item retains the label but drops the toolbar
        // button's original accessibility identifier.
        let visibleMenu = app.buttons["メニュー"]
        XCTAssertTrue(visibleMenu.waitForExistence(timeout: 5))
        visibleMenu.tap()
        let settings = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "設定")).firstMatch
        XCTAssertTrue(reveal(settings))
        settings.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5))
        PomoGemSettingsUITestNavigation.open(.themes, in: app)
    }

    private func openEnglishActivityEditor() {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "英語")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(reveal(row))
        row.tap()
        XCTAssertTrue(app.buttons["subject-editor.save"].waitForExistence(timeout: 5))
    }

    private func toggleAutoplay(_ toggle: XCUIElement) {
        let originalValue = toggle.value as? String
        // SwiftUI exposes the label and UISwitch as one wide accessibility
        // element. Tap the switch itself, not the middle of its text label.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in toggle.value as? String != originalValue }, object: nil
        )], timeout: 4) == .completed)
    }

    private func openMusicFromHome() {
        let music = app.buttons["home.focus-music"]
        XCTAssertTrue(music.waitForExistence(timeout: 12))
        XCTAssertTrue(reveal(music))
        music.tap()
        XCTAssertTrue(app.buttons["focus-music.close"].waitForExistence(timeout: 5))
    }

    private func reveal(_ element: XCUIElement, in requestedSurface: XCUIElement? = nil) -> Bool {
        var lastKnownFrame: CGRect?
        var direction: CGFloat = -1
        var observations: [String] = []
        var revealed = false
        defer {
            let geometry = XCTAttachment(string: observations.joined(separator: "\n"))
            geometry.name = "Music reveal \(revealed ? "succeeded" : "failed") — viewport and target geometry"
            geometry.lifetime = .keepAlways
            add(geometry)
        }
        let deadline = Date().addingTimeInterval(60)
        for attempt in 0..<32 {
            let window = app.windows.firstMatch
            let windowFrame = window.frame
            let navigationBottom = app.navigationBars.allElementsBoundByIndex
                .filter(\.isHittable).map(\.frame.maxY).max() ?? windowFrame.minY
            let keyboard = app.keyboards.firstMatch
            let keyboardTop = keyboard.exists ? keyboard.frame.minY - 12 : windowFrame.maxY - 24
            let surfaces = app.scrollViews.allElementsBoundByIndex + app.collectionViews.allElementsBoundByIndex
            guard let surface = requestedSurface ?? surfaces.last(where: {
                $0.isHittable && $0.frame.maxY > navigationBottom + 60 && $0.frame.minY < keyboardTop
            }) else {
                observations.append("attempt=\(attempt); no frontmost scrollable surface")
                return false
            }
            let scrollFrame = surface.frame.intersection(windowFrame)
            let top = max(scrollFrame.minY, navigationBottom) + 8
            let bottom = min(scrollFrame.maxY - 8, keyboardTop)
            let room = bottom - top
            guard room > 60 else { return false }
            var distance = room * 0.65
            if element.exists {
                let frame = element.frame
                lastKnownFrame = frame
                observations.append("attempt=\(attempt); target=\(frame); top=\(top); bottom=\(bottom); surface=\(scrollFrame)")
                if frame.minY >= top, frame.maxY <= bottom, element.isHittable {
                    revealed = true
                    return true
                }
                // A row taller than the usable viewport is a real layout
                // failure. Keep the full-visibility requirement for all rows.
                guard frame.height <= room else { return false }
                let correction = (top + bottom) / 2 - frame.midY
                direction = correction < 0 ? -1 : 1
                distance = min(distance, max(24, abs(correction)))
            } else {
                observations.append("attempt=\(attempt); target absent; last=\(String(describing: lastKnownFrame)); direction=\(direction); top=\(top); bottom=\(bottom); surface=\(scrollFrame)")
            }
            guard attempt < 31, Date() < deadline else { return false }
            // Lazy AX5 forms can span seven pages before creating the row.
            // Seek by a viewport fraction; once it exists, center it precisely.
            // If virtualization hides it again, retain the last known direction.
            let startY = direction < 0 ? bottom - 12 : top + 12
            let start = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: scrollFrame.minX + scrollFrame.width * 0.9 - windowFrame.minX,
                dy: startY - windowFrame.minY
            ))
            // Stop the finger before lifting so inertia cannot carry a tall
            // AX5 row past the opposite viewport edge and alternate forever.
            start.press(
                forDuration: 0.05,
                thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance * direction)),
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )
        }
        return false
    }

    private func retainScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForValue(_ element: XCUIElement, equalTo value: String) -> Bool {
        // On a busy simulator, typeText can finish before the final keyboard
        // events reach SwiftUI and its accessibility value. Observe the actual
        // completed input before saving or reporting a validation failure.
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: element
        )], timeout: 4) == .completed
    }

    private func waitForContext(_ element: XCUIElement, containing text: String) -> Bool {
        let predicate = NSPredicate { _, _ in
            element.label.contains(text) || (element.value as? String)?.contains(text) == true
        }
        return XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)],
            timeout: 4
        ) == .completed
    }
}

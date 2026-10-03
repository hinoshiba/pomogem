import XCTest

/// The language every UI test launches PomoGem in.
///
/// Most UI tests find elements by their Japanese labels; the English smoke
/// test checks the shipping English interface. Every launch goes through this
/// helper so none can forget the intended language;
/// `Scripts/l10n/l10n.py check` rejects a launch that is not pinned. For the
/// same reason it also tags the launch with the running test
/// (`PomoGemUITestScenario`).
enum PomoGemUITestLanguage {
    static let japaneseArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
    static let englishArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]

    static func configureEnglish(_ application: XCUIApplication) {
        application.launchArguments = withoutLanguagePin(application.launchArguments) + englishArguments
        PomoGemUITestScenario.tag(application)
    }

    /// Launch in Japanese with the Japan region. Idempotent: a relaunch of the
    /// same application keeps exactly one language pin.
    static func configureJapanese(_ application: XCUIApplication) {
        application.launchArguments = withoutLanguagePin(application.launchArguments) + japaneseArguments
        PomoGemUITestScenario.tag(application)
    }

    /// Launch in Japanese with 設定 > 一般 > 言語と地域 > 暦法 set to 和暦, for
    /// tests that prove month and year labels stay 西暦. Idempotent like
    /// `configureJapanese(_:)`.
    static func configureJapaneseWithJapaneseCalendar(_ application: XCUIApplication) {
        application.launchArguments = withoutLanguagePin(application.launchArguments)
            + ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP@calendar=japanese"]
        PomoGemUITestScenario.tag(application)
    }

    private static func withoutLanguagePin(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            if ["-AppleLanguages", "-AppleLocale"].contains(arguments[index]) {
                index += 2
                continue
            }
            result.append(arguments[index])
            index += 1
        }
        return result
    }
}

/// The shipping Settings tree. This helper follows its visible rows; it never
/// changes a preference, answers a permission prompt, or skips a confirmation.
@MainActor
enum PomoGemSettingsUITestNavigation {
    enum Page: String, CaseIterable {
        case themes, timer, sensory, jar, notifications, data, support

        func title(english: Bool = false) -> String {
            switch (self, english) {
            case (.themes, false): "テーマ"
            case (.timer, false): "集中タイマー"
            case (.sensory, false): "音と触覚"
            case (.jar, false): "瓶とシェア"
            case (.notifications, false): "お知らせ"
            case (.data, false): "記録とiCloud"
            case (.support, false): "サポートとアプリ情報"
            case (.themes, true): "Themes"
            case (.timer, true): "Focus Timer"
            case (.sensory, true): "Sound & Haptics"
            case (.jar, true): "Jar & Sharing"
            case (.notifications, true): "Reminders"
            case (.data, true): "Records & iCloud"
            case (.support, true): "Support & App Info"
            }
        }

        var identifier: String { "settings.category.\(rawValue)" }
    }

    @discardableResult
    static func open(
        _ page: Page,
        in app: XCUIApplication,
        english: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let destination = app.navigationBars[page.title(english: english)]
        if destination.exists && destination.isHittable { return true }
        guard backToIndex(in: app, english: english, file: file, line: line) else { return false }
        let row = app.buttons[page.identifier]
        guard reveal(row, in: app, indexIdentifier: page.identifier) else {
            XCTFail("Settings must expose \(page.identifier)", file: file, line: line)
            return false
        }
        row.tap()
        let opened = destination.waitForExistence(timeout: 8)
        XCTAssertTrue(opened, "The category opens \(page.title(english: english))", file: file, line: line)
        return opened
    }

    @discardableResult
    static func backToIndex(
        in app: XCUIApplication,
        english: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        for page in Page.allCases {
            let bar = app.navigationBars[page.title(english: english)]
            if bar.exists && bar.isHittable {
                bar.buttons.firstMatch.tap()
                break
            }
        }
        let index = app.navigationBars[english ? "Settings" : "設定"]
        let returned = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: index
        )], timeout: 8) == .completed
        XCTAssertTrue(returned, "Back returns to the Settings index", file: file, line: line)
        return returned
    }

    static func returnHome(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard backToIndex(in: app, file: file, line: line) else { return }
        app.navigationBars["設定"].buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["home.menu.open"].waitForExistence(timeout: 8),
                      "Back from Settings returns Home", file: file, line: line)
    }

    @discardableResult
    static func reveal(
        _ element: XCUIElement,
        in app: XCUIApplication,
        indexIdentifier: String? = nil
    ) -> Bool {
        // Lazy List removes an index row above the viewport from its AX tree.
        // Use the visible category's position to choose a direction, rather
        // than assuming every absent row is further down the page.
        let indexRows = [
            "settings.category.themes", "settings.category.timer", "settings.screen-time",
            "settings.category.sensory", "settings.category.jar", "settings.category.notifications",
            "settings.category.data", "settings.pro", "settings.category.support"
        ]
        var swipingDown = false
        if !element.exists, let indexIdentifier, let target = indexRows.firstIndex(of: indexIdentifier) {
            for (index, identifier) in indexRows.enumerated() {
                let candidate = app.buttons[identifier]
                if candidate.exists && candidate.isHittable {
                    swipingDown = target < index
                    break
                }
            }
        }
        for attempt in 0 ..< 24 {
            if element.exists {
                let top = app.navigationBars.allElementsBoundByIndex
                    .filter(\.isHittable).map(\.frame.maxY).max() ?? 0
                let bottom = app.windows.firstMatch.frame.maxY - 24
                let frame = element.frame
                if frame.height > 0, frame.minY >= top, frame.maxY <= bottom, element.isHittable {
                    var previous = frame
                    for _ in 0 ..< 8 {
                        usleep(100_000)
                        let next = element.frame
                        if next == previous { return true }
                        previous = next
                    }
                }
                if frame.height > bottom - top, element.isHittable { return true }
                if frame.height > 0, frame.width > 0,
                   frame.minY < top || frame.maxY > bottom {
                    // At AX5 an index row can occupy much of a small screen.
                    // A whole-screen swipe can carry it past the opposite
                    // edge, so correct only its distance from the viewport.
                    let correction = frame.minY < top
                        ? top - frame.minY + 12 : bottom - frame.maxY - 12
                    let distance = min(220, max(60, abs(correction)))
                        * (correction < 0 ? -1 : 1)
                    let start = app.windows.firstMatch.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                    )
                    start.press(forDuration: 0.05,
                                thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)))
                    continue
                }
            }
            if attempt == 12 { swipingDown.toggle() }
            if swipingDown {
                app.swipeDown(velocity: .slow)
            } else {
                app.swipeUp(velocity: .slow)
            }
        }
        return false
    }
}

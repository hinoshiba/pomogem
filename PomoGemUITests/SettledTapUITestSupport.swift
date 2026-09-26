import XCTest

extension XCTestCase {
    /// True once two reads of the element's frame 0.25 s apart agree.
    ///
    /// On a loaded Simulator a tap sent while a sheet, card or rotation is
    /// still settling can be lost (screen recordings of failed runs show the
    /// screen at rest with nothing selected), and asking whether the element
    /// is hittable can even throw ("Activation point invalid"). Waiting for
    /// the frame to hold still avoids both.
    @MainActor
    func waitUntilFrameSettles(
        _ element: XCUIElement,
        timeout: TimeInterval = 8
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = element.frame
        while Date() < deadline {
            let idle = XCTestExpectation(description: "frame settle")
            idle.isInverted = true
            _ = XCTWaiter.wait(for: [idle], timeout: 0.25)
            let current = element.frame
            if current == previous, !current.isEmpty { return true }
            previous = current
        }
        return false
    }

    /// Taps a control that goes away when it works, such as a card's 閉じる,
    /// once it has come to rest. If the same control is still on screen 3 s
    /// later the tap was lost, so it taps once more. Fails if the control
    /// still does not go away.
    @MainActor
    func tapUntilGone(
        _ element: XCUIElement,
        _ message: @autoclosure () -> String = "The control must go away when tapped",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(waitUntilFrameSettles(element), "The control must come to rest", file: file, line: line)
        element.tap()
        if !waitUntilGone(element, timeout: 3), element.exists, element.isHittable {
            XCTContext.runActivity(named: "The first tap was lost; tapping again") { _ in }
            element.tap()
        }
        XCTAssertTrue(waitUntilGone(element, timeout: 5), message(), file: file, line: line)
    }

    @MainActor
    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }
}

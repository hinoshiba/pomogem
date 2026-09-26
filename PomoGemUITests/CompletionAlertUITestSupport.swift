import XCTest

extension XCTestCase {
    /// Stops the repeating completion alarm with its Stop button, if the alarm
    /// appears within `timeout`, and checks that the alarm really stopped.
    ///
    /// The Stop button can already be hittable while the alarm screen is still
    /// replacing the timer, and on a loaded Simulator a tap in that moment is
    /// sometimes lost. The alarm then keeps repeating, and the test times out
    /// waiting for a reward card that only comes after Stop. The button exists
    /// only while the alarm repeats, so if the same button is still on screen
    /// a moment after the tap, the tap was lost and is repeated once. If the
    /// alarm cannot be stopped at all, this fails.
    @MainActor
    @discardableResult
    func stopCompletionAlertIfPresented(
        in app: XCUIApplication,
        timeout: TimeInterval = 25,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let stop = app.buttons["focus.completion-alert.stop"]
        guard stop.waitForExistence(timeout: timeout) else { return false }
        XCTAssertEqual(stop.label, "終了アラートを止める", file: file, line: line)
        XCTAssertTrue(stop.isHittable, file: file, line: line)
        stop.tap()
        if !waitForCompletionAlertStopToDisappear(stop, timeout: 3),
           stop.exists, stop.isHittable {
            XCTContext.runActivity(named: "The first Stop tap was lost; tapping Stop again") { _ in }
            stop.tap()
        }
        XCTAssertTrue(
            waitForCompletionAlertStopToDisappear(stop, timeout: 5),
            "Stop must end the repeating completion alarm",
            file: file,
            line: line
        )
        return true
    }

    @MainActor
    private func waitForCompletionAlertStopToDisappear(
        _ stop: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: stop
        )
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }
}

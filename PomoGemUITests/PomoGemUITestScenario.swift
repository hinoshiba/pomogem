import XCTest

/// Names the UI test a launch belongs to.
///
/// The Simulator keeps the app's UserDefaults from one test to the next. A
/// test that ends during its completion alarm, or with a timer running,
/// leaves that timer saved, and the next test would open on it instead of
/// Home. The Debug app reads this identifier (`UITestLocalStateIsolation`) and
/// forgets the timer and its local queues on the first launch of a new test,
/// while a test's own relaunches, which share the identifier, still recover
/// them. `PomoGemUITestLanguage` tags every launch, so no test can forget it.
enum PomoGemUITestScenario {
    static let environmentKey = "POMOGEM_UI_TEST_SCENARIO"

    static func tag(_ application: XCUIApplication) {
        application.launchEnvironment[environmentKey] = Tracker.shared.currentID
    }

    private final class Tracker: NSObject, XCTestObservation {
        static let shared: Tracker = {
            let tracker = Tracker()
            XCTestObservationCenter.shared.addTestObserver(tracker)
            return tracker
        }()

        /// The test that first reaches this type is already running, so it
        /// keeps the initial identifier. Every later test (and every
        /// `-test-iterations` repeat) starts a new one.
        private(set) var currentID = UUID().uuidString

        func testCaseWillStart(_ testCase: XCTestCase) {
            currentID = UUID().uuidString
        }
    }
}

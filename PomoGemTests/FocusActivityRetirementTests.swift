import XCTest
@testable import PomoGem

@MainActor
final class FocusActivityRetirementTests: XCTestCase {
    func testAcceptedSnapshotNeverEndsANewerActivityEvenForTheSameSession() async {
        let oldSessionID = UUID()
        for nextSessionID in [oldSessionID, UUID()] {
            let client = FakeRetiringFocusActivities()
            client.start(id: "old", sessionID: oldSessionID)
            let retirement = client.prepare()

            // Notification cleanup has not completed yet. A subsequent focus
            // or replacement Activity must not join the accepted snapshot.
            client.start(id: "new", sessionID: nextSessionID)
            let newGeneration = client.lifecycle.generation
            await retirement.end()

            XCTAssertEqual(Set(client.activities.keys), ["new"])
            XCTAssertEqual(client.ended, ["old"])
            XCTAssertEqual(client.currentActivityID, "new")
            XCTAssertEqual(client.lifecycle.generation, newGeneration)
        }
    }

    func testNewActivitySurvivesWhileCapturedActivityEndIsSuspended() async {
        let gate = ActivityRetirementGate(started: expectation(description: "old end pending"))
        let client = FakeRetiringFocusActivities()
        client.start(id: "old-a", sessionID: UUID())
        client.start(id: "old-b", sessionID: UUID())
        client.endGate = gate
        let retirement = client.prepare()
        let finished = expectation(description: "accepted targets ended")
        let task = Task {
            await retirement.end()
            finished.fulfill()
        }
        await fulfillment(of: [gate.started], timeout: 3)
        client.start(id: "new", sessionID: UUID())
        let newGeneration = client.lifecycle.generation
        gate.release()
        await fulfillment(of: [finished], timeout: 3)
        await task.value

        XCTAssertEqual(Set(client.activities.keys), ["new"])
        XCTAssertEqual(client.ended, ["old-a", "old-b"])
        XCTAssertEqual(client.currentActivityID, "new")
        XCTAssertEqual(client.lifecycle.generation, newGeneration)
    }

    func testPreservedSessionSurvivesWhileOtherOldActivitiesAreRetired() async {
        let client = FakeRetiringFocusActivities()
        client.start(id: "old", sessionID: UUID())
        let preservedSession = UUID()
        client.start(id: "preserved", sessionID: preservedSession)
        let preservedGeneration = client.lifecycle.generation

        let retirement = client.prepare(preserving: preservedSession)
        XCTAssertEqual(client.lifecycle.generation, preservedGeneration)
        await retirement.end()

        XCTAssertEqual(Set(client.activities.keys), ["preserved"])
        XCTAssertEqual(client.ended, ["old"])
        XCTAssertEqual(client.currentActivityID, "preserved")
    }

    /// notify-06. A reset retry that keeps a rest started after the reset
    /// keeps that rest's Live Activity, and only that one.
    func testPreservedBreakSurvivesAlongsideThePreservedFocus() async {
        let client = FakeRetiringFocusActivities()
        let focus = UUID()
        let rest = UUID()
        client.start(id: "old", sessionID: UUID())
        client.start(id: "focus", sessionID: focus)
        client.start(id: "rest", sessionID: rest)

        let retirement = client.prepare(preserving: focus, preservingBreak: rest)
        await retirement.end()

        XCTAssertEqual(Set(client.activities.keys), ["focus", "rest"])
        XCTAssertEqual(client.ended, ["old"])
    }

    func testAcceptanceKeepsAPendingBreakStartValid() {
        var lifecycle = FocusActivityLifecycleState()
        let rest = UUID()
        let restGeneration = lifecycle.begin(sessionID: rest)
        lifecycle.acceptRetirement(preserving: nil, preservingBreak: rest)
        XCTAssertEqual(lifecycle.generation, restGeneration)

        lifecycle.acceptRetirement(preserving: nil, preservingBreak: UUID())
        XCTAssertNotEqual(lifecycle.generation, restGeneration)
    }

    func testAcceptanceInvalidatesOldPendingStartsAndPreservesOnlyExactSession() {
        var lifecycle = FocusActivityLifecycleState()
        let oldSession = UUID()
        let oldGeneration = lifecycle.begin(sessionID: oldSession)
        lifecycle.acceptRetirement(preserving: nil)
        XCTAssertNotEqual(lifecycle.generation, oldGeneration)

        let preservedSession = UUID()
        let preservedGeneration = lifecycle.begin(sessionID: preservedSession)
        lifecycle.acceptRetirement(preserving: preservedSession)
        XCTAssertEqual(lifecycle.generation, preservedGeneration)

        let foreignGeneration = lifecycle.begin(sessionID: oldSession)
        lifecycle.acceptRetirement(preserving: preservedSession)
        XCTAssertNotEqual(lifecycle.generation, foreignGeneration)
    }
}

@MainActor
private final class FakeRetiringFocusActivities {
    var activities: [String: UUID] = [:]
    var ended: [String] = []
    var currentActivityID: String?
    var lifecycle = FocusActivityLifecycleState()
    var endGate: ActivityRetirementGate?

    func start(id: String, sessionID: UUID) {
        _ = lifecycle.begin(sessionID: sessionID)
        activities[id] = sessionID
        currentActivityID = id
    }

    func prepare(
        preserving sessionID: UUID? = nil,
        preservingBreak breakID: UUID? = nil
    ) -> FocusActivityRetirement {
        lifecycle.acceptRetirement(preserving: sessionID, preservingBreak: breakID)
        let targets = activities.sorted { $0.key < $1.key }.map { id, sessionID in
            FocusActivityRetirement.Target(id: id, sessionID: sessionID) {
                await self.endGate?.wait()
                self.activities[id] = nil
                self.ended.append(id)
            }
        }
        return FocusActivityRetirement(
            targets: targets,
            preserving: sessionID,
            preservingBreak: breakID
        ) { id in
            guard self.currentActivityID == id else { return }
            self.currentActivityID = nil
        }
    }
}

@MainActor
private final class ActivityRetirementGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(started: XCTestExpectation) { self.started = started }

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func release() {
        released = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

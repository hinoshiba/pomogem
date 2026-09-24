import Combine
import FamilyControls
import Foundation
import XCTest
@testable import PomoGem

/// The foreground loop calls `reload()` every three seconds while the app is
/// active, for every user. Each `objectWillChange` re-evaluates every view
/// observing the controller, so a pass that finds nothing new must stay silent.
@MainActor
final class ScreenTimeControllerPublishingTests: XCTestCase {
    private final class Driver: ScreenTimeMonitoringDriving {
        let store: ScreenTimeStore
        init(store: ScreenTimeStore) { self.store = store }
        func stop() {}
        func invalidateAuthorizationIfNeeded() throws {}
        func synchronize(now: Date) throws -> Bool {
            try store.withMonitoringLock { try store.snapshot().runs.contains(where: \.active) }
        }
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var directories: [URL] = []
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        super.tearDown()
    }

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        return directory
    }

    private func makeStore(negativeGemCount: Int = 3) throws -> ScreenTimeStore {
        let store = ScreenTimeStore(directory: makeDirectory())
        var state = ScreenTimeState()
        state.contextKey = "owner"
        state.contextIsActive = true
        state.configuration.enabled = true
        state.configuration.themeID = UUID()
        state.negativeGemCount = negativeGemCount
        state.runs = [ScreenTimeRun(
            lane: .learning, dayStart: start, dayEnd: start.addingTimeInterval(86_400),
            startedAt: start, timeZoneID: "UTC", includesPastActivity: false,
            themeID: state.configuration.themeID
        )]
        try store.update { $0 = state }
        return store
    }

    private func makeController(
        store: ScreenTimeStore,
        authorization: AuthorizationStatus = .approved
    ) -> ScreenTimeController {
        ScreenTimeController(
            store: store,
            currentContextKey: { "owner" },
            monitoring: Driver(store: store),
            authorization: { authorization },
            diagnosticsMirror: ScreenTimeDiagnosticsMirror(directory: makeDirectory())
        )
    }

    private func countChanges(of controller: ScreenTimeController) -> () -> Int {
        var count = 0
        controller.objectWillChange.sink { count += 1 }.store(in: &cancellables)
        return { count }
    }

    func testReloadOfUnchangedBoundLedgerPublishesNothing() async throws {
        let store = try makeStore()
        let controller = makeController(store: store)
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        XCTAssertEqual(controller.negativeGemCount, 3)
        XCTAssertTrue(controller.isMonitoring)

        let changes = countChanges(of: controller)
        for _ in 0..<3 { controller.reload() }

        XCTAssertEqual(changes(), 0, "An idle refresh pass must not re-render observers")
    }

    func testReloadPublishesOnlyTheValueThatChanged() async throws {
        let store = try makeStore()
        let controller = makeController(store: store)
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        var counts: [Int] = []
        controller.negativeGemCountChanges.sink { counts.append($0) }.store(in: &cancellables)
        let changes = countChanges(of: controller)

        try store.update { $0.negativeGemCount = 4 }
        controller.reload()
        controller.reload()

        XCTAssertEqual(changes(), 1)
        XCTAssertEqual(controller.negativeGemCount, 4)
        XCTAssertEqual(counts, [3, 4], "Home's stream starts at the current value and skips repeats")
    }

    func testOverriddenMonitoringErrorIsPublishedOncePerChange() async throws {
        let store = try makeStore()
        let controller = makeController(store: store, authorization: .denied)
        // A denied status is never bound as authorized; the enabled ledger
        // explains itself through the unauthorized message on every pass.
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        XCTAssertEqual(controller.monitoringError, ScreenTimeError.unauthorized.localizedDescription)

        let changes = countChanges(of: controller)
        for _ in 0..<3 { controller.reload() }

        XCTAssertEqual(changes(), 0, "The unauthorized override must not flip-flop through the stored error")
    }

    func testUnboundControllerStaysSilentAcrossRefreshPasses() {
        let controller = makeController(store: ScreenTimeStore(directory: makeDirectory()))
        let changes = countChanges(of: controller)

        for _ in 0..<3 { controller.reload() }

        XCTAssertEqual(changes(), 0)
        XCTAssertEqual(controller.negativeGemCount, 0)
    }

    /// Unsigned builds have no App Group, so every refresh pass retries the
    /// bind and fails the same way. The reason is published once, not per pass.
    func testRepeatedBindFailurePublishesTheSameReasonOnce() async {
        let controller = makeController(store: ScreenTimeStore(directory: nil))
        var reasons: [String?] = []
        controller.$bindingError.dropFirst().sink { reasons.append($0) }.store(in: &cancellables)

        for _ in 0..<3 {
            try? await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        }

        XCTAssertEqual(reasons.count, 1)
        XCTAssertNotNil(controller.bindingError)
        XCTAssertFalse(controller.isUpdatingMonitoring)
    }
}

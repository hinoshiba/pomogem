import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import PomoGem

@MainActor
final class PersistenceSessionLifetimeTests: XCTestCase {
    func testLoadedRenderCallbackDoesNotRetainRetiredContainer() async throws {
        let probe = SessionLifetimeProbe(
            ready: expectation(description: "empty host appeared"),
            loaded: expectation(description: "loaded render installed its callback"),
            unmounted: expectation(description: "loaded content disappeared"),
            finished: expectation(description: "bounded retirement completed")
        )
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: SessionLifetimeHost(probe: probe))
        window.isHidden = false
        defer {
            probe.mount = nil
            probe.retire = nil
            probe.retirementTask?.cancel()
            window.isHidden = true
            window.rootViewController = nil
        }
        await fulfillment(of: [probe.ready], timeout: 3)

        // Begin empty, then load and render, just like the production launch
        // host. A non-nil State(initialValue:) would test a different lifetime.
        try autoreleasepool {
            let session = try SessionLifetimeSession()
            probe.container = session.container
            probe.lifetimes.track(session.container)
            try XCTUnwrap(probe.mount)(session)
        }
        await fulfillment(of: [probe.loaded], timeout: 3)
        XCTAssertNotNil(probe.container)
        try XCTUnwrap(probe.retire)()
        await fulfillment(of: [probe.unmounted, probe.finished], timeout: 5)

        XCTAssertNotNil(probe.retire, "Keep the loaded render's callback alive throughout retirement")
        XCTAssertEqual(probe.outcome, .retired)
        XCTAssertNil(probe.container, "A captured Host value must not keep its previous session alive")
        XCTAssertNoThrow(try probe.lifetimes.requireAllReleased())
    }

    func testRetainedTransferLeaseReleasesOldContainerAndRejectsReplacementSession() throws {
        let holder = PersistenceSessionHolder<SessionLifetimeSession>()
        weak var container: ModelContainer?
        let callback: () throws -> Void = try autoreleasepool {
            let session = try SessionLifetimeSession()
            holder.session = session
            container = session.container
            let sessionID = session.id
            return {
                guard holder.resolve(sessionID) != nil else {
                    throw StorageTransferError.staleTransaction
                }
            }
        }
        try callback()
        holder.session = nil
        XCTAssertNil(container, "An installed transfer callback only owns a value lease")
        XCTAssertThrowsError(try callback()) { error in
            XCTAssertEqual(error as? StorageTransferError, .staleTransaction)
        }

        let replacement = try SessionLifetimeSession()
        holder.session = replacement
        XCTAssertThrowsError(try callback()) { error in
            XCTAssertEqual(error as? StorageTransferError, .staleTransaction)
        }
        XCTAssertTrue(holder.resolve(replacement.id) === replacement)
    }

    func testAcceptedTransferLeaseKeepsContainerUntilOperationCompletes() async throws {
        let holder = PersistenceSessionHolder<SessionLifetimeSession>()
        let lifetimes = PersistenceContainerLifetimeTracker<ModelContainer>()
        let gate = SessionLifetimeGate(started: expectation(description: "transfer accepted its source"))
        weak var container: ModelContainer?
        let sessionID = try autoreleasepool {
            let session = try SessionLifetimeSession()
            holder.session = session
            container = session.container
            lifetimes.track(session.container)
            return session.id
        }
        let operation = {
            guard let sourceSession = holder.resolve(sessionID) else {
                throw StorageTransferError.staleTransaction
            }
            await gate.wait()
            withExtendedLifetime(sourceSession) {}
        }
        let accepted = Task { try await operation() }
        await fulfillment(of: [gate.started], timeout: 3)
        holder.session = nil
        XCTAssertNotNil(container, "An accepted operation still owns its source until its durable handoff")
        XCTAssertThrowsError(try lifetimes.requireAllReleased())

        gate.release()
        try await accepted.value
        XCTAssertNil(container)
        XCTAssertNoThrow(try lifetimes.requireAllReleased())
        // Even a retained callback cannot start another operation after retirement.
        do {
            try await operation()
            XCTFail("A retired session lease must be rejected")
        } catch {
            XCTAssertEqual(error as? StorageTransferError, .staleTransaction)
        }
    }
}

@MainActor
private final class SessionLifetimeSession: Identifiable {
    let id = UUID()
    let container: ModelContainer

    init() throws {
        let schema = Schema([Subject.self])
        container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    }
}

@MainActor
private final class SessionLifetimeProbe {
    let ready: XCTestExpectation
    let loaded: XCTestExpectation
    let unmounted: XCTestExpectation
    let finished: XCTestExpectation
    let lifetimes = PersistenceContainerLifetimeTracker<ModelContainer>()
    weak var container: ModelContainer?
    var mount: ((SessionLifetimeSession) -> Void)?
    var retire: (() -> Void)?
    var retirementTask: Task<Void, Never>?
    var outcome: PersistenceContainerRetirementPollDecision?

    init(ready: XCTestExpectation, loaded: XCTestExpectation,
         unmounted: XCTestExpectation, finished: XCTestExpectation) {
        self.ready = ready
        self.loaded = loaded
        self.unmounted = unmounted
        self.finished = finished
    }
}

@MainActor
private final class SessionLifetimeGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    init(started: XCTestExpectation) { self.started = started }

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private struct SessionLifetimeHost: View {
    let probe: SessionLifetimeProbe
    @State private var sessionHolder = PersistenceSessionHolder<SessionLifetimeSession>()
    private var session: SessionLifetimeSession? {
        get { sessionHolder.session }
        nonmutating set { sessionHolder.session = newValue }
    }

    var body: some View {
        Group {
            if let session {
                Text("Loaded")
                    .id(session.id)
                    .modelContainer(session.container)
                    .onAppear {
                        // Store a method from this loaded render, preserving
                        // the same Host value captured by its retirement Task.
                        probe.retire = retireSession
                        probe.loaded.fulfill()
                    }
                    .onDisappear { probe.unmounted.fulfill() }
            } else {
                Text("Unloaded")
            }
        }
        .onAppear {
            probe.mount = { session = $0 }
            probe.ready.fulfill()
        }
    }

    private func retireSession() {
        session = nil
        probe.retirementTask = Task { @MainActor in
            var budget = PersistenceContainerRetirementPollBudget(maximumPolls: 80)
            while true {
                let decision = budget.observe(
                    isReleased: !probe.lifetimes.hasLiveContainers,
                    generationMatches: true
                )
                if decision != .continueWaiting {
                    probe.outcome = decision
                    probe.finished.fulfill()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(25)) }
                catch { return }
            }
        }
    }
}

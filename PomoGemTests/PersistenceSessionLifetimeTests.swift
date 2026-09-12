import CloudKit
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import PomoGem

@MainActor
final class PersistenceSessionLifetimeTests: XCTestCase {
    func testExpiredWarmLaunchDoesNotAutomaticallyRenewAfterImmediateRetirement() async throws {
        try await assertExpiredWarmLaunchDoesNotAutomaticallyRenew(delaysExpiredTaskUntilRetired: false)
    }

    func testExpiredWarmLaunchDoesNotAutomaticallyRenewWhenInvalidatedTaskStartsAfterRetirement() async throws {
        try await assertExpiredWarmLaunchDoesNotAutomaticallyRenew(delaysExpiredTaskUntilRetired: true)
    }

    func testExplicitRetryAfterExpiredWarmLaunchCanVerifyAndRenderANewSession() async throws {
        try await assertExpiredWarmLaunchDoesNotAutomaticallyRenew(delaysExpiredTaskUntilRetired: true,
                                                                  explicitlyRetries: true)
    }

    private func assertExpiredWarmLaunchDoesNotAutomaticallyRenew(delaysExpiredTaskUntilRetired: Bool,
                                                                 explicitlyRetries: Bool = false) async throws {
        let suite = "PersistenceDeadlineLifecycle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = DeadlineLifecycleProbe(
            loaded: expectation(description: "first verified session rendered"),
            retirementStarted: expectation(description: "background retirement is waiting"),
            activeWhileQuiescing: expectation(description: "active scene awaits retirement"),
            resumedLookup: expectation(description: "foreground account lookup started"),
            expired: expectation(description: "foreground watchdog expired"),
            expiredGenerationObserved: expectation(description: "invalidated generation task checked admission"))
        probe.delaysExpiredTaskUntilRetired = delaysExpiredTaskUntilRetired
        let resolver = AppleAccountBoundaryResolver(defaults: defaults,
            client: CloudAccountVerificationClient(
                accountStatus: { await probe.accountStatus() },
                userRecordID: { CKRecord.ID(recordName: "synthetic-deadline-account") },
                probePrivateDatabase: {}), verificationTimeout: 30)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: DeadlineLifecycleHost(probe: probe, resolver: resolver))
        window.isHidden = false
        defer {
            probe.cancelDeadline?()
            probe.releaseAccountLookups()
            probe.releaseRetirement()
            probe.changePhase = nil
            probe.cancelDeadline = nil
            probe.retry = nil
            window.isHidden = true
            window.rootViewController = nil
            print("DeadlineLifecycleProbe: \(probe.events.joined(separator: ", "))")
        }
        await fulfillment(of: [probe.loaded], timeout: 3)
        try XCTUnwrap(probe.changePhase)(.background)
        await fulfillment(of: [probe.retirementStarted], timeout: 2)
        try XCTUnwrap(probe.changePhase)(.active)
        await fulfillment(of: [probe.activeWhileQuiescing], timeout: 2)
        probe.releaseRetirement()
        await fulfillment(of: [probe.resumedLookup, probe.expired, probe.expiredGenerationObserved],
                          timeout: 3, enforceOrder: true)
        XCTAssertFalse(probe.automaticallyRenewed,
                       "An expired launch must wait for explicit retry after retirement, even if SwiftUI starts its invalidated generation late")
        XCTAssertEqual(probe.status, "timedOut")
        XCTAssertEqual(probe.lookupCount, 2, "Initial proof plus one foreground proof; no automatic third verification")
        if explicitlyRetries {
            let suppressedAttempt = try XCTUnwrap(probe.expiredAttempt)
            let retryRendered = expectation(description: "explicit retry verified and rendered a new session")
            probe.retryRendered = retryRendered
            probe.allowsRetryLookup = true
            try XCTUnwrap(probe.retry)()
            await fulfillment(of: [retryRendered], timeout: 3)
            XCTAssertEqual(probe.retryRenderedAttempt, suppressedAttempt + 1)
            XCTAssertEqual(probe.lookupCount, 3)
            XCTAssertFalse(probe.automaticallyRenewed)
        }
    }

    func testLoadedRenderCallbackDoesNotRetainRetiredContainer() async throws {
        try await assertLoadedRenderCanRetire(usesQuery: false)
    }

    func testLoadedQueryRenderCanRetireWithoutInvalidatingQueryUpdate() async throws {
        try await assertLoadedRenderCanRetire(usesQuery: true)
    }

    func testPresentedQueryCoverCanRetireWithoutInvalidatingQueryUpdate() async throws {
        try await assertLoadedRenderCanRetire(usesQuery: true, presentsQueryCover: true)
    }

    func testPresentedQueryCoverRetiresDuringQueuedModelChangeWithoutQueryFailure() async throws {
        try await assertLoadedRenderCanRetire(usesQuery: true, presentsQueryCover: true,
                                             queuesModelChangeBeforeRetirement: true)
    }

    private func assertLoadedRenderCanRetire(usesQuery: Bool, presentsQueryCover: Bool = false,
                                            queuesModelChangeBeforeRetirement: Bool = false) async throws {
        let probe = SessionLifetimeProbe(
            ready: expectation(description: "empty host appeared"),
            loaded: expectation(description: "loaded render installed its callback"),
            unmounted: expectation(description: "loaded content disappeared"),
            finished: expectation(description: "bounded retirement completed")
        )
        if presentsQueryCover {
            probe.coverLoaded = expectation(description: "presented cover fetched its Query")
            probe.coverDidAppear = expectation(description: "UIKit completed the cover appearance")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: SessionLifetimeHost(
            probe: probe, usesQuery: usesQuery, presentsQueryCover: presentsQueryCover))
        window.isHidden = false
        defer {
            probe.mount = nil
            probe.retire = nil
            probe.presentCover = nil
            probe.retirementTask?.cancel()
            window.isHidden = true
            window.rootViewController = nil
        }
        await fulfillment(of: [probe.ready], timeout: 3)

        // Begin empty, then load and render, just like the production launch
        // host. A non-nil State(initialValue:) would test a different lifetime.
        try autoreleasepool {
            let session = try SessionLifetimeSession()
            if usesQuery {
                session.container.mainContext.insert(Subject(name: "Synthetic Query Lifetime", colorHex: "#445566", sortOrder: 0))
                try session.container.mainContext.save()
            }
            probe.container = session.container
            probe.viewLifetime = session.viewLifetime
            probe.lifetimes.track(session.container)
            try XCTUnwrap(probe.mount)(session)
        }
        await fulfillment(of: [probe.loaded], timeout: 3)
        if usesQuery { XCTAssertEqual(probe.queryRowCount, 1, "The real Query must fetch its seeded row before retirement") }
        if let coverLoaded = probe.coverLoaded {
            try XCTUnwrap(probe.presentCover)()
            await fulfillment(of: [coverLoaded, try XCTUnwrap(probe.coverDidAppear)], timeout: 5)
            XCTAssertEqual(probe.coverQueryRowCount, 1)
        }
        XCTAssertNotNil(probe.container)
        if queuesModelChangeBeforeRetirement {
            // Commit a real context change immediately before removing the
            // Query graph, matching pause-save followed by a background edge.
            // Do not retain this context/container across retirement or await
            // an arbitrary delay that would drain the pending update first.
            try autoreleasepool {
                let container = try XCTUnwrap(probe.container)
                let context = ModelContext(container)
                let subject = try XCTUnwrap(context.fetch(FetchDescriptor<Subject>()).first)
                subject.name = "Synthetic Query Updated Before Retirement"
                try context.save()
            }
        }
        try XCTUnwrap(probe.retire)()
        await fulfillment(of: [probe.unmounted, probe.finished], timeout: 5)

        XCTAssertNotNil(probe.retire, "Keep the loaded render's callback alive throughout retirement")
        XCTAssertEqual(probe.outcome, .retired)
        XCTAssertNil(probe.container, "A captured Host value must not keep its previous session alive")
        XCTAssertNil(probe.viewLifetime, "The removed view graph must release its container lease")
        if presentsQueryCover {
            XCTAssertEqual(probe.coverTeardownRowCount, 1,
                           "The disappearing Query graph must still have a usable store")
        }
        XCTAssertNoThrow(try probe.lifetimes.requireAllReleased())
    }

    func testRetainedViewEnvironmentKeepsStoreUsableWithoutRestoringSessionAuthority() throws {
        let holder = PersistenceSessionHolder<SessionLifetimeSession>()
        let lifetimes = PersistenceContainerLifetimeTracker<ModelContainer>()
        weak var container: ModelContainer?
        weak var viewLifetime: PersistenceViewContainerLifetime?
        var retainedEnvironment: EnvironmentValues?
        let sessionID = try autoreleasepool {
            let session = try SessionLifetimeSession()
            session.container.mainContext.insert(Subject(name: "Synthetic Retained Environment",
                                                        colorHex: "#445566", sortOrder: 0))
            try session.container.mainContext.save()
            holder.session = session
            container = session.container
            viewLifetime = session.viewLifetime
            lifetimes.track(session.container)
            var environment = EnvironmentValues()
            environment.modelContext = session.container.mainContext
            environment.persistenceViewContainerLifetime = session.viewLifetime
            retainedEnvironment = environment
            return session.id
        }

        holder.session = nil
        XCTAssertNil(holder.resolve(sessionID), "A retained graph has no authority to start session work")
        XCTAssertNotNil(container)
        XCTAssertNotNil(viewLifetime)
        XCTAssertThrowsError(try lifetimes.requireAllReleased(),
                             "Another store must not open while an old graph still owns this one")
        try autoreleasepool {
            let environment = try XCTUnwrap(retainedEnvironment)
            XCTAssertEqual(try environment.modelContext.fetchCount(FetchDescriptor<Subject>()), 1)
        }

        // This control deliberately owns an EnvironmentValues copy. The hosted
        // regression above owns no such copy and tests SwiftUI's actual graph.
        retainedEnvironment = nil
        XCTAssertNil(container)
        XCTAssertNil(viewLifetime)
        XCTAssertNoThrow(try lifetimes.requireAllReleased())
        XCTAssertNil(holder.resolve(sessionID))
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
    let viewLifetime: PersistenceViewContainerLifetime

    init() throws {
        let schema = Schema([Subject.self])
        container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        viewLifetime = PersistenceViewContainerLifetime(container: container)
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
    weak var viewLifetime: PersistenceViewContainerLifetime?
    var mount: ((SessionLifetimeSession) -> Void)?
    var retire: (() -> Void)?
    var retirementTask: Task<Void, Never>?
    var outcome: PersistenceContainerRetirementPollDecision?
    var queryRowCount: Int?
    var coverQueryRowCount: Int?
    var coverTeardownRowCount: Int?
    var coverLoaded: XCTestExpectation?
    var coverDidAppear: XCTestExpectation?
    var presentCover: (() -> Void)?
    var didLoad = false
    var retirementRequested = false

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
    var usesQuery = false
    var presentsQueryCover = false
    @State private var sessionHolder = PersistenceSessionHolder<SessionLifetimeSession>()
    private var session: SessionLifetimeSession? {
        get { sessionHolder.session }
        nonmutating set { sessionHolder.session = newValue }
    }

    var body: some View {
        Group {
            if let session {
                Group {
                    if usesQuery {
                        SessionLifetimeQueryContent(probe: probe, presentsQueryCover: presentsQueryCover)
                    } else {
                        Text("Loaded")
                    }
                }
                    .id(session.id)
                    .modelContainer(session.container)
                    .environment(\.persistenceViewContainerLifetime, session.viewLifetime)
                    .onAppear {
                        // Store a method from this loaded render, preserving
                        // the same Host value captured by its retirement Task.
                        probe.retire = retireSession
                        if !probe.didLoad {
                            probe.didLoad = true
                            probe.loaded.fulfill()
                        }
                    }
                    .onDisappear {
                        if probe.retirementRequested { probe.unmounted.fulfill() }
                    }
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
        probe.retirementRequested = true
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

@MainActor
private struct SessionLifetimeQueryContent: View {
    let probe: SessionLifetimeProbe
    let presentsQueryCover: Bool
    @Query(sort: \Subject.sortOrder) private var subjects: [Subject]
    @State private var isCoverPresented = false

    var body: some View {
        Group {
            if presentsQueryCover {
                NavigationStack {
                    Text("Query rows: \(subjects.count)")
                        .navigationTitle("Synthetic Query Root")
                        .fullScreenCover(isPresented: $isCoverPresented) {
                            SessionLifetimeQueryCover(probe: probe)
                        }
                }
            } else {
                Text("Query rows: \(subjects.count)")
            }
        }
        .onAppear {
            probe.queryRowCount = subjects.count
            let binding = $isCoverPresented
            probe.presentCover = { binding.wrappedValue = true }
        }
    }
}

@MainActor
private struct SessionLifetimeQueryCover: View {
    let probe: SessionLifetimeProbe
    @Query(sort: \Subject.sortOrder) private var subjects: [Subject]

    var body: some View {
        Text("Presented Query rows: \(subjects.count)")
            .background(SessionLifetimeCoverAppearance(probe: probe))
            .onAppear {
                probe.coverQueryRowCount = subjects.count
                probe.coverLoaded?.fulfill()
            }
            .onDisappear {
                // Read only through the weak observer during teardown. This
                // callback does not extend the graph's lifetime across a turn.
                probe.coverTeardownRowCount = try? probe.container?.mainContext.fetchCount(FetchDescriptor<Subject>())
            }
    }
}

@MainActor
private struct SessionLifetimeCoverAppearance: UIViewControllerRepresentable {
    let probe: SessionLifetimeProbe

    func makeUIViewController(context: Context) -> Controller { Controller(probe: probe) }
    func updateUIViewController(_ uiViewController: Controller, context: Context) {}

    final class Controller: UIViewController {
        let probe: SessionLifetimeProbe
        private var reported = false

        init(probe: SessionLifetimeProbe) {
            self.probe = probe
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("Not used by this synthetic fixture") }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !reported else { return }
            reported = true
            probe.coverDidAppear?.fulfill()
        }
    }
}

/// Test-only replay of the launch Host's Group/task, scene retirement, and
/// watchdog callbacks. All account callbacks are injected and use no CloudKit.
@MainActor
private final class DeadlineLifecycleProbe {
    let loaded: XCTestExpectation
    let retirementStarted: XCTestExpectation
    let activeWhileQuiescing: XCTestExpectation
    let resumedLookup: XCTestExpectation
    let expired: XCTestExpectation
    let expiredGenerationObserved: XCTestExpectation
    var changePhase: ((ScenePhase) -> Void)?
    var cancelDeadline: (() -> Void)?
    var retry: (() -> Void)?
    var retryRendered: XCTestExpectation?
    var retryRenderedAttempt: Int?
    var allowsRetryLookup = false
    var events: [String] = []
    var status = "idle"
    var lookupCount = 0
    var automaticallyRenewed = false
    var expiredAttempt: Int?
    var didReportExpiredTask = false
    var didReportLoaded = false
    var delaysExpiredTaskUntilRetired = false
    private var didFinishExpiryRetirement = false
    private var expiryTaskContinuation: CheckedContinuation<Void, Never>?
    private var isTearingDown = false
    private var retirementContinuation: CheckedContinuation<Void, Never>?
    private var accountContinuations: [CheckedContinuation<CKAccountStatus, Never>] = []

    init(loaded: XCTestExpectation, retirementStarted: XCTestExpectation,
         activeWhileQuiescing: XCTestExpectation,
         resumedLookup: XCTestExpectation, expired: XCTestExpectation,
         expiredGenerationObserved: XCTestExpectation) {
        self.loaded = loaded
        self.retirementStarted = retirementStarted
        self.activeWhileQuiescing = activeWhileQuiescing
        self.resumedLookup = resumedLookup
        self.expired = expired
        self.expiredGenerationObserved = expiredGenerationObserved
    }

    func accountStatus() async -> CKAccountStatus {
        lookupCount += 1
        events.append("account-lookup-\(lookupCount)")
        if lookupCount == 1 || allowsRetryLookup || isTearingDown { return .available }
        return await withCheckedContinuation {
            accountContinuations.append($0)
            if lookupCount == 2 { resumedLookup.fulfill() }
        }
    }

    func waitForRetirement() async {
        await withCheckedContinuation {
            retirementContinuation = $0
            retirementStarted.fulfill()
        }
    }

    func releaseRetirement() {
        retirementContinuation?.resume()
        retirementContinuation = nil
    }

    func releaseAccountLookups() {
        isTearingDown = true
        let pending = accountContinuations
        accountContinuations.removeAll()
        pending.forEach { $0.resume(returning: .available) }
    }

    func waitUntilExpiryRetirementFinishes() async {
        events.append("invalidated-task-waits-for-retirement")
        guard !didFinishExpiryRetirement else { return }
        await withCheckedContinuation { expiryTaskContinuation = $0 }
    }

    func expiryRetirementFinished() {
        didFinishExpiryRetirement = true
        events.append("expiry-retirement-finished")
        expiryTaskContinuation?.resume()
        expiryTaskContinuation = nil
    }

    func reportExpiredTask(attempt: Int, admitted: Bool) {
        guard attempt == expiredAttempt, !didReportExpiredTask else { return }
        didReportExpiredTask = true
        automaticallyRenewed = admitted
        expiredGenerationObserved.fulfill()
    }
}

@MainActor
private struct DeadlineLifecycleHost: View {
    let probe: DeadlineLifecycleProbe
    let resolver: AppleAccountBoundaryResolver
    @State private var loaded = false
    @State private var launchAttempt = 0
    @State private var launchAttemptGate = PersistenceLaunchAttemptGate()
    @State private var isPreparing = false
    @State private var isQuiescing = false
    @State private var scenePhase: ScenePhase = .active
    @State private var status = "idle"
    @State private var cloudDeadline: CloudLaunchDeadline?

    var body: some View {
        Group {
            if loaded {
                Text("Loaded").id("verified-session")
                    .onAppear {
                        if !probe.didReportLoaded {
                            probe.didReportLoaded = true
                            probe.loaded.fulfill()
                        } else if let retryRendered = probe.retryRendered, probe.retryRenderedAttempt == nil {
                            probe.retryRenderedAttempt = launchAttempt
                            retryRendered.fulfill()
                        }
                    }
            } else {
                Text(status)
            }
        }
        .task(id: launchAttempt) {
            if probe.delaysExpiredTaskUntilRetired, launchAttempt == probe.expiredAttempt {
                // Control only task scheduling. SwiftUI may legally deliver
                // this new-generation task after the retirement continuation.
                await probe.waitUntilExpiryRetirementFinishes()
            }
            await prepare()
        }
        .onAppear {
            probe.changePhase = { scenePhase = $0 }
            probe.cancelDeadline = { cloudDeadline?.cancel() }
            probe.retry = {
                guard !isPreparing, !isQuiescing else { return }
                setStatus("preparing")
                launchAttempt += 1
            }
        }
        .onChange(of: scenePhase) { _, phase in handleScene(phase) }
    }

    private func setStatus(_ value: String) {
        status = value
        probe.status = value
        probe.events.append("status-\(value)-\(launchAttempt)")
    }

    private func prepare() async {
        let attempt = launchAttempt
        probe.events.append("task-start-\(attempt)-quiescing-\(isQuiescing)")
        guard !loaded, !isQuiescing, launchAttemptGate.allowsPreparation(for: attempt) else {
            probe.reportExpiredTask(attempt: attempt, admitted: false)
            return
        }
        isPreparing = true
        var ownedDeadline: CloudLaunchDeadline?
        defer {
            ownedDeadline?.cancel()
            if let ownedDeadline, cloudDeadline === ownedDeadline { cloudDeadline = nil }
            if launchAttempt == attempt { isPreparing = false }
            probe.events.append("task-finish-\(attempt)")
        }
        do {
            let deadline = beginDeadline(attempt: attempt)
            ownedDeadline = deadline
            setStatus("verifying")
            probe.reportExpiredTask(attempt: attempt, admitted: true)
            _ = try await deadline.run { try await resolver.resolve() }
            try Task.checkCancellation()
            guard launchAttempt == attempt else { return }
            try deadline.finish()
            loaded = true
        } catch is CancellationError {
            probe.events.append("task-cancelled-\(attempt)")
        } catch {
            guard launchAttempt == attempt, !Task.isCancelled else { return }
            setStatus("failed")
        }
    }

    private func beginDeadline(attempt: Int) -> CloudLaunchDeadline {
        cloudDeadline?.cancel()
        var expiryGeneration: Int?
        let deadline = CloudLaunchDeadline(timeout: probe.didReportLoaded ? 0.1 : 3,
            invalidateAttempt: {
                guard launchAttempt == attempt, !loaded else { return }
                isQuiescing = true
                isPreparing = false
                launchAttempt += 1
                launchAttemptGate.suppressAutomaticStart(for: launchAttempt)
                expiryGeneration = launchAttempt
                probe.expiredAttempt = launchAttempt
                probe.events.append("expired-\(attempt)-invalidated-as-\(launchAttempt)")
            }, onExpiry: {
                guard let expiryGeneration, launchAttempt == expiryGeneration,
                      !loaded, isQuiescing else { return }
                setStatus("timedOut")
                probe.expired.fulfill()
                Task { @MainActor in
                    // The real Host's async retirement function returns
                    // immediately when its weak tracker has no live stores.
                    await alreadyReleased()
                    guard launchAttempt == expiryGeneration else { return }
                    isQuiescing = false
                    setStatus("timedOut")
                    probe.expiryRetirementFinished()
                }
            })
        cloudDeadline = deadline
        return deadline
    }

    private func alreadyReleased() async {}

    private func handleScene(_ phase: ScenePhase) {
        probe.events.append("scene-\(phase)-\(launchAttempt)")
        if phase == .active, isQuiescing { probe.activeWhileQuiescing.fulfill() }
        if phase != .active {
            cloudDeadline?.cancel()
            cloudDeadline = nil
        }
        switch PersistenceLaunchScenePolicy.action(phase: phase, hasSession: loaded,
            isPreparing: isPreparing, isQuiescingAccountChange: isQuiescing,
            usesCloudAccountBoundary: true) {
        case .preparePersistence:
            setStatus("preparing")
            launchAttempt += 1
        case .retireCloudSession:
            loaded = false
            setStatus("retiring")
            isQuiescing = true
            launchAttempt += 1
            let generation = launchAttempt
            Task { @MainActor in
                await probe.waitForRetirement()
                guard launchAttempt == generation else { return }
                isPreparing = false
                isQuiescing = false
                if scenePhase == .active { launchAttempt += 1 }
            }
        default:
            break
        }
    }
}

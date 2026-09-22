import CloudKit
import Foundation
import XCTest
@testable import PomoGem

@MainActor
final class StorageTransferAccountNamespaceTests: XCTestCase {
    private let registryKey = "account-boundary.namespace-registry.v1"
    private let digest = String(repeating: "a", count: 64)

    private struct Fixture {
        let defaults: UserDefaults
        let directory: URL
        let store: StorageTransferJournalStore
        let old: ActiveAccountLocalBinding
        let new: ActiveAccountLocalBinding
        let registryBytes: Data
        let journal: StorageTransferJournal
    }

    private func client(account: String = "synthetic-namespace-account",
                        probe: @escaping @Sendable () async throws -> Void = {}) -> CloudAccountVerificationClient {
        let record = CKRecord.ID(recordName: account)
        return CloudAccountVerificationClient(accountStatus: { .available }, userRecordID: { record },
                                              probePrivateDatabase: probe)
    }

    private func fixture() async throws -> Fixture {
        let suite = "StorageTransferAccountNamespaceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let old = try await AppleAccountBoundaryResolver(defaults: defaults, client: client()).resolve().binding
        let new = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                        accountFingerprint: old.accountFingerprint))
        var registry = AppleAccountNamespaceRegistry()
        XCTAssertEqual(registry.resolve(.verified(fingerprint: old.accountFingerprint), expectedBinding: old), .allow(old))
        let registryBytes = try JSONEncoder().encode(registry)
        defaults.set(registryBytes, forKey: registryKey)
        let store = StorageTransferJournalStore(directory: directory)
        let journal = try StorageTransferJournal(choice: .enableCloudKeepingCloud,
            source: .cloud(binding: old), destination: .cloud(binding: new), cloudBinding: new)
        return Fixture(defaults: defaults, directory: directory, store: store, old: old, new: new,
                       registryBytes: registryBytes, journal: journal)
    }

    private func resolver(_ f: Fixture,
                          client: CloudAccountVerificationClient? = nil) -> AppleAccountBoundaryResolver {
        AppleAccountBoundaryResolver(defaults: f.defaults, client: client ?? self.client(),
                                     retryDelay: 0, transferJournalStore: f.store)
    }

    private func expectBlocked(_ reason: AppleAccountBoundaryBlockReason = .invalidStoredRegistry,
                               _ operation: () async throws -> ResolvedAppleAccountBoundary,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected fail-closed namespace decision", file: file, line: line) }
        catch { XCTAssertEqual(error as? AppleAccountBoundaryResolutionError, .blocked(reason), file: file, line: line) }
    }

    private func advance(_ journal: StorageTransferJournal, in store: StorageTransferJournalStore,
                         through phase: StorageTransferJournal.Phase) throws -> StorageTransferJournal {
        var current = journal
        for nextPhase in StorageTransferJournal.Phase.allCases where nextPhase > current.phase && nextPhase <= phase {
            if nextPhase == .selectionCommitted { try store.commitSelection(for: current) }
            let next = try current.advancing(to: nextPhase,
                sourceDigest: nextPhase == .sourceSaved ? digest : nil,
                destinationDigest: nextPhase == .destinationSaved ? digest : nil,
                remoteRecoveryTransactionID: nextPhase == .recoveryCopySaved && current.choice.replacesCloud
                    ? current.transactionID : nil)
            try store.save(next, replacing: current)
            current = next
        }
        return current
    }

    func testUnrecordedReplacementCannotOverrideLegacyNamespace() async throws {
        let f = try await fixture()
        await expectBlocked { try await self.resolver(f).resolve(expectedBinding: f.new) }
        let ordinary = try await resolver(f).resolve()
        XCTAssertEqual(ordinary.binding, f.old)
        XCTAssertEqual(f.defaults.data(forKey: registryKey), f.registryBytes)
    }

    func testRecordedSameAccountRefreshAllowsExactDestinationWithoutWritingRegistry() async throws {
        let f = try await fixture()
        try f.store.begin(f.journal)
        let result = try await resolver(f).resolve(expectedBinding: f.new)
        XCTAssertEqual(result.binding, f.new)
        let source = try await resolver(f).resolve(expectedBinding: f.old)
        XCTAssertEqual(source.binding, f.old, "Before commit, source authentication is still needed for the frozen copy")
        let unrelated = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                              accountFingerprint: f.old.accountFingerprint))
        await expectBlocked { try await self.resolver(f).resolve(expectedBinding: unrelated) }
        XCTAssertEqual(f.defaults.data(forKey: registryKey), f.registryBytes)
        XCTAssertEqual(try f.store.load(), f.journal)
        XCTAssertNil(try f.store.committedSelection())
    }

    func testPendingRefreshStillRejectsAnotherLiveAccount() async throws {
        let f = try await fixture()
        try f.store.begin(f.journal)
        await expectBlocked(.accountMismatch) {
            try await self.resolver(f, client: self.client(account: "different-synthetic-account"))
                .resolve(expectedBinding: f.new)
        }
        XCTAssertEqual(f.defaults.data(forKey: registryKey), f.registryBytes)
    }

    func testDestinationCannotAliasAnotherAccountsRegisteredNamespace() async throws {
        let f = try await fixture()
        var registry = try JSONDecoder().decode(AppleAccountNamespaceRegistry.self, from: f.registryBytes)
        let other = String(repeating: "b", count: 64)
        _ = registry.resolve(.verified(fingerprint: other), makeNamespace: { f.new.namespace })
        let bytes = try JSONEncoder().encode(registry)
        f.defaults.set(bytes, forKey: registryKey)
        try f.store.begin(f.journal)
        await expectBlocked { try await self.resolver(f).resolve(expectedBinding: f.new) }
        XCTAssertEqual(f.defaults.data(forKey: registryKey), bytes)
    }

    func testSourceMustMatchLegacyRegistryWhenNoPriorReceiptExists() async throws {
        let f = try await fixture()
        let unselectedSource = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                                    accountFingerprint: f.old.accountFingerprint))
        let request = try StorageTransferJournal(choice: .enableCloudKeepingCloud,
            source: .cloud(binding: unselectedSource), destination: .cloud(binding: f.new), cloudBinding: f.new)
        try f.store.begin(request)
        await expectBlocked { try await self.resolver(f).resolve(expectedBinding: f.new) }
    }

    func testAtomicCommitImmediatelyForbidsOldNamespaceIncludingCrashBeforePhaseUpdate() async throws {
        let f = try await fixture()
        try f.store.begin(f.journal)
        let verified = try advance(f.journal, in: f.store, through: .destinationVerified)
        try f.store.commitSelection(for: verified)
        XCTAssertEqual(try f.store.load()?.phase, .destinationVerified)
        let implicit = try await resolver(f).resolve()
        let explicit = try await resolver(f).resolve(expectedBinding: f.new)
        XCTAssertEqual(implicit.binding, f.new)
        XCTAssertEqual(explicit.binding, f.new)
        await expectBlocked { try await self.resolver(f).resolve(expectedBinding: f.old) }
        XCTAssertEqual(f.defaults.data(forKey: registryKey), f.registryBytes)
    }

    func testFinishedRefreshSurvivesNewResolverAndNeverFallsBackToLegacyCache() async throws {
        let f = try await fixture()
        try f.store.begin(f.journal)
        let complete = try advance(f.journal, in: f.store, through: .sourceRetired)
        try f.store.finish(complete)
        XCTAssertNil(try f.store.load())
        let reopened = StorageTransferJournalStore(directory: f.directory)
        let resolver = AppleAccountBoundaryResolver(defaults: f.defaults, client: client(), transferJournalStore: reopened)
        let result = try await resolver.resolve()
        XCTAssertEqual(result.binding, f.new)
        await expectBlocked { try await resolver.resolve(expectedBinding: f.old) }
        XCTAssertEqual(f.defaults.data(forKey: registryKey), f.registryBytes)
    }

    func testSecondRefreshUsesCommittedSourceDespiteMuchOlderLegacyMapping() async throws {
        let f = try await fixture()
        try f.store.begin(f.journal)
        try f.store.finish(advance(f.journal, in: f.store, through: .sourceRetired))
        let newest = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                           accountFingerprint: f.old.accountFingerprint))
        let next = try StorageTransferJournal(choice: .enableCloudKeepingCloud,
            source: .cloud(binding: f.new), destination: .cloud(binding: newest), cloudBinding: newest)
        try f.store.begin(next)
        let pendingResult = try await resolver(f).resolve(expectedBinding: newest)
        XCTAssertEqual(pendingResult.binding, newest)
        await expectBlocked { try await self.resolver(f).resolve(expectedBinding: f.old) }
        try f.store.finish(advance(next, in: f.store, through: .sourceRetired))
        let committedResult = try await resolver(f).resolve()
        XCTAssertEqual(committedResult.binding, newest)
        await expectBlocked { try await self.resolver(f).resolve(expectedBinding: f.new) }
    }

    func testNonRefreshJournalDoesNotPermitAnArbitraryNewNamespace() async throws {
        let f = try await fixture()
        let request = try StorageTransferJournal(choice: .enableCloudKeepingCloud,
            source: .localOnly(namespace: AccountDataNamespace()), destination: .cloud(binding: f.old), cloudBinding: f.old)
        try f.store.begin(request)
        let result = try await resolver(f).resolve(expectedBinding: f.old)
        XCTAssertEqual(result.binding, f.old)
        await expectBlocked { try await self.resolver(f).resolve(expectedBinding: f.new) }
    }

    func testUnknownOrMalformedAuthorityNeverFallsBackToLegacyRegistry() async throws {
        for name in ["pending-v1.json", "selection-v1.json"] {
            for malformed in [false, true] {
                let f = try await fixture()
                try f.store.begin(f.journal)
                _ = try advance(f.journal, in: f.store, through: .selectionCommitted)
                let file = f.directory.appendingPathComponent(name)
                if malformed { try Data("invalid".utf8).write(to: file) }
                else {
                    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
                    json["unknownFutureNamespacePermission"] = true
                    try JSONSerialization.data(withJSONObject: json).write(to: file)
                }
                await expectBlocked { try await self.resolver(f).resolve(expectedBinding: f.new) }
                await expectBlocked { try await self.resolver(f).resolve(expectedBinding: f.old) }
            }
        }
    }

    func testCancelledJournalDuringOnlineProofCannotPublishDestination() async throws {
        let f = try await fixture()
        try f.store.begin(f.journal)
        let gate = NamespaceVerificationGate(started: expectation(description: "online probe waiting"))
        let finished = expectation(description: "resolution finished")
        let resolver = resolver(f, client: client(probe: { await gate.wait() }))
        var failure: AppleAccountBoundaryResolutionError?
        let task = Task {
            defer { finished.fulfill() }
            do { _ = try await resolver.resolve(expectedBinding: f.new); XCTFail("Cancelled request authorized namespace") }
            catch { failure = error as? AppleAccountBoundaryResolutionError }
        }
        await fulfillment(of: [gate.started], timeout: 3)
        try f.store.cancel(f.journal)
        await gate.release()
        await fulfillment(of: [finished], timeout: 3)
        await task.value
        XCTAssertEqual(failure, .blocked(.invalidStoredRegistry))
        XCTAssertEqual(f.defaults.data(forKey: registryKey), f.registryBytes)
    }

    func testCommittedLocalOnlyReceiptKeepsOrdinaryOnlineRegistryPolicyForReenable() async throws {
        let f = try await fixture()
        let request = try StorageTransferJournal(choice: .disableCloudKeepingCopy, source: .cloud(binding: f.old),
            destination: .localOnly(namespace: AccountDataNamespace()), cloudBinding: f.old)
        try f.store.begin(request)
        try f.store.finish(advance(request, in: f.store, through: .sourceRetired))
        let result = try await resolver(f).resolve()
        XCTAssertEqual(result.binding, f.old)
        await expectBlocked { try await self.resolver(f).resolve(expectedBinding: f.new) }
        XCTAssertEqual(f.defaults.data(forKey: registryKey), f.registryBytes)
    }

    func testDisableAfterRefreshCanResumeRetirementAfterLocalCommit() async throws {
        let f = try await fixture()
        try f.store.begin(f.journal)
        try f.store.finish(advance(f.journal, in: f.store, through: .sourceRetired))
        let disable = try StorageTransferJournal(choice: .disableCloudKeepingCopy, source: .cloud(binding: f.new),
            destination: .localOnly(namespace: AccountDataNamespace()), cloudBinding: f.new)
        try f.store.begin(disable)
        let verified = try advance(disable, in: f.store, through: .destinationVerified)
        try f.store.commitSelection(for: verified)
        // Cover the crash between receipt commit and journal phase update.
        let beforePhase = try await resolver(f).resolve(expectedBinding: f.new)
        XCTAssertEqual(beforePhase.binding, f.new)
        let committed = try advance(verified, in: f.store, through: .selectionCommitted)
        let afterPhase = try await resolver(f).resolve(expectedBinding: f.new)
        XCTAssertEqual(afterPhase.binding, f.new)
        await expectBlocked { try await self.resolver(f).resolve(expectedBinding: f.old) }
        try f.store.finish(advance(committed, in: f.store, through: .sourceRetired))
        let reenable = try await resolver(f).resolve()
        XCTAssertEqual(reenable.binding, f.old, "After retirement only ordinary reenable policy remains")
        XCTAssertEqual(f.defaults.data(forKey: registryKey), f.registryBytes)
    }

    func testExplicitReenableFromCommittedLocalCopyCanUseNewAppleAccountOnlyAtExactDestination() async throws {
        let f = try await fixture()
        let local = PersistenceDeploymentSelection.localOnly(namespace: AccountDataNamespace())
        let disable = try StorageTransferJournal(choice: .disableCloudKeepingCopy,
            source: .cloud(binding: f.old), destination: local, cloudBinding: f.old)
        try f.store.begin(disable)
        try f.store.finish(advance(disable, in: f.store, through: .sourceRetired))
        let accountB = client(account: "synthetic-namespace-account-B")
        let nextBinding = try await resolver(f, client: accountB).resolve().binding
        let request = try StorageTransferJournal(choice: .enableCloudKeepingCloud, source: local,
            destination: .cloud(binding: nextBinding), cloudBinding: nextBinding)
        try f.store.begin(request)
        let result = try await resolver(f, client: accountB).resolve(expectedBinding: nextBinding)
        XCTAssertEqual(result.binding, nextBinding)
        let arbitrary = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                              accountFingerprint: nextBinding.accountFingerprint))
        await expectBlocked { try await self.resolver(f, client: accountB).resolve(expectedBinding: arbitrary) }
        await expectBlocked(.accountMismatch) { try await self.resolver(f).resolve(expectedBinding: nextBinding) }
        XCTAssertEqual(f.defaults.data(forKey: registryKey), f.registryBytes)
        let file = f.directory.appendingPathComponent("pending-v1.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["source"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            PersistenceDeploymentSelection.localOnly(namespace: AccountDataNamespace())))
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        await expectBlocked { try await self.resolver(f, client: accountB).resolve(expectedBinding: nextBinding) }
    }

    // MARK: - Device -> iCloud overwrite

    private func overwrite(_ f: Fixture) throws -> StorageTransferJournal {
        try StorageTransferJournal(choice: .overwriteCloudFromDevice,
            source: .cloud(binding: f.old), destination: .cloud(binding: f.new), cloudBinding: f.new)
    }

    func testRecordedCloudSourceOverwriteAuthorizesOnlyItsRecordedDestination() async throws {
        let f = try await fixture()
        try f.store.begin(overwrite(f))
        let result = try await resolver(f).resolve(expectedBinding: f.new)
        XCTAssertEqual(result.binding, f.new)
        let source = try await resolver(f).resolve(expectedBinding: f.old)
        XCTAssertEqual(source.binding, f.old, "Before commit the frozen source must still authenticate")
        let unrelated = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                               accountFingerprint: f.old.accountFingerprint))
        await expectBlocked { try await self.resolver(f).resolve(expectedBinding: unrelated) }
        XCTAssertEqual(f.defaults.data(forKey: registryKey), f.registryBytes)
    }

    func testCommittedOverwriteReceiptMakesTheOldCloudSourceIneligible() async throws {
        let f = try await fixture()
        let journal = try overwrite(f)
        try f.store.begin(journal)
        let verified = try advance(journal, in: f.store, through: .destinationVerified)
        try f.store.commitSelection(for: verified)
        let committed = try await resolver(f).resolve().binding
        XCTAssertEqual(committed, f.new)
        await expectBlocked { try await self.resolver(f).resolve(expectedBinding: f.old) }
        try f.store.finish(advance(verified, in: f.store, through: .sourceRetired))
        let reopened = StorageTransferJournalStore(directory: f.directory)
        let after = AppleAccountBoundaryResolver(defaults: f.defaults, client: client(),
                                                 transferJournalStore: reopened)
        let reresolved = try await after.resolve().binding
        XCTAssertEqual(reresolved, f.new)
        await expectBlocked { try await after.resolve(expectedBinding: f.old) }
        XCTAssertEqual(f.defaults.data(forKey: registryKey), f.registryBytes)
    }

    func testOverwriteUnderAnotherLiveAccountIsBlocked() async throws {
        let f = try await fixture()
        try f.store.begin(overwrite(f))
        await expectBlocked(.accountMismatch) {
            try await self.resolver(f, client: self.client(account: "different-synthetic-account"))
                .resolve(expectedBinding: f.new)
        }
        XCTAssertEqual(f.defaults.data(forKey: registryKey), f.registryBytes)
    }

    /// The reinstall shape recoverRemoteTransfer synthesizes must keep exactly
    /// the authority the legacy replacement had from a committed local source.
    func testServerRecoveredOverwriteKeepsTheLegacyLocalSourceAuthority() async throws {
        let f = try await fixture()
        let local = PersistenceDeploymentSelection.localOnly(namespace: AccountDataNamespace())
        let disable = try StorageTransferJournal(choice: .disableCloudKeepingCopy,
            source: .cloud(binding: f.old), destination: local, cloudBinding: f.old)
        try f.store.begin(disable)
        try f.store.finish(advance(disable, in: f.store, through: .sourceRetired))
        let recovered = try StorageTransferJournal(choice: .overwriteCloudFromDevice,
            source: local, destination: .cloud(binding: f.new), cloudBinding: f.new)
        try f.store.begin(recovered)
        let authorized = try await resolver(f).resolve(expectedBinding: f.new).binding
        XCTAssertEqual(authorized, f.new)
        let arbitrary = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                               accountFingerprint: f.new.accountFingerprint))
        await expectBlocked { try await self.resolver(f).resolve(expectedBinding: arbitrary) }
        XCTAssertEqual(f.defaults.data(forKey: registryKey), f.registryBytes)
    }
}


private actor NamespaceVerificationGate {
    nonisolated let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(started: XCTestExpectation) { self.started = started }
    func wait() async {
        started.fulfill()
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}
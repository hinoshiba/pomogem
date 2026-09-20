import Foundation
import XCTest
@testable import PomoGem

/// Adversarial coverage for the hypothesis that the phone's
/// `StorageTransferRuntimeError.datasetRefreshRequired` is a BINDING mismatch
/// (a changed local namespace or a changed Apple Account fingerprint) rather
/// than a dataset-generation mismatch.
///
/// The admission record compared at StorageTransferRuntime.swift:153 is the
/// whole struct `StorageTransferDatasetAdmission { binding, datasetGenerationID }`
/// (StorageTransferRuntimeState.swift:159-162), so the hypothesis is at least
/// type-plausible. These tests establish the two structural facts that make it
/// unreachable in practice:
///
///  1. the admission file is keyed BY NAMESPACE (`admission-<namespace>.json`,
///     StorageTransferRuntime.swift:975), so a changed namespace selects a
///     DIFFERENT file, `load()` returns nil, and control never reaches the
///     equality guard;
///  2. a changed account fingerprint is rejected by the namespace policy
///     (AppleAccountNamespaceRegistry.resolve, PersistenceStoreTopology.swift:43-46)
///     with `.accountMismatch` BEFORE any cloud mount preflight runs, and a
///     fingerprint with no registry entry is given a fresh namespace, i.e.
///     again a different admission file.
@MainActor
final class StorageTransferBindingMismatchRefutationTests: XCTestCase {
    private let account = String(repeating: "a", count: 64)
    private let otherAccount = String(repeating: "b", count: 64)

    private struct Fixture {
        let parent: URL
        let root: URL
        let store: StorageTransferJournalStore
        let runtime: StorageTransferRuntime
    }

    private func fixture() throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("BindingMismatchRefutation-\(UUID())")
        let root = parent.appendingPathComponent("StorageTransfer", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let store = StorageTransferJournalStore(directory: root)
        return Fixture(parent: parent, root: root, store: store,
                       runtime: StorageTransferRuntime(store: store, root: root))
    }

    private func admissionFile(_ root: URL, _ binding: ActiveAccountLocalBinding)
        throws -> StorageTransferStateFile<StorageTransferDatasetAdmission> {
        try StorageTransferStateFile(
            url: root.appendingPathComponent(StorageTransferRuntime.admissionFileName(
                namespace: binding.namespace, scope: .unknown)))
    }

    private func committedControl(fingerprint: String) throws -> StorageTransferRecoveryControl {
        let payload = Data("binding refutation payload".utf8)
        let manifest = try StorageTransferRecoveryManifest(transactionID: UUID(),
            accountFingerprint: fingerprint, payload: payload, previousDatasetGenerationID: nil)
        let digest = StorageTransferRecoverySchema.digest(payload)
        return try StorageTransferRecoveryControl(manifest: manifest)
            .advancing(to: .backupVerified)
            .advancing(to: .replacing)
            .advancing(to: .committed, verifiedDestinationSHA256: digest)
    }

    // MARK: - 1. A changed namespace cannot trip the equality guard

    /// The device already holds `admission-<A>.json` recording generation G.
    /// A refresh/reinstall that minted namespace B now preflights with binding
    /// B against the SAME unchanged server generation G. If the admission
    /// comparison were binding-sensitive in the way the hypothesis claims, this
    /// would raise `datasetRefreshRequired`. It does not: the file for B does
    /// not exist, so the enrolment arm runs and writes `admission-<B>.json`.
    func testChangedNamespaceEnrolsInsteadOfTrippingTheAdmissionComparison() async throws {
        let f = try fixture()
        let old = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                          accountFingerprint: account))
        let control = try committedControl(fingerprint: account)
        let generation = try XCTUnwrap(control.datasetGenerationID)
        try admissionFile(f.root, old).save(
            StorageTransferDatasetAdmission(binding: old, datasetGenerationID: generation),
            replacing: nil)

        // Same account, brand-new namespace, unchanged server generation.
        let new = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                          accountFingerprint: account))
        try await f.runtime.preflightCloudMount(binding: new,
            readControl: { control }, validateAccess: {})

        let enrolled = try XCTUnwrap(try admissionFile(f.root, new).load())
        XCTAssertEqual(enrolled.binding, new,
            "The file written for a namespace always carries that namespace's own binding.")
        XCTAssertEqual(enrolled.datasetGenerationID, generation)
        let untouched = try XCTUnwrap(try admissionFile(f.root, old).load())
        XCTAssertEqual(untouched.binding, old,
            "The previous namespace's admission file is left in place and is never consulted again.")
    }

    /// The file-naming invariant stated positively: whatever binding the
    /// preflight is called with, the record it loads back was written under a
    /// file name derived from that same namespace, so `found.binding.namespace`
    /// can never differ from `binding.namespace`.
    func testAdmissionRecordAlwaysCarriesTheNamespaceItIsFiledUnder() async throws {
        let f = try fixture()
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                              accountFingerprint: account))
        let control = try committedControl(fingerprint: account)
        try await f.runtime.preflightCloudMount(binding: binding,
            readControl: { control }, validateAccess: {})
        let written = try XCTUnwrap(try admissionFile(f.root, binding).load())
        XCTAssertEqual(written.binding.namespace, binding.namespace)
        XCTAssertEqual(written.binding.accountFingerprint, binding.accountFingerprint)

        // A second, unchanged preflight is a no-op: equality holds.
        try await f.runtime.preflightCloudMount(binding: binding,
            readControl: { control }, validateAccess: {})
    }

    // MARK: - 2. A changed fingerprint never reaches the preflight

    /// If a foreign fingerprint COULD be handed to the preflight on the same
    /// namespace, the whole-struct comparison would indeed fire. This test
    /// records that counterfactual so the next two tests can show the state is
    /// unreachable, not merely unobserved.
    func testForeignFingerprintOnTheSameNamespaceWouldTripTheGuardIfItCouldOccur() async throws {
        let f = try fixture()
        let namespace = AccountDataNamespace()
        let mine = try XCTUnwrap(ActiveAccountLocalBinding(namespace: namespace,
                                                           accountFingerprint: account))
        let foreign = try XCTUnwrap(ActiveAccountLocalBinding(namespace: namespace,
                                                              accountFingerprint: otherAccount))
        let control = try committedControl(fingerprint: account)
        let generation = try XCTUnwrap(control.datasetGenerationID)
        try admissionFile(f.root, foreign).save(
            StorageTransferDatasetAdmission(binding: foreign, datasetGenerationID: generation),
            replacing: nil)

        do {
            try await f.runtime.preflightCloudMount(binding: mine,
                readControl: { control }, validateAccess: {})
            XCTFail("Expected datasetRefreshRequired for a same-namespace fingerprint difference")
        } catch {
            // Deliberately still the LEGACY error: the binding guard is the one
            // arm of the old comparison that was never about dataset lineage,
            // and it stays fail-closed under its own, now clearly separate name.
            XCTAssertEqual(error as? StorageTransferRuntimeError, .datasetRefreshRequired)
            XCTAssertNil(CloudOfflineHostPolicy.datasetLineageBlock(
                for: StorageTransferRuntimeError.datasetRefreshRequired),
                "A binding difference is not one of the four lineage states")
        }
    }

    /// The upstream gate. A selected cloud installation always resolves with an
    /// `expectedBinding`; a different verified fingerprint is blocked with
    /// `.accountMismatch` and the launch never calls `preflightCloudMount`.
    func testChangedFingerprintIsBlockedByThePolicyBeforeAnyPreflight() throws {
        var registry = AppleAccountNamespaceRegistry()
        let namespace = AccountDataNamespace()
        let mine = try XCTUnwrap(ActiveAccountLocalBinding(namespace: namespace,
                                                           accountFingerprint: account))
        XCTAssertEqual(registry.resolve(.verified(fingerprint: account),
                                        makeNamespace: { namespace }), .allow(mine))

        XCTAssertEqual(registry.resolve(.verified(fingerprint: otherAccount), expectedBinding: mine),
                       .block(.accountMismatch),
                       "A changed Apple Account is an accountMismatch block, not a dataset refresh.")
    }

    /// And without an expected binding a new fingerprint receives a FRESH
    /// namespace, so it is filed under a different admission file rather than
    /// colliding with the previous account's record.
    func testANewFingerprintReceivesAFreshNamespaceRatherThanReusingTheOldOne() throws {
        var registry = AppleAccountNamespaceRegistry()
        let first = AccountDataNamespace()
        let second = AccountDataNamespace()
        _ = registry.resolve(.verified(fingerprint: account), makeNamespace: { first })
        let decision = registry.resolve(.verified(fingerprint: otherAccount),
                                        makeNamespace: { second })
        let expected = try XCTUnwrap(ActiveAccountLocalBinding(namespace: second,
                                                               accountFingerprint: otherAccount))
        XCTAssertEqual(decision, .allow(expected))
        XCTAssertNotEqual(second, first)
    }

    /// The namespace-replacement authority that is actually in force on a
    /// device with a committed cloud selection applies the same fingerprint
    /// gate, so a namespace hand-over after a transfer cannot smuggle a changed
    /// account into the preflight either.
    func testCommittedSelectionAuthorityAlsoBlocksAChangedFingerprint() throws {
        var registry = AppleAccountNamespaceRegistry()
        let namespace = AccountDataNamespace()
        let mine = try XCTUnwrap(ActiveAccountLocalBinding(namespace: namespace,
                                                           accountFingerprint: account))
        _ = registry.resolve(.verified(fingerprint: account), makeNamespace: { namespace })
        let authority = try StorageTransferAccountNamespaceAuthority.read(from: nil)
        XCTAssertNil(authority.decision(verifiedFingerprint: account, expectedBinding: mine,
                                        registry: registry),
                     "With no journal the authority delegates to the ordinary registry policy.")
        XCTAssertEqual(authority.decision(verifiedFingerprint: otherAccount, expectedBinding: mine,
                                          registry: registry),
                       .block(.accountMismatch))
    }
}

import Foundation
import XCTest
@testable import PomoGem

/// transfer-01 / device-01. 1.0 and 1.0.1 never wrote an admission receipt,
/// but they mounted this same Production mirror at this same store path and
/// recorded that mount. 1.0.2 enrolled such a store with a nil generation;
/// 1.1.0 refused it as an unconsented device -> iCloud publication and sent
/// every returning 1.0 / 1.0.1 iCloud user to the lineage stop screen on every
/// online launch, with no enabled way back to sync.
///
/// The rule that restores 1.0.2's behaviour is deliberately narrow. These
/// tests pin that it applies ONLY when every condition holds, and that every
/// neighbouring shape still fails closed exactly as before.
@MainActor
final class StorageTransferLegacyCloudAdoptionTests: XCTestCase {
    private let account = String(repeating: "d", count: 64)
    private let container = "iCloud.com.hinoshiba.pomogem"

    private var production: StorageTransferCloudScope {
        StorageTransferCloudScope(environment: .production, containerIdentifier: container)
    }
    private var development: StorageTransferCloudScope {
        StorageTransferCloudScope(environment: .development, containerIdentifier: container)
    }

    private let evidence = StorageTransferLegacyCloudMountEvidence(
        recordedCloudMountOfThisBinding: true, hasExactCompleteStorePair: true,
        offlineReceiptPostdatesAdmissionReceipts: false)

    // MARK: - The pure rule

    func testThePreReceiptShapeIsAdoptedOnlyWhenEveryConditionHolds() throws {
        XCTAssertTrue(StorageTransferLegacyCloudAdoptionPolicy.adoptsPreReceiptStore(
            scope: production, hasAdmissionReceiptUnderAnyName: false,
            serverControl: nil, evidence: evidence))
    }

    func testEachMissingConditionKeepsTheEnrolmentFailClosed() throws {
        let adopt = StorageTransferLegacyCloudAdoptionPolicy.adoptsPreReceiptStore
        XCTAssertFalse(adopt(development, false, nil, evidence),
                       "A Development build on a developer's phone keeps failing closed")
        XCTAssertFalse(adopt(.unknown, false, nil, evidence),
                       "An environment the host cannot prove is never Production")
        XCTAssertFalse(adopt(production, true, nil, evidence),
                       "Any receipt means a receipt-writing build has been here")
        XCTAssertFalse(adopt(production, false, try cancelledControlWithoutGeneration(), evidence),
                       "A terminal control with a nil generation is not an ABSENT control")
        XCTAssertFalse(adopt(production, false, nil, .none),
                       "No evidence gathered means no adoption")
        XCTAssertFalse(adopt(production, false, nil, StorageTransferLegacyCloudMountEvidence(
            recordedCloudMountOfThisBinding: false, hasExactCompleteStorePair: true,
            offlineReceiptPostdatesAdmissionReceipts: false)),
                       "A store this binding never mounted may hold rows that never mirrored here")
        XCTAssertFalse(adopt(production, false, nil, StorageTransferLegacyCloudMountEvidence(
            recordedCloudMountOfThisBinding: true, hasExactCompleteStorePair: false,
            offlineReceiptPostdatesAdmissionReceipts: false)))
        XCTAssertFalse(adopt(production, false, nil, StorageTransferLegacyCloudMountEvidence(
            recordedCloudMountOfThisBinding: true, hasExactCompleteStorePair: true,
            offlineReceiptPostdatesAdmissionReceipts: true)),
                       "A post-1.0.2 install that lost its receipt is not the pre-receipt shape")
    }

    func testOnlyAnOfflineReceiptFromAReceiptWritingBuildRulesAdoptionOut() throws {
        let binding = try makeBinding()
        func receipt(_ origin: CloudOfflineAccessOrigin, known: Bool,
                     used: Bool, revocation: CloudOfflineRevocationReason? = nil) -> CloudOfflineAccessReceipt {
            CloudOfflineAccessReceipt(revisionID: UUID(), binding: binding, origin: origin,
                isDatasetGenerationKnown: known, datasetGenerationID: nil, resetBaseline: nil,
                wasUsedOffline: used, revocation: revocation)
        }
        let postdates = StorageTransferLegacyCloudMountEvidence.offlineReceiptPostdatesAdmissionReceipts
        XCTAssertTrue(postdates(receipt(.verifiedOnline, known: true, used: false)))
        XCTAssertTrue(postdates(receipt(.legacySuccessfulMount, known: true, used: true)))
        // 1.1.0's own offline door on a 1.0.1 store, before it ever went online.
        XCTAssertFalse(postdates(receipt(.legacySuccessfulMount, known: false, used: true)))
        XCTAssertFalse(postdates(receipt(.revokedWithoutBaseline, known: false, used: false,
                                         revocation: .accountChanged)))
    }

    // MARK: - The runtime's `.enrol` arm

    /// The 1.0.1 upgrade: an existing cloud store, a recorded mount of this
    /// binding, no receipt of any kind and a healthy account with no transfer
    /// control record. It is enrolled with a nil generation, exactly as 1.0.2
    /// did, and the receipt records the Production scope it was earned in.
    func testAOnePointZeroOneStoreIsEnrolledWithANilGenerationInProduction() async throws {
        let f = try fixture(scope: production)
        try makeStoreArtifacts(f.binding)
        var reads = 0
        try await f.runtime.preflightCloudMount(binding: f.binding, readControl: {
            reads += 1
            return nil
        }, legacyCloudMountEvidence: { self.evidence }, validateAccess: {})

        XCTAssertEqual(reads, 2, "The second control read still guards the race")
        XCTAssertEqual(try admission(f, scope: production).load(),
                       StorageTransferDatasetAdmission(binding: f.binding, datasetGenerationID: nil,
                                                       cloudScope: production))
        XCTAssertNil(try f.store.load(), "Admission opens no transfer journal")

        // The next launch reads its own receipt and is simply admitted.
        try await f.runtime.preflightCloudMount(binding: f.binding,
            readControl: { nil }, validateAccess: {})
    }

    func testTheEvidenceIsNotReadWhileTheControlRecordExists() async throws {
        let f = try fixture(scope: production)
        try makeStoreArtifacts(f.binding)
        let control = try cancelledControlWithoutGeneration()
        var evidenceReads = 0
        await expectRefusal(.cloudLineageUnavailable) {
            try await f.runtime.preflightCloudMount(binding: f.binding, readControl: { control },
                legacyCloudMountEvidence: {
                    evidenceReads += 1
                    return self.evidence
                }, validateAccess: {})
        }
        XCTAssertEqual(evidenceReads, 0)
        XCTAssertNil(try admission(f, scope: production).load())
    }

    func testDefaultCallersNeverAdopt() async throws {
        let f = try fixture(scope: production)
        try makeStoreArtifacts(f.binding)
        await expectRefusal(.cloudLineageUnavailable) {
            try await f.runtime.preflightCloudMount(binding: f.binding,
                readControl: { nil }, validateAccess: {})
        }
        XCTAssertNil(try admission(f, scope: production).load())
    }

    func testADevelopmentBuildKeepsRefusingTheSameStore() async throws {
        let f = try fixture(scope: development)
        try makeStoreArtifacts(f.binding)
        var evidenceReads = 0
        await expectRefusal(.cloudLineageUnavailable) {
            try await f.runtime.preflightCloudMount(binding: f.binding, readControl: { nil },
                legacyCloudMountEvidence: {
                    evidenceReads += 1
                    return self.evidence
                }, validateAccess: {})
        }
        XCTAssertEqual(evidenceReads, 0)
        XCTAssertNil(try admission(f, scope: development).load())
    }

    func testAnotherEnvironmentsReceiptStillStopsAsAnEnvironmentMismatch() async throws {
        let f = try fixture(scope: production)
        try makeStoreArtifacts(f.binding)
        try admission(f, scope: development).save(StorageTransferDatasetAdmission(
            binding: f.binding, datasetGenerationID: UUID(), cloudScope: development), replacing: nil)
        await expectRefusal(.cloudEnvironmentMismatch) {
            try await f.runtime.preflightCloudMount(binding: f.binding, readControl: { nil },
                legacyCloudMountEvidence: { self.evidence }, validateAccess: {})
        }
        XCTAssertNil(try admission(f, scope: production).load())
    }

    /// The owner's phone: an unscoped Development-era receipt carrying a
    /// generation. That receipt is found, so this is not an enrolment at all
    /// and the rule is never consulted.
    func testALegacyReceiptWithAGenerationStillStopsOnTheLineageScreen() async throws {
        let f = try fixture(scope: production)
        try makeStoreArtifacts(f.binding)
        let recorded = StorageTransferDatasetAdmission(binding: f.binding, datasetGenerationID: UUID())
        try admission(f, scope: .unknown).save(recorded, replacing: nil)
        var evidenceReads = 0
        await expectRefusal(.cloudLineageUnavailable) {
            try await f.runtime.preflightCloudMount(binding: f.binding, readControl: { nil },
                legacyCloudMountEvidence: {
                    evidenceReads += 1
                    return self.evidence
                }, validateAccess: {})
        }
        XCTAssertEqual(evidenceReads, 0)
        XCTAssertEqual(try admission(f, scope: .unknown).load(), recorded)
    }

    func testAPostOnePointZeroTwoInstallThatLostItsReceiptIsNotAdopted() async throws {
        let f = try fixture(scope: production)
        try makeStoreArtifacts(f.binding)
        await expectRefusal(.cloudLineageUnavailable) {
            try await f.runtime.preflightCloudMount(binding: f.binding, readControl: { nil },
                legacyCloudMountEvidence: {
                    StorageTransferLegacyCloudMountEvidence(recordedCloudMountOfThisBinding: true,
                        hasExactCompleteStorePair: true, offlineReceiptPostdatesAdmissionReceipts: true)
                }, validateAccess: {})
        }
        XCTAssertNil(try admission(f, scope: production).load())
    }

    /// A lineage published by another device between the two reads is not
    /// adopted over: the ordinary equality check still stops the mount.
    func testALineageAppearingBetweenTheTwoReadsStillStopsTheMount() async throws {
        let f = try fixture(scope: production)
        try makeStoreArtifacts(f.binding)
        let appeared = try cancelledControlWithoutGeneration()
        var reads = 0
        await expectRefusal(.remoteRecoveryRequired) {
            try await f.runtime.preflightCloudMount(binding: f.binding, readControl: {
                reads += 1
                return reads == 1 ? nil : appeared
            }, legacyCloudMountEvidence: { self.evidence }, validateAccess: {})
        }
    }

    // MARK: - The evidence reader, against 1.0.1's own on-disk shape

    /// Whether real 1.0 / 1.0.1 users are rescued depends on the READER, not
    /// only on the rule: the runtime tests above inject the evidence. This
    /// writes exactly what v1.0.1-build7 leaves behind — its two
    /// `UserDefaults` keys holding the sorted-keys JSON its
    /// `PersistenceDeploymentState.select` / `recordSuccessfulMount` wrote,
    /// the namespaced store pair, and no offline receipt at all — and reads it
    /// back through the same function `live` uses.
    func testTheEvidenceReaderRecognisesTheExactStateOnePointZeroOneLeaves() throws {
        let shape = try onePointZeroOneShape()
        let evidence = shape.read()
        XCTAssertEqual(evidence, StorageTransferLegacyCloudMountEvidence(
            recordedCloudMountOfThisBinding: true, hasExactCompleteStorePair: true,
            offlineReceiptPostdatesAdmissionReceipts: false))
        XCTAssertTrue(StorageTransferLegacyCloudAdoptionPolicy.adoptsPreReceiptStore(
            scope: production, hasAdmissionReceiptUnderAnyName: false,
            serverControl: nil, evidence: evidence))
    }

    func testTheEvidenceReaderFailsClosedOnEveryNeighbouringShape() throws {
        // Selected but never mounted: 1.0.1 records the mount only after the
        // first successful container construction.
        var shape = try onePointZeroOneShape()
        shape.defaults.removeObject(forKey: "persistence.deployment-mounted-selection.v1")
        XCTAssertFalse(shape.read().recordedCloudMountOfThisBinding)

        // A different binding's mount is not this binding's.
        shape = try onePointZeroOneShape()
        let other = try makeBinding()
        XCTAssertFalse(StorageTransferLegacyCloudMountEvidence.read(binding: other,
            defaults: shape.defaults, artifactHistory: shape.history,
            offlineReceipt: { try shape.offline.load() }).recordedCloudMountOfThisBinding)

        // Half a store pair.
        shape = try onePointZeroOneShape()
        try FileManager.default.removeItem(at: shape.stores[1])
        XCTAssertFalse(shape.read().hasExactCompleteStorePair)

        // A receipt-writing build already verified this installation online.
        shape = try onePointZeroOneShape()
        try shape.offline.recordVerifiedOnline(binding: shape.binding, datasetGenerationID: nil,
                                               resetBaseline: nil, expectedReceipt: nil)
        XCTAssertTrue(shape.read().offlineReceiptPostdatesAdmissionReceipts)

        // An unreadable offline receipt counts as one that postdates receipts.
        shape = try onePointZeroOneShape()
        try Data("not a receipt".utf8).write(to: shape.offline.directory
            .appendingPathComponent("access-v1.json"))
        XCTAssertTrue(shape.read().offlineReceiptPostdatesAdmissionReceipts)
    }

    // MARK: - Helpers

    @MainActor
    private struct OnePointZeroOneShape {
        let binding: ActiveAccountLocalBinding
        let defaults: UserDefaults
        let stores: [URL]
        let history: () -> PersistenceArtifactHistory
        let offline: CloudOfflineAccessState

        func read() -> StorageTransferLegacyCloudMountEvidence {
            StorageTransferLegacyCloudMountEvidence.read(binding: binding, defaults: defaults,
                artifactHistory: history, offlineReceipt: { try offline.load() })
        }
    }

    private func onePointZeroOneShape() throws -> OnePointZeroOneShape {
        let binding = try makeBinding()
        let suite = "LegacyCloudAdoption-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let selection = #"{"cloudBinding":{"accountFingerprint":"\#(account)","namespace":{"rawValue":"\#(binding.namespace.rawValue)"}},"mode":"cloud"}"#
        defaults.set(Data(selection.utf8), forKey: "persistence.deployment-selection.v1")
        defaults.set(Data(selection.utf8), forKey: "persistence.deployment-mounted-selection.v1")

        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyCloudEvidence-\(UUID())", isDirectory: true)
        let storeDirectory = parent.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let stores = PersistenceStoreTopology.accountStoreURLs(accountNamespace: binding.namespace,
                                                               directory: storeDirectory)
        XCTAssertEqual(stores.map(\.lastPathComponent),
                       ["PomoGem-\(binding.namespace.rawValue).store",
                        "PomoGemLocalProjection-\(binding.namespace.rawValue).store"],
                       "The names 1.0.1 gave its store pair")
        try Data("1.0.1 cloud store".utf8).write(to: stores[0])
        try Data("1.0.1 projection".utf8).write(to: stores[1])
        let offline = try CloudOfflineAccessState(
            directory: parent.appendingPathComponent("CloudOffline", isDirectory: true))
        XCTAssertNil(try offline.load(), "1.0 and 1.0.1 wrote no offline receipt")
        return OnePointZeroOneShape(binding: binding, defaults: defaults, stores: stores,
            history: { PersistenceStoreTopology.persistenceArtifactHistory(directory: storeDirectory) },
            offline: offline)
    }

    private struct Fixture {
        let root: URL
        let binding: ActiveAccountLocalBinding
        let store: StorageTransferJournalStore
        let runtime: StorageTransferRuntime
    }

    private func makeBinding() throws -> ActiveAccountLocalBinding {
        try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                accountFingerprint: account))
    }

    private func fixture(scope: StorageTransferCloudScope) throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyCloudAdoption-\(UUID())")
        let root = parent.appendingPathComponent("StorageTransfer", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let store = StorageTransferJournalStore(directory: root)
        return Fixture(root: root, binding: try makeBinding(), store: store,
                       runtime: StorageTransferRuntime(store: store, root: root, cloudScope: scope))
    }

    private func admission(_ f: Fixture, scope: StorageTransferCloudScope) throws
        -> StorageTransferStateFile<StorageTransferDatasetAdmission> {
        try StorageTransferStateFile(url: f.root.appendingPathComponent(
            StorageTransferRuntime.admissionFileName(namespace: f.binding.namespace, scope: scope)))
    }

    /// The store a 1.0.1 install leaves at the SAME path this build mounts.
    /// The namespace is a fresh UUID, so it cannot collide with a real store.
    private func makeStoreArtifacts(_ binding: ActiveAccountLocalBinding) throws {
        let urls = try PersistenceStoreTopology.persistentStoreURLs(for: .cloudKit,
                                                                    accountNamespace: binding.namespace)
        let storeURL = try XCTUnwrap(urls.first)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: storeURL.path,
            contents: Data("1.0.1 cloud store".utf8)))
        addTeardownBlock {
            for artifact in urls.flatMap({ PersistenceStoreArtifactLayout.artifacts(for: $0) }) {
                try? FileManager.default.removeItem(at: artifact)
            }
        }
    }

    /// A terminal control whose dataset generation is nil: a transfer was
    /// staged and cancelled on this account, so it is not 1.0.1's untouched
    /// account even though no committed lineage exists.
    private func cancelledControlWithoutGeneration() throws -> StorageTransferRecoveryControl {
        let manifest = try StorageTransferRecoveryManifest(transactionID: UUID(),
            accountFingerprint: account, payload: Data("cancelled payload".utf8),
            previousDatasetGenerationID: nil)
        let control = try StorageTransferRecoveryControl(manifest: manifest).cancelling()
        XCTAssertTrue(control.isTerminal)
        XCTAssertNil(control.datasetGenerationID)
        return control
    }

    private func expectRefusal(_ expected: StorageTransferRuntimeError,
                               file: StaticString = #filePath, line: UInt = #line,
                               _ action: () async throws -> Void) async {
        do {
            try await action()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? StorageTransferRuntimeError, expected, file: file, line: line)
        }
    }
}

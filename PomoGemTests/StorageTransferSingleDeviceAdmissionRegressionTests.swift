import Foundation
import XCTest
@testable import PomoGem

/// Regression coverage for `StorageTransferRuntimeError.datasetRefreshRequired`
/// reached WITHOUT a second device. Every raise site named below is exercised
/// with the real Runtime, real admission/state files in a temporary directory
/// and an injected control read. No CloudKit transport and no model container
/// is constructed, so these tests are safe on CI and in the simulator.
///
/// The user-facing string for this error is
/// 「別の端末でiCloudデータが置き換えられました。…」
/// (StorageTransferRuntime.swift:17). Each test records whether that sentence
/// is truthful for the path it reproduces.
@MainActor
final class StorageTransferSingleDeviceAdmissionRegressionTests: XCTestCase {
    private let account = String(repeating: "c", count: 64)

    private struct Fixture {
        let parent: URL
        let root: URL
        let binding: ActiveAccountLocalBinding
        let store: StorageTransferJournalStore
        let runtime: StorageTransferRuntime
        let admission: StorageTransferStateFile<StorageTransferDatasetAdmission>
    }

    private func fixture() throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("SingleDeviceAdmission-\(UUID())")
        let root = parent.appendingPathComponent("StorageTransfer", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                              accountFingerprint: account))
        let store = StorageTransferJournalStore(directory: root)
        return Fixture(parent: parent, root: root, binding: binding, store: store,
            runtime: StorageTransferRuntime(store: store, root: root),
            admission: try StorageTransferStateFile(
                url: root.appendingPathComponent(StorageTransferRuntime.admissionFileName(
                    namespace: binding.namespace, scope: .unknown))))
    }

    /// A committed control record, i.e. a server that carries a dataset
    /// generation. `datasetGenerationID` of a committed control is its own
    /// transaction ID (StorageTransferRemoteRecovery.swift:190).
    private func committedControl(previous: UUID? = nil) throws -> StorageTransferRecoveryControl {
        let payload = Data("synthetic single-device payload".utf8)
        let manifest = try StorageTransferRecoveryManifest(transactionID: UUID(),
            accountFingerprint: account, payload: payload, previousDatasetGenerationID: previous)
        let digest = StorageTransferRecoverySchema.digest(payload)
        return try StorageTransferRecoveryControl(manifest: manifest)
            .advancing(to: .backupVerified)
            .advancing(to: .replacing)
            .advancing(to: .committed, verifiedDestinationSHA256: digest)
    }

    /// After the split at StorageTransferRuntime the expected error names WHICH
    /// state was observed, so every call site states it.
    private func expectRefusal(_ expected: StorageTransferRuntimeError,
                               _ action: () async throws -> Void,
                               _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await action()
            XCTFail("Expected \(expected): \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? StorageTransferRuntimeError, expected,
                           message, file: file, line: line)
            XCTAssertFalse(expected.localizedDescription.contains("別の端末"),
                           "No refusal may claim how many devices exist", file: file, line: line)
        }
    }

    /// The admission receipt file the runtime under test actually uses.
    private func admissionFile(_ root: URL, _ binding: ActiveAccountLocalBinding,
                               scope: StorageTransferCloudScope = .unknown)
        throws -> StorageTransferStateFile<StorageTransferDatasetAdmission> {
        try StorageTransferStateFile(url: root.appendingPathComponent(
            StorageTransferRuntime.admissionFileName(namespace: binding.namespace, scope: scope)))
    }

    // MARK: - Raise site StorageTransferRuntime.swift:153 (admission compare)

    /// SINGLE DEVICE. The phone recorded generation G during an earlier online
    /// session. The control record it reads now is ABSENT — the transport maps
    /// `unknownItem` / `zoneNotFound` to nil (StorageTransferRemoteRecoveryCloudKit.swift:713),
    /// so a build talking to a different CloudKit environment (a development
    /// -signed build vs. a TestFlight/App Store build on the SAME phone), an
    /// iCloud "delete this app's data", or a container that never received the
    /// `PomoGemStorageTransfer-v1` zone all produce `status == nil`.
    /// `expected.datasetGenerationID` is then nil, the stored admission is G,
    /// and the compare at StorageTransferRuntime.swift:153 fails.
    ///
    /// FIXED: this is now `cloudLineageUnavailable`. Nothing replaced the data;
    /// the server has no control record at all, so there is no other record a
    /// replacement could have come from, and the copy says so.
    func testAbsentServerControlWithRecordedGenerationReportsAnUnavailableLineage() async throws {
        let f = try fixture()
        let recorded = StorageTransferDatasetAdmission(binding: f.binding, datasetGenerationID: UUID())
        try f.admission.save(recorded, replacing: nil)

        var reads = 0
        await expectRefusal(.cloudLineageUnavailable, {
            try await f.runtime.preflightCloudMount(binding: f.binding, readControl: {
                reads += 1
                return nil
            }, validateAccess: {})
        }, "An absent server control must not be indistinguishable from a foreign replacement")

        XCTAssertEqual(reads, 1, "The mismatch is decided on the first read")
        XCTAssertEqual(try f.admission.load(), recorded,
                       "A blocked preflight must not rewrite the local admission receipt")
        XCTAssertNil(try f.store.load())
    }

    /// SINGLE DEVICE. Same phone, same account, two DIFFERENT generations: the
    /// server moved from G1 to G2 because THIS device committed a replacement
    /// (StorageTransferRuntime.promote -> commitReplacement, Runtime.swift:852)
    /// while some copy of the app still holds the G1 admission file for the old
    /// namespace. Reinstall-with-restored-container and a resumed transfer that
    /// never re-ran `promote` land here.
    ///
    /// FIXED: the replacement IS real, so the case stays a refusal. The
    /// classification is `datasetReplacedRemotely`, but a real replacement is
    /// one of the two states the launch host can still REMEDY, so the thrown
    /// error keeps the legacy name until the host is wired to the taxonomy —
    /// otherwise the 「iCloudから再取得」 screen becomes unreachable. Both halves
    /// are asserted here; the copy of neither names a device count.
    func testGenerationAdvancedByThisDeviceItselfIsReportedWithoutADeviceClaim() async throws {
        let f = try fixture()
        let first = try committedControl()
        let firstGeneration = try XCTUnwrap(first.datasetGenerationID)
        try f.admission.save(StorageTransferDatasetAdmission(binding: f.binding,
            datasetGenerationID: firstGeneration), replacing: nil)

        // The same phone completes a second transfer; the server generation is
        // now the new transaction ID, chained to the previous one.
        let second = try committedControl(previous: firstGeneration)
        XCTAssertNotEqual(second.datasetGenerationID, firstGeneration)

        XCTAssertEqual(StorageTransferAdmissionPolicy.decide(
            found: StorageTransferDatasetAdmission(binding: f.binding, datasetGenerationID: firstGeneration),
            binding: f.binding, scope: .unknown, serverGenerationID: second.datasetGenerationID),
            .refuse(.datasetReplacedRemotely),
            "The classification names the state that is actually true")

        await expectRefusal(.datasetRefreshRequired, {
            try await f.runtime.preflightCloudMount(binding: f.binding,
                readControl: { second }, validateAccess: {})
        }, "A generation this device advanced itself must still be detected")
        XCTAssertEqual(CloudOfflineHostPolicy.launchRoute(for: .datasetRefreshRequired), .datasetRefresh,
                       "and it must still reach the screen that can refresh from that generation")
        XCTAssertFalse(StorageTransferRuntimeError.datasetReplacedRemotely
            .localizedDescription.contains("別の端末"))
    }

    // MARK: - Raise site StorageTransferRuntime.swift:982 (requireNoArtifacts)

    /// SINGLE DEVICE, upgrade path. The admission file does not exist (the
    /// installed build predates the admission feature, or the container was
    /// restored from a backup that omitted `StorageTransfer/`), the server
    /// already carries a generation, and the cloud store artifacts for this
    /// namespace are present. `preflightCloudMount` takes the enrolment branch
    /// and `requireNoArtifacts` refuses (StorageTransferRuntime.swift:157/982).
    ///
    /// FIXED: this is classified as `localLedgerMissing` - "this build has never
    /// seen the current generation" - and no longer borrows the replacement
    /// sentence. The server here DOES carry a terminal generation, so the host
    /// can still offer 「iCloudから再取得」; the thrown error therefore keeps the
    /// legacy name until the launch-state wiring lands.
    func testUpgradeWithoutAdmissionFileButWithExistingStoreIsRejected() async throws {
        let f = try fixture()
        let control = try committedControl()
        XCTAssertNil(try f.admission.load(), "Precondition: the upgraded build has no admission receipt")

        let urls = try PersistenceStoreTopology.persistentStoreURLs(for: .cloudKit,
                                                                    accountNamespace: f.binding.namespace)
        let storeURL = try XCTUnwrap(urls.first)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // The namespace is a fresh UUID, so this file cannot collide with any
        // real store in the test host container. It is removed again below.
        XCTAssertTrue(FileManager.default.createFile(atPath: storeURL.path,
            contents: Data("single-device upgrade store".utf8)))
        addTeardownBlock {
            for artifact in urls.flatMap({ PersistenceStoreArtifactLayout.artifacts(for: $0) }) {
                try? FileManager.default.removeItem(at: artifact)
            }
        }

        await expectRefusal(.datasetRefreshRequired, {
            try await f.runtime.preflightCloudMount(binding: f.binding,
                readControl: { control }, validateAccess: {})
        }, "An existing local cache must not silently enrol into a newer generation")
        XCTAssertEqual(CloudOfflineHostPolicy.launchRoutableRefusal(.localLedgerMissing),
                       .datasetRefreshRequired,
                       "The R2 upgrade case previously reached the refresh offer and must keep it")
        XCTAssertEqual(CloudOfflineHostPolicy.datasetLineageBlock(for: StorageTransferRuntimeError.localLedgerMissing),
                       .localLedgerMissing, "and the taxonomy still records which state it is")

        XCTAssertNil(try f.admission.load(),
                     "A refused enrolment must not leave an admission receipt behind")
    }

    /// The same enrolment branch with an EMPTY remote ledger. Before this fix
    /// the store-artifact precondition ran only when the server reported a
    /// generation, so an existing local cloud store met a database with no
    /// ledger at all, preflight returned success, and the host built the mirror
    /// over that store — publishing the whole device dataset into a database
    /// that never held it, with no prompt and with
    /// `allowsDatasetOverwriteFromDevice` still false. That publication is the
    /// consented `startCloudLineageFromDevice` operation, never a preflight.
    func testEnrolmentWithAnExistingStoreIsRefusedEvenWhenTheServerHasNoLineage() async throws {
        let f = try fixture()
        XCTAssertNil(try f.admission.load(), "Precondition: no receipt under any scope")

        let urls = try PersistenceStoreTopology.persistentStoreURLs(for: .cloudKit,
                                                                    accountNamespace: f.binding.namespace)
        let storeURL = try XCTUnwrap(urls.first)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: storeURL.path,
            contents: Data("device rows nobody consented to publish".utf8)))
        addTeardownBlock {
            for artifact in urls.flatMap({ PersistenceStoreArtifactLayout.artifacts(for: $0) }) {
                try? FileManager.default.removeItem(at: artifact)
            }
        }

        await expectRefusal(.cloudLineageUnavailable, {
            try await f.runtime.preflightCloudMount(binding: f.binding,
                readControl: { nil }, validateAccess: {})
        }, "An empty remote ledger must not be joined by an existing local cloud store")

        XCTAssertNil(try f.admission.load(),
                     "A refused enrolment must not leave an admission receipt behind")
        XCTAssertNil(try f.store.load())
    }

    /// Control case for the test above: the very same upgrade WITHOUT local
    /// store artifacts enrols cleanly. This isolates the trigger to "a store
    /// already exists", not to the missing admission file, and shows a fresh
    /// install on the same phone is unaffected.
    func testUpgradeWithoutAdmissionFileAndWithoutStoreEnrolsIntoCurrentGeneration() async throws {
        let f = try fixture()
        let control = try committedControl()
        var reads = 0
        try await f.runtime.preflightCloudMount(binding: f.binding, readControl: {
            reads += 1
            return control
        }, validateAccess: {})
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(try f.admission.load(), StorageTransferDatasetAdmission(binding: f.binding,
            datasetGenerationID: control.datasetGenerationID))
    }

    // MARK: - The recovery dead end (PomoGemApp.swift:2014-2015)

    /// SINGLE DEVICE. `presentDatasetRefresh` only offers the destructive
    /// 「iCloudから再取得」 screen when the re-read control is terminal AND has a
    /// generation (PomoGemApp.swift:2014). With an absent control record the
    /// guard fails, `datasetRefreshRequired` is re-thrown into the local catch
    /// and the app falls back to the GENERIC blocked screen — which is exactly
    /// what the phone shows. This test proves the refresh itself is refused too,
    /// so the offered 「もう一度試す」 can never clear the state.
    func testRefreshCannotRecoverWhenTheServerControlIsAbsent() async throws {
        let f = try fixture()
        let stranded = UUID()
        try f.admission.save(StorageTransferDatasetAdmission(binding: f.binding,
            datasetGenerationID: stranded), replacing: nil)
        var reads = 0
        do {
            try await f.runtime.refreshCloudDataset(binding: f.binding, expectedGenerationID: stranded,
                verifyAccount: { f.binding }, readControl: { reads += 1; return nil }, validateAccess: {})
            XCTFail("A refresh without a server control must not start a transfer")
        } catch {
            XCTAssertEqual(error as? StorageTransferError, .staleTransaction)
        }
        XCTAssertEqual(reads, 1)
        XCTAssertNil(try f.store.load(), "No journal may be opened against an absent control")
    }

    /// A still-pending (non-terminal) control also refuses the refresh, so a
    /// device that observes `blocksWriters` never reaches the refresh screen.
    func testRefreshIsRefusedWhileTheServerControlIsNotTerminal() async throws {
        let f = try fixture()
        let staging = try StorageTransferRecoveryControl(manifest:
            StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: account,
                payload: Data("pending single-device payload".utf8), previousDatasetGenerationID: nil))
        XCTAssertTrue(staging.blocksWriters)
        do {
            try await f.runtime.refreshCloudDataset(binding: f.binding, expectedGenerationID: UUID(),
                verifyAccount: { f.binding }, readControl: { staging }, validateAccess: {})
            XCTFail("A pending replacement must not be refreshed away")
        } catch {
            XCTAssertEqual(error as? StorageTransferError, .staleTransaction)
        }
    }

    // MARK: - Raise sites PomoGemApp.swift:1293 and 1626 (offline receipt lineage)

    /// SINGLE DEVICE, upgrade path. An offline copy adopted by
    /// `adoptLegacyMountedCopy` (PomoGemApp.swift:1566) while no admission file
    /// existed produces `origin == .legacySuccessfulMount` with an UNKNOWN
    /// generation. `matchesVerifiedDataset` accepts that receipt only against a
    /// nil server generation (CloudOfflineAccessPolicy.swift:87), so the first
    /// time the same phone reconnects to a server that carries ANY generation
    /// the launch path and the 「もう一度試す」 retry both throw
    /// `datasetRefreshRequired`.
    ///
    /// MESSAGE VERDICT: WRONG. The lineage is unknown, not superseded.
    func testLegacyAdoptedOfflineReceiptNeverMatchesAServerGeneration() throws {
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                              accountFingerprint: account))
        let legacy = CloudOfflineAccessReceipt(revisionID: UUID(), binding: binding,
            origin: .legacySuccessfulMount, isDatasetGenerationKnown: false, datasetGenerationID: nil,
            resetBaseline: nil, wasUsedOffline: true, revocation: nil)
        XCTAssertNoThrow(try legacy.validate())
        XCTAssertTrue(CloudOfflineAccessPolicy.matchesVerifiedDataset(receipt: legacy,
            datasetGenerationID: nil), "A legacy receipt is admissible only against a generationless server")
        XCTAssertFalse(CloudOfflineAccessPolicy.matchesVerifiedDataset(receipt: legacy,
            datasetGenerationID: UUID()),
            "A legacy offline receipt is rejected by any server generation, on one device")
    }

    /// SINGLE DEVICE. A verified-online receipt pinned to G1 stops matching as
    /// soon as THIS phone's own transfer promotes the admission file to G2
    /// (StorageTransferRuntime.swift:855-862). Both PomoGemApp.swift:1293 and
    /// PomoGemApp.swift:1626 turn that into `datasetRefreshRequired`.
    ///
    /// MESSAGE VERDICT: WRONG in the "別の端末" part.
    func testOfflineReceiptPinnedToTheOlderGenerationRejectsThisDevicesOwnTransfer() throws {
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                              accountFingerprint: account))
        let older = UUID()
        let receipt = CloudOfflineAccessReceipt(revisionID: UUID(), binding: binding,
            origin: .verifiedOnline, isDatasetGenerationKnown: true, datasetGenerationID: older,
            resetBaseline: nil, wasUsedOffline: true, revocation: nil)
        XCTAssertNoThrow(try receipt.validate())
        XCTAssertTrue(CloudOfflineAccessPolicy.matchesVerifiedDataset(receipt: receipt,
            datasetGenerationID: older))
        XCTAssertFalse(CloudOfflineAccessPolicy.matchesVerifiedDataset(receipt: receipt,
            datasetGenerationID: UUID()))
        // The environment-swap variant: the server suddenly has no generation.
        XCTAssertFalse(CloudOfflineAccessPolicy.matchesVerifiedDataset(receipt: receipt,
            datasetGenerationID: nil),
            "A verified receipt is also rejected when the control record disappears")
    }
}

/// Adversarial verification of candidate C1 (angle: code reachability).
/// C1 claims the phone's generic blocked screen carrying the
/// `datasetRefreshRequired` text implies the queried CloudKit database has NO
/// committed transfer lineage — i.e. `status == nil`, or a cancelled control
/// whose `previousDatasetGenerationID` is nil — because any other control
/// value would have produced the `.datasetRefresh` screen instead
/// (PomoGemApp.swift:2005-2019). These tests attack that implication by
/// enumerating every control value the guard at PomoGemApp.swift:2014 can see.
@MainActor
final class StorageTransferRefreshGuardExclusivityTests: XCTestCase {
    private let account = String(repeating: "d", count: 64)

    private func manifest(previous: UUID?) throws -> StorageTransferRecoveryManifest {
        try StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: account,
            payload: Data("c1 adversarial payload".utf8), previousDatasetGenerationID: previous)
    }

    private func committed(previous: UUID?) throws -> StorageTransferRecoveryControl {
        let manifest = try manifest(previous: previous)
        return try StorageTransferRecoveryControl(manifest: manifest)
            .advancing(to: .backupVerified)
            .advancing(to: .replacing)
            .advancing(to: .committed,
                       verifiedDestinationSHA256: StorageTransferRecoverySchema.digest(
                           Data("c1 adversarial payload".utf8)))
    }

    /// The refresh guard is `status.isTerminal && status.datasetGenerationID != nil`.
    /// If a committed control could ever fail it, the observed blocked screen
    /// would NOT exclude "a newer generation was committed" and C1 would be
    /// refuted. It cannot: a committed control's generation is its own
    /// transaction ID (StorageTransferRemoteRecovery.swift:190-192).
    func testEveryCommittedControlSatisfiesTheRefreshGuard() throws {
        for previous in [nil, UUID()] as [UUID?] {
            let control = try committed(previous: previous)
            XCTAssertTrue(control.isTerminal)
            XCTAssertFalse(control.blocksWriters)
            XCTAssertEqual(control.datasetGenerationID, control.manifest.transactionID)
            XCTAssertNotNil(control.datasetGenerationID,
                            "A committed control always offers the .datasetRefresh screen")
        }
    }

    /// The other half of the guard: a non-terminal control never reaches it,
    /// because `blocksWriters` routes to the .remoteRecovery screen first
    /// (PomoGemApp.swift:2008-2013). So a pending transfer cannot be the cause
    /// of a generic blocked screen either.
    func testEveryNonTerminalControlIsRoutedToRemoteRecoveryBeforeTheGuard() throws {
        var control = try StorageTransferRecoveryControl(manifest: manifest(previous: UUID()))
        for phase in [StorageTransferRecoveryControl.Phase.staging, .backupVerified, .replacing] {
            if control.phase != phase { control = try control.advancing(to: phase) }
            XCTAssertEqual(control.phase, phase)
            XCTAssertFalse(control.isTerminal)
            XCTAssertTrue(control.blocksWriters, "phase \(phase) must block writers")
        }
    }

    /// C1's second admissible sub-case. A cancelled control keeps the PREVIOUS
    /// generation, so it fails the guard only when there was no predecessor —
    /// which `stage`/`cancelUnclaimed` allow only when the control record was
    /// absent when that transaction started (StorageTransferRemoteRecovery.swift:359,
    /// :433-437). Both sub-cases therefore mean "no committed lineage".
    func testOnlyACancelledControlWithoutAPredecessorFailsTheRefreshGuard() throws {
        let orphan = try StorageTransferRecoveryControl(manifest: manifest(previous: nil)).cancelling()
        XCTAssertTrue(orphan.isTerminal)
        XCTAssertNil(orphan.datasetGenerationID, "No lineage: the guard fails and the host blocks")

        let chained = try StorageTransferRecoveryControl(manifest: manifest(previous: UUID())).cancelling()
        XCTAssertTrue(chained.isTerminal)
        XCTAssertNotNil(chained.datasetGenerationID,
                        "A cancelled control with a predecessor still offers the refresh screen")
    }

    /// End-to-end over the real Runtime: both C1 sub-cases produce the launch
    /// block against a recorded generation, and a server that still carries the
    /// device's own generation does NOT.
    func testPreflightBlocksForBothNoLineageCasesAndPassesForAMatchingGeneration() async throws {
        for control in [nil, try StorageTransferRecoveryControl(manifest: manifest(previous: nil)).cancelling()] {
            let parent = FileManager.default.temporaryDirectory
                .appendingPathComponent("C1Exclusivity-\(UUID())")
            let root = parent.appendingPathComponent("StorageTransfer", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: parent) }
            let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                                  accountFingerprint: account))
            let runtime = StorageTransferRuntime(store: StorageTransferJournalStore(directory: root), root: root)
            let file = try StorageTransferStateFile<StorageTransferDatasetAdmission>(
                url: root.appendingPathComponent(StorageTransferRuntime.admissionFileName(
                    namespace: binding.namespace, scope: .unknown)))
            try file.save(StorageTransferDatasetAdmission(binding: binding, datasetGenerationID: UUID()),
                          replacing: nil)
            do {
                try await runtime.preflightCloudMount(binding: binding, readControl: { control },
                                                      validateAccess: {})
                XCTFail("Expected cloudLineageUnavailable for a server without committed lineage")
            } catch {
                XCTAssertEqual(error as? StorageTransferRuntimeError, .cloudLineageUnavailable,
                    "Both no-lineage shapes are the SAME state and must not be called a replacement")
            }
        }

        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("C1Matching-\(UUID())")
        let root = parent.appendingPathComponent("StorageTransfer", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                              accountFingerprint: account))
        let runtime = StorageTransferRuntime(store: StorageTransferJournalStore(directory: root), root: root)
        let control = try committed(previous: nil)
        let file = try StorageTransferStateFile<StorageTransferDatasetAdmission>(
            url: root.appendingPathComponent(StorageTransferRuntime.admissionFileName(
                namespace: binding.namespace, scope: .unknown)))
        try file.save(StorageTransferDatasetAdmission(binding: binding,
            datasetGenerationID: control.datasetGenerationID), replacing: nil)
        try await runtime.preflightCloudMount(binding: binding, readControl: { control }, validateAccess: {})
    }

    /// Adversarial verification of candidate C5 ("another device genuinely
    /// replaced the iCloud dataset"), angle: code reachability + reproduction.
    /// This reproduces exactly what C5 asserts happened — a committed control
    /// written by some OTHER device, whose transaction ID differs from the
    /// generation this device recorded — and shows that it produces the SAME
    /// first symptom (datasetRefreshRequired out of preflight) but a DIFFERENT
    /// host screen: the control satisfies `blocksWriters == false`,
    /// `isTerminal`, and `datasetGenerationID != nil`, so
    /// `presentDatasetRefresh` (PomoGemApp.swift:2007-2019) reaches
    /// `launchState = .datasetRefresh` (title 「iCloudのデータが置き換わりました」),
    /// never `.blocked` (title 「保存領域を確認できません」, PomoGemApp.swift:2685-2698).
    /// The photographed probe screen is the latter, so C5 cannot be the state
    /// of the queried database.
    func testAnotherDeviceCommittedGenerationWouldReachTheRefreshScreen() async throws {
        let deviceRecordedGeneration = UUID()
        let foreign = try committed(previous: deviceRecordedGeneration)
        XCTAssertNotEqual(foreign.datasetGenerationID, deviceRecordedGeneration)

        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("C5Foreign-\(UUID())")
        let root = parent.appendingPathComponent("StorageTransfer", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                              accountFingerprint: account))
        let runtime = StorageTransferRuntime(store: StorageTransferJournalStore(directory: root), root: root)
        let file = try StorageTransferStateFile<StorageTransferDatasetAdmission>(
            url: root.appendingPathComponent(StorageTransferRuntime.admissionFileName(
                namespace: binding.namespace, scope: .unknown)))
        try file.save(StorageTransferDatasetAdmission(binding: binding,
            datasetGenerationID: deviceRecordedGeneration), replacing: nil)

        // Same first symptom as the phone: preflight refuses the mount.
        var thrown: StorageTransferRuntimeError?
        do {
            try await runtime.preflightCloudMount(binding: binding, readControl: { foreign },
                                                  validateAccess: {})
            XCTFail("A foreign committed generation must still block the mount")
        } catch {
            thrown = error as? StorageTransferRuntimeError
        }
        let refusal = try XCTUnwrap(thrown)

        // ...but the host guard that decides which screen appears passes.
        XCTAssertFalse(foreign.blocksWriters, "would otherwise route to .remoteRecovery")
        XCTAssertTrue(foreign.isTerminal)
        XCTAssertNotNil(foreign.datasetGenerationID,
                        "PomoGemApp.swift:2014 would offer 「iCloudから再取得」, not the blocked screen")

        // The executable half of that claim, and the reason the split alone is
        // not enough: `PomoGemApp.swift:1143` routes ONLY
        // `.datasetRefreshRequired` to `presentDatasetRefresh`, the sole writer
        // of `storageTransferRefreshGenerationID` and therefore the only route
        // into `refreshCloudDataset`. If the refusal thrown here ever stops
        // reaching `.datasetRefresh`, this device loses its only in-app remedy
        // and 「もう一度試す」 repeats the same refusal forever.
        XCTAssertEqual(CloudOfflineHostPolicy.launchRoute(for: refusal), .datasetRefresh,
            "A genuine remote replacement must reach the 「iCloudから再取得」 screen")
        XCTAssertEqual(CloudOfflineHostPolicy.datasetLineageBlock(
            for: StorageTransferRuntimeError.datasetReplacedRemotely), .remoteDatasetOffer,
            "and the split taxonomy routes exactly this case to that offer")
        XCTAssertEqual(StorageTransferAdmissionPolicy.decide(found: try file.load(),
            binding: binding, scope: .unknown, serverGenerationID: foreign.datasetGenerationID),
            .refuse(.datasetReplacedRemotely),
            "The state itself is still classified as the replacement it is")

        // And the local admission is left untouched either way, so the screen
        // choice is the only observable difference between C5 and no-lineage.
        XCTAssertEqual(try file.load()?.datasetGenerationID, deviceRecordedGeneration)
    }
}

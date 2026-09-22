import Foundation
import XCTest
@testable import PomoGem

/// The durable, single-shot record Settings leaves behind so the next launch
/// can run the dataset direction the user confirmed. Nothing here opens a
/// container, writes a journal or makes a remote call.
@MainActor
final class StorageTransferDatasetRequestTests: XCTestCase {
    private let scope = StorageTransferCloudScope(environment: .development,
        containerIdentifier: "iCloud.com.example.scope-test")
    private let account = String(repeating: "b", count: 64)

    private struct Fixture {
        let root: URL
        let binding: ActiveAccountLocalBinding
        let runtime: StorageTransferRuntime
        let store: StorageTransferJournalStore
    }

    private func fixture() throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatasetRequest-\(UUID())")
        let root = parent.appendingPathComponent("StorageTransfer", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(
            namespace: AccountDataNamespace(), accountFingerprint: account))
        let store = StorageTransferJournalStore(directory: root)
        return Fixture(root: root, binding: binding,
                       runtime: StorageTransferRuntime(store: store, root: root), store: store)
    }

    private func request(_ f: Fixture,
                         direction: StorageTransferDatasetRequestDirection = .overwriteCloudFromDevice,
                         generation: UUID? = UUID()) -> StorageTransferDatasetRequest {
        StorageTransferDatasetRequest(direction: direction, binding: f.binding, cloudScope: scope,
                                      datasetGenerationID: generation,
                                      requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                      requestingProcessID: UUID())
    }

    // MARK: Recording

    func testRecordedRequestSurvivesAndCarriesTheDisplayedGeneration() throws {
        let f = try fixture()
        let generation = UUID()
        try f.runtime.recordDatasetRequest(request(f, generation: generation))
        let loaded = try XCTUnwrap(f.runtime.pendingDatasetRequest())
        XCTAssertEqual(loaded.direction, .overwriteCloudFromDevice)
        XCTAssertEqual(loaded.binding, f.binding)
        XCTAssertEqual(loaded.cloudScope, scope)
        XCTAssertEqual(loaded.datasetGenerationID, generation)
        XCTAssertEqual(loaded.formatVersion, StorageTransferDatasetRequest.currentFormatVersion)
    }

    func testRecordingCreatesNoJournalCheckpointOrContainerArtifact() throws {
        let f = try fixture()
        try f.runtime.recordDatasetRequest(request(f))
        XCTAssertNil(try f.store.load())
        let entries = try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted()
        XCTAssertEqual(entries, ["dataset-request.json"])
    }

    /// A second confirmed direction replaces the first. The launch host must
    /// never find two competing destructive intents.
    func testASecondRequestReplacesTheFirstRatherThanQueueing() throws {
        let f = try fixture()
        try f.runtime.recordDatasetRequest(request(f, direction: .overwriteCloudFromDevice))
        let second = request(f, direction: .overwriteCloudFromDevice, generation: UUID())
        try f.runtime.recordDatasetRequest(second)
        XCTAssertEqual(try f.runtime.pendingDatasetRequest(), second)
    }

    // MARK: Consumption

    func testConsumingReturnsTheRequestExactlyOnceAndDeletesIt() throws {
        let f = try fixture()
        let recorded = request(f)
        try f.runtime.recordDatasetRequest(recorded)
        XCTAssertEqual(try f.runtime.consumeDatasetRequest(), recorded)
        XCTAssertNil(try f.runtime.consumeDatasetRequest())
        XCTAssertNil(try f.runtime.pendingDatasetRequest())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: f.root.appendingPathComponent("dataset-request.json").path))
    }

    func testConsumingNothingIsNotAnError() throws {
        let f = try fixture()
        XCTAssertNil(try f.runtime.consumeDatasetRequest())
    }

    /// Fail closed: a request this build cannot understand is dropped, never
    /// guessed at. A destructive direction must never be inferred.
    func testUnknownFormatVersionIsRefusedAndNeverExecuted() throws {
        let f = try fixture()
        let alien = StorageTransferDatasetRequest(formatVersion: 99,
            direction: .overwriteCloudFromDevice, binding: f.binding, cloudScope: scope,
            datasetGenerationID: UUID(), requestedAt: Date(), requestingProcessID: UUID())
        XCTAssertThrowsError(try alien.validate())
        XCTAssertThrowsError(try f.runtime.recordDatasetRequest(alien))
        XCTAssertNil(try f.runtime.pendingDatasetRequest())
        let url = f.root.appendingPathComponent("dataset-request.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(alien).write(to: url)
        XCTAssertNil(try f.runtime.consumeDatasetRequest())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAnUnreadableRequestIsDroppedRatherThanRetriedForever() throws {
        let f = try fixture()
        let url = f.root.appendingPathComponent("dataset-request.json")
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(try f.runtime.consumeDatasetRequest())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testValidationRefusesAMismatchedAccountFingerprint() throws {
        let f = try fixture()
        let other = try XCTUnwrap(ActiveAccountLocalBinding(
            namespace: AccountDataNamespace(), accountFingerprint: String(repeating: "c", count: 64)))
        let recorded = StorageTransferDatasetRequest(direction: .overwriteCloudFromDevice,
            binding: other, cloudScope: scope, datasetGenerationID: UUID(), requestedAt: Date(),
            requestingProcessID: UUID())
        XCTAssertFalse(recorded.authorizes(binding: f.binding, cloudScope: scope))
        XCTAssertTrue(recorded.authorizes(binding: other, cloudScope: scope))
    }

    /// The same account/namespace and an absent ledger can exist in both
    /// databases. A build change during the requested relaunch must not turn
    /// consent to Development into a request to discard stores for Production.
    func testDurableRequestsCannotCrossCloudScopesAtRelaunch() throws {
        let f = try fixture()
        let evidenceURL = f.root.appendingPathComponent("admission-development-\(f.binding.namespace.rawValue).json")
        let evidence = Data("existing admission evidence".utf8)
        try evidence.write(to: evidenceURL)
        let otherScopes = [
            StorageTransferCloudScope(environment: .production,
                containerIdentifier: scope.containerIdentifier),
            StorageTransferCloudScope(environment: .development,
                containerIdentifier: "iCloud.com.example.another-container"),
            .unknown
        ]
        for generation in [nil, UUID()] as [UUID?] {
            for direction in [StorageTransferDatasetRequestDirection.overwriteCloudFromDevice,
                              .refreshFromCloud] {
                let recorded = request(f, direction: direction, generation: generation)
                try f.runtime.recordDatasetRequest(recorded)
                let consumed = try XCTUnwrap(f.runtime.consumeDatasetRequest())
                XCTAssertEqual(consumed.cloudScope, scope)
                XCTAssertNotNil(consumed.dispatch(for: f.binding, cloudScope: scope))
                for otherScope in otherScopes {
                    XCTAssertNil(consumed.dispatch(for: f.binding, cloudScope: otherScope))
                }
                XCTAssertNil(try f.store.load(), "Refusal must not create a transfer")
                XCTAssertEqual(try Data(contentsOf: evidenceURL), evidence)
            }
        }
    }

    /// A pre-upgrade request cannot establish which database the user saw.
    /// Drop only the one-shot request; never infer scope from the new build or
    /// rewrite the existing admission as if the user had confirmed again.
    func testLegacyUnscopedRequestIsNeverDispatched() throws {
        let f = try fixture()
        let evidenceURL = f.root.appendingPathComponent("admission-\(f.binding.namespace.rawValue).json")
        let evidence = Data("legacy admission evidence".utf8)
        try evidence.write(to: evidenceURL)
        let encoded = try JSONEncoder().encode(request(f, direction: .refreshFromCloud,
                                                     generation: nil))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy["formatVersion"] = 1
        legacy.removeValue(forKey: "cloudScope")
        let requestURL = f.root.appendingPathComponent(StorageTransferDatasetRequestStore.fileName)
        try JSONSerialization.data(withJSONObject: legacy).write(to: requestURL)

        XCTAssertNil(try f.runtime.consumeDatasetRequest())
        XCTAssertNil(try f.runtime.pendingDatasetRequest())
        XCTAssertNil(try f.store.load())
        XCTAssertEqual(try Data(contentsOf: evidenceURL), evidence)
    }

    func testUnknownScopeCannotAuthorizeOrRecordARequest() throws {
        let f = try fixture()
        let unscoped = StorageTransferDatasetRequest(direction: .refreshFromCloud,
            binding: f.binding, cloudScope: .unknown, datasetGenerationID: nil,
            requestedAt: .now, requestingProcessID: UUID())
        XCTAssertThrowsError(try f.runtime.recordDatasetRequest(unscoped))
        XCTAssertNil(unscoped.dispatch(for: f.binding, cloudScope: .unknown))
        XCTAssertNil(unscoped.dispatch(for: f.binding, cloudScope: scope))
        XCTAssertNil(try f.runtime.pendingDatasetRequest())
        XCTAssertNil(try f.store.load())
    }

    // MARK: The Settings gate

    /// Only the device -> iCloud direction is fenced. PLAN Step 12: direction
    /// (B) replaces nothing on the server, introduces no journal shape and no
    /// policy bit, and is the exact operation the recovery screen already runs
    /// unconditionally — so none of the three release bits is its gate.
    func testStandardPolicyPublishesOnlyTheNonDestructiveDirection() {
        XCTAssertThrowsError(try StorageTransferDatasetRequestPolicy.validate(
            .overwriteCloudFromDevice, policy: .standard)) { error in
            XCTAssertEqual(error as? StorageTransferReleaseError, .datasetOverwriteUnavailable)
        }
        XCTAssertNoThrow(try StorageTransferDatasetRequestPolicy.validate(
            .refreshFromCloud, policy: .standard),
            "A direction that deletes nothing on the server must not be fenced by the one that does")
    }

    func testEveryPolicyPublishesTheRefreshDirectionAndOnlyTheOverwriteBitPublishesTheOverwrite() {
        for policy in [StorageTransferReleasePolicy.standard,
                       .isolatedTestingPolicy(allowsCloudReplacement: true),
                       .isolatedTestingPolicy(allowsRemoteResumeBeforeReplacing: true),
                       .isolatedTestingPolicy(allowsDatasetOverwriteFromDevice: true)] {
            XCTAssertNoThrow(try StorageTransferDatasetRequestPolicy.validate(
                .refreshFromCloud, policy: policy))
        }
        for policy in [StorageTransferReleasePolicy.standard,
                       .isolatedTestingPolicy(allowsCloudReplacement: true),
                       .isolatedTestingPolicy(allowsRemoteResumeBeforeReplacing: true)] {
            XCTAssertThrowsError(try StorageTransferDatasetRequestPolicy.validate(
                .overwriteCloudFromDevice, policy: policy),
                "Only allowsDatasetOverwriteFromDevice may open the device -> iCloud direction")
        }
        XCTAssertNoThrow(try StorageTransferDatasetRequestPolicy.validate(
            .overwriteCloudFromDevice,
            policy: .isolatedTestingPolicy(allowsDatasetOverwriteFromDevice: true)))
    }

    /// The durable format is read by a later process. Pin the raw values.
    func testDirectionRawValuesAreTheDurableFormat() {
        XCTAssertEqual(StorageTransferDatasetRequestDirection.overwriteCloudFromDevice.rawValue,
                       "overwriteCloudFromDevice")
        XCTAssertEqual(StorageTransferDatasetRequestDirection.refreshFromCloud.rawValue,
                       "refreshFromCloud")
    }

    func testARecordedRefreshRequestRoundTripsUnchanged() throws {
        let f = try fixture()
        let recorded = request(f, direction: .refreshFromCloud)
        try f.runtime.recordDatasetRequest(recorded)
        XCTAssertEqual(try f.runtime.consumeDatasetRequest(), recorded)
        XCTAssertNil(try f.store.load())
    }

    /// The legacy `localOnly -> cloud` replacement bit must not open the new
    /// Settings door, and the new bit must not open the legacy one.
    func testTheLegacyReplacementBitDoesNotPublishTheSettingsOverwriteDoor() {
        let legacy = StorageTransferReleasePolicy.isolatedTestingPolicy(allowsCloudReplacement: true)
        XCTAssertThrowsError(try StorageTransferDatasetRequestPolicy.validate(
            .overwriteCloudFromDevice, policy: legacy)) { error in
            XCTAssertEqual(error as? StorageTransferReleaseError, .datasetOverwriteUnavailable)
        }
        let overwrite = StorageTransferReleasePolicy.isolatedTestingPolicy(allowsDatasetOverwriteFromDevice: true)
        XCTAssertThrowsError(try overwrite.validate(.enableCloudReplacingCloud)) { error in
            XCTAssertEqual(error as? StorageTransferReleaseError, .cloudReplacementUnavailable)
        }
    }
}

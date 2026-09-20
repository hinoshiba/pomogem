import Foundation
import XCTest
@testable import PomoGem

/// The durable, single-shot record Settings leaves behind so the next launch
/// can run the dataset direction the user confirmed. Nothing here opens a
/// container, writes a journal or makes a remote call.
@MainActor
final class StorageTransferDatasetRequestTests: XCTestCase {
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
                         generation: UUID = UUID()) -> StorageTransferDatasetRequest {
        StorageTransferDatasetRequest(direction: direction, binding: f.binding,
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
            direction: .overwriteCloudFromDevice, binding: f.binding,
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
            binding: other, datasetGenerationID: UUID(), requestedAt: Date(),
            requestingProcessID: UUID())
        XCTAssertFalse(recorded.authorizes(binding: f.binding))
        XCTAssertTrue(recorded.authorizes(binding: other))
    }

    // MARK: The Settings gate

    func testStandardPolicyPublishesNeitherSettingsDirection() {
        XCTAssertThrowsError(try StorageTransferDatasetRequestPolicy.validate(
            .overwriteCloudFromDevice, policy: .standard)) { error in
            XCTAssertEqual(error as? StorageTransferReleaseError, .datasetOverwriteUnavailable)
        }
        XCTAssertThrowsError(try StorageTransferDatasetRequestPolicy.validate(
            .refreshFromCloud, policy: .standard)) { error in
            XCTAssertEqual(error as? StorageTransferSettingsDatasetError, .refreshFromSettingsUnavailable)
        }
    }

    func testRaisingTheOverwriteBitPublishesBothSettingsDoors() {
        let policy = StorageTransferReleasePolicy.isolatedTestingPolicy(allowsDatasetOverwriteFromDevice: true)
        XCTAssertNoThrow(try StorageTransferDatasetRequestPolicy.validate(
            .overwriteCloudFromDevice, policy: policy))
        XCTAssertNoThrow(try StorageTransferDatasetRequestPolicy.validate(
            .refreshFromCloud, policy: policy))
    }

    /// Direction (B) is refused from Settings, never described as unavailable
    /// outright: the recovery screen still offers exactly this operation, and
    /// a fenced device has no other way forward.
    func testTheRefusedRefreshDoorPointsAtTheScreenThatStillOffersIt() {
        let message = StorageTransferSettingsDatasetError
            .refreshFromSettingsUnavailable.localizedDescription
        XCTAssertTrue(message.contains("設定から実行できません"))
        XCTAssertTrue(message.contains("iCloudのデータが置き換わりました"))
        XCTAssertFalse(message.contains("復旧用コピー"),
            "This direction stages nothing on the server; it must not promise one")
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

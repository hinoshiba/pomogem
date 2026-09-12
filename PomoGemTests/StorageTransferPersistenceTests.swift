import Foundation
import SwiftData
import XCTest
@testable import PomoGem

@MainActor
final class StorageTransferPersistenceTests: XCTestCase {
    private func files() throws -> StorageTransferStoreFiles {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageTransferPersistence-\(UUID())")
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try StorageTransferStoreFiles(transactionID: UUID(),
            transferRoot: root.appendingPathComponent("transfer"), storeDirectory: source)
    }

    func testAcknowledgedPayloadCannotBeReplacedAndTamperingDoesNotLookAbsent() throws {
        let files = try files()
        let store = StorageTransferPayloadStore(files: files)
        let snapshot = PomoGemStorageSnapshot(records: [])
        let receipt = try store.save(snapshot)
        XCTAssertEqual(try store.load(expectedDigest: receipt.sha256), snapshot)
        XCTAssertEqual(try store.save(snapshot), receipt)
        try Data("tampered".utf8).write(to: files.snapshotURL)
        XCTAssertThrowsError(try store.acknowledgedReceipt())
        XCTAssertThrowsError(try store.save(snapshot))
    }

    func testCrashAfterPayloadWriteBeforeReceiptRecoversTheExactExistingBytes() throws {
        let files = try files()
        let snapshot = PomoGemStorageSnapshot(records: [])
        let original = try snapshot.write(to: files.snapshotURL)
        let store = StorageTransferPayloadStore(files: files)
        XCTAssertNil(try store.acknowledgedReceipt())
        let resumed = try store.save(snapshot)
        XCTAssertEqual(resumed, original)
        XCTAssertEqual(try store.bytes(expectedDigest: resumed.sha256).count, original.encodedBytes)
    }

    func testServerRecoveryPreservesAcknowledgedNonCanonicalBytesAcrossRetry() throws {
        let files = try files()
        let store = StorageTransferPayloadStore(files: files)
        let bytes = Data("{ \"records\" : [], \"formatVersion\" : 1 }\n".utf8)
        let manifest = try StorageTransferRecoveryManifest(transactionID: files.transactionID,
            accountFingerprint: String(repeating: "a", count: 64), payload: bytes)
        let receipt = try store.saveRecovered(bytes, manifest: manifest)
        XCTAssertEqual(receipt.sha256, manifest.payloadSHA256)
        XCTAssertEqual(try store.bytes(expectedDigest: receipt.sha256), bytes)
        XCTAssertEqual(try store.saveRecovered(bytes, manifest: manifest), receipt)
        let canonical = try JSONEncoder().encode(PomoGemStorageSnapshot(records: []))
        XCTAssertNotEqual(canonical, bytes)
        let different = try StorageTransferRecoveryManifest(transactionID: files.transactionID,
            accountFingerprint: manifest.accountFingerprint, payload: canonical)
        XCTAssertThrowsError(try store.saveRecovered(canonical, manifest: different))
        XCTAssertEqual(try store.bytes(expectedDigest: receipt.sha256), bytes)
    }

    func testWrongRemotePayloadHashCannotCreateOrReplaceLocalSnapshot() throws {
        let files = try files()
        let bytes = try JSONEncoder().encode(PomoGemStorageSnapshot(records: []))
        let manifest = try StorageTransferRecoveryManifest(transactionID: files.transactionID,
            accountFingerprint: String(repeating: "a", count: 64), payload: bytes)
        XCTAssertThrowsError(try StorageTransferPayloadStore(files: files).saveRecovered(Data([1, 2, 3]), manifest: manifest))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.snapshotURL.path))
    }

    func testLocalStagingUsesBothSchemasWithoutCloudOrMutatingSource() throws {
        let files = try files()
        let selection = PersistenceDeploymentSelection.localOnly(namespace: AccountDataNamespace())
        let urls = files.storeURLs(for: selection, location: .staged)
        let container = try StorageTransferPersistence.makeContainer(selection: selection, urls: urls, cloudEnabled: false)
        XCTAssertEqual(container.configurations.count, 2)
        XCTAssertTrue(container.configurations.allSatisfy { $0.cloudKitContainerIdentifier == nil })
        try PomoGemStorageSnapshot.validateSchema(container.schema)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.storeURLs(for: selection, location: .source)[0].path))
        XCTAssertThrowsError(try StorageTransferPersistence.makeContainer(selection: selection, urls: urls, cloudEnabled: true))
    }
}

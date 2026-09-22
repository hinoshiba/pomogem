import CloudKit
import Foundation
import XCTest
@testable import PomoGem

/// L5 / P2-6 was "record a writer device id in the recovery manifest, if the
/// format allows a backward-compatible optional field". It does NOT, and this
/// test is the evidence, kept executable so the conclusion cannot rot.
///
/// The whole control (manifest included) travels as one canonical JSON blob in
/// `controlJSON`, and `decodeControl` deliberately re-encodes what it decoded
/// and compares the two as dictionaries, rejecting "unknown nested metadata
/// rather than ignoring future fields". Adding any field to the manifest -
/// even an optional one, even without bumping a format version - therefore
/// makes every already-shipped build reject the control record outright, which
/// is a remote format change in everything but name.
///
/// P2-6 is skipped for that reason. Its motivation is served instead by
/// removing every device-count claim from the copy (ROOT-CAUSE §6.2, covered
/// by StorageTransferAdmissionTaxonomyTests): the manifest cannot say who
/// wrote a generation, so nothing in the app pretends to know.
@MainActor
final class StorageTransferManifestWriterFieldTests: XCTestCase {
    private let account = String(repeating: "2", count: 64)

    private func committed() throws -> StorageTransferRecoveryControl {
        let payload = Data("writer field payload".utf8)
        let manifest = try StorageTransferRecoveryManifest(transactionID: UUID(),
            accountFingerprint: account, payload: payload, previousDatasetGenerationID: nil)
        return try StorageTransferRecoveryControl(manifest: manifest)
            .advancing(to: .backupVerified)
            .advancing(to: .replacing)
            .advancing(to: .committed,
                       verifiedDestinationSHA256: StorageTransferRecoverySchema.digest(payload))
    }

    /// A round trip of the CURRENT shape succeeds, so the rejection below is
    /// attributable to the added field and nothing else.
    func testTheCurrentControlShapeRoundTrips() throws {
        let control = try committed()
        let record = try StorageTransferRecoveryCloudCodec.control(control,
            name: StorageTransferRecoverySchema.controlRecordName)
        XCTAssertEqual(try StorageTransferRecoveryCloudCodec.decodeControl(record,
            name: StorageTransferRecoverySchema.controlRecordName, terminal: false), control)
    }

    /// The same record with a `writerDeviceID` added to the manifest is
    /// rejected by the CURRENT decoder - i.e. by every build already in the
    /// field - with no format version having changed.
    func testAWriterDeviceIDInTheManifestIsRejectedByTheCurrentDecoder() throws {
        let control = try committed()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: encoder.encode(control)) as? [String: Any])
        var manifest = try XCTUnwrap(object["manifest"] as? [String: Any])
        XCTAssertEqual(manifest["formatVersion"] as? Int, 1)
        manifest["writerDeviceID"] = "this-device"
        object["manifest"] = manifest
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        let record = CKRecord(recordType: StorageTransferRecoverySchema.controlRecordType,
                              recordID: StorageTransferRecoveryCloudCodec.controlID)
        record["formatVersion"] = 1 as NSNumber
        record["controlJSON"] = data as NSData
        record["controlSHA256"] = StorageTransferRecoverySchema.digest(data) as NSString

        XCTAssertThrowsError(try StorageTransferRecoveryCloudCodec.decodeControl(record,
            name: StorageTransferRecoverySchema.controlRecordName, terminal: false),
            "An optional manifest field is NOT backward compatible on this wire format") { error in
            XCTAssertEqual(error as? StorageTransferRecoveryError, .invalidControl)
        }
    }

    /// And the reason it cannot be waved through: the app has no way to attribute
    /// a committed generation to a device, so no refusal may imply one.
    func testTheManifestCarriesNoWriterIdentityToday() throws {
        let control = try committed()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let json = try XCTUnwrap(String(data: try encoder.encode(control), encoding: .utf8))
        XCTAssertFalse(json.lowercased().contains("device"),
                       "No device identity exists in the control record")
    }
}

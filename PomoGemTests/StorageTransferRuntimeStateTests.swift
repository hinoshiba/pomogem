import Foundation
import XCTest
@testable import PomoGem

@MainActor
final class StorageTransferRuntimeStateTests: XCTestCase {
    private let payload = Data("synthetic runtime checkpoint source".utf8)
    private var sourceDigest: String { StorageTransferRecoverySchema.digest(payload) }
    private let otherDigest = String(repeating: "b", count: 64)

    private func journal(_ choice: StorageTransferChoice = .enableCloudReplacingCloud,
                         through phase: StorageTransferJournal.Phase = .requested) throws -> StorageTransferJournal {
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
            accountFingerprint: String(repeating: "a", count: 64)))
        let cloud = PersistenceDeploymentSelection.cloud(binding: binding)
        let local = PersistenceDeploymentSelection.localOnly(namespace: AccountDataNamespace())
        var value = try StorageTransferJournal(choice: choice,
            source: choice == .disableCloudKeepingCopy ? cloud : local,
            destination: choice == .disableCloudKeepingCopy ? local : cloud, cloudBinding: binding)
        while value.phase < phase {
            let next = try XCTUnwrap(StorageTransferJournal.Phase(rawValue: value.phase.rawValue + 1))
            value = try value.advancing(to: next,
                sourceDigest: next == .sourceSaved ? sourceDigest : nil,
                destinationDigest: next == .destinationSaved ? (choice == .enableCloudKeepingCloud ? otherDigest : sourceDigest) : nil,
                remoteRecoveryTransactionID: next == .recoveryCopySaved && choice.replacesCloud ? value.transactionID : nil)
        }
        return value
    }

    private func checkpoint(_ journal: StorageTransferJournal) throws -> StorageTransferRuntimeCheckpoint {
        var value = StorageTransferRuntimeCheckpoint(transactionID: journal.transactionID, requestingProcessID: UUID())
        value.didObserveBaselineControl = true
        if journal.choice.replacesCloud, journal.phase >= .sourceSaved {
            value.recoveryManifest = try StorageTransferRecoveryManifest(transactionID: journal.transactionID,
                accountFingerprint: journal.cloudBinding.accountFingerprint, payload: payload)
        }
        if journal.phase >= .preparingDestination {
            if journal.choice != .enableCloudKeepingCloud { value.importedPayloadDigest = sourceDigest }
            if journal.choice.replacesCloud { value.cloudExportIntentRecorded = true }
            if journal.choice != .disableCloudKeepingCopy {
                value.verifiedCloudProcessID = UUID()
                value.verifiedCloudPayloadDigest = journal.choice.replacesCloud ? sourceDigest : otherDigest
            }
        }
        return value
    }

    func testEveryOrdinaryChoiceCheckpointRoundTripsAtEveryAcknowledgedPhase() throws {
        for choice in StorageTransferChoice.allCases {
            for phase in StorageTransferJournal.Phase.allCases {
                let journal = try journal(choice, through: phase)
                let value = try checkpoint(journal)
                try value.validate(journal: journal)
                let decoded = try JSONDecoder().decode(StorageTransferRuntimeCheckpoint.self, from: JSONEncoder().encode(value))
                XCTAssertEqual(decoded, value)
                try decoded.validate(journal: journal)
            }
        }
    }

    func testFutureVersionMissingProcessAndDifferentTransactionAreRefused() throws {
        let journal = try journal()
        var future = try checkpoint(journal); future.formatVersion = 2
        XCTAssertThrowsError(try future.validate(journal: journal))
        var missing = try checkpoint(journal); missing.requestingProcessID = nil
        XCTAssertThrowsError(try missing.validate(journal: journal))
        let wrong = StorageTransferRuntimeCheckpoint(transactionID: UUID(), requestingProcessID: UUID())
        XCTAssertThrowsError(try wrong.validate(journal: journal))
    }

    func testMissingRequiredVersionAndRecoveryOriginNeverDecodeAsOldDefaults() throws {
        let journal = try journal()
        let encoded = try JSONEncoder().encode(checkpoint(journal))
        for key in ["formatVersion", "didObserveBaselineControl", "recoveredFromServer", "cloudExportIntentRecorded"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object.removeValue(forKey: key)
            XCTAssertThrowsError(try JSONDecoder().decode(StorageTransferRuntimeCheckpoint.self,
                from: JSONSerialization.data(withJSONObject: object)))
        }
    }

    func testImportedReceiptMustMatchFrozenPayloadBeforeAnyCloudReopen() throws {
        let journal = try journal(through: .preparingDestination)
        for digest in [otherDigest, "invalid", String(repeating: "A", count: 64)] {
            var value = try checkpoint(journal)
            value.importedPayloadDigest = digest
            XCTAssertThrowsError(try value.validate(journal: journal))
        }
        let early = try self.journal(through: .sourceSaved)
        var value = try checkpoint(early); value.importedPayloadDigest = sourceDigest
        XCTAssertThrowsError(try value.validate(journal: early))
    }

    func testCloudAuthorityCannotAdoptAnImportedLocalReceipt() throws {
        let journal = try journal(.enableCloudKeepingCloud, through: .preparingDestination)
        var value = try checkpoint(journal); value.importedPayloadDigest = sourceDigest
        XCTAssertThrowsError(try value.validate(journal: journal))
    }

    func testExportIntentRequiresAcknowledgedReplacementImportBeforeCloudConstruction() throws {
        let replacement = try journal(through: .preparingDestination)
        var valid = try checkpoint(replacement)
        valid.verifiedCloudProcessID = nil; valid.verifiedCloudPayloadDigest = nil
        try valid.validate(journal: replacement)
        valid.importedPayloadDigest = nil
        XCTAssertThrowsError(try valid.validate(journal: replacement))
        for choice in [StorageTransferChoice.disableCloudKeepingCopy, .enableCloudKeepingCloud] {
            let journal = try self.journal(choice, through: .preparingDestination)
            var value = try checkpoint(journal); value.cloudExportIntentRecorded = true
            XCTAssertThrowsError(try value.validate(journal: journal))
        }
        let early = try journal(through: .sourceSaved)
        var value = try checkpoint(early); value.cloudExportIntentRecorded = true
        XCTAssertThrowsError(try value.validate(journal: early))
        value = try checkpoint(replacement); value.cloudExportIntentRecorded = false
        XCTAssertThrowsError(try value.validate(journal: replacement), "Mirroring verification cannot precede export intent")
    }

    func testCloudVerificationRequiresMatchingPairedReceiptForThisChoice() throws {
        let journal = try journal(through: .preparingDestination)
        var value = try checkpoint(journal); value.verifiedCloudProcessID = nil
        XCTAssertThrowsError(try value.validate(journal: journal))
        value = try checkpoint(journal); value.verifiedCloudPayloadDigest = otherDigest
        XCTAssertThrowsError(try value.validate(journal: journal))
        value = try checkpoint(journal); value.importedPayloadDigest = nil
        XCTAssertThrowsError(try value.validate(journal: journal))
        let disabled = try self.journal(.disableCloudKeepingCopy, through: .preparingDestination)
        value = try checkpoint(disabled); value.verifiedCloudProcessID = UUID(); value.verifiedCloudPayloadDigest = sourceDigest
        XCTAssertThrowsError(try value.validate(journal: disabled))
    }

    func testRecoveryManifestCannotCrossAccountPayloadTransactionChoiceOrEarlyPhase() throws {
        let journal = try journal(through: .sourceSaved)
        let wrongManifests = [
            try StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: journal.cloudBinding.accountFingerprint, payload: payload),
            try StorageTransferRecoveryManifest(transactionID: journal.transactionID, accountFingerprint: otherDigest, payload: payload),
            try StorageTransferRecoveryManifest(transactionID: journal.transactionID, accountFingerprint: journal.cloudBinding.accountFingerprint, payload: Data([9]))
        ]
        for manifest in wrongManifests {
            var value = try checkpoint(journal); value.recoveryManifest = manifest
            XCTAssertThrowsError(try value.validate(journal: journal))
        }
        for choice in StorageTransferChoice.allCases {
            let early = try self.journal(choice)
            var value = try checkpoint(early)
            value.recoveryManifest = try StorageTransferRecoveryManifest(transactionID: early.transactionID,
                accountFingerprint: early.cloudBinding.accountFingerprint, payload: payload)
            XCTAssertThrowsError(try value.validate(journal: early))
        }
    }

    func testAcknowledgedRemoteCopyCannotLoseItsManifest() throws {
        let journal = try journal(through: .recoveryCopySaved)
        var value = try checkpoint(journal); value.recoveryManifest = nil
        XCTAssertThrowsError(try value.validate(journal: journal))
    }

    func testDestinationAcknowledgmentRequiresPriorImportOrCloudVerificationReceipt() throws {
        for choice in StorageTransferChoice.allCases {
            let journal = try journal(choice, through: .destinationSaved)
            var value = try checkpoint(journal)
            if choice == .disableCloudKeepingCopy { value.importedPayloadDigest = nil }
            else { value.verifiedCloudProcessID = nil; value.verifiedCloudPayloadDigest = nil }
            XCTAssertThrowsError(try value.validate(journal: journal))
        }
        let cloud = try journal(.enableCloudKeepingCloud, through: .destinationSaved)
        var value = try checkpoint(cloud); value.verifiedCloudPayloadDigest = sourceDigest
        XCTAssertThrowsError(try value.validate(journal: cloud))
    }

    func testServerOriginAndPartialAttemptCannotAuthorizeOrdinarySourceRetirement() throws {
        let recovered = try journal(through: .preparingDestination)
        var value = try checkpoint(recovered)
        value.recoveredFromServer = true; value.partialRecoveryAttemptID = UUID()
        value.baselineControl = try StorageTransferRecoveryControl(manifest: XCTUnwrap(value.recoveryManifest))
        try value.validate(journal: recovered)
        value.recoveredFromServer = false
        XCTAssertThrowsError(try value.validate(journal: recovered))
        value.recoveredFromServer = true; value.recoveryManifest = nil
        XCTAssertThrowsError(try value.validate(journal: recovered))
        for choice in [StorageTransferChoice.disableCloudKeepingCopy, .enableCloudKeepingCloud] {
            let ordinary = try journal(choice, through: .preparingDestination)
            var impossible = try checkpoint(ordinary); impossible.recoveredFromServer = true
            XCTAssertThrowsError(try impossible.validate(journal: ordinary))
        }
    }

    func testStateFileReadbackAndCASNeverSubstituteAnotherCheckpoint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try StorageTransferStateFile<StorageTransferRuntimeCheckpoint>(url: directory.appendingPathComponent("runtime-v1.json"))
        let journal = try journal()
        let initial = try checkpoint(journal)
        try file.save(initial, replacing: nil)
        XCTAssertEqual(try file.load(), initial)
        var successor = initial; successor.requestingProcessID = UUID()
        try file.save(successor, replacing: initial)
        XCTAssertThrowsError(try file.save(initial, replacing: initial))
        XCTAssertEqual(try file.load(), successor)
    }

    // MARK: - Device -> iCloud overwrite (.overwriteCloudFromDevice)

    /// The user's actual case: a device already bound to the account replaces
    /// the current generation with its own cache.
    private func overwriteFromCloud(through phase: StorageTransferJournal.Phase = .requested) throws -> StorageTransferJournal {
        let account = String(repeating: "a", count: 64)
        let previous = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                               accountFingerprint: account))
        let destination = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                                  accountFingerprint: account))
        var value = try StorageTransferJournal(choice: .overwriteCloudFromDevice,
            source: .cloud(binding: previous), destination: .cloud(binding: destination),
            cloudBinding: destination)
        while value.phase < phase {
            let next = try XCTUnwrap(StorageTransferJournal.Phase(rawValue: value.phase.rawValue + 1))
            value = try value.advancing(to: next,
                sourceDigest: next == .sourceSaved ? sourceDigest : nil,
                destinationDigest: next == .destinationSaved ? sourceDigest : nil,
                remoteRecoveryTransactionID: next == .recoveryCopySaved ? value.transactionID : nil)
        }
        return value
    }

    func testOverwriteCheckpointCarriesExactlyTheLegacyReplacementEvidence() throws {
        for phase in StorageTransferJournal.Phase.allCases {
            let journal = try overwriteFromCloud(through: phase)
            let value = try checkpoint(journal)
            try value.validate(journal: journal)
            let decoded = try JSONDecoder().decode(StorageTransferRuntimeCheckpoint.self,
                                                   from: JSONEncoder().encode(value))
            XCTAssertEqual(decoded, value)
            try decoded.validate(journal: journal)
        }
        // The acknowledged remote recovery copy cannot be lost afterwards.
        let acknowledged = try overwriteFromCloud(through: .recoveryCopySaved)
        var value = try checkpoint(acknowledged); value.recoveryManifest = nil
        XCTAssertThrowsError(try value.validate(journal: acknowledged))
        // destinationSaved needs BOTH the local import receipt and another
        // process's cloud-mirroring proof, exactly as the legacy case does.
        let saved = try overwriteFromCloud(through: .destinationSaved)
        value = try checkpoint(saved)
        value.verifiedCloudProcessID = nil; value.verifiedCloudPayloadDigest = nil
        XCTAssertThrowsError(try value.validate(journal: saved))
        value = try checkpoint(saved); value.importedPayloadDigest = nil
        XCTAssertThrowsError(try value.validate(journal: saved))
        value = try checkpoint(saved); value.cloudExportIntentRecorded = false
        XCTAssertThrowsError(try value.validate(journal: saved))
    }

    func testServerOriginOverwriteStillRequiresTheSynthesizedLocalOnlySource() throws {
        let reinstall = try journal(.overwriteCloudFromDevice, through: .preparingDestination)
        var value = try checkpoint(reinstall)
        value.recoveredFromServer = true
        value.baselineControl = try StorageTransferRecoveryControl(manifest: XCTUnwrap(value.recoveryManifest))
        try value.validate(journal: reinstall)
        value.partialRecoveryAttemptID = UUID()
        try value.validate(journal: reinstall)

        // A cloud-source overwrite owns a real store and must retire it, so it
        // can never claim the server origin that skips source retirement.
        let fromCloud = try overwriteFromCloud(through: .preparingDestination)
        var impossible = try checkpoint(fromCloud)
        impossible.recoveredFromServer = true
        impossible.baselineControl = try StorageTransferRecoveryControl(manifest: XCTUnwrap(impossible.recoveryManifest))
        XCTAssertThrowsError(try impossible.validate(journal: fromCloud))
    }
}

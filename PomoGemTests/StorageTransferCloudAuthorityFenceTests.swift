import Foundation
import XCTest
@testable import PomoGem

final class StorageTransferCloudAuthorityFenceTests: XCTestCase {
    private let account = String(repeating: "a", count: 64)
    private let bytes = Data("synthetic authority payload".utf8)

    private func control(transactionID: UUID = UUID(), phase: StorageTransferRecoveryControl.Phase = .committed,
                         previousGeneration: UUID? = nil) throws -> StorageTransferRecoveryControl {
        let manifest = try StorageTransferRecoveryManifest(transactionID: transactionID,
            accountFingerprint: account, payload: bytes, previousDatasetGenerationID: previousGeneration)
        return try advance(StorageTransferRecoveryControl(manifest: manifest), to: phase)
    }

    private func advance(_ control: StorageTransferRecoveryControl,
                         to phase: StorageTransferRecoveryControl.Phase) throws -> StorageTransferRecoveryControl {
        if phase == .cancelled { return try control.cancelling() }
        var value = control
        while value.phase.rawValue < phase.rawValue {
            let next = try XCTUnwrap(StorageTransferRecoveryControl.Phase(rawValue: value.phase.rawValue + 1))
            value = try value.advancing(to: next,
                verifiedDestinationSHA256: next == .committed ? value.manifest.payloadSHA256 : nil)
        }
        return value
    }

    private func fixture(choice: StorageTransferChoice = .enableCloudReplacingCloud,
                         phase: StorageTransferJournal.Phase = .sourceSaved,
                         baseline: StorageTransferRecoveryControl? = nil,
                         withManifest: Bool = true) throws -> (StorageTransferJournal, StorageTransferRuntimeCheckpoint) {
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: account))
        let cloud = PersistenceDeploymentSelection.cloud(binding: binding)
        let local = PersistenceDeploymentSelection.localOnly(namespace: AccountDataNamespace())
        var journal = try StorageTransferJournal(choice: choice,
            source: choice == .disableCloudKeepingCopy ? cloud : local,
            destination: choice == .disableCloudKeepingCopy ? local : cloud, cloudBinding: binding)
        let digest = StorageTransferRecoverySchema.digest(bytes)
        while journal.phase < phase {
            let next = try XCTUnwrap(StorageTransferJournal.Phase(rawValue: journal.phase.rawValue + 1))
            journal = try journal.advancing(to: next, sourceDigest: next == .sourceSaved ? digest : nil,
                destinationDigest: next == .destinationSaved ? digest : nil,
                remoteRecoveryTransactionID: next == .recoveryCopySaved && choice.replacesCloud ? journal.transactionID : nil)
        }
        var checkpoint = StorageTransferRuntimeCheckpoint(transactionID: journal.transactionID, requestingProcessID: UUID())
        checkpoint.didObserveBaselineControl = true
        checkpoint.baselineControl = baseline
        if choice.replacesCloud, withManifest, phase >= .sourceSaved {
            checkpoint.recoveryManifest = try StorageTransferRecoveryManifest(transactionID: journal.transactionID,
                accountFingerprint: account, payload: bytes, previousDatasetGenerationID: baseline?.datasetGenerationID)
        }
        if phase >= .preparingDestination {
            if choice != .enableCloudKeepingCloud { checkpoint.importedPayloadDigest = digest }
            if choice.replacesCloud { checkpoint.cloudExportIntentRecorded = true }
            if choice != .disableCloudKeepingCopy {
                checkpoint.verifiedCloudProcessID = UUID(); checkpoint.verifiedCloudPayloadDigest = digest
            }
        }
        return (journal, checkpoint)
    }

    func testUnchangedCloudChoicesRequireExactBaselineIncludingObservedNil() throws {
        for choice in [StorageTransferChoice.disableCloudKeepingCopy, .enableCloudKeepingCloud] {
            for baseline in [nil, try control(), try control(phase: .cancelled)] {
                let (journal, checkpoint) = try fixture(choice: choice, baseline: baseline)
                try StorageTransferCloudAuthorityFence.validate(observed: baseline, journal: journal, checkpoint: checkpoint)
                let different = try control(previousGeneration: baseline?.datasetGenerationID)
                XCTAssertThrowsError(try StorageTransferCloudAuthorityFence.validate(observed: different,
                    journal: journal, checkpoint: checkpoint))
                if baseline != nil {
                    XCTAssertThrowsError(try StorageTransferCloudAuthorityFence.validate(observed: nil,
                        journal: journal, checkpoint: checkpoint))
                }
            }
        }
    }

    func testSourceCloudRefreshUsesSameStrictBaselineAsCloudAuthority() throws {
        let baseline = try control()
        let (localJournal, checkpoint) = try fixture(choice: .enableCloudKeepingCloud, phase: .requested, baseline: baseline)
        let oldBinding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: account))
        let refresh = try StorageTransferJournal(transactionID: localJournal.transactionID,
            choice: .enableCloudKeepingCloud, source: .cloud(binding: oldBinding),
            destination: localJournal.destination, cloudBinding: localJournal.cloudBinding)
        try StorageTransferCloudAuthorityFence.validate(observed: baseline, journal: refresh, checkpoint: checkpoint)
        XCTAssertThrowsError(try StorageTransferCloudAuthorityFence.validate(observed: control(), journal: refresh, checkpoint: checkpoint))
    }

    func testReplacementCanObservePriorBaselineOnlyBeforeStageAcknowledgment() throws {
        for baseline in [nil, try control(), try control(phase: .cancelled)] {
            let (before, checkpoint) = try fixture(baseline: baseline)
            try StorageTransferCloudAuthorityFence.validate(observed: baseline, journal: before, checkpoint: checkpoint)
            let claimed = try before.advancing(to: .recoveryCopySaved, remoteRecoveryTransactionID: before.transactionID)
            XCTAssertThrowsError(try StorageTransferCloudAuthorityFence.validate(observed: baseline,
                journal: claimed, checkpoint: checkpoint))
        }
    }

    func testReplacementAcceptsOnlyItsExactManifestThroughInFlightPhases() throws {
        let (journal, checkpoint) = try fixture(phase: .preparingDestination, baseline: control())
        let own = try StorageTransferRecoveryControl(manifest: XCTUnwrap(checkpoint.recoveryManifest))
        for phase in [StorageTransferRecoveryControl.Phase.staging, .backupVerified, .replacing] {
            try StorageTransferCloudAuthorityFence.validate(observed: advance(own, to: phase),
                journal: journal, checkpoint: checkpoint)
        }
        for other in [try control(phase: .staging), try control(phase: .committed), try control(phase: .cancelled), try own.cancelling()] {
            XCTAssertThrowsError(try StorageTransferCloudAuthorityFence.validate(observed: other,
                journal: journal, checkpoint: checkpoint))
        }
        XCTAssertThrowsError(try StorageTransferCloudAuthorityFence.validate(observed: nil, journal: journal, checkpoint: checkpoint))
    }

    func testOtherTransactionWithIdenticalDataAndGenerationCannotAuthorizePromotion() throws {
        let (journal, checkpoint) = try fixture(phase: .destinationVerified)
        let own = try StorageTransferRecoveryControl(manifest: XCTUnwrap(checkpoint.recoveryManifest))
        let committed = try advance(own, to: .committed)
        try StorageTransferCloudAuthorityFence.validate(observed: committed, journal: journal, checkpoint: checkpoint)
        // A newer cancelled control preserves this same dataset generation.
        // That is still not this transaction's authority before local commit.
        let later = try control(phase: .cancelled, previousGeneration: committed.datasetGenerationID)
        XCTAssertEqual(later.datasetGenerationID, committed.datasetGenerationID)
        XCTAssertEqual(later.manifest.payloadSHA256, committed.manifest.payloadSHA256)
        XCTAssertThrowsError(try StorageTransferCloudAuthorityFence.validate(observed: later, journal: journal, checkpoint: checkpoint))
    }

    func testCommittedReplacementIsRefusedBeforeIndependentDestinationVerification() throws {
        for phase in [StorageTransferJournal.Phase.sourceSaved, .preparingDestination, .destinationSaved] {
            let (journal, checkpoint) = try fixture(phase: phase)
            let own = try StorageTransferRecoveryControl(manifest: XCTUnwrap(checkpoint.recoveryManifest))
            XCTAssertThrowsError(try StorageTransferCloudAuthorityFence.validate(observed: advance(own, to: .committed),
                journal: journal, checkpoint: checkpoint))
        }
    }

    func testUnobservedBaselineIsNeverEquivalentToAuthoritativeAbsence() throws {
        let (journal, checkpoint) = try fixture(phase: .requested, withManifest: false)
        var unobserved = checkpoint; unobserved.didObserveBaselineControl = false
        XCTAssertThrowsError(try StorageTransferCloudAuthorityFence.validate(observed: nil, journal: journal, checkpoint: unobserved))
        try StorageTransferCloudAuthorityFence.validate(observed: nil, journal: journal, checkpoint: checkpoint)
    }

    func testRecoveredOwnPendingBaselineRemainsBoundBeforeManifestCheckpoint() throws {
        let (journal, initial) = try fixture(phase: .requested, withManifest: false)
        var checkpoint = initial
        checkpoint.recoveredFromServer = true
        let own = try control(transactionID: journal.transactionID, phase: .replacing)
        checkpoint.baselineControl = own
        try StorageTransferCloudAuthorityFence.validate(observed: own, journal: journal, checkpoint: checkpoint)
        XCTAssertThrowsError(try StorageTransferCloudAuthorityFence.validate(observed: nil, journal: journal, checkpoint: checkpoint))
        XCTAssertThrowsError(try StorageTransferCloudAuthorityFence.validate(observed: control(phase: .replacing),
            journal: journal, checkpoint: checkpoint))
        checkpoint.baselineControl = try control(phase: .replacing)
        XCTAssertThrowsError(try checkpoint.validate(journal: journal))
    }

    func testManifestCannotReplaceAnUnrelatedBaselineGeneration() throws {
        let (journal, initial) = try fixture(baseline: control())
        var checkpoint = initial
        checkpoint.recoveryManifest = try StorageTransferRecoveryManifest(transactionID: journal.transactionID,
            accountFingerprint: account, payload: bytes, previousDatasetGenerationID: UUID())
        XCTAssertThrowsError(try checkpoint.validate(journal: journal))
    }
}

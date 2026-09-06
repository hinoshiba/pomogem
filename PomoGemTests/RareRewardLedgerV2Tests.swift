import CloudKit
import XCTest
@testable import PomoGem

final class RareRewardLedgerV2Tests: XCTestCase {
    private let epochID = UUID(
        uuidString: "70000000-0000-0000-0000-000000000001"
    )!

    private func migration(
        total: Int = 0,
        misses: Int = 0,
        seed: UInt64 = 0xA11C_E5E5_1234_5678
    ) -> RareRewardLedgerMigration {
        RareRewardLedgerMigration(
            epochID: epochID,
            fingerprint: "test-v1:\(epochID.uuidString):\(total):\(misses)",
            totalCreditedGrams: total,
            sinceLastGold: misses,
            seed: seed
        )
    }

    private func submission(
        _ suffix: Int,
        grams: Int,
        seconds: Int? = nil,
        mode: RareRewardMode = .standard,
        source: SessionSource = .timer,
        epochID: UUID? = nil
    ) -> RareRewardLedgerSubmission {
        RareRewardLedgerSubmission(
            epochID: epochID ?? self.epochID,
            sessionID: UUID(
                uuidString: String(
                    format: "71000000-0000-0000-0000-%012d",
                    suffix
                )
            )!,
            source: source,
            completedSeconds: seconds ?? max(
                Constants.Gacha.minimumMeasuredSeconds,
                grams / Constants.Mass.gramsPerMinute
                    * Constants.Timer.secondsPerMinute
            ),
            completedGrams: grams,
            mode: mode
        )
    }

    func testCloudKitOperationPolicyBoundsEveryLedgerRequest() {
        let operation = RareRewardCloudKitOperationPolicy.configure(
            CKFetchRecordsOperation(recordIDs: [])
        )

        XCTAssertEqual(
            operation.configuration.timeoutIntervalForRequest,
            RareRewardCloudKitOperationPolicy.requestTimeout
        )
        XCTAssertEqual(
            operation.configuration.timeoutIntervalForResource,
            RareRewardCloudKitOperationPolicy.resourceTimeout
        )
        XCTAssertEqual(operation.configuration.qualityOfService, .userInitiated)
        XCTAssertLessThanOrEqual(
            operation.configuration.timeoutIntervalForRequest,
            operation.configuration.timeoutIntervalForResource
        )
    }

    func testCloudKitBatchCompanionIsNotMisclassifiedAsConflict() {
        let batchFailure = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.batchRequestFailed.rawValue
        )

        XCTAssertFalse(
            RareRewardCloudKitErrorClassifier.isConflict(batchFailure)
        )
        guard case .transport = RareRewardCloudKitErrorClassifier
            .repositoryError(from: batchFailure) else {
            return XCTFail("A batch companion alone must remain a transport error")
        }
    }

    func testCloudKitPartialFailureUsesActualConflictCause() {
        let conflict = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.serverRecordChanged.rawValue
        )
        let batchFailure = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.batchRequestFailed.rawValue
        )
        let partial = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.partialFailure.rawValue,
            userInfo: [
                CKPartialErrorsByItemIDKey: [
                    AnyHashable("epoch"): conflict,
                    AnyHashable("receipt"): batchFailure
                ]
            ]
        )

        XCTAssertTrue(RareRewardCloudKitErrorClassifier.isConflict(partial))
        XCTAssertEqual(
            RareRewardCloudKitErrorClassifier.repositoryError(from: partial),
            .conflict
        )
    }

    func testCloudKitNonConflictPartialFailureDoesNotSpinCASRetries() {
        let quotaFailure = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.quotaExceeded.rawValue
        )
        let batchFailure = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.batchRequestFailed.rawValue
        )
        let partial = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.partialFailure.rawValue,
            userInfo: [
                CKPartialErrorsByItemIDKey: [
                    AnyHashable("epoch"): batchFailure,
                    AnyHashable("receipt"): quotaFailure
                ]
            ]
        )

        XCTAssertFalse(RareRewardCloudKitErrorClassifier.isConflict(partial))
        guard case .transport = RareRewardCloudKitErrorClassifier
            .repositoryError(from: partial) else {
            return XCTFail("Quota failure must not enter the CAS retry loop")
        }
    }

    func testCloudKitRepositoryErrorsAreNotDoubleMapped() {
        XCTAssertEqual(
            RareRewardCloudKitErrorClassifier.repositoryError(
                from: RareRewardLedgerRepositoryError.conflict
            ),
            .conflict
        )
    }

    func testUserDeletedZoneIsNotAutomaticallyRecreatedAsMissingZone() {
        let userDeletedZone = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.userDeletedZone.rawValue
        )

        XCTAssertFalse(
            RareRewardCloudKitErrorClassifier.isZoneNotFound(userDeletedZone)
        )
        guard case .transport = RareRewardCloudKitErrorClassifier
            .repositoryError(from: userDeletedZone) else {
            return XCTFail("A Settings deletion must stop automatic re-upload")
        }
    }

    func testCanonicalV2MigrationDoesNotForkForDivergentLegacyCaches() {
        let first = RareRewardLedgerMigration.canonicalV2(dataEpochID: epochID)
        let second = RareRewardLedgerMigration.canonicalV2(dataEpochID: epochID)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.totalCreditedGrams, 0)
        XCTAssertEqual(first.sinceLastGold, 0)
        XCTAssertEqual(first.initialEpoch.nextOrdinal, 0)
    }

    func testConcurrentFiftyPlusFiftyConsumesPityCreditExactlyOnce() async throws {
        let repository = InMemoryRareRewardLedgerRepository()
        let firstDevice = RareRewardLedgerCoordinator(repository: repository)
        let secondDevice = RareRewardLedgerCoordinator(repository: repository)
        let baseline = migration(
            total: Constants.Gacha.creditGrams - 50,
            misses: Constants.Gacha.pityMissCount
        )

        async let first = firstDevice.commit(
            submission(1, grams: 50),
            migration: baseline
        )
        async let second = secondDevice.commit(
            submission(2, grams: 50),
            migration: baseline
        )
        let (firstReceipt, secondReceipt) = try await (first, second)
        let receipts = [firstReceipt, secondReceipt]
        let epochSnapshot = await repository.fetchEpoch(epochID: epochID)
        let epoch = try XCTUnwrap(epochSnapshot?.epoch)

        XCTAssertEqual(epoch.totalCreditedGrams, 300)
        XCTAssertEqual(epoch.creditRemainderGrams, 50)
        XCTAssertEqual(epoch.nextOrdinal, 1)
        XCTAssertEqual(receipts.flatMap(\.outcomes), [.gold])
        XCTAssertEqual(receipts.reduce(0) { $0 + $1.acceptedGrams }, 100)
        XCTAssertEqual(Set(receipts.map(\.revisionAfter)), [1, 2])
    }

    func testConcurrentMassPartitionsHaveOneContiguousOrdinalStream() async throws {
        for (firstGrams, secondGrams, expectedCredits, expectedRemainder) in [
            (100, 150, 1, 0),
            (250, 250, 2, 0),
            (600, 600, 4, 200)
        ] {
            let repository = InMemoryRareRewardLedgerRepository()
            let firstDevice = RareRewardLedgerCoordinator(repository: repository)
            let secondDevice = RareRewardLedgerCoordinator(repository: repository)
            let baseline = migration()

            async let first = firstDevice.commit(
                submission(10 + firstGrams, grams: firstGrams),
                migration: baseline
            )
            async let second = secondDevice.commit(
                submission(20 + secondGrams, grams: secondGrams),
                migration: baseline
            )
            _ = try await (first, second)

            let epochSnapshot = await repository.fetchEpoch(epochID: epochID)
            let epoch = try XCTUnwrap(epochSnapshot?.epoch)
            let receipts = await repository.allReceipts(epochID: epochID)
            let ordinals = receipts
                .compactMap(\.ordinals)
                .flatMap(Array.init)
                .sorted()

            XCTAssertEqual(
                epoch.totalCreditedGrams,
                firstGrams + secondGrams
            )
            XCTAssertEqual(epoch.creditRemainderGrams, expectedRemainder)
            XCTAssertEqual(epoch.nextOrdinal, Int64(expectedCredits))
            XCTAssertEqual(
                ordinals,
                Array(Int64(0) ..< Int64(expectedCredits))
            )
            XCTAssertEqual(Set(ordinals).count, expectedCredits)
            XCTAssertEqual(
                receipts.flatMap(\.outcomes).count,
                expectedCredits
            )
        }
    }

    func testSameSessionConcurrentResendReturnsIdenticalReceipt() async throws {
        let repository = InMemoryRareRewardLedgerRepository()
        let firstDevice = RareRewardLedgerCoordinator(repository: repository)
        let secondDevice = RareRewardLedgerCoordinator(repository: repository)
        let baseline = migration()
        let completion = submission(30, grams: 600)

        async let first = firstDevice.commit(completion, migration: baseline)
        async let second = secondDevice.commit(completion, migration: baseline)
        let (firstReceipt, secondReceipt) = try await (first, second)

        XCTAssertEqual(firstReceipt, secondReceipt)
        let allReceipts = await repository.allReceipts(epochID: epochID)
        XCTAssertEqual(allReceipts.count, 1)
        let epochSnapshot = await repository.fetchEpoch(epochID: epochID)
        let epoch = try XCTUnwrap(epochSnapshot?.epoch)
        XCTAssertEqual(epoch.totalCreditedGrams, 600)
        XCTAssertEqual(epoch.nextOrdinal, 2)
        XCTAssertEqual(epoch.creditRemainderGrams, 100)
    }

    func testLostCommitAcknowledgementIsRecoveredByReceiptLookup() async throws {
        let repository = InMemoryRareRewardLedgerRepository(
            losesAcknowledgementAfterNextCommit: true
        )
        let coordinator = RareRewardLedgerCoordinator(repository: repository)
        let baseline = migration()
        let completion = submission(40, grams: 250)

        do {
            _ = try await coordinator.commit(completion, migration: baseline)
            XCTFail("The simulated process/network boundary must lose its acknowledgement")
        } catch let error as RareRewardLedgerRepositoryError {
            XCTAssertEqual(
                error,
                .transport("commit acknowledgement lost")
            )
        }

        let replayed = try await coordinator.commit(
            completion,
            migration: baseline
        )
        XCTAssertEqual(replayed.ordinalCount, 1)
        let allReceipts = await repository.allReceipts(epochID: epochID)
        XCTAssertEqual(allReceipts.count, 1)
        let epochSnapshot = await repository.fetchEpoch(epochID: epochID)
        let epoch = try XCTUnwrap(epochSnapshot?.epoch)
        XCTAssertEqual(epoch.totalCreditedGrams, 250)
        XCTAssertEqual(epoch.revision, 1)
    }

    func testCompareAndSwapConflictsDiscardProvisionalStateAndRetry() async throws {
        let repository = InMemoryRareRewardLedgerRepository(
            conflictsBeforeNextSuccess: 3
        )
        let coordinator = RareRewardLedgerCoordinator(repository: repository)

        let receipt = try await coordinator.commit(
            submission(50, grams: 600),
            migration: migration()
        )

        XCTAssertEqual(receipt.ordinals, Int64(0) ..< Int64(2))
        XCTAssertEqual(receipt.outcomes.count, 2)
        let epochSnapshot = await repository.fetchEpoch(epochID: epochID)
        let epoch = try XCTUnwrap(epochSnapshot?.epoch)
        XCTAssertEqual(epoch.totalCreditedGrams, 600)
        XCTAssertEqual(epoch.revision, 1)
    }

    func testOffWritesANonparticipatingReceiptWithoutBankingMass() async throws {
        let repository = InMemoryRareRewardLedgerRepository()
        let coordinator = RareRewardLedgerCoordinator(repository: repository)
        let receipt = try await coordinator.commit(
            submission(
                60,
                grams: 600,
                mode: .off
            ),
            migration: migration(total: 200, misses: 7)
        )

        XCTAssertFalse(receipt.participated)
        XCTAssertEqual(receipt.nonparticipationReason, .optedOut)
        XCTAssertEqual(receipt.acceptedGrams, 0)
        XCTAssertEqual(receipt.outcomes, [])
        let epochSnapshot = await repository.fetchEpoch(epochID: epochID)
        let epoch = try XCTUnwrap(epochSnapshot?.epoch)
        XCTAssertEqual(epoch.totalCreditedGrams, 200)
        XCTAssertEqual(epoch.sinceLastGold, 7)
        XCTAssertEqual(epoch.nextOrdinal, 0)
    }

    func testDemotedTimerWritesNonparticipatingReceipt() async throws {
        let repository = InMemoryRareRewardLedgerRepository()
        let coordinator = RareRewardLedgerCoordinator(repository: repository)
        let receipt = try await coordinator.commit(
            submission(
                70,
                grams: 250,
                source: .timerDemoted
            ),
            migration: migration()
        )

        XCTAssertFalse(receipt.participated)
        XCTAssertEqual(receipt.nonparticipationReason, .ineligibleSource)
        XCTAssertEqual(receipt.acceptedGrams, 0)
        let epochSnapshot = await repository.fetchEpoch(epochID: epochID)
        let epoch = try XCTUnwrap(epochSnapshot?.epoch)
        XCTAssertEqual(epoch.revision, 1)
        XCTAssertEqual(epoch.totalCreditedGrams, 0)
    }

    func testDifferentOfflineSessionIDsBothRemainMeasured() async throws {
        let repository = InMemoryRareRewardLedgerRepository()
        let firstDevice = RareRewardLedgerCoordinator(repository: repository)
        let secondDevice = RareRewardLedgerCoordinator(repository: repository)
        let baseline = migration()

        async let first = firstDevice.commit(
            submission(80, grams: 250),
            migration: baseline
        )
        async let second = secondDevice.commit(
            submission(81, grams: 250),
            migration: baseline
        )
        let (firstReceipt, secondReceipt) = try await (first, second)
        let receipts = [firstReceipt, secondReceipt]

        XCTAssertTrue(receipts.allSatisfy(\.participated))
        XCTAssertEqual(receipts.reduce(0) { $0 + $1.acceptedGrams }, 500)
        XCTAssertEqual(receipts.flatMap(\.outcomes).count, 2)
        let allReceipts = await repository.allReceipts(epochID: epochID)
        XCTAssertEqual(allReceipts.count, 2)
    }

    func testMigrationIsIdempotentAndMismatchFailsClosed() async throws {
        let repository = InMemoryRareRewardLedgerRepository()
        let firstDevice = RareRewardLedgerCoordinator(repository: repository)
        let secondDevice = RareRewardLedgerCoordinator(repository: repository)
        let accepted = migration(total: 200, misses: 4)

        _ = try await firstDevice.commit(
            submission(100, grams: 50),
            migration: accepted
        )
        _ = try await secondDevice.commit(
            submission(101, grams: 250),
            migration: accepted
        )

        let conflicting = RareRewardLedgerMigration(
            epochID: epochID,
            fingerprint: "different-device-legacy-snapshot",
            totalCreditedGrams: 400,
            sinceLastGold: 12,
            seed: 99
        )
        do {
            _ = try await secondDevice.commit(
                submission(102, grams: 250),
                migration: conflicting
            )
            XCTFail("Mismatched migration snapshots must not be max-merged")
        } catch let error as RareRewardLedgerError {
            XCTAssertEqual(error, .migrationFingerprintMismatch)
        }

        let epochSnapshot = await repository.fetchEpoch(epochID: epochID)
        let epoch = try XCTUnwrap(epochSnapshot?.epoch)
        XCTAssertEqual(epoch.migrationFingerprint, accepted.fingerprint)
        XCTAssertEqual(epoch.totalCreditedGrams, 500)
    }

    func testResetEpochHasIndependentReceiptAndOrdinalNamespace() async throws {
        let repository = InMemoryRareRewardLedgerRepository()
        let coordinator = RareRewardLedgerCoordinator(repository: repository)
        let first = submission(110, grams: 250)
        _ = try await coordinator.commit(first, migration: migration())

        let nextEpochID = UUID(
            uuidString: "70000000-0000-0000-0000-000000000002"
        )!
        let nextMigration = RareRewardLedgerMigration(
            epochID: nextEpochID,
            fingerprint: "reset-v1:\(nextEpochID.uuidString):0:0",
            totalCreditedGrams: 0,
            sinceLastGold: 0,
            seed: 0xBEEF
        )
        let replayedSessionID = RareRewardLedgerSubmission(
            epochID: nextEpochID,
            sessionID: first.sessionID,
            source: .timer,
            completedSeconds: first.completedSeconds,
            completedGrams: 250,
            mode: .standard
        )
        let second = try await coordinator.commit(
            replayedSessionID,
            migration: nextMigration
        )

        XCTAssertEqual(second.firstOrdinal, 0)
        let oldReceipts = await repository.allReceipts(epochID: epochID)
        let newReceipts = await repository.allReceipts(epochID: nextEpochID)
        XCTAssertEqual(oldReceipts.count, 1)
        XCTAssertEqual(newReceipts.count, 1)
    }

    func testOrdinalRollsAreStableAcrossProcessesAndRetryOrder() async throws {
        let baseline = migration(seed: 0x1234_5678_9ABC_DEF0)
        let orderedRepository = InMemoryRareRewardLedgerRepository()
        let ordered = RareRewardLedgerCoordinator(
            repository: orderedRepository
        )
        _ = try await ordered.commit(
            submission(120, grams: 250),
            migration: baseline
        )
        _ = try await ordered.commit(
            submission(121, grams: 250),
            migration: baseline
        )

        let reversedRepository = InMemoryRareRewardLedgerRepository()
        let reversed = RareRewardLedgerCoordinator(
            repository: reversedRepository
        )
        _ = try await reversed.commit(
            submission(121, grams: 250),
            migration: baseline
        )
        _ = try await reversed.commit(
            submission(120, grams: 250),
            migration: baseline
        )

        let orderedSnapshot = await orderedRepository.fetchEpoch(epochID: epochID)
        let reversedSnapshot = await reversedRepository.fetchEpoch(epochID: epochID)
        let orderedEpoch = try XCTUnwrap(orderedSnapshot?.epoch)
        let reversedEpoch = try XCTUnwrap(reversedSnapshot?.epoch)
        XCTAssertEqual(orderedEpoch, reversedEpoch)
        let orderedOutcomes = await orderedRepository
            .allReceipts(epochID: epochID)
            .flatMap(\.outcomes)
        let reversedOutcomes = await reversedRepository
            .allReceipts(epochID: epochID)
            .flatMap(\.outcomes)
        XCTAssertEqual(orderedOutcomes, reversedOutcomes)
    }
}

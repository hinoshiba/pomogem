import Foundation

/// The server-authoritative rare-reward ledger introduced for multi-device
/// accounts. A `StudySession` remains the source of truth for effort; this
/// ledger serializes only the optional visual reward credits derived from it.
enum RareRewardLedgerV2 {
    static let ruleVersion = 2
    static let maximumCommitAttempts = 12

    /// Stores pre-reset data in a real CloudKit record namespace without
    /// inventing a different identifier on each device.
    static let legacyEpochID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

    static func normalizedEpochID(_ dataEpochID: UUID?) -> UUID {
        dataEpochID ?? legacyEpochID
    }

    static func epochRecordName(_ epochID: UUID) -> String {
        "rare-epoch-v2-\(epochID.uuidString.lowercased())"
    }

    static func receiptRecordName(epochID: UUID, sessionID: UUID) -> String {
        "rare-receipt-v2-\(epochID.uuidString.lowercased())-\(sessionID.uuidString.lowercased())"
    }

    /// A readable canonical fingerprint is preferable to an opaque local hash:
    /// two devices can prove they migrated the same legacy scalar state, and a
    /// disagreement is diagnosable without logging reward outcomes.
    static func migrationFingerprint(
        epochID: UUID,
        legacyTotalCreditedGrams: Int,
        legacySinceLastGold: Int
    ) -> String {
        [
            "rare-v1",
            epochID.uuidString.lowercased(),
            String(max(0, legacyTotalCreditedGrams)),
            String(max(0, legacySinceLastGold))
        ].joined(separator: ":")
    }

    /// Stable FNV-1a seed derivation. It is not a security boundary; its only
    /// job is making a given migration fingerprint produce the same ordinal
    /// stream on every device racing to create the epoch.
    static func deterministicSeed(for migrationFingerprint: String) -> UInt64 {
        migrationFingerprint.utf8.reduce(14_695_981_039_346_656_037) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
    }

    /// Generates a stable uniform value from the epoch seed and server-issued
    /// ordinal. SplitMix64 is small, platform-independent, and has no mutable
    /// generator state that could diverge across retries.
    static func unitRoll(seed: UInt64, ordinal: Int64) -> Double {
        var value = seed &+ UInt64(bitPattern: ordinal)
            &+ 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Double(value >> 11) / 9_007_199_254_740_992.0
    }
}

struct RareRewardLedgerMigration: Equatable, Codable, Sendable {
    let epochID: UUID
    let fingerprint: String
    let totalCreditedGrams: Int
    let sinceLastGold: Int
    let seed: UInt64

    init(
        epochID: UUID,
        fingerprint: String,
        totalCreditedGrams: Int,
        sinceLastGold: Int,
        seed: UInt64
    ) {
        self.epochID = epochID
        self.fingerprint = fingerprint
        self.totalCreditedGrams = max(0, totalCreditedGrams)
        self.sinceLastGold = max(0, sinceLastGold)
        self.seed = seed
    }

    static func legacy(
        dataEpochID: UUID?,
        totalCreditedGrams: Int,
        sinceLastGold: Int
    ) -> Self {
        let epochID = RareRewardLedgerV2.normalizedEpochID(dataEpochID)
        let fingerprint = RareRewardLedgerV2.migrationFingerprint(
            epochID: epochID,
            legacyTotalCreditedGrams: totalCreditedGrams,
            legacySinceLastGold: sinceLastGold
        )
        return Self(
            epochID: epochID,
            fingerprint: fingerprint,
            totalCreditedGrams: totalCreditedGrams,
            sinceLastGold: sinceLastGold,
            seed: RareRewardLedgerV2.deterministicSeed(
                for: fingerprint
            )
        )
    }

    /// First-release baseline shared by every device, regardless of any
    /// pre-V2 local scalar cache. Those caches cannot be losslessly merged when
    /// two devices advanced them offline, so importing either device's value
    /// would make the other device permanently disagree. Existing awarded
    /// StudySession visuals remain intact; only the V2 remainder/pity stream
    /// starts from this deterministic zero baseline.
    static func canonicalV2(dataEpochID: UUID?) -> Self {
        let epochID = RareRewardLedgerV2.normalizedEpochID(dataEpochID)
        let fingerprint = [
            "rare-v2-canonical",
            epochID.uuidString.lowercased()
        ].joined(separator: ":")
        return Self(
            epochID: epochID,
            fingerprint: fingerprint,
            totalCreditedGrams: 0,
            sinceLastGold: 0,
            seed: RareRewardLedgerV2.deterministicSeed(for: fingerprint)
        )
    }

    var initialEpoch: RareRewardLedgerEpoch {
        RareRewardLedgerEpoch(
            epochID: epochID,
            migrationFingerprint: fingerprint,
            totalCreditedGrams: totalCreditedGrams,
            creditRemainderGrams: totalCreditedGrams
                % Constants.Gacha.creditGrams,
            nextOrdinal: Int64(
                totalCreditedGrams / Constants.Gacha.creditGrams
            ),
            sinceLastGold: sinceLastGold,
            seed: seed,
            revision: 0
        )
    }
}

struct RareRewardLedgerEpoch: Equatable, Codable, Sendable {
    let epochID: UUID
    let migrationFingerprint: String
    let totalCreditedGrams: Int
    let creditRemainderGrams: Int
    let nextOrdinal: Int64
    let sinceLastGold: Int
    let seed: UInt64
    let revision: Int64

    func validated() throws -> Self {
        guard !migrationFingerprint.isEmpty,
              totalCreditedGrams >= 0,
              creditRemainderGrams >= 0,
              creditRemainderGrams < Constants.Gacha.creditGrams,
              creditRemainderGrams
                == totalCreditedGrams % Constants.Gacha.creditGrams,
              nextOrdinal >= 0,
              nextOrdinal == Int64(
                totalCreditedGrams / Constants.Gacha.creditGrams
              ),
              sinceLastGold >= 0,
              revision >= 0 else {
            throw RareRewardLedgerError.corruptEpoch
        }
        return self
    }
}

struct RareRewardLedgerSubmission: Equatable, Codable, Sendable {
    let epochID: UUID
    let sessionID: UUID
    let source: SessionSource
    let completedSeconds: Int
    let completedGrams: Int
    let mode: RareRewardMode

    init(
        epochID: UUID,
        sessionID: UUID,
        source: SessionSource,
        completedSeconds: Int,
        completedGrams: Int,
        mode: RareRewardMode
    ) {
        self.epochID = epochID
        self.sessionID = sessionID
        self.source = source
        self.completedSeconds = max(0, completedSeconds)
        self.completedGrams = max(0, completedGrams)
        self.mode = mode
    }

    var fingerprint: String {
        [
            epochID.uuidString.lowercased(),
            sessionID.uuidString.lowercased(),
            source.rawValue,
            String(completedSeconds),
            String(completedGrams),
            mode.rawValue
        ].joined(separator: ":")
    }
}

enum RareRewardLedgerNonparticipationReason: String, Codable, Sendable {
    case optedOut
    case ineligibleSource
    case insufficientMeasuredDuration
}

struct RareRewardLedgerReceipt: Equatable, Codable, Sendable {
    let epochID: UUID
    let sessionID: UUID
    let submissionFingerprint: String
    let participated: Bool
    let nonparticipationReason: RareRewardLedgerNonparticipationReason?
    let acceptedGrams: Int
    let firstOrdinal: Int64?
    let ordinalCount: Int
    let outcomes: [PebbleKind]
    let revisionBefore: Int64
    let revisionAfter: Int64
    let totalCreditedGramsAfter: Int
    let creditRemainderGramsAfter: Int
    let sinceLastGoldAfter: Int

    var ordinals: Range<Int64>? {
        guard let firstOrdinal, ordinalCount > 0 else { return nil }
        return firstOrdinal ..< firstOrdinal + Int64(ordinalCount)
    }

    var representativeKind: PebbleKind {
        RareRewardPolicy.representativeKind(for: outcomes)
    }

    func validated() throws -> Self {
        let ordinalRangeIsValid: Bool
        if let firstOrdinal {
            ordinalRangeIsValid = ordinalCount > 0
                && firstOrdinal >= 0
                && firstOrdinal <= Int64.max - Int64(ordinalCount)
        } else {
            ordinalRangeIsValid = ordinalCount == 0
        }
        guard !submissionFingerprint.isEmpty,
              participated == (nonparticipationReason == nil),
              acceptedGrams >= 0,
              acceptedGrams
                <= Constants.Gacha.maximumCreditableGramsPerCompletion,
              participated || acceptedGrams == 0,
              ordinalCount >= 0,
              ordinalCount == outcomes.count,
              RareRewardCreditPolicy.isPossibleOutcomeCount(
                ordinalCount,
                forContributionGrams: acceptedGrams
              ),
              ordinalRangeIsValid,
              revisionBefore >= 0,
              revisionBefore < Int64.max,
              revisionAfter == revisionBefore + 1,
              totalCreditedGramsAfter >= acceptedGrams,
              creditRemainderGramsAfter >= 0,
              creditRemainderGramsAfter < Constants.Gacha.creditGrams,
              creditRemainderGramsAfter
                == totalCreditedGramsAfter % Constants.Gacha.creditGrams,
              sinceLastGoldAfter >= 0 else {
            throw RareRewardLedgerError.corruptReceipt
        }
        return self
    }
}

struct RareRewardLedgerEpochSnapshot: Equatable, Sendable {
    let epoch: RareRewardLedgerEpoch
    /// Opaque compare-and-swap token. CloudKit implementations use the record
    /// change tag; the in-memory implementation uses its own generation.
    let changeToken: String
}

enum RareRewardLedgerRepositoryError: Error, LocalizedError, Equatable, Sendable {
    case conflict
    case notFound
    case corruptRecord
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .conflict:
            "別の端末と同時に台帳を更新しました。再試行します。"
        case .notFound:
            "iCloudのレア粒台帳が見つかりません。"
        case .corruptRecord:
            "iCloudのレア粒台帳を検証できませんでした。"
        case let .transport(message):
            "iCloudへレア粒を確定できませんでした。端末内の完走記録は保持されています。\n\(message)"
        }
    }
}

protocol RareRewardLedgerRepository: Sendable {
    func fetchEpoch(
        epochID: UUID
    ) async throws -> RareRewardLedgerEpochSnapshot?

    func fetchReceipt(
        epochID: UUID,
        sessionID: UUID
    ) async throws -> RareRewardLedgerReceipt?

    func createEpoch(
        _ epoch: RareRewardLedgerEpoch
    ) async throws -> RareRewardLedgerEpochSnapshot

    func commit(
        expected: RareRewardLedgerEpochSnapshot,
        updatedEpoch: RareRewardLedgerEpoch,
        receipt: RareRewardLedgerReceipt
    ) async throws -> RareRewardLedgerEpochSnapshot
}

enum RareRewardLedgerError: Error, LocalizedError, Equatable, Sendable {
    case corruptEpoch
    case corruptReceipt
    case migrationFingerprintMismatch
    case submissionEpochMismatch
    case duplicateSessionPayloadMismatch
    case arithmeticOverflow
    case retryLimitExceeded

    var errorDescription: String? {
        switch self {
        case .corruptEpoch:
            "iCloudのレア粒epochが不整合です。抽選を停止しました。"
        case .corruptReceipt:
            "iCloudのレア粒確定結果が不整合です。抽選を停止しました。"
        case .migrationFingerprintMismatch:
            "別の端末と旧レア粒台帳の状態が一致しません。抽選を停止しました。"
        case .submissionEpochMismatch:
            "完走記録とレア粒epochが一致しません。"
        case .duplicateSessionPayloadMismatch:
            "同じ完走IDに異なる内容が届いたため、抽選を停止しました。"
        case .arithmeticOverflow:
            "レア粒台帳の数値上限を超えました。"
        case .retryLimitExceeded:
            "別の端末との更新競合が続いています。完走記録を保持して後で再試行します。"
        }
    }
}

struct RareRewardLedgerCoordinator: Sendable {
    private let repository: any RareRewardLedgerRepository

    init(repository: any RareRewardLedgerRepository) {
        self.repository = repository
    }

    /// Returns the one durable receipt for a logical StudySession. Every
    /// conflict discards its provisional transition and recomputes from the
    /// newly fetched epoch; no random state survives a failed CAS attempt.
    func commit(
        _ submission: RareRewardLedgerSubmission,
        migration: RareRewardLedgerMigration
    ) async throws -> RareRewardLedgerReceipt {
        guard submission.epochID == migration.epochID else {
            throw RareRewardLedgerError.submissionEpochMismatch
        }

        for _ in 0 ..< RareRewardLedgerV2.maximumCommitAttempts {
            if let receipt = try await repository.fetchReceipt(
                epochID: submission.epochID,
                sessionID: submission.sessionID
            ) {
                guard receipt.epochID == submission.epochID,
                      receipt.sessionID == submission.sessionID,
                      receipt.submissionFingerprint == submission.fingerprint else {
                    throw RareRewardLedgerError.duplicateSessionPayloadMismatch
                }
                return try receipt.validated()
            }

            let snapshot: RareRewardLedgerEpochSnapshot
            if let existing = try await repository.fetchEpoch(
                epochID: submission.epochID
            ) {
                snapshot = existing
            } else {
                do {
                    snapshot = try await repository.createEpoch(
                        migration.initialEpoch
                    )
                } catch RareRewardLedgerRepositoryError.conflict {
                    continue
                }
            }

            let current = try snapshot.epoch.validated()
            guard current.migrationFingerprint == migration.fingerprint else {
                throw RareRewardLedgerError.migrationFingerprintMismatch
            }
            let transition = try Self.transition(
                from: current,
                submission: submission
            )
            do {
                _ = try await repository.commit(
                    expected: snapshot,
                    updatedEpoch: transition.epoch,
                    receipt: transition.receipt
                )
                return try transition.receipt.validated()
            } catch RareRewardLedgerRepositoryError.conflict {
                continue
            }
        }
        throw RareRewardLedgerError.retryLimitExceeded
    }

    private static func transition(
        from current: RareRewardLedgerEpoch,
        submission: RareRewardLedgerSubmission
    ) throws -> (
        epoch: RareRewardLedgerEpoch,
        receipt: RareRewardLedgerReceipt
    ) {
        let nonparticipationReason: RareRewardLedgerNonparticipationReason?
        if !submission.mode.performsRandomDraw {
            nonparticipationReason = .optedOut
        } else if submission.source != .timer {
            nonparticipationReason = .ineligibleSource
        } else if submission.completedSeconds
            < Constants.Gacha.minimumMeasuredSeconds {
            nonparticipationReason = .insufficientMeasuredDuration
        } else {
            nonparticipationReason = nil
        }
        let participated = nonparticipationReason == nil
        let acceptedGrams = participated
            ? min(
                submission.completedGrams,
                Constants.Gacha.maximumCreditableGramsPerCompletion
            )
            : 0

        guard current.revision < Int64.max,
              current.totalCreditedGrams <= Int.max - acceptedGrams else {
            throw RareRewardLedgerError.arithmeticOverflow
        }
        let total = current.totalCreditedGrams + acceptedGrams
        let newCreditCount = total / Constants.Gacha.creditGrams
            - current.totalCreditedGrams / Constants.Gacha.creditGrams
        guard current.nextOrdinal <= Int64.max - Int64(newCreditCount) else {
            throw RareRewardLedgerError.arithmeticOverflow
        }

        var outcomes: [PebbleKind] = []
        outcomes.reserveCapacity(newCreditCount)
        var sinceLastGold = current.sinceLastGold
        for offset in 0 ..< newCreditCount {
            let ordinal = current.nextOrdinal + Int64(offset)
            let roll = GachaEngine.drawCredit(
                sinceLastGold: sinceLastGold,
                unitRoll: RareRewardLedgerV2.unitRoll(
                    seed: current.seed,
                    ordinal: ordinal
                )
            )
            outcomes.append(roll.kind)
            sinceLastGold = roll.sinceLastGold
        }

        let next = RareRewardLedgerEpoch(
            epochID: current.epochID,
            migrationFingerprint: current.migrationFingerprint,
            totalCreditedGrams: total,
            creditRemainderGrams: total % Constants.Gacha.creditGrams,
            nextOrdinal: current.nextOrdinal + Int64(newCreditCount),
            sinceLastGold: sinceLastGold,
            seed: current.seed,
            revision: current.revision + 1
        )
        _ = try next.validated()

        let receipt = RareRewardLedgerReceipt(
            epochID: current.epochID,
            sessionID: submission.sessionID,
            submissionFingerprint: submission.fingerprint,
            participated: participated,
            nonparticipationReason: nonparticipationReason,
            acceptedGrams: acceptedGrams,
            firstOrdinal: newCreditCount > 0 ? current.nextOrdinal : nil,
            ordinalCount: newCreditCount,
            outcomes: outcomes,
            revisionBefore: current.revision,
            revisionAfter: next.revision,
            totalCreditedGramsAfter: next.totalCreditedGrams,
            creditRemainderGramsAfter: next.creditRemainderGrams,
            sinceLastGoldAfter: next.sinceLastGold
        )
        return (next, try receipt.validated())
    }
}

/// A real compare-and-swap store used by deterministic tests and previews.
/// Multiple coordinators may share this actor to model fully offline devices
/// reconnecting at the same time.
actor InMemoryRareRewardLedgerRepository: RareRewardLedgerRepository {
    private struct StoredEpoch {
        var epoch: RareRewardLedgerEpoch
        var generation: Int64

        var snapshot: RareRewardLedgerEpochSnapshot {
            RareRewardLedgerEpochSnapshot(
                epoch: epoch,
                changeToken: "memory-\(generation)"
            )
        }
    }

    private var epochs: [UUID: StoredEpoch] = [:]
    private var receipts: [String: RareRewardLedgerReceipt] = [:]
    private var conflictsBeforeNextSuccess: Int
    private var losesAcknowledgementAfterNextCommit: Bool

    init(
        conflictsBeforeNextSuccess: Int = 0,
        losesAcknowledgementAfterNextCommit: Bool = false
    ) {
        self.conflictsBeforeNextSuccess = max(
            0,
            conflictsBeforeNextSuccess
        )
        self.losesAcknowledgementAfterNextCommit =
            losesAcknowledgementAfterNextCommit
    }

    func fetchEpoch(
        epochID: UUID
    ) -> RareRewardLedgerEpochSnapshot? {
        epochs[epochID]?.snapshot
    }

    func fetchReceipt(
        epochID: UUID,
        sessionID: UUID
    ) -> RareRewardLedgerReceipt? {
        receipts[Self.receiptKey(epochID: epochID, sessionID: sessionID)]
    }

    func createEpoch(
        _ epoch: RareRewardLedgerEpoch
    ) throws -> RareRewardLedgerEpochSnapshot {
        guard epochs[epoch.epochID] == nil else {
            throw RareRewardLedgerRepositoryError.conflict
        }
        _ = try epoch.validated()
        let stored = StoredEpoch(epoch: epoch, generation: 1)
        epochs[epoch.epochID] = stored
        return stored.snapshot
    }

    func commit(
        expected: RareRewardLedgerEpochSnapshot,
        updatedEpoch: RareRewardLedgerEpoch,
        receipt: RareRewardLedgerReceipt
    ) throws -> RareRewardLedgerEpochSnapshot {
        if conflictsBeforeNextSuccess > 0 {
            conflictsBeforeNextSuccess -= 1
            throw RareRewardLedgerRepositoryError.conflict
        }
        guard var stored = epochs[expected.epoch.epochID],
              stored.snapshot.changeToken == expected.changeToken,
              stored.epoch == expected.epoch,
              updatedEpoch.epochID == stored.epoch.epochID,
              updatedEpoch.revision == stored.epoch.revision + 1 else {
            throw RareRewardLedgerRepositoryError.conflict
        }
        let key = Self.receiptKey(
            epochID: receipt.epochID,
            sessionID: receipt.sessionID
        )
        guard receipts[key] == nil else {
            throw RareRewardLedgerRepositoryError.conflict
        }
        _ = try updatedEpoch.validated()
        _ = try receipt.validated()

        stored.epoch = updatedEpoch
        stored.generation += 1
        epochs[updatedEpoch.epochID] = stored
        receipts[key] = receipt

        if losesAcknowledgementAfterNextCommit {
            losesAcknowledgementAfterNextCommit = false
            throw RareRewardLedgerRepositoryError.transport(
                "commit acknowledgement lost"
            )
        }
        return stored.snapshot
    }

    func allReceipts(epochID: UUID) -> [RareRewardLedgerReceipt] {
        receipts.values
            .filter { $0.epochID == epochID }
            .sorted {
                if $0.revisionAfter == $1.revisionAfter {
                    return $0.sessionID.uuidString < $1.sessionID.uuidString
                }
                return $0.revisionAfter < $1.revisionAfter
            }
    }

    private static func receiptKey(epochID: UUID, sessionID: UUID) -> String {
        RareRewardLedgerV2.receiptRecordName(
            epochID: epochID,
            sessionID: sessionID
        )
    }
}

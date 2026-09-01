import SwiftData
import XCTest
@testable import Tsumiben

@MainActor
final class GachaHistoryReconciliationTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Subject.self,
            StudySession.self,
            AchievementStone.self,
            AggregatePebble.self,
            Stratum.self,
            Bedrock.self,
            GachaState.self,
            Prefs.self,
            ActivityResetMarker.self,
            SyncedFocusTimer.self,
            FocusTimerDeviceClaim.self
        ])
        let configuration = ModelConfiguration(
            "GachaHistoryReconciliationTests",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func snapshot(
        id: UUID = UUID(),
        endAt: Date,
        seconds: Int = Constants.Gacha.minimumEligibleSeconds,
        source: SessionSource = .timer,
        kind: PebbleKind = .normal,
        ruleVersion: Int? = nil,
        participated: Bool? = nil,
        creditedGrams: Int? = nil,
        outcomes: [PebbleKind]? = nil
    ) -> GachaHistorySnapshot {
        GachaHistorySnapshot(
            id: id,
            endAt: endAt,
            seconds: seconds,
            source: source,
            pebbleKind: kind,
            rareRewardRuleVersion: ruleVersion,
            rareRewardParticipated: participated,
            rareRewardCreditedGrams: creditedGrams,
            rareRewardOutcomes: outcomes
        )
    }

    private func session(
        id: UUID = UUID(),
        endAt: Date,
        source: SessionSource = .timer,
        kind: PebbleKind = .normal
    ) -> StudySession {
        StudySession(
            id: id,
            startAt: endAt.addingTimeInterval(
                -TimeInterval(Constants.Gacha.minimumEligibleSeconds)
            ),
            endAt: endAt,
            seconds: Constants.Gacha.minimumEligibleSeconds,
            source: source,
            pebbleKind: kind,
            deviceDayKey: "2027-01-01"
        )
    }

    func testPartialOneRowDeliveryNeverRegressesKnownProgress() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(GachaState(sinceLastGold: 12))
        context.insert(session(endAt: Date(timeIntervalSince1970: 100)))
        try context.save()

        try SeedData.bootstrap(context: context)

        let state = try XCTUnwrap(context.fetch(FetchDescriptor<GachaState>()).first)
        XCTAssertEqual(state.sinceLastGold, 12)
    }

    func testDelayedOldRowsCannotChangeTheTailAfterANewerGold() {
        let base = Date(timeIntervalSince1970: 1_000)
        let gold = snapshot(endAt: base, kind: .gold)
        let tail = (1...4).map {
            snapshot(endAt: base.addingTimeInterval(TimeInterval($0)))
        }
        let delayedOld = snapshot(endAt: base.addingTimeInterval(-100))

        XCTAssertEqual(
            GachaHistoryReconciliationPolicy.reconciledProgress(
                knownProgress: 4,
                sessions: tail + [delayedOld, gold]
            ),
            4
        )
    }

    func testDuplicatePhysicalRowsCountAsOneLogicalCompletionInEitherOrder() {
        let id = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let date = Date(timeIntervalSince1970: 2_000)
        let normal = snapshot(id: id, endAt: date, kind: .normal)
        let prism = snapshot(id: id, endAt: date, kind: .prism)

        let forward = GachaHistoryReconciliationPolicy.reconciledProgress(
            knownProgress: 0,
            sessions: [normal, prism]
        )
        let reverse = GachaHistoryReconciliationPolicy.reconciledProgress(
            knownProgress: 0,
            sessions: [prism, normal]
        )

        XCTAssertEqual(forward, 1)
        XCTAssertEqual(reverse, forward)
    }

    func testDemotingLatestGoldReplaysTheBoundedPriorTail() {
        let base = Date(timeIntervalSince1970: 3_000)
        let misses = (0..<3).map {
            snapshot(endAt: base.addingTimeInterval(TimeInterval($0)))
        }
        let goldID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let gold = snapshot(
            id: goldID,
            endAt: base.addingTimeInterval(3),
            kind: .gold
        )
        let demotedGold = snapshot(
            id: goldID,
            endAt: base.addingTimeInterval(3),
            source: .timerDemoted,
            kind: .gold
        )

        XCTAssertEqual(
            GachaHistoryReconciliationPolicy.reconciledProgress(
                knownProgress: 0,
                sessions: misses + [gold]
            ),
            0
        )
        XCTAssertEqual(
            GachaHistoryReconciliationPolicy.reconciledProgress(
                knownProgress: 0,
                sessions: misses + [gold, demotedGold]
            ),
            3
        )
    }

    func testEqualTimestampUsesUUIDTieBreakIndependentOfInsertionOrder() {
        let instant = Date(timeIntervalSince1970: 4_000)
        let lowerID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let higherID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
        let gold = snapshot(id: lowerID, endAt: instant, kind: .gold)
        let laterMiss = snapshot(id: higherID, endAt: instant)

        let forward = GachaHistoryReconciliationPolicy.reconciledProgress(
            knownProgress: 0,
            sessions: [gold, laterMiss]
        )
        let reverse = GachaHistoryReconciliationPolicy.reconciledProgress(
            knownProgress: 0,
            sessions: [laterMiss, gold]
        )

        XCTAssertEqual(forward, 1)
        XCTAssertEqual(reverse, forward)
    }

    func testVersionedBatchCountsCreditsRatherThanCompletionRows() {
        let value = snapshot(
            endAt: Date(timeIntervalSince1970: 5_000),
            kind: .normal,
            ruleVersion: Constants.Gacha.creditRuleVersion,
            participated: true,
            creditedGrams: 600,
            outcomes: [.normal, .prism]
        )

        XCTAssertEqual(
            GachaHistoryReconciliationPolicy.reconciledProgress(
                knownProgress: 0,
                sessions: [value]
            ),
            2
        )
        XCTAssertEqual(
            GachaHistoryReconciliationPolicy.observedRewardCreditGrams(
                sessions: [value]
            ),
            600
        )
    }

    func testGoldInsideVersionedBatchPreservesOnlyFollowingMisses() {
        let value = snapshot(
            endAt: Date(timeIntervalSince1970: 5_100),
            kind: .gold,
            ruleVersion: Constants.Gacha.creditRuleVersion,
            participated: true,
            creditedGrams: 600,
            outcomes: [.gold, .normal]
        )

        XCTAssertEqual(
            GachaHistoryReconciliationPolicy.reconciledProgress(
                knownProgress: 0,
                sessions: [value]
            ),
            1
        )
    }

    func testVersionedOffSessionNeverAdvancesPityOrCreditMass() {
        let disabled = snapshot(
            endAt: Date(timeIntervalSince1970: 5_200),
            ruleVersion: Constants.Gacha.creditRuleVersion,
            participated: false,
            creditedGrams: 0,
            outcomes: []
        )

        XCTAssertEqual(
            GachaHistoryReconciliationPolicy.reconciledProgress(
                knownProgress: 7,
                sessions: [disabled]
            ),
            7
        )
        XCTAssertEqual(
            GachaHistoryReconciliationPolicy.observedRewardCreditGrams(
                sessions: [disabled]
            ),
            0
        )
    }

    func testLegacySixtyMinuteRowRemainsOneOldDrawAndAddsNoNewLedgerMass() {
        let legacy = snapshot(
            endAt: Date(timeIntervalSince1970: 5_300),
            seconds: Constants.Timer.sixtyMinutes * Constants.Timer.secondsPerMinute
        )

        XCTAssertEqual(
            GachaHistoryReconciliationPolicy.reconciledProgress(
                knownProgress: 0,
                sessions: [legacy]
            ),
            1
        )
        XCTAssertEqual(
            GachaHistoryReconciliationPolicy.observedRewardCreditGrams(
                sessions: [legacy]
            ),
            0
        )
    }

    func testVersionedDuplicateIDCannotDoubleCreditMass() {
        let id = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        let date = Date(timeIntervalSince1970: 5_400)
        let value = snapshot(
            id: id,
            endAt: date,
            ruleVersion: Constants.Gacha.creditRuleVersion,
            participated: true,
            creditedGrams: 250,
            outcomes: [.normal]
        )

        XCTAssertEqual(
            GachaHistoryReconciliationPolicy.observedRewardCreditGrams(
                sessions: [value, value]
            ),
            250
        )
        XCTAssertEqual(
            GachaHistoryReconciliationPolicy.reconciledProgress(
                knownProgress: 0,
                sessions: [value, value]
            ),
            1
        )
    }

    func testUnsupportedOrUnboundedVersionedMetadataFailsClosed() {
        let future = snapshot(
            endAt: Date(timeIntervalSince1970: 5_500),
            ruleVersion: Constants.Gacha.creditRuleVersion + 1,
            participated: true,
            creditedGrams: Int.max,
            outcomes: [.gold]
        )

        XCTAssertEqual(
            GachaHistoryReconciliationPolicy.observedRewardCreditGrams(
                sessions: [future]
            ),
            0
        )
        XCTAssertEqual(
            GachaHistoryReconciliationPolicy.reconciledProgress(
                knownProgress: 3,
                sessions: [future]
            ),
            3
        )

        let impossibleBatch = snapshot(
            endAt: Date(timeIntervalSince1970: 5_600),
            ruleVersion: Constants.Gacha.creditRuleVersion,
            participated: true,
            creditedGrams: 100,
            outcomes: [.normal, .normal]
        )
        XCTAssertEqual(
            GachaHistoryReconciliationPolicy.observedRewardCreditGrams(
                sessions: [impossibleBatch]
            ),
            0
        )
    }

    /// Release-blocker proof: two devices that leave the same pity state while
    /// fully offline can both consume the same logical credit. Once only their
    /// scalar states and completed-session projections remain, a merge cannot
    /// reconstruct the serial result without inventing which receipt came first.
    func testOfflinePityScalarMergeCannotEqualAOnceOnlySerialLedger() {
        let initialMisses = Constants.Gacha.pityMissCount
        let highNaturalRoll = Double(1).nextDown

        let deviceA = GachaEngine.drawCredit(
            sinceLastGold: initialMisses,
            unitRoll: highNaturalRoll
        )
        let deviceB = GachaEngine.drawCredit(
            sinceLastGold: initialMisses,
            unitRoll: highNaturalRoll
        )
        XCTAssertEqual([deviceA.kind, deviceB.kind], [.gold, .gold])

        let serialFirst = GachaEngine.drawCredit(
            sinceLastGold: initialMisses,
            unitRoll: highNaturalRoll
        )
        let serialSecond = GachaEngine.drawCredit(
            sinceLastGold: serialFirst.sinceLastGold,
            unitRoll: highNaturalRoll
        )
        XCTAssertEqual([serialFirst.kind, serialSecond.kind], [.gold, .normal])

        let mergedHistory = [
            snapshot(
                id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
                endAt: Date(timeIntervalSince1970: 6_000),
                kind: deviceA.kind,
                ruleVersion: Constants.Gacha.creditRuleVersion,
                participated: true,
                creditedGrams: Constants.Gacha.creditGrams,
                outcomes: [deviceA.kind]
            ),
            snapshot(
                id: UUID(uuidString: "50000000-0000-0000-0000-000000000002")!,
                endAt: Date(timeIntervalSince1970: 6_001),
                kind: deviceB.kind,
                ruleVersion: Constants.Gacha.creditRuleVersion,
                participated: true,
                creditedGrams: Constants.Gacha.creditGrams,
                outcomes: [deviceB.kind]
            )
        ]

        let scalarMerge = GachaHistoryReconciliationPolicy.reconciledProgress(
            knownProgress: 0,
            sessions: mergedHistory
        )
        XCTAssertEqual(scalarMerge, 0)
        XCTAssertEqual(serialSecond.sinceLastGold, 1)
        XCTAssertNotEqual(scalarMerge, serialSecond.sinceLastGold)
    }

    /// Release-blocker proof for fractional mass: max-merging two local totals
    /// loses one device's contribution, while summing only the new rows loses
    /// the shared pre-split remainder. Neither scalar is a CRDT for this state.
    func testOfflineFractionalScalarMergeLosesSharedBaselineRemainder() {
        let sharedBaseline = Constants.Gacha.creditGrams - 50
        let localA = RareRewardCreditPolicy.allocation(
            previousTotalGrams: sharedBaseline,
            completedGrams: 50,
            source: .timer
        )
        let localB = RareRewardCreditPolicy.allocation(
            previousTotalGrams: sharedBaseline,
            completedGrams: 50,
            source: .timer
        )
        XCTAssertEqual(localA.totalGrams, Constants.Gacha.creditGrams)
        XCTAssertEqual(localB.totalGrams, Constants.Gacha.creditGrams)

        let offlineRows = [
            snapshot(
                id: UUID(uuidString: "60000000-0000-0000-0000-000000000001")!,
                endAt: Date(timeIntervalSince1970: 7_000),
                ruleVersion: Constants.Gacha.creditRuleVersion,
                participated: true,
                creditedGrams: 50,
                outcomes: [.normal]
            ),
            snapshot(
                id: UUID(uuidString: "60000000-0000-0000-0000-000000000002")!,
                endAt: Date(timeIntervalSince1970: 7_001),
                ruleVersion: Constants.Gacha.creditRuleVersion,
                participated: true,
                creditedGrams: 50,
                outcomes: [.normal]
            )
        ]
        let observedNewMass = GachaHistoryReconciliationPolicy
            .observedRewardCreditGrams(sessions: offlineRows)
        let scalarMerge = max(
            max(localA.totalGrams, localB.totalGrams),
            observedNewMass
        )
        let serialized = RareRewardCreditPolicy.allocation(
            previousTotalGrams: sharedBaseline,
            completedGrams: 100,
            source: .timer
        )

        XCTAssertEqual(observedNewMass, 100)
        XCTAssertEqual(scalarMerge, 250)
        XCTAssertEqual(serialized.totalGrams, 300)
        XCTAssertEqual(scalarMerge % Constants.Gacha.creditGrams, 0)
        XCTAssertEqual(serialized.remainderGrams, 50)
        XCTAssertNotEqual(scalarMerge, serialized.totalGrams)
    }
}

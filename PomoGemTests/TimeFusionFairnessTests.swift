import XCTest
import SwiftData
import SpriteKit
@testable import PomoGem

/// The shape of the jar is a representation of saved time. It must not
/// reward a person for dividing the same focus into more completions.
final class TimeFusionFairnessTests: XCTestCase {
    func testEqualTimePartitionsHaveIdenticalCrystalsAndRemainder() {
        let routes: [[Int]] = [
            Array(repeating: 10, count: 25),
            Array(repeating: 25, count: 10),
            Array(repeating: 50, count: 5),
            [250]
        ]
        for route in routes {
            let snapshot = projection(minutes: route)
            XCTAssertEqual(snapshot.totalGrams, 2_500)
            XCTAssertEqual(snapshot.remainderGrams, 0)
            XCTAssertEqual(snapshot.crystals.map(\.grams), [2_500])
            XCTAssertEqual(snapshot, projection(minutes: [250]), "Route: \(route)")
        }
    }

    func testCrossingWithWholeSessionsDoesNotSwallowTheNextCrystalsTime() {
        // A greedy whole-session threshold would turn five 100-minute
        // sessions into one 300-minute crystal and a 200-minute remainder,
        // while fifty 10-minute sessions would earn two crystals.
        let routes: [[Int]] = [Array(repeating: 10, count: 50), Array(repeating: 100, count: 5), [250, 250]]
        for route in routes {
            let snapshot = projection(minutes: route)
            XCTAssertEqual(snapshot.crystals.map(\.grams), [2_500, 2_500])
            XCTAssertEqual(snapshot.remainderGrams, 0)
            XCTAssertEqual(snapshot.representedGrams, 5_000)
        }
    }

    func testExcessTimeIsCarriedExactlyForEveryPartition() {
        let routes: [[Int]] = [Array(repeating: 10, count: 60), Array(repeating: 120, count: 5), [360, 240]]
        let expected = projection(minutes: [360, 240])
        for route in routes {
            let snapshot = projection(minutes: route)
            XCTAssertEqual(snapshot, expected)
            XCTAssertEqual(snapshot.crystals.map(\.grams), [2_500, 2_500])
            XCTAssertEqual(snapshot.remainderGrams, 1_000)
            XCTAssertEqual(snapshot.nextCrystalRemainingGrams, 1_500)
            XCTAssertEqual(snapshot.representedGrams, 6_000)
        }
    }

    func testOneLongCompletionCanCreateTheFirstCrystal() throws {
        let snapshot = projection(minutes: [360])
        XCTAssertEqual(snapshot.crystals.count, 1)
        XCTAssertEqual(snapshot.remainderGrams, 1_100)
        let transition = try XCTUnwrap(TimeFusionPolicy.transition(from: 0, to: 3_600))
        XCTAssertEqual(transition.beforeGrams, 0)
        XCTAssertEqual(transition.afterGrams, 3_600)
        XCTAssertEqual(transition.destinationLevel, 1)
    }

    func testThresholdEdgesUseTimeRatherThanCompletionCount() {
        for grams in [0, 10, 100, 1_000, 2_490, 2_499] {
            let snapshot = TimeFusionPolicy.snapshot(totalGrams: grams)
            XCTAssertTrue(snapshot.crystals.isEmpty)
            XCTAssertEqual(snapshot.remainderGrams, grams)
            XCTAssertEqual(snapshot.nextCrystalRemainingGrams, 2_500 - grams)
        }
        XCTAssertNil(TimeFusionPolicy.transition(from: 900, to: 1_000), "The tenth 10-minute completion is only 100 minutes")
        XCTAssertNotNil(TimeFusionPolicy.transition(from: 2_499, to: 2_500))
        XCTAssertNil(TimeFusionPolicy.transition(from: 2_500, to: 2_501))
    }

    func testTenTimeCrystalsCarryIntoOneLargerTimeCrystal() throws {
        let before = TimeFusionPolicy.snapshot(totalGrams: 24_999)
        XCTAssertEqual(before.crystals.count, 9)
        XCTAssertEqual(before.remainderGrams, 2_499)
        let after = TimeFusionPolicy.snapshot(totalGrams: 25_000)
        XCTAssertEqual(after.crystals.count, 1)
        XCTAssertEqual(after.crystals.first?.grams, 25_000)
        XCTAssertEqual(after.crystals.first?.level, 2)
        XCTAssertEqual(after.remainderGrams, 0)
        XCTAssertEqual(try XCTUnwrap(TimeFusionPolicy.transition(from: 24_999, to: 25_000)).destinationLevel, 2)
        XCTAssertEqual(try XCTUnwrap(TimeFusionPolicy.transition(from: 0, to: 25_000)).newCrystalCount, 10)
    }

    func testOrderAndReconstructionDoNotAlterCrystalsOrIdentities() {
        let route = [10, 360, 25, 120, 1, 249, 50, 90, 5]
        let expected = projection(minutes: route)
        for offset in route.indices {
            let rotated = Array(route[offset...] + route[..<offset])
            XCTAssertEqual(projection(minutes: rotated), expected)
            XCTAssertEqual(projection(minutes: rotated.reversed()), expected)
        }
        XCTAssertEqual(TimeFusionPolicy.snapshot(totalGrams: expected.totalGrams), expected)
        XCTAssertEqual(Set(expected.crystals.map(\.id)).count, expected.crystals.count)
    }

    func testMoreTimeWithinTheRemainderKeepsExistingCrystalIdentities() {
        let before = TimeFusionPolicy.snapshot(totalGrams: 5_000)
        let after = TimeFusionPolicy.snapshot(totalGrams: 6_000)
        XCTAssertEqual(before.crystals, after.crystals)
        XCTAssertEqual(after.remainderGrams, 1_000)
    }

    func testUnchangedOrReducedTotalsNeverReplayACelebration() {
        for pair in [(0, 0), (2_500, 2_500), (25_000, 2_500), (25_000, 0), (0, -1)] {
            XCTAssertNil(TimeFusionPolicy.transition(from: pair.0, to: pair.1))
        }
    }

    func testProgressDisclosesUnknownTotalsInsteadOfEstimatingACompletionCount() {
        XCTAssertEqual(TimeFusionPresentation.progress(totalGrams: nil, isLowerBound: false), "結晶の時間を確認中")
        XCTAssertEqual(TimeFusionPresentation.progress(totalGrams: 2_490, isLowerBound: true), "結晶の時間を確認中")
        XCTAssertEqual(TimeFusionPresentation.progress(totalGrams: 2_490, isLowerBound: false), "次の結晶まで あと1分")
        XCTAssertEqual(TimeFusionPresentation.progress(totalGrams: 1_000, isLowerBound: false), "次の結晶まで あと2時間30分")
    }

    func testNegativeAndMaximumValuesAreBoundedAndConserveExactGrams() {
        let empty = TimeFusionPolicy.snapshot(totalGrams: -1)
        XCTAssertEqual(empty.totalGrams, 0)
        XCTAssertEqual(empty.representedGrams, 0)
        XCTAssertEqual(empty.remainderGrams, 0)
        XCTAssertTrue(empty.crystals.isEmpty)
        for grams in [1, 2_500, 99_999, 87_660_000, Int.max - 1, Int.max] {
            let snapshot = TimeFusionPolicy.snapshot(totalGrams: grams)
            XCTAssertEqual(snapshot.totalGrams, grams)
            XCTAssertEqual(snapshot.representedGrams, grams)
            XCTAssertTrue((0..<2_500).contains(snapshot.remainderGrams))
            XCTAssertTrue((1...2_500).contains(snapshot.nextCrystalRemainingGrams))
            XCTAssertLessThanOrEqual(snapshot.crystals.count, 9 * String(Int.max).count)
            XCTAssertEqual(snapshot.crystals.reduce(snapshot.remainderGrams) { $0 + $1.grams }, grams)
            XCTAssertEqual(Set(snapshot.crystals.map(\.id)).count, snapshot.crystals.count)
            XCTAssertLessThanOrEqual(snapshot.visibleCrystals.count, TimeFusionPolicy.maximumVisibleCrystals)
            XCTAssertEqual(snapshot.visibleCrystals.reduce(snapshot.remainderGrams) { $0 + $1.grams }, grams)
        }
    }

    private func projection<S: Sequence>(minutes: S) -> TimeFusionSnapshot where S.Element == Int {
        TimeFusionPolicy.snapshot(totalGrams: minutes.reduce(0, +) * Constants.Mass.gramsPerMinute)
    }
}

@MainActor
final class TimeFusionPersistenceFairnessTests: XCTestCase {
    func testCanonicalSceneBodiesNeverRequestPersistentCountFusion() {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = true
        var persistentRequests = 0
        var celebrations = 0
        scene.onAggregateRequested = { _ in persistentRequests += 1 }
        scene.onTimeFusionFormed = { _ in celebrations += 1 }
        for grams in [1_000, 5_000, 24_999, 25_000, 6_000] {
            scene.configureTimeFusion(totalGrams: grams, colorMix: [])
            scene.update(0)
            let expected = TimeFusionPolicy.snapshot(totalGrams: grams)
            XCTAssertEqual(scene.timeFusionSnapshot, expected)
            XCTAssertEqual(scene.physicalAggregateCount, expected.visibleCrystals.count)
            var descriptors: [PebbleDescriptor] = []
            scene.enumerateChildNodes(withName: "//pebble.*") { node, _ in
                if let pebble = node as? PebbleNode { descriptors.append(pebble.descriptor) }
            }
            XCTAssertEqual(descriptors.reduce(0) { $0 + $1.grams }, grams)
            XCTAssertTrue(descriptors.allSatisfy(\.isTimeProjection))
            XCTAssertTrue(descriptors.allSatisfy { !$0.participatesInAggregation })
            XCTAssertTrue(descriptors.allSatisfy { $0.aggregate?.sessionIDs.isEmpty ?? true })
        }
        scene.setScreenTimeObstacles(totalUnits: 100)
        XCTAssertEqual(scene.timeFusionSnapshot?.totalGrams, 6_000)
        XCTAssertEqual(persistentRequests, 0)
        XCTAssertEqual(celebrations, 0, "Restoring a total never replays a completion celebration")
        let displayCrystals = TimeFusionPolicy.snapshot(totalGrams: 24_999).crystals.map {
            PebbleDescriptor.timeProjection(unit: $0, colorMix: [])
        }
        let extra = PebbleDescriptor.timeProjection(unit: TimeFusionUnit(level: 1, grams: 2_500, ordinal: 9),
                                                    colorMix: [])
        XCTAssertNil(JarAggregateRequest(pebbles: displayCrystals + [extra], innerWidth: 320),
                     "A time display has no ownership of raw records and cannot be persisted as one")
    }

    func testBackgroundIndexAndCheckpointReplayPreserveTwoHundredFiftyRecordsOfOneMinute() async throws {
        let schema = Schema([
            Subject.self, StudySession.self, AchievementStone.self, AggregatePebble.self,
            Stratum.self, Bedrock.self, GachaState.self, Prefs.self, ActivityResetMarker.self,
            SyncedFocusTimer.self, FocusTimerDeviceClaim.self, RareRewardPendingCommit.self,
            RareRewardLedgerCursor.self
        ])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(
            schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none
        )])
        let context = container.mainContext
        let originalSessions = (0..<250).map { session(index: $0, minutes: 1) }
        originalSessions.forEach(context.insert)
        try context.save()
        let expected = TimeFusionPolicy.snapshot(totalGrams: 2_500)
        var cursor: SyncMaintenanceCursor?
        var completed = false
        var replayed = false
        for _ in 0..<180 where !completed {
            let request = SyncMaintenanceSliceRequest(kind: .aggregates, generation: 19,
                                                       cursor: cursor, limits: .production)
            let result = try await SyncMaintenanceSliceWorker(modelContainer: container).run(request)
            XCTAssertNotEqual(result.disposition, .retry)
            if !replayed, result.nextCursor?.phase == 2, result.audit.saveCount == 1 {
                // A process may end after the index save but before its
                // checkpoint. Replaying must not award another visual unit.
                let replay = try await SyncMaintenanceSliceWorker(modelContainer: container).run(request)
                XCTAssertNotEqual(replay.disposition, .retry)
                cursor = replay.nextCursor
                replayed = true
            } else {
                cursor = result.nextCursor
            }
            completed = result.disposition == .completed
        }
        XCTAssertTrue(completed)
        XCTAssertTrue(replayed)

        let relaunchedContext = ModelContext(container)
        let sessions = try relaunchedContext.fetch(FetchDescriptor<StudySession>())
        let aggregates = try relaunchedContext.fetch(FetchDescriptor<AggregatePebble>())
        let frontier = AggregatePebblePolicy.accountingFrontier(from: aggregates)
        XCTAssertFalse(frontier.isLowerBound)
        XCTAssertFalse(frontier.containsUnknownMembership)
        let loose = sessions.filter { !frontier.representedSessionIDs.contains($0.id) }
        XCTAssertEqual(loose.count, HomeProjectionPolicy.looseSessionLimit)
        XCTAssertEqual(sessions.count, 250)
        XCTAssertTrue(sessions.allSatisfy { $0.seconds == 60 && $0.grams == 10 })
        XCTAssertEqual(aggregates.flatMap(\.sessionIDs).count, frontier.representedSessionIDs.count)
        let restored = HomeProjectionPolicy.totals(roots: frontier.summaries, looseSessions: loose)
        XCTAssertEqual(restored.pebbleCount, 250)
        XCTAssertEqual(restored.grams, 2_500)
        XCTAssertEqual(TimeFusionPolicy.snapshot(totalGrams: restored.grams), expected)
        XCTAssertNil(TimeFusionPolicy.transition(from: expected.totalGrams, to: restored.grams))
    }

    func testPendingReceiptTimeJoinsTheJarOnlyAtLanding() {
        let landed = session(index: 1, minutes: 100)
        let pending = session(index: 2, minutes: 150)
        let before = HomeProjectionPolicy.landedTotals(roots: [], looseSessions: [landed, pending],
                                                       unlandedSessionIDs: [pending.id])
        let after = HomeProjectionPolicy.landedTotals(roots: [], looseSessions: [landed, pending],
                                                      unlandedSessionIDs: [])
        XCTAssertTrue(TimeFusionPolicy.snapshot(totalGrams: before.grams).crystals.isEmpty)
        XCTAssertEqual(TimeFusionPolicy.snapshot(totalGrams: after.grams).crystals.count, 1)
        XCTAssertNotNil(TimeFusionPolicy.transition(from: before.grams, to: after.grams))
        XCTAssertEqual(HomeProjectionPolicy.totals(roots: [], looseSessions: [landed, pending]).grams, 2_500,
                       "Saving a receipt already records the full time; landing changes presentation only")
        XCTAssertEqual(pending.seconds, 9_000)
    }

    func testAReceiptAlreadyInTheBackgroundIndexStillWaitsForItsOneLanding() {
        let members = (0..<10).map { session(index: $0, minutes: 25) }
        let pending = members[9]
        let loose = session(index: 20, minutes: 10)
        let index = AggregatePebble(
            level: 1, pebbleCount: 10, grams: 2_500, measuredPebbleCount: 10,
            colorMixJSON: "[]", periodStart: members[0].startAt,
            periodEnd: pending.endAt, sessionIDs: members.map(\.id)
        )
        let before = HomeProjectionPolicy.landedTotals(
            roots: [index], looseSessions: [loose], unlandedSessionIDs: [pending.id],
            representedPendingSessions: [pending, pending]
        )
        XCTAssertEqual(before.grams, 2_350)
        XCTAssertEqual(before.pebbleCount, 10)
        XCTAssertTrue(TimeFusionPolicy.snapshot(totalGrams: before.grams).crystals.isEmpty)
        let contributions = HomeProjectionPolicy.timeFusionPendingContributions(
            looseSessions: [loose], representedPendingSessions: [pending, pending],
            unlandedSessionIDs: [pending.id]
        )
        XCTAssertEqual(contributions, [pending.id: 250])
        let after = HomeProjectionPolicy.landedTotals(
            roots: [index], looseSessions: [loose], unlandedSessionIDs: [],
            representedPendingSessions: [pending]
        )
        XCTAssertEqual(after.grams, 2_600)
        XCTAssertEqual(after.pebbleCount, 11)
        XCTAssertEqual(TimeFusionPolicy.snapshot(totalGrams: after.grams).remainderGrams, 100)
        XCTAssertEqual(TimeFusionPolicy.transition(from: before.grams, to: after.grams)?.newCrystalCount, 1)
        XCTAssertEqual(index.grams, 2_500)
        XCTAssertEqual(index.sessionIDs.count, 10)
    }

    private func session(index: Int, minutes: Int) -> StudySession {
        let end = Date(timeIntervalSince1970: 1_790_000_000 + Double(index * 60))
        return StudySession(
            id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012X", index + 1))!,
            startAt: end.addingTimeInterval(-Double(minutes * 60)), endAt: end,
            seconds: minutes * 60, source: .timer, deviceDayKey: "2026-09-01",
            subjectNameSnapshot: "集中", subjectColorHexSnapshot: Constants.Color.english
        )
    }
}

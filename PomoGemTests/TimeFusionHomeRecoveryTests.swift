import SwiftData
import XCTest
@testable import PomoGem

@MainActor
final class TimeFusionHomeRecoveryTests: XCTestCase {
    func testLegacySummaryUnderVerifiedNonrootDoesNotKeepTotalsProvisional() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let legacy = stratum()
        let parentID = UUID()
        let child = aggregate(id: legacy.id, parent: parentID)
        let parent = aggregate(id: parentID, level: 2, children: [child.id])
        context.insert(legacy)
        context.insert(child)
        context.insert(parent)
        try context.save()
        let trusted = try HomeProjectionPolicy.acceptedRootSummaryIDs(
            roots: [parent], context: context, resetMarkers: []
        )
        XCTAssertEqual(trusted, [parent.id])
        XCTAssertTrue(try HomeProjectionPolicy.unresolvedLegacyCompatibilityIDs(
            legacyStrata: [legacy], acceptedRootIDs: trusted,
            context: context, resetMarkers: []
        ).isEmpty)
        XCTAssertEqual(HomeProjectionPolicy.totals(roots: [parent], looseSessions: []).grams, 250,
                       "The old summary is represented exactly once by the accepted root")
        XCTAssertFalse(context.hasChanges)
    }

    func testUnprovedLegacyTimeStaysProvisionalWithoutBecomingAdditionalMass() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let missing = stratum()
        let dangling = stratum()
        let unverified = stratum()
        let unrelatedRoot = aggregate()
        let danglingIndex = aggregate(id: dangling.id, parent: UUID())
        let unverifiedIndex = aggregate(id: unverified.id)
        unverifiedIndex.projectionValidationVersion = 0
        [missing, dangling, unverified].forEach(context.insert)
        [unrelatedRoot, danglingIndex, unverifiedIndex].forEach(context.insert)
        try context.save()
        let unresolved = try HomeProjectionPolicy.unresolvedLegacyCompatibilityIDs(
            legacyStrata: [missing, dangling, unverified],
            acceptedRootIDs: [unrelatedRoot.id, unverifiedIndex.id],
            context: context, resetMarkers: []
        )
        XCTAssertEqual(unresolved, [missing.id, dangling.id, unverified.id])
        XCTAssertEqual(HomeProjectionPolicy.totals(roots: [unrelatedRoot], looseSessions: []).grams, 250)
        XCTAssertFalse(context.hasChanges)
    }

    func testMarkerOnlyCompletionRecoversOutsideHomePageEvenAfterAggregation() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let old = session(end: Date(timeIntervalSince1970: 1_790_000_000))
        let root = aggregate(sessionIDs: [old.id])
        context.insert(old)
        context.insert(root)
        for index in 1...HomeProjectionPolicy.looseSessionQueryLimit {
            context.insert(session(end: old.endAt.addingTimeInterval(Double(index))))
        }
        try context.save()
        let page = try HomeProjectionPolicy.supportedLooseSessionPage(context: context, resetMarkers: [])
        XCTAssertFalse(page.sessions.contains { $0.id == old.id })
        let recovered = try HomeProjectionPolicy.pendingRewardSessionCandidates(
            for: [], context: context, resetMarkers: [],
            completionMarker: old.id.uuidString.lowercased()
        )
        XCTAssertEqual(recovered.map(\.id), [old.id])
        let membership = try HomeProjectionPolicy.localMembershipProjection(
            for: recovered, representedAggregateRoots: [root], context: context, resetMarkers: []
        )
        XCTAssertEqual(membership.representedSessionIDs, [old.id])
        let landed = HomeProjectionPolicy.landedTotals(
            roots: [root], looseSessions: [], unlandedSessionIDs: [old.id],
            representedPendingSessions: recovered
        )
        XCTAssertEqual(landed.grams, 0, "An index-owned completion still waits for its visible landing")
        XCTAssertTrue(try HomeProjectionPolicy.pendingRewardSessionCandidates(
            for: [], context: context, resetMarkers: [], completionMarker: "malformed-marker"
        ).isEmpty)
        XCTAssertFalse(context.hasChanges)
    }

    func testCompletionMarkerAddsAtMostOneExactLookupAndDeduplicatesReceipts() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_790_100_000)
        let values = (0..<5).map { session(end: start.addingTimeInterval(Double($0))) }
        values.forEach(context.insert)
        try context.save()
        let receipts = values.prefix(4).map { value in
            PendingRewardReceipt(
                id: value.id, createdAt: value.endAt, breakMinutes: 5,
                grams: value.grams, subjectName: "Recovery test", colorHex: "#336699",
                weeklyCompletionCount: 1, kind: .normal, totalPebbleCount: 1,
                projectionIsLowerBound: true, dropPhase: .awaitingAcknowledgement
            )
        }
        let extra = try HomeProjectionPolicy.pendingRewardSessionCandidates(
            for: receipts, context: context, resetMarkers: [], completionMarker: values[4].id.uuidString
        )
        XCTAssertEqual(Set(extra.map(\.id)), Set(values.map(\.id)))
        let duplicate = try HomeProjectionPolicy.pendingRewardSessionCandidates(
            for: receipts, context: context, resetMarkers: [], completionMarker: values[0].id.uuidString
        )
        XCTAssertEqual(duplicate.count, 4)
    }

    func testPendingOrHeldHeadlineCannotAuthorizeAnotherVisualCredit() {
        let pending = [UUID(): 100]
        XCTAssertEqual(HomeProjectionPolicy.timeFusionLandingContributions(
            pending: pending, displayedGrams: 2_400, landedGrams: 2_400, allowsLiveCredit: true
        ), pending)
        let displayedTotals: [Int?] = [nil, 2_400, 2_500]
        for displayed in displayedTotals {
            XCTAssertTrue(HomeProjectionPolicy.timeFusionLandingContributions(
                pending: pending, displayedGrams: displayed, landedGrams: 2_400, allowsLiveCredit: false
            ).isEmpty, "A pending cloud total may already include the receipt even when numeric totals coincide")
        }
        XCTAssertTrue(HomeProjectionPolicy.timeFusionLandingContributions(
            pending: pending, displayedGrams: 2_500, landedGrams: 2_400, allowsLiveCredit: true
        ).isEmpty, "A held headline is not the proven pre-landing baseline")
    }

    private func session(end: Date) -> StudySession {
        StudySession(startAt: end.addingTimeInterval(-1_500), endAt: end,
                     seconds: 1_500, source: .timer, grams: 250, deviceDayKey: "recovery")
    }

    private func stratum() -> Stratum {
        Stratum(pebbleCount: 1, heightPt: 8, colorMixJSON: "[]", monthLabel: "legacy", grams: 250)
    }

    private func aggregate(id: UUID = UUID(), level: Int = 1, parent: UUID? = nil,
                           children: [UUID] = [], sessionIDs: [UUID] = []) -> AggregatePebble {
        AggregatePebble(id: id, level: level, pebbleCount: 1, childAggregateCount: children.count,
                        grams: 250, measuredPebbleCount: 1, colorMixJSON: "[]",
                        periodStart: .distantPast, periodEnd: .distantPast,
                        sessionIDs: sessionIDs, childAggregateIDs: children, parentAggregateID: parent)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Subject.self, StudySession.self, AchievementStone.self, AggregatePebble.self,
            Stratum.self, Bedrock.self, GachaState.self, Prefs.self, ActivityResetMarker.self,
            SyncedFocusTimer.self, FocusTimerDeviceClaim.self
        ])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(
            schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none
        )])
    }
}

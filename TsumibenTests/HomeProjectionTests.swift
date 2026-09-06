import SwiftData
import XCTest
@testable import Tsumiben

@MainActor
final class HomeProjectionTests: XCTestCase {
    func testPendingRewardCandidatesFindCanonicalRecordOutsideNormalHomePage() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let oldEnd = Date(timeIntervalSince1970: 1_800_000_000)
        let old = pendingRewardSession(endAt: oldEnd)
        let canonical = pendingRewardSession(id: old.id, endAt: oldEnd, source: .timerDemoted)
        context.insert(old)
        context.insert(canonical)
        for index in 1...HomeProjectionPolicy.looseSessionQueryLimit {
            context.insert(pendingRewardSession(endAt: oldEnd.addingTimeInterval(Double(index))))
        }
        try context.save()
        let page = try HomeProjectionPolicy.supportedLooseSessionPage(
            context: context, resetMarkers: []
        )
        XCTAssertEqual(page.sessions.count, HomeProjectionPolicy.looseSessionQueryLimit)
        XCTAssertFalse(page.sessions.contains { $0.id == old.id })

        let recovered = try HomeProjectionPolicy.pendingRewardSessionCandidates(
            for: [pendingRewardReceipt(for: old)],
            context: context,
            resetMarkers: []
        )
        XCTAssertEqual(recovered.map(\.id), [old.id])
        XCTAssertEqual(recovered.first?.syncRecordID, canonical.syncRecordID)
        XCTAssertEqual(recovered.first?.source, .timerDemoted)
        let combined = StudySessionSyncPolicy.canonicalSessions(from: page.sessions + recovered + [old])
        XCTAssertEqual(combined.filter { $0.id == old.id }.count, 1)
        XCTAssertEqual(combined.first { $0.id == old.id }?.syncRecordID, canonical.syncRecordID)
        XCTAssertFalse(context.hasChanges, "Recovering presentation candidates must not save or award effort")
    }

    func testPendingRewardCandidatesIgnoreLegacyDeduplicateAndKeepFourLookupBound() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_800_100_000)
        let candidates = (0...PendingRewardReceiptStore.maximumPendingCount).map {
            pendingRewardSession(endAt: start.addingTimeInterval(Double($0)))
        }
        let legacy = pendingRewardSession(endAt: start.addingTimeInterval(-1))
        (candidates + [legacy]).forEach { context.insert($0) }
        try context.save()
        let receipts = [pendingRewardReceipt(for: legacy, phase: nil)]
            + candidates.reversed().map { pendingRewardReceipt(for: $0) }
            + [pendingRewardReceipt(for: candidates[0], phase: .awaitingLanding)]

        let recovered = try HomeProjectionPolicy.pendingRewardSessionCandidates(
            for: receipts, context: context, resetMarkers: []
        )
        XCTAssertEqual(recovered.map(\.id), Array(candidates.prefix(4)).map(\.id))
        XCTAssertEqual(Set(recovered.map(\.id)).count, 4)
        XCTAssertFalse(recovered.contains { $0.id == legacy.id })
        XCTAssertFalse(context.hasChanges)
    }

    func testPendingRewardCandidatesRespectResetEpochAndRejectUnsupportedRows() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let end = Date(timeIntervalSince1970: 1_800_200_000)
        let currentEpoch = UUID()
        let marker = ActivityResetSnapshot(
            id: UUID(), epochID: currentEpoch, sequence: 1,
            resetAt: end.addingTimeInterval(-2_000), writerDeviceID: "reward-test"
        )
        let current = pendingRewardSession(endAt: end, epochID: currentEpoch)
        let stale = pendingRewardSession(endAt: end.addingTimeInterval(1))
        let awaitingMarker = pendingRewardSession(endAt: end.addingTimeInterval(2), epochID: UUID())
        let unsupported = pendingRewardSession(endAt: end.addingTimeInterval(3), epochID: currentEpoch)
        unsupported.seconds = -1
        let candidates = [current, stale, awaitingMarker, unsupported]
        candidates.forEach { context.insert($0) }
        try context.save()

        let recovered = try HomeProjectionPolicy.pendingRewardSessionCandidates(
            for: candidates.map { pendingRewardReceipt(for: $0) },
            context: context,
            resetMarkers: [marker]
        )
        XCTAssertEqual(recovered.map(\.id), [current.id])
        let missing = pendingRewardSession(endAt: end.addingTimeInterval(4), epochID: currentEpoch)
        XCTAssertTrue(try HomeProjectionPolicy.pendingRewardSessionCandidates(
            for: [pendingRewardReceipt(for: missing)], context: context, resetMarkers: [marker]
        ).isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StudySession>()), candidates.count)
        XCTAssertFalse(context.hasChanges, "Missing and quarantined source rows must remain untouched")
    }

    func testPendingRewardCandidatesFailClosedAtOversizedExactReplicaGroup() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let end = Date(timeIntervalSince1970: 1_800_300_000)
        let id = UUID()
        let copies = (0...BoundedHistoryPolicy.maximumPhysicalRowsPerLogicalSession).map { _ in
            pendingRewardSession(id: id, endAt: end)
        }
        copies.forEach { context.insert($0) }
        try context.save()

        XCTAssertThrowsError(try HomeProjectionPolicy.pendingRewardSessionCandidates(
            for: [pendingRewardReceipt(for: copies[0])], context: context, resetMarkers: []
        )) { error in
            XCTAssertEqual(error as? BoundedHistoryPolicy.SessionResolutionError, .logicalReplicaLimitExceeded)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StudySession>()), copies.count)
        XCTAssertFalse(context.hasChanges)
    }

    func testPendingRewardCandidatesRequireAcceptedAggregateRootForMembership() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let fixture = try makeLeafAggregateFixture()
        fixture.sessions.forEach { context.insert($0) }
        let root = fixture.request.makeAggregatePebble()
        context.insert(root)
        try context.save()
        let session = try XCTUnwrap(fixture.sessions.first)
        let recovered = try HomeProjectionPolicy.pendingRewardSessionCandidates(
            for: [pendingRewardReceipt(for: session)], context: context, resetMarkers: []
        )

        let unverified = try HomeProjectionPolicy.localMembershipProjection(
            for: recovered, representedAggregateRoots: [], context: context, resetMarkers: []
        )
        XCTAssertTrue(unverified.representedSessionIDs.isEmpty,
                      "Finding a pending source must not promote an unverified aggregate")
        let verified = try HomeProjectionPolicy.localMembershipProjection(
            for: recovered, representedAggregateRoots: [root], context: context, resetMarkers: []
        )
        XCTAssertEqual(verified.representedSessionIDs, [session.id])
        XCTAssertTrue(verified.isCompleteForCandidates)
        XCTAssertFalse(context.hasChanges)
    }

    private func pendingRewardSession(
        id: UUID = UUID(),
        endAt: Date,
        source: SessionSource = .timer,
        epochID: UUID? = nil
    ) -> StudySession {
        StudySession(
            id: id, startAt: endAt.addingTimeInterval(-1_500), endAt: endAt,
            seconds: 1_500, source: source, grams: 250,
            deviceDayKey: "pending-reward", dataEpochID: epochID
        )
    }

    private func pendingRewardReceipt(
        for session: StudySession,
        phase: PendingRewardDropPhase? = .awaitingAcknowledgement
    ) -> PendingRewardReceipt {
        PendingRewardReceipt(
            id: session.id, createdAt: session.endAt, breakMinutes: 5,
            grams: session.grams, subjectName: "資格", colorHex: "#3FA57C",
            weeklyCompletionCount: 1, kind: .normal, totalPebbleCount: 1,
            projectionIsLowerBound: true, dropPhase: phase
        )
    }

    func testHistoryDestinationDescriptorsAreEpochFilteredAndHardBounded() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let currentEpoch = UUID()
        let staleEpoch = UUID()
        let base = Date(timeIntervalSince1970: 5_000)

        for index in 0..<24 {
            context.insert(StudySession(
                startAt: base.addingTimeInterval(Double(index)),
                endAt: base.addingTimeInterval(Double(index + 1)),
                seconds: 1_500,
                source: .timer,
                grams: 250,
                deviceDayKey: "current",
                dataEpochID: currentEpoch
            ))
            context.insert(StudySession(
                startAt: base.addingTimeInterval(Double(index)),
                endAt: base.addingTimeInterval(Double(index + 1)),
                seconds: 1_500,
                source: .timer,
                grams: 250,
                deviceDayKey: "stale",
                dataEpochID: staleEpoch
            ))
        }
        try context.save()

        let descriptor = BoundedHistoryPolicy.sessionDescriptor(
            epochID: currentEpoch,
            order: .reverse,
            limit: 11
        )
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(descriptor.fetchLimit, 11)
        XCTAssertEqual(fetched.count, 11)
        XCTAssertTrue(fetched.allSatisfy { $0.dataEpochID == currentEpoch })

        XCTAssertEqual(
            BoundedHistoryPolicy.latestResetMarkerDescriptor().fetchLimit,
            1
        )
        XCTAssertEqual(
            BoundedHistoryPolicy.rootAggregateDescriptor(
                epochID: currentEpoch,
                limit: BoundedHistoryPolicy.aggregateRootLimit + 1
            ).fetchLimit,
            BoundedHistoryPolicy.aggregateRootLimit + 1
        )
    }

    func testResolvedHistoryPageIsNotStarvedBySixtyOnePhysicalDuplicates() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let epochID = UUID()
        let duplicateID = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        for index in 0..<61 {
            context.insert(StudySession(
                id: duplicateID,
                startAt: base.addingTimeInterval(-1_500),
                endAt: base,
                seconds: 1_500,
                source: index == 60 ? .timerDemoted : .timer,
                grams: 250,
                deviceDayKey: "duplicate-starvation",
                dataEpochID: epochID
            ))
        }
        for index in 1...5 {
            let endAt = base.addingTimeInterval(TimeInterval(-index))
            context.insert(StudySession(
                startAt: endAt.addingTimeInterval(-1_500),
                endAt: endAt,
                seconds: 1_500,
                source: .timer,
                grams: 250,
                deviceDayKey: "duplicate-starvation",
                dataEpochID: epochID
            ))
        }
        try context.save()

        let page = try BoundedHistoryPolicy.resolvedSessionPage(
            context: context,
            epochID: epochID,
            order: .reverse,
            logicalLimit: 5
        )

        XCTAssertEqual(page.sessions.count, 5)
        XCTAssertEqual(Set(page.sessions.map(\.id)).count, 5)
        XCTAssertEqual(page.sessions.first?.id, duplicateID)
        XCTAssertEqual(page.sessions.first?.source, .timerDemoted)
        XCTAssertEqual(page.sessions.last?.endAt, base.addingTimeInterval(-4))
        XCTAssertTrue(page.isPartial)
        XCTAssertEqual(page.scannedPhysicalRowCount, 66)
    }

    func testBatchedHistoryResolutionFindsCanonicalCopyOutsideCandidatePrefix() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let epochID = UUID()
        let duplicatedID = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        for index in 0..<40 {
            let endAt = base.addingTimeInterval(TimeInterval(-index))
            context.insert(StudySession(
                id: index == 0 ? duplicatedID : UUID(),
                startAt: endAt.addingTimeInterval(-1_500),
                endAt: endAt,
                seconds: 1_500,
                source: .timer,
                grams: 250,
                deviceDayKey: "batched-hidden-copy",
                dataEpochID: epochID
            ))
        }
        let hiddenWinnerEnd = base.addingTimeInterval(-100)
        context.insert(StudySession(
            id: duplicatedID,
            startAt: hiddenWinnerEnd.addingTimeInterval(-1_500),
            endAt: hiddenWinnerEnd,
            seconds: 1_500,
            source: .timerDemoted,
            grams: 250,
            deviceDayKey: "batched-hidden-copy",
            dataEpochID: epochID
        ))
        try context.save()

        let page = try BoundedHistoryPolicy.resolvedSessionPage(
            context: context,
            epochID: epochID,
            order: .reverse,
            logicalLimit: 40,
            maximumCandidateRows: 40,
            mode: .lowerBound
        )

        XCTAssertEqual(page.sessions.count, 40)
        XCTAssertEqual(
            page.sessions.first(where: { $0.id == duplicatedID })?.source,
            .timerDemoted
        )
        XCTAssertEqual(
            page.sessions.first(where: { $0.id == duplicatedID })?.endAt,
            hiddenWinnerEnd
        )
        XCTAssertTrue(page.isPartial)
        XCTAssertFalse(page.boundaryIsProven)
    }

    func testBatchedLowerBoundOmitsOnlyOversizedLogicalGroup() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let epochID = UUID()
        let oversizedID = UUID()
        let retainedID = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        context.insert(StudySession(
            id: retainedID,
            startAt: base.addingTimeInterval(-1_500),
            endAt: base,
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: "batched-oversized",
            dataEpochID: epochID
        ))
        let maximumCopies = BoundedHistoryPolicy
            .maximumPhysicalRowsPerLogicalSession
        for offset in 0...maximumCopies {
            let endAt = base.addingTimeInterval(TimeInterval(-offset - 1))
            context.insert(StudySession(
                id: oversizedID,
                startAt: endAt.addingTimeInterval(-1_500),
                endAt: endAt,
                seconds: 1_500,
                source: .timer,
                grams: 250,
                deviceDayKey: "batched-oversized",
                dataEpochID: epochID
            ))
        }
        try context.save()

        let page = try BoundedHistoryPolicy.resolvedSessionPage(
            context: context,
            epochID: epochID,
            order: .reverse,
            logicalLimit: 2,
            maximumCandidateRows: 258,
            mode: .lowerBound
        )

        XCTAssertEqual(page.sessions.map(\.id), [retainedID])
        XCTAssertTrue(page.isPartial)
        XCTAssertFalse(page.boundaryIsProven)
    }

    func testResolvedHistoryPageFailsClosedWhenRawEdgeHasNotPassedWinner() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let epochID = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        for groupOffset in 0..<3 {
            let logicalID = UUID()
            for index in 0..<99 {
                let endAt = base.addingTimeInterval(
                    TimeInterval(-(groupOffset * 100 + index))
                )
                context.insert(StudySession(
                    id: logicalID,
                    startAt: endAt.addingTimeInterval(-1_500),
                    endAt: endAt,
                    seconds: 1_500,
                    source: .timer,
                    grams: 250,
                    deviceDayKey: "unproven-prefix",
                    dataEpochID: epochID
                ))
            }
            let demotedDate = base.addingTimeInterval(
                TimeInterval(-1_000 - groupOffset)
            )
            context.insert(StudySession(
                id: logicalID,
                startAt: demotedDate.addingTimeInterval(-1_500),
                endAt: demotedDate,
                seconds: 1_500,
                source: .timerDemoted,
                grams: 250,
                deviceDayKey: "unproven-prefix",
                dataEpochID: epochID
            ))
        }

        let actualNewestDate = base.addingTimeInterval(-500)
        context.insert(StudySession(
            startAt: actualNewestDate.addingTimeInterval(-1_500),
            endAt: actualNewestDate,
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: "unproven-prefix",
            dataEpochID: epochID
        ))
        try context.save()

        XCTAssertThrowsError(try BoundedHistoryPolicy.resolvedSessionPage(
            context: context,
            epochID: epochID,
            order: .reverse,
            logicalLimit: 1
        )) { error in
            XCTAssertEqual(
                error as? BoundedHistoryPolicy.SessionResolutionError,
                .candidateScanLimitExceeded
            )
        }
    }

    func testExactHistoryResolutionIncludesCopyAfterLegacyFourRowPrefix() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let epochID = UUID()
        let logicalID = UUID()
        let endAt = Date(timeIntervalSince1970: 1_800_000_000)

        for index in 0..<5 {
            context.insert(StudySession(
                id: logicalID,
                startAt: endAt.addingTimeInterval(-1_500),
                endAt: endAt,
                seconds: 1_500,
                source: index == 4 ? .timerDemoted : .timer,
                grams: 250,
                deviceDayKey: "exact-five",
                dataEpochID: epochID
            ))
        }
        try context.save()

        let resolved = try XCTUnwrap(BoundedHistoryPolicy.resolvedSession(
            id: logicalID,
            epochID: epochID,
            context: context
        ))

        XCTAssertEqual(resolved.source, .timerDemoted)
        XCTAssertEqual(
            BoundedHistoryPolicy.sessionDescriptor(
                id: logicalID,
                epochID: epochID
            ).fetchLimit,
            BoundedHistoryPolicy.maximumPhysicalRowsPerLogicalSession + 1
        )
    }

    func testShareAggregateSummaryIsSupplementalWithoutExpandingMembership() {
        let memberIDs = (0..<10).map { _ in UUID() }
        let aggregate = AggregatePebble(
            level: 1,
            pebbleCount: 10,
            grams: 2_500,
            measuredPebbleCount: 8,
            manualPebbleCount: 2,
            goldPebbleCount: 1,
            prismPebbleCount: 1,
            colorMixJSON: "[]",
            periodStart: .now.addingTimeInterval(-3_600),
            periodEnd: .now,
            sessionIDs: memberIDs
        )

        let summary = ShareAggregateVisual(aggregateSummary: aggregate)
        XCTAssertTrue(summary.sessionIDs.isEmpty)
        XCTAssertEqual(summary.pebbleCount, 10)
        XCTAssertEqual(summary.grams, 2_500)
        XCTAssertEqual(summary.measuredPebbleCount, 8)
        XCTAssertEqual(summary.manualPebbleCount, 2)
        XCTAssertEqual(summary.goldPebbleCount, 1)
        XCTAssertEqual(summary.prismPebbleCount, 1)
        XCTAssertTrue(summary.contributesStandaloneTotals)
    }

    func testScopedAggregateShareUsesOneAuthoritativeAccountingSource() {
        let base = Date(timeIntervalSince1970: 50_000)
        let aggregate = AggregatePebble(
            level: 1,
            pebbleCount: 10,
            grams: 2_500,
            measuredPebbleCount: 10,
            manualPebbleCount: 0,
            colorMixJSON: "[]",
            periodStart: base,
            periodEnd: base.addingTimeInterval(15_000),
            sessionIDs: (0..<10).map { _ in UUID() }
        )

        XCTAssertEqual(
            ScopedAggregateShareProjection.mode(
                for: aggregate,
                includesSelfReportedFocus: false
            ),
            .authoritativeSummary
        )
        XCTAssertEqual(
            ScopedAggregateShareProjection.mode(
                for: aggregate,
                includesSelfReportedFocus: true
            ),
            .authoritativeSummary
        )
    }

    func testScopedMixedAggregateReconstructsMeasuredOnlyButSummarizesWhenIncluded() {
        let base = Date(timeIntervalSince1970: 60_000)
        let aggregate = AggregatePebble(
            level: 1,
            pebbleCount: 10,
            grams: 3_200,
            measuredPebbleCount: 8,
            manualPebbleCount: 2,
            colorMixJSON: "[]",
            periodStart: base,
            periodEnd: base.addingTimeInterval(15_000),
            sessionIDs: (0..<10).map { _ in UUID() }
        )

        XCTAssertEqual(
            ScopedAggregateShareProjection.mode(
                for: aggregate,
                includesSelfReportedFocus: false
            ),
            .filteredMembers
        )
        XCTAssertEqual(
            ScopedAggregateShareProjection.mode(
                for: aggregate,
                includesSelfReportedFocus: true
            ),
            .authoritativeSummary
        )
    }

    func testHomeFetchDescriptorsRemainHardBounded() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let base = Date(timeIntervalSince1970: 10_000)

        for index in 0..<600 {
            context.insert(StudySession(
                startAt: base.addingTimeInterval(Double(index)),
                endAt: base.addingTimeInterval(Double(index + 1)),
                seconds: 1_500,
                source: .timer,
                grams: 250,
                deviceDayKey: "fixture",
                isBaked: false
            ))
        }
        for index in 0..<160 {
            context.insert(AggregatePebble(
                createdAt: base.addingTimeInterval(Double(index)),
                level: 2,
                pebbleCount: 100,
                grams: 25_000,
                colorMixJSON: "[]",
                periodStart: base,
                periodEnd: base.addingTimeInterval(Double(index + 1))
            ))
        }
        for index in 0..<40 {
            context.insert(AchievementStone(
                kind: .perfectScore,
                achievedAt: base.addingTimeInterval(Double(index)),
                createdAt: base.addingTimeInterval(Double(index))
            ))
        }
        for index in 0..<24 {
            context.insert(Stratum(
                bakedAt: base.addingTimeInterval(Double(index)),
                pebbleCount: 10,
                heightPt: 1,
                colorMixJSON: "[]",
                monthLabel: "legacy"
            ))
        }
        try context.save()

        XCTAssertEqual(
            try context.fetch(HomeProjectionPolicy.looseSessionDescriptor()).count,
            HomeProjectionPolicy.looseSessionQueryLimit
        )
        XCTAssertEqual(
            try context.fetch(HomeProjectionPolicy.aggregateRootDescriptor()).count,
            HomeProjectionPolicy.aggregateRootLimit
        )
        XCTAssertEqual(
            try context.fetch(HomeProjectionPolicy.achievementCandidateDescriptor()).count,
            HomeProjectionPolicy.achievementLimit
        )
        XCTAssertEqual(
            try context.fetch(HomeProjectionPolicy.legacyCompatibilityDescriptor()).count,
            HomeProjectionPolicy.legacyCompatibilityLimit
        )
    }

    func testHomeSessionChangeSentinelIsRecentAndHardBounded() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let inside = reference.addingTimeInterval(
            -HomeProjectionPolicy.localSessionChangeWindow + 1
        )
        let outside = reference.addingTimeInterval(
            -HomeProjectionPolicy.localSessionChangeWindow - 1
        )
        for endAt in [inside, outside] {
            context.insert(StudySession(
                startAt: endAt.addingTimeInterval(-1_500),
                endAt: endAt,
                seconds: 1_500,
                source: .timer,
                grams: 250,
                deviceDayKey: "recent-sentinel"
            ))
        }
        try context.save()

        let descriptor = HomeProjectionPolicy.sessionChangeSentinelDescriptor(
            relativeTo: reference,
            limit: 1
        )
        let values = try context.fetch(descriptor)

        XCTAssertEqual(descriptor.fetchLimit, 1)
        XCTAssertEqual(values.map(\.endAt), [inside])
    }

    func testHomeLooseHorizonIsAlwaysIncompleteWithoutTypedCertificate() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let horizon = base.addingTimeInterval(-10)
        let older = base.addingTimeInterval(-100)
        for endAt in [base, older] {
            context.insert(StudySession(
                startAt: endAt.addingTimeInterval(-1_500),
                endAt: endAt,
                seconds: 1_500,
                source: .timer,
                grams: 250,
                deviceDayKey: "verified-horizon"
            ))
        }
        try context.save()

        let page = try HomeProjectionPolicy.supportedLooseSessionPage(
            context: context,
            resetMarkers: [],
            startingAt: horizon
        )

        XCTAssertEqual(page.sessions.map(\.endAt), [base])
        XCTAssertFalse(page.isCompleteForHomeCandidates)
    }

    func testSmallOldRootlessStoreUsesExactFullRange() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let oldEnd = reference.addingTimeInterval(
            -HomeProjectionPolicy.localSessionChangeWindow - 86_400
        )
        let expectedIDs = (0..<3).map { index -> UUID in
            let id = UUID()
            let endAt = oldEnd.addingTimeInterval(TimeInterval(index))
            context.insert(StudySession(
                id: id,
                startAt: endAt.addingTimeInterval(-1_500),
                endAt: endAt,
                seconds: 1_500,
                source: .timer,
                grams: 250,
                deviceDayKey: "small-old-rootless"
            ))
            return id
        }
        try context.save()

        let plan = HomeProjectionPolicy.initialLooseSessionQueryPlan(
            physicalSessionRowCount: 3,
            verifiedAggregateEnd: nil,
            referenceDate: reference
        )
        let page = try HomeProjectionPolicy.supportedLooseSessionPage(
            context: context,
            resetMarkers: [],
            startingAt: plan.lowerBound
        )

        XCTAssertNil(plan.lowerBound)
        XCTAssertEqual(Set(page.sessions.map(\.id)), Set(expectedIDs))
        XCTAssertTrue(page.isCompleteForHomeCandidates)
        XCTAssertFalse(HomeProjectionPolicy.shouldRequestLocalSessionMaintenance(
            trustedAggregateHorizon: nil,
            requestedLowerBound: plan.lowerBound,
            pageIsComplete: page.isCompleteForHomeCandidates
        ))
    }

    func testRootless513SessionPageRequestsLocalMaintenance() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let physicalRowCount = HomeProjectionPolicy.looseSessionQueryLimit + 1
        for index in 0..<physicalRowCount {
            let endAt = base.addingTimeInterval(TimeInterval(-index))
            context.insert(StudySession(
                startAt: endAt.addingTimeInterval(-1_500),
                endAt: endAt,
                seconds: 1_500,
                source: .timer,
                grams: 250,
                deviceDayKey: "rootless-513"
            ))
        }
        try context.save()

        let plan = HomeProjectionPolicy.initialLooseSessionQueryPlan(
            physicalSessionRowCount: physicalRowCount,
            verifiedAggregateEnd: nil,
            referenceDate: base
        )
        let page = try HomeProjectionPolicy.supportedLooseSessionPage(
            context: context,
            resetMarkers: [],
            startingAt: plan.lowerBound
        )

        XCTAssertNil(plan.lowerBound)
        XCTAssertEqual(
            page.sessions.count,
            HomeProjectionPolicy.looseSessionQueryLimit
        )
        XCTAssertFalse(page.isCompleteForHomeCandidates)
        XCTAssertTrue(HomeProjectionPolicy.shouldRequestLocalSessionMaintenance(
            trustedAggregateHorizon: nil,
            requestedLowerBound: plan.lowerBound,
            pageIsComplete: page.isCompleteForHomeCandidates
        ))
    }

    func testLargeStoreAggregateHorizonRemainsExplicitLowerBound() {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let aggregateEnd = reference.addingTimeInterval(-86_400)

        let plan = HomeProjectionPolicy.initialLooseSessionQueryPlan(
            physicalSessionRowCount: HomeProjectionPolicy
                .maximumLooseSessionScanRows + 1,
            verifiedAggregateEnd: aggregateEnd,
            referenceDate: reference
        )

        XCTAssertEqual(plan.lowerBound, aggregateEnd)
        XCTAssertFalse(HomeProjectionPolicy.shouldRequestLocalSessionMaintenance(
            trustedAggregateHorizon: aggregateEnd,
            requestedLowerBound: plan.lowerBound,
            pageIsComplete: false
        ))
    }

    func testLargeOrUnknownStoreWithoutAggregateUsesRecentLowerBound() {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let expectedStart = reference.addingTimeInterval(
            -HomeProjectionPolicy.localSessionChangeWindow
        )

        for rowCount in [
            nil,
            HomeProjectionPolicy.maximumLooseSessionScanRows + 1
        ] as [Int?] {
            let plan = HomeProjectionPolicy.initialLooseSessionQueryPlan(
                physicalSessionRowCount: rowCount,
                verifiedAggregateEnd: nil,
                referenceDate: reference
            )
            XCTAssertEqual(plan.lowerBound, expectedStart)
            XCTAssertTrue(HomeProjectionPolicy.shouldRequestLocalSessionMaintenance(
                trustedAggregateHorizon: nil,
                requestedLowerBound: plan.lowerBound,
                pageIsComplete: false
            ))
        }
    }

    func testHomeLoosePageCannotBeStarvedByNewestUnsupportedRows() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let validCount = 12

        let hostileCount = HomeProjectionPolicy.looseSessionQueryLimit * 2
        for index in 0..<hostileCount {
            let endAt = now.addingTimeInterval(Double(-index))
            let hostile = StudySession(
                startAt: endAt,
                endAt: endAt,
                seconds: 60,
                source: .timer,
                grams: 10,
                deviceDayKey: "unsupported-newest"
            )
            hostile.seconds = Int.max
            hostile.grams = Int.max
            context.insert(hostile)
        }
        for index in 0..<validCount {
            let endAt = now.addingTimeInterval(Double(-10_000 - index))
            context.insert(StudySession(
                startAt: endAt.addingTimeInterval(-1_500),
                endAt: endAt,
                seconds: 1_500,
                source: .timer,
                grams: 250,
                deviceDayKey: "supported-older"
            ))
        }
        try context.save()

        let firstRawPage = try context.fetch(
            HomeProjectionPolicy.looseSessionDescriptor()
        )
        XCTAssertEqual(firstRawPage.count, HomeProjectionPolicy.looseSessionQueryLimit)
        XCTAssertTrue(firstRawPage.allSatisfy {
            !StudySessionIntegrityPolicy.isSupported($0)
        })

        let scan = try HomeProjectionPolicy.supportedLooseSessionPage(
            context: context,
            resetMarkers: []
        )
        let fetched = scan.sessions
        XCTAssertEqual(fetched.count, validCount)
        XCTAssertTrue(scan.isCompleteForHomeCandidates)
        XCTAssertEqual(scan.scannedRowCount, hostileCount + validCount)
        XCTAssertTrue(fetched.allSatisfy {
            StudySessionIntegrityPolicy.isSupported($0)
        })
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<StudySession>()),
            hostileCount + validCount
        )
    }

    func testHomeLoosePageUsesSharedSessionResolverForPhysicalDuplicates() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let logicalID = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let newerTimer = StudySession(
            id: logicalID,
            startAt: now.addingTimeInterval(-1_500),
            endAt: now,
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: "shared-resolver",
            syncRecordID: UUID(
                uuidString: "A0000000-0000-0000-0000-000000000001"
            )!
        )
        let earlierDemotion = StudySession(
            id: logicalID,
            startAt: now.addingTimeInterval(-11_500),
            endAt: now.addingTimeInterval(-10_000),
            seconds: 1_500,
            source: .timerDemoted,
            grams: 250,
            deviceDayKey: "shared-resolver",
            syncRecordID: UUID(
                uuidString: "A0000000-0000-0000-0000-000000000002"
            )!
        )
        context.insert(newerTimer)
        for index in 1..<HomeProjectionPolicy.looseSessionQueryLimit {
            let endAt = now.addingTimeInterval(Double(-index))
            context.insert(StudySession(
                startAt: endAt.addingTimeInterval(-1_500),
                endAt: endAt,
                seconds: 1_500,
                source: .timer,
                grams: 250,
                deviceDayKey: "shared-resolver"
            ))
        }
        context.insert(earlierDemotion)
        try context.save()

        let scan = try HomeProjectionPolicy.supportedLooseSessionPage(
            context: context,
            resetMarkers: []
        )

        XCTAssertEqual(
            scan.sessions.count,
            HomeProjectionPolicy.looseSessionQueryLimit
        )
        XCTAssertEqual(
            scan.scannedRowCount,
            HomeProjectionPolicy.looseSessionQueryLimit + 1
        )
        XCTAssertTrue(scan.sessions.contains { $0 === earlierDemotion })
        XCTAssertFalse(scan.sessions.contains { $0 === newerTimer })
        XCTAssertTrue(
            StudySessionSyncPolicy.canonicalSession(
                from: [earlierDemotion, newerTimer]
            ) === earlierDemotion
        )
    }

    func testHomeLoosePageStopsAtHardScanCapAndDisclosesLowerBound() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rowCount = HomeProjectionPolicy.maximumLooseSessionScanRows + 1
        let boundaryID = UUID()
        for index in 0..<rowCount {
            let endAt = now.addingTimeInterval(Double(-index))
            if index == 0 || index == rowCount - 1 {
                context.insert(StudySession(
                    id: boundaryID,
                    startAt: endAt.addingTimeInterval(-1_500),
                    endAt: endAt,
                    seconds: 1_500,
                    source: index == 0 ? .timer : .timerDemoted,
                    grams: 250,
                    deviceDayKey: "late-demotion-at-cap"
                ))
            } else {
                let hostile = StudySession(
                    startAt: endAt,
                    endAt: endAt,
                    seconds: 60,
                    source: .manual,
                    grams: 10,
                    deviceDayKey: "unsupported-cap"
                )
                context.insert(hostile)
            }
        }
        try context.save()

        let scan = try HomeProjectionPolicy.supportedLooseSessionPage(
            context: context,
            resetMarkers: []
        )
        XCTAssertEqual(scan.sessions.map(\.id), [boundaryID])
        XCTAssertEqual(scan.sessions.first?.source, .timerDemoted)
        XCTAssertEqual(
            scan.scannedRowCount,
            HomeProjectionPolicy.maximumLooseSessionScanRows
        )
        XCTAssertFalse(scan.isCompleteForHomeCandidates)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<StudySession>()),
            rowCount
        )
    }

    func testFortyYearProjectionTotalsUseOnlyEighteenDecimalRoots() {
        let base = Date(timeIntervalSince1970: 20_000)
        let rootPebbleCounts = Array(repeating: 10, count: 4)
            + Array(repeating: 100, count: 6)
            + Array(repeating: 10_000, count: 5)
            + Array(repeating: 100_000, count: 3)
        let roots = rootPebbleCounts.enumerated().map { index, count in
            AggregatePebble(
                createdAt: base.addingTimeInterval(Double(index)),
                level: count == 10 ? 1 : (count == 100 ? 2 : (count == 10_000 ? 4 : 5)),
                pebbleCount: count,
                grams: count * 250,
                colorMixJSON: "[]",
                periodStart: base,
                periodEnd: base.addingTimeInterval(Double(index + 1))
            )
        }
        let loose: [StudySession] = []

        let totals = HomeProjectionPolicy.totals(roots: roots, looseSessions: loose)
        XCTAssertEqual(roots.count, 18)
        XCTAssertEqual(rootPebbleCounts.reduce(0, +), 350_640)
        XCTAssertEqual(totals.pebbleCount, 350_640)
        XCTAssertEqual(totals.grams, 87_660_000)
        XCTAssertEqual(roots.count + loose.count, 18)
        XCTAssertLessThanOrEqual(roots.count + loose.count, Constants.Jar.maxPhysicsBodies)
    }

    func testHomeProjectionTotalsSaturateInsteadOfCrashingOnIntegerOverflow() {
        let base = Date(timeIntervalSince1970: 21_000)
        let roots = [
            AggregatePebble(
                createdAt: base,
                level: 1,
                pebbleCount: Int.max,
                grams: Int.max,
                colorMixJSON: "[]",
                periodStart: base,
                periodEnd: base
            ),
            AggregatePebble(
                createdAt: base.addingTimeInterval(1),
                level: 1,
                pebbleCount: 1,
                grams: 250,
                colorMixJSON: "[]",
                periodStart: base,
                periodEnd: base.addingTimeInterval(1)
            )
        ]

        let totals = HomeProjectionPolicy.totals(
            roots: roots,
            looseSessions: []
        )

        XCTAssertEqual(totals.grams, Int.max)
        XCTAssertEqual(totals.pebbleCount, Int.max)
        XCTAssertEqual(
            HomeProjectionPolicy.saturatingNonnegativeSum([-10, 40, Int.max]),
            Int.max
        )
    }

    func testCompletionMetricsCountSaturatesAtIntegerLimit() throws {
        let container = try makeContainer()
        let now = Date(timeIntervalSince1970: 22_000)
        let root = AggregatePebble(
            createdAt: now,
            level: 1,
            pebbleCount: Int.max,
            grams: Int.max,
            measuredPebbleCount: Int.max,
            manualPebbleCount: 0,
            colorMixJSON: "[]",
            periodStart: now,
            periodEnd: now
        )
        let loose = StudySession(
            startAt: now.addingTimeInterval(-600),
            endAt: now,
            seconds: 600,
            source: .timer,
            grams: 100,
            deviceDayKey: "fixture"
        )

        let metrics = try HomeProjectionPolicy.completionMetrics(
            context: container.mainContext,
            resetMarkers: [],
            roots: [root],
            looseSessions: [loose],
            at: now
        )
        XCTAssertEqual(metrics.completedFocusCount, Int.max)
    }

    func testBoundedProjectionRejectsUnverifiedFlattenedParent() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let base = Date(timeIntervalSince1970: 25_000)
        let parentSessionIDs = (0..<100).map { _ in UUID() }
        let child = AggregatePebble(
            createdAt: base.addingTimeInterval(1),
            level: 1,
            pebbleCount: 10,
            grams: 2_500,
            measuredPebbleCount: 10,
            manualPebbleCount: 0,
            colorMixJSON: "[]",
            periodStart: base,
            periodEnd: base.addingTimeInterval(1),
            sessionIDs: Array(parentSessionIDs.prefix(10))
        )
        let flattenedParent = AggregatePebble(
            createdAt: base,
            level: 2,
            pebbleCount: 100,
            childAggregateCount: 1,
            grams: 25_000,
            measuredPebbleCount: 100,
            manualPebbleCount: 0,
            colorMixJSON: "[]",
            periodStart: base,
            periodEnd: base.addingTimeInterval(2),
            sessionIDs: parentSessionIDs,
            childAggregateIDs: [child.id],
            projectionValidationVersion: 0
        )
        context.insert(flattenedParent)
        context.insert(child)
        try context.save()

        let acceptedIDs = try HomeProjectionPolicy.acceptedRootSummaryIDs(
            roots: [child, flattenedParent],
            context: context,
            resetMarkers: []
        )
        let acceptedRoots = [child, flattenedParent].filter {
            acceptedIDs.contains($0.id)
        }
        let totals = HomeProjectionPolicy.totals(
            roots: acceptedRoots,
            looseSessions: []
        )

        XCTAssertTrue(acceptedIDs.isEmpty)
        XCTAssertEqual(totals.pebbleCount, 0)
        XCTAssertEqual(totals.grams, 0)
    }

    func testRefreshedAggregatePageReloadsRegisteredPayloadAfterSecondaryContextSave() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let instant = Date(timeIntervalSince1970: 25_500)
        let rootID = UUID()
        let stratumID = UUID()
        context.insert(AggregatePebble(
            id: rootID,
            createdAt: instant,
            level: 1,
            pebbleCount: 1,
            grams: 250,
            measuredPebbleCount: 1,
            colorMixJSON: "[]",
            periodStart: instant,
            periodEnd: instant
        ))
        context.insert(Stratum(
            id: stratumID,
            bakedAt: instant,
            pebbleCount: 1,
            heightPt: 8,
            colorMixJSON: "[]",
            monthLabel: "before",
            grams: 250
        ))
        try context.save()

        var presentation = AggregateProjectionPresentationContext.initial(
            for: .cloudKit
        )
        presentation.markVerified()
        let stamp = try XCTUnwrap(presentation.verifiedCacheStamp)
        let initialPage = try HomeProjectionPolicy
            .refreshedAggregatePresentationPage(
                context: context,
                resetMarkers: [],
                cacheStamp: stamp
            )
        let registeredRoot = try XCTUnwrap(initialPage.aggregateRoots.first)
        let registeredStratum = try XCTUnwrap(initialPage.legacyStrata.first)
        XCTAssertEqual(registeredRoot.grams, 250)
        XCTAssertEqual(registeredStratum.grams, 250)

        let writer = ModelContext(container)
        let aggregateID = rootID
        let stratumLogicalID = stratumID
        let writerRoot = try XCTUnwrap(writer.fetch(
            FetchDescriptor<AggregatePebble>(predicate: #Predicate {
                $0.id == aggregateID
            })
        ).first)
        let writerStratum = try XCTUnwrap(writer.fetch(
            FetchDescriptor<Stratum>(predicate: #Predicate {
                $0.id == stratumLogicalID
            })
        ).first)
        writerRoot.grams = 900
        writerRoot.pebbleCount = 3
        writerStratum.grams = 700
        writerStratum.monthLabel = "after"
        try writer.save()

        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<AggregatePebble>()),
            1
        )
        XCTAssertEqual(
            registeredRoot.grams,
            250,
            "fetchCount must not be mistaken for a value-bearing refresh"
        )
        XCTAssertEqual(registeredStratum.monthLabel, "before")

        let refreshedPage = try HomeProjectionPolicy
            .refreshedAggregatePresentationPage(
                context: context,
                resetMarkers: [],
                cacheStamp: stamp
            )
        XCTAssertEqual(refreshedPage.aggregateRoots.first?.grams, 900)
        XCTAssertEqual(refreshedPage.aggregateRoots.first?.pebbleCount, 3)
        XCTAssertEqual(refreshedPage.legacyStrata.first?.grams, 700)
        XCTAssertEqual(refreshedPage.legacyStrata.first?.monthLabel, "after")
    }

    func testRefreshedAggregatePageNeedsNewLeaseAfterFalseTrueFalseTransition() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let instant = Date(timeIntervalSince1970: 25_750)
        context.insert(AggregatePebble(
            createdAt: instant,
            level: 1,
            pebbleCount: 2,
            grams: 500,
            measuredPebbleCount: 2,
            colorMixJSON: "[]",
            periodStart: instant,
            periodEnd: instant
        ))
        try context.save()

        var presentation = AggregateProjectionPresentationContext.initial(
            for: .cloudKit
        )
        presentation.markVerified()
        let preImportStamp = try XCTUnwrap(presentation.verifiedCacheStamp)
        let preImportPage = try HomeProjectionPolicy
            .refreshedAggregatePresentationPage(
                context: context,
                resetMarkers: [],
                cacheStamp: preImportStamp
            )
        XCTAssertEqual(preImportPage.aggregateRoots.first?.grams, 500)
        XCTAssertTrue(presentation.acceptsVerifiedAggregateCache(
            preImportPage.cacheStamp
        ))

        presentation.invalidate()
        XCTAssertFalse(presentation.acceptsVerifiedAggregateCache(
            preImportPage.cacheStamp
        ))
        presentation.markVerified()
        XCTAssertFalse(
            presentation.acceptsVerifiedAggregateCache(preImportPage.cacheStamp),
            "verification alone must not stamp an old exact Home page"
        )

        let postImportStamp = try XCTUnwrap(presentation.verifiedCacheStamp)
        let postImportPage = try HomeProjectionPolicy
            .refreshedAggregatePresentationPage(
                context: context,
                resetMarkers: [],
                cacheStamp: postImportStamp
            )
        XCTAssertNotEqual(preImportPage.cacheStamp, postImportPage.cacheStamp)
        XCTAssertTrue(presentation.acceptsVerifiedAggregateCache(
            postImportPage.cacheStamp
        ))
    }

    func testAcceptedRootRequiresCurrentValidationOnItsChildren() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let instant = Date(timeIntervalSince1970: 26_000)
        let rootID = UUID()
        let child = AggregatePebble(
            level: 1,
            pebbleCount: 1,
            grams: 250,
            colorMixJSON: "[]",
            periodStart: instant,
            periodEnd: instant,
            sessionIDs: [UUID()],
            parentAggregateID: rootID,
            projectionValidationVersion: 0
        )
        let root = AggregatePebble(
            id: rootID,
            level: 2,
            pebbleCount: 1,
            childAggregateCount: 1,
            grams: 250,
            colorMixJSON: "[]",
            periodStart: instant,
            periodEnd: instant,
            childAggregateIDs: [child.id]
        )
        context.insert(child)
        context.insert(root)
        try context.save()

        let acceptedIDs = try HomeProjectionPolicy.acceptedRootSummaryIDs(
            roots: [root],
            context: context,
            resetMarkers: []
        )

        XCTAssertTrue(acceptedIDs.isEmpty)
    }

    func testAcceptedRootRejectsCurrentHigherLevelDirectMembership() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let instant = Date(timeIntervalSince1970: 27_000)
        let root = AggregatePebble(
            level: 2,
            pebbleCount: 2,
            grams: 500,
            colorMixJSON: "[]",
            periodStart: instant,
            periodEnd: instant,
            sessionIDs: [UUID(), UUID()]
        )
        context.insert(root)
        try context.save()

        let acceptedIDs = try HomeProjectionPolicy.acceptedRootSummaryIDs(
            roots: [root],
            context: context,
            resetMarkers: []
        )

        XCTAssertTrue(acceptedIDs.isEmpty)
    }

    func testAggregatePersistenceMissingLeafDoesNotMutateAnySource() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let fixture = try makeLeafAggregateFixture()
        for session in fixture.sessions.dropLast() {
            context.insert(session)
        }
        try context.save()

        XCTAssertThrowsError(try HomeAggregatePersistence.persist(
            fixture.request,
            context: context,
            dataEpochID: nil,
            resetMarkers: []
        )) { error in
            XCTAssertEqual(
                error as? HomeAggregatePersistenceError,
                .missingCurrentSource(fixture.sessions.last!.id)
            )
        }

        XCTAssertTrue(fixture.sessions.dropLast().allSatisfy { !$0.isBaked })
        XCTAssertTrue(try aggregateRows(id: fixture.request.id, context: context).isEmpty)
    }

    func testAggregatePersistenceIgnoresLegacyBakedBitWhenLocalMembershipIsAbsent() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let fixture = try makeLeafAggregateFixture()
        fixture.sessions[3].isBaked = true
        fixture.sessions.forEach { context.insert($0) }
        try context.save()

        try HomeAggregatePersistence.persist(
            fixture.request,
            context: context,
            dataEpochID: nil,
            resetMarkers: []
        )

        XCTAssertTrue(fixture.sessions[3].isBaked)
        XCTAssertTrue(
            fixture.sessions.enumerated().allSatisfy { index, session in
                index == 3 || !session.isBaked
            }
        )
        XCTAssertEqual(try aggregateRows(id: fixture.request.id, context: context).count, 1)
    }

    func testAggregatePersistenceCompetingChildParentIsNeverOverwritten() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let fixture = try makeHigherLevelAggregateFixture()
        let competingParentID = UUID()
        fixture.children[4].parentAggregateID = competingParentID
        fixture.children.forEach { context.insert($0) }
        try context.save()

        XCTAssertThrowsError(try HomeAggregatePersistence.persist(
            fixture.request,
            context: context,
            dataEpochID: nil,
            resetMarkers: []
        )) { error in
            XCTAssertEqual(
                error as? HomeAggregatePersistenceError,
                .competingParent(
                    childID: fixture.children[4].id,
                    parentID: competingParentID
                )
            )
        }

        XCTAssertEqual(fixture.children[4].parentAggregateID, competingParentID)
        XCTAssertTrue(
            fixture.children.enumerated().allSatisfy { index, child in
                index == 4 || child.parentAggregateID == nil
            }
        )
        XCTAssertTrue(try aggregateRows(id: fixture.request.id, context: context).isEmpty)
    }

    func testExactExistingAggregateRequestFailsClosedWhenLeafIsMissing() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let fixture = try makeLeafAggregateFixture()
        // An existing aggregate is a local derived projection, not authority
        // for a synchronized source that has disappeared. Even an idempotent
        // replay must fail closed without mutating the remaining sources or
        // creating a duplicate aggregate.
        for session in fixture.sessions.dropLast() {
            context.insert(session)
        }
        let existing = fixture.request.makeAggregatePebble()
        context.insert(existing)
        try context.save()

        XCTAssertThrowsError(try HomeAggregatePersistence.persist(
            fixture.request,
            context: context,
            dataEpochID: nil,
            resetMarkers: []
        )) { error in
            XCTAssertEqual(
                error as? HomeAggregatePersistenceError,
                .missingCurrentSource(fixture.sessions.last!.id)
            )
        }

        XCTAssertTrue(fixture.sessions.dropLast().allSatisfy { !$0.isBaked })
        XCTAssertEqual(try aggregateRows(id: fixture.request.id, context: context).count, 1)
    }

    func testLocalMembershipProjectionFailsOpenWhenOnlyLegacyBakedBitExists() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let fixture = try makeLeafAggregateFixture()
        fixture.sessions.forEach {
            $0.isBaked = true
            context.insert($0)
        }
        try context.save()

        var projection = try HomeProjectionPolicy.localMembershipProjection(
            for: fixture.sessions,
            representedAggregateRoots: [],
            context: context,
            resetMarkers: []
        )
        XCTAssertTrue(projection.representedSessionIDs.isEmpty)

        context.insert(fixture.request.makeAggregatePebble())
        try context.save()
        let root = try XCTUnwrap(context.fetch(FetchDescriptor<AggregatePebble>()).first)
        projection = try HomeProjectionPolicy.localMembershipProjection(
            for: fixture.sessions,
            representedAggregateRoots: [root],
            context: context,
            resetMarkers: []
        )
        XCTAssertEqual(
            projection.representedSessionIDs,
            Set(fixture.sessions.map(\.id))
        )
        XCTAssertTrue(projection.isCompleteForCandidates)
    }

    func testLocalMembershipRequiresLineageToAPresentedRoot() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let instant = Date(timeIntervalSince1970: 80_000)
        let session = StudySession(
            startAt: instant.addingTimeInterval(-1_500),
            endAt: instant,
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: "fixture"
        )
        let leaf = AggregatePebble(
            level: 1,
            pebbleCount: 1,
            grams: 250,
            colorMixJSON: "[]",
            periodStart: session.startAt,
            periodEnd: session.endAt,
            sessionIDs: [session.id],
            parentAggregateID: UUID()
        )
        let root = AggregatePebble(
            level: 2,
            pebbleCount: 1,
            childAggregateCount: 1,
            grams: 250,
            colorMixJSON: "[]",
            periodStart: session.startAt,
            periodEnd: session.endAt
        )
        context.insert(session)
        context.insert(leaf)
        context.insert(root)
        try context.save()

        var projection = try HomeProjectionPolicy.localMembershipProjection(
            for: [session],
            representedAggregateRoots: [root],
            context: context,
            resetMarkers: []
        )
        XCTAssertTrue(projection.representedSessionIDs.isEmpty)
        XCTAssertFalse(projection.isCompleteForCandidates)

        leaf.parentAggregateID = root.id
        root.replaceChildAggregateIDs([leaf.id])
        try context.save()

        projection = try HomeProjectionPolicy.localMembershipProjection(
            for: [session],
            representedAggregateRoots: [root],
            context: context,
            resetMarkers: []
        )
        XCTAssertEqual(projection.representedSessionIDs, [session.id])
        XCTAssertTrue(projection.isCompleteForCandidates)
    }

    func testLocalMembershipUsesExactUUIDWhenCanonicalDateMovesOutsideLeafSpan() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let canonicalEnd = Date(timeIntervalSince1970: 800_000)
        let staleProjectionEnd = Date(timeIntervalSince1970: 80_000)
        let session = StudySession(
            startAt: canonicalEnd.addingTimeInterval(-1_500),
            endAt: canonicalEnd,
            seconds: 1_500,
            source: .timerDemoted,
            grams: 250,
            deviceDayKey: "late-canonical-winner"
        )
        let rootID = UUID()
        let leaf = AggregatePebble(
            level: 1,
            pebbleCount: 1,
            grams: 250,
            colorMixJSON: "[]",
            periodStart: staleProjectionEnd.addingTimeInterval(-1_500),
            periodEnd: staleProjectionEnd,
            sessionIDs: [session.id],
            parentAggregateID: rootID
        )
        let root = AggregatePebble(
            id: rootID,
            level: 2,
            pebbleCount: 1,
            childAggregateCount: 1,
            grams: 250,
            colorMixJSON: "[]",
            periodStart: staleProjectionEnd.addingTimeInterval(-1_500),
            periodEnd: staleProjectionEnd,
            childAggregateIDs: [leaf.id]
        )
        context.insert(session)
        context.insert(leaf)
        context.insert(root)
        try context.save()

        let projection = try HomeProjectionPolicy.localMembershipProjection(
            for: [session],
            representedAggregateRoots: [root],
            context: context,
            resetMarkers: []
        )

        XCTAssertEqual(projection.representedSessionIDs, [session.id])
        XCTAssertTrue(projection.isCompleteForCandidates)
        XCTAssertTrue(projection.conflictedRootIDs.isEmpty)
    }

    func testLocalMembershipExcludesBothRootsForConflictingExactOwners() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let instant = Date(timeIntervalSince1970: 810_000)
        let session = StudySession(
            startAt: instant.addingTimeInterval(-1_500),
            endAt: instant,
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: "conflicting-owners"
        )
        var roots: [AggregatePebble] = []
        for offset in 0..<2 {
            let rootID = UUID()
            let leaf = AggregatePebble(
                createdAt: instant.addingTimeInterval(Double(offset)),
                level: 1,
                pebbleCount: 1,
                grams: 250,
                colorMixJSON: "[]",
                periodStart: session.startAt,
                periodEnd: session.endAt,
                sessionIDs: [session.id],
                parentAggregateID: rootID
            )
            let root = AggregatePebble(
                id: rootID,
                createdAt: instant.addingTimeInterval(Double(offset)),
                level: 2,
                pebbleCount: 1,
                childAggregateCount: 1,
                grams: 250,
                colorMixJSON: "[]",
                periodStart: session.startAt,
                periodEnd: session.endAt,
                childAggregateIDs: [leaf.id]
            )
            context.insert(leaf)
            context.insert(root)
            roots.append(root)
        }
        context.insert(session)
        try context.save()

        let projection = try HomeProjectionPolicy.localMembershipProjection(
            for: [session],
            representedAggregateRoots: roots,
            context: context,
            resetMarkers: []
        )

        XCTAssertTrue(projection.representedSessionIDs.isEmpty)
        XCTAssertFalse(projection.isCompleteForCandidates)
        XCTAssertEqual(projection.conflictedRootIDs, Set(roots.map(\.id)))
    }

    func testLocalMembershipFailsClosedAt257StringMatchingLeaves() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let instant = Date(timeIntervalSince1970: 820_000)
        let session = StudySession(
            startAt: instant.addingTimeInterval(-1_500),
            endAt: instant,
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: "membership-sentinel"
        )
        let root = AggregatePebble(
            level: 2,
            pebbleCount: 257,
            grams: 64_250,
            colorMixJSON: "[]",
            periodStart: session.startAt,
            periodEnd: session.endAt
        )
        context.insert(session)
        context.insert(root)
        for index in 0...HomeProjectionPolicy.maximumPhysicalAggregateRowsPerExactLookup {
            context.insert(AggregatePebble(
                createdAt: instant.addingTimeInterval(Double(index)),
                level: 1,
                pebbleCount: 1,
                grams: 250,
                colorMixJSON: "[]",
                periodStart: session.startAt,
                periodEnd: session.endAt,
                sessionIDs: [session.id],
                parentAggregateID: root.id
            ))
        }
        try context.save()

        let projection = try HomeProjectionPolicy.localMembershipProjection(
            for: [session],
            representedAggregateRoots: [root],
            context: context,
            resetMarkers: []
        )

        XCTAssertTrue(projection.representedSessionIDs.isEmpty)
        XCTAssertFalse(projection.isCompleteForCandidates)
        XCTAssertEqual(projection.conflictedRootIDs, [root.id])
    }

    func testLocalMembershipFailsClosedAt257CopiesInParentChain() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let instant = Date(timeIntervalSince1970: 830_000)
        let session = StudySession(
            startAt: instant.addingTimeInterval(-1_500),
            endAt: instant,
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: "lineage-sentinel"
        )
        let rootID = UUID()
        let leaf = AggregatePebble(
            level: 1,
            pebbleCount: 1,
            grams: 250,
            colorMixJSON: "[]",
            periodStart: session.startAt,
            periodEnd: session.endAt,
            sessionIDs: [session.id],
            parentAggregateID: rootID
        )
        var presentedRoot: AggregatePebble?
        context.insert(session)
        context.insert(leaf)
        for _ in 0...HomeProjectionPolicy.maximumPhysicalAggregateRowsPerExactLookup {
            let root = AggregatePebble(
                id: rootID,
                createdAt: instant,
                level: 2,
                pebbleCount: 1,
                childAggregateCount: 1,
                grams: 250,
                colorMixJSON: "[]",
                periodStart: session.startAt,
                periodEnd: session.endAt,
                childAggregateIDs: [leaf.id]
            )
            context.insert(root)
            if presentedRoot == nil { presentedRoot = root }
        }
        try context.save()
        let root = try XCTUnwrap(presentedRoot)

        let projection = try HomeProjectionPolicy.localMembershipProjection(
            for: [session],
            representedAggregateRoots: [root],
            context: context,
            resetMarkers: []
        )

        XCTAssertTrue(projection.representedSessionIDs.isEmpty)
        XCTAssertFalse(projection.isCompleteForCandidates)
        XCTAssertEqual(projection.conflictedRootIDs, [rootID])
    }

    func testExactExistingHigherLevelRequestRepairsOnlyNilBacklinks() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let fixture = try makeHigherLevelAggregateFixture()
        fixture.children[0].parentAggregateID = fixture.request.id
        fixture.children.forEach { context.insert($0) }
        context.insert(fixture.request.makeAggregatePebble())
        try context.save()

        try HomeAggregatePersistence.persist(
            fixture.request,
            context: context,
            dataEpochID: nil,
            resetMarkers: []
        )

        XCTAssertTrue(fixture.children.allSatisfy {
            $0.parentAggregateID == fixture.request.id
        })
        XCTAssertEqual(try aggregateRows(id: fixture.request.id, context: context).count, 1)
    }

    func testCompletionMetricsUseBoundedProjectionAndFilterEnumInMemory() throws {
        let container = try makeContainer()
        let context = container.mainContext
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 31,
            hour: 12
        ))!
        let measuredID = UUID()
        let manualID = UUID()
        let measured = StudySession(
            id: measuredID,
            startAt: now.addingTimeInterval(-1_500),
            endAt: now,
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: "fixture"
        )
        let manual = StudySession(
            id: manualID,
            startAt: now.addingTimeInterval(-1_800),
            endAt: now.addingTimeInterval(-300),
            seconds: 1_500,
            source: .manual,
            grams: 250,
            deviceDayKey: "fixture"
        )
        context.insert(measured)
        context.insert(manual)
        try context.save()

        let root = AggregatePebble(
            level: 3,
            pebbleCount: 1_000,
            grams: 250_000,
            measuredPebbleCount: 997,
            manualPebbleCount: 3,
            colorMixJSON: "[]",
            periodStart: now.addingTimeInterval(-100_000),
            periodEnd: now.addingTimeInterval(-10_000)
        )
        let metrics = try HomeProjectionPolicy.completionMetrics(
            context: context,
            resetMarkers: [],
            roots: [root],
            looseSessions: [measured, manual],
            at: now,
            calendar: calendar
        )

        XCTAssertEqual(metrics.completedFocusCount, 998)
        XCTAssertEqual(metrics.weeklyMeasuredSessionIDs, [measuredID])
        XCTAssertEqual(metrics.weeklyMeasuredDates, [now])
        XCTAssertEqual(metrics.weeklyMeasuredGrams, 250)
    }

    func testWeeklyMeasuredMassPagesPastNonTimerRowsBeforeFiltering() throws {
        let container = try makeContainer()
        let context = container.mainContext
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 2,
            hour: 12
        ))!

        // Newer manual rows fill the first 512-row database page. A fetch
        // limit applied before the in-memory source filter would report 0g.
        for index in 0 ..< 520 {
            let end = now.addingTimeInterval(TimeInterval(-index))
            context.insert(StudySession(
                startAt: end.addingTimeInterval(-600),
                endAt: end,
                seconds: 600,
                source: .manual,
                grams: 100,
                deviceDayKey: "fixture"
            ))
        }
        let measuredIDs = (0 ..< 6).map { index -> UUID in
            let id = UUID()
            let end = now.addingTimeInterval(TimeInterval(-2_000 - index))
            context.insert(StudySession(
                id: id,
                startAt: end.addingTimeInterval(-600),
                endAt: end,
                seconds: 600,
                source: .timer,
                grams: 100,
                deviceDayKey: "fixture"
            ))
            return id
        }
        try context.save()

        let metrics = try HomeProjectionPolicy.completionMetrics(
            context: context,
            resetMarkers: [],
            roots: [],
            looseSessions: [],
            at: now,
            calendar: calendar
        )

        XCTAssertEqual(metrics.weeklyMeasuredSessionIDs, Set(measuredIDs))
        XCTAssertEqual(metrics.weeklyMeasuredDates.count, 6)
        XCTAssertEqual(metrics.weeklyMeasuredGrams, 600)
    }

    func testWeeklyMetricsResolveBoundaryCopyBeforeWeekMembership() throws {
        let container = try makeContainer()
        let context = container.mainContext
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let reference = calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 2,
            hour: 12
        ))!
        let interval = try XCTUnwrap(
            calendar.dateInterval(of: .weekOfYear, for: reference)
        )
        let boundaryID = UUID()
        let retainedID = UUID()
        let inside = reference
        let outside = interval.end.addingTimeInterval(60)

        context.insert(StudySession(
            id: retainedID,
            startAt: inside.addingTimeInterval(-600),
            endAt: inside,
            seconds: 600,
            source: .timer,
            grams: 100,
            deviceDayKey: "weekly-boundary"
        ))
        context.insert(StudySession(
            id: boundaryID,
            startAt: inside.addingTimeInterval(-600),
            endAt: inside,
            seconds: 600,
            source: .timer,
            grams: 100,
            deviceDayKey: "weekly-boundary"
        ))
        context.insert(StudySession(
            id: boundaryID,
            startAt: outside.addingTimeInterval(-600),
            endAt: outside,
            seconds: 600,
            source: .timerDemoted,
            grams: 100,
            deviceDayKey: "weekly-boundary"
        ))
        try context.save()

        let metrics = try HomeProjectionPolicy.completionMetrics(
            context: context,
            resetMarkers: [],
            roots: [],
            looseSessions: [],
            at: reference,
            calendar: calendar
        )

        XCTAssertEqual(metrics.weeklyMeasuredSessionIDs, [retainedID])
        XCTAssertEqual(metrics.weeklyMeasuredDates, [inside])
        XCTAssertEqual(metrics.weeklyMeasuredGrams, 100)
    }

    func testWeeklyMetricsFailClosedAtDensePhysicalRowCap() throws {
        let container = try makeContainer()
        let context = container.mainContext
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 2,
            hour: 12
        ))!

        for index in 0..<4 {
            let endAt = reference.addingTimeInterval(TimeInterval(index))
            context.insert(StudySession(
                startAt: endAt.addingTimeInterval(-600),
                endAt: endAt,
                seconds: 600,
                source: .timer,
                grams: 100,
                deviceDayKey: "dense-week"
            ))
        }
        try context.save()

        XCTAssertThrowsError(try HomeProjectionPolicy.completionMetrics(
            context: context,
            resetMarkers: [],
            roots: [],
            looseSessions: [],
            at: reference,
            calendar: calendar,
            maximumWeeklyPhysicalRows: 3
        )) { error in
            XCTAssertEqual(
                error as? BoundedHistoryPolicy.SessionResolutionError,
                .candidateScanLimitExceeded
            )
        }
    }

    func testOverviewWeeklyLoaderReadsPastTheOrdinaryHistoryPage() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let currentEpoch = UUID()
        let staleEpoch = UUID()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let reference = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 31,
            hour: 12
        ))!

        for index in 0 ..< 721 {
            let end = reference.addingTimeInterval(TimeInterval(index))
            let source: SessionSource = index.isMultiple(of: 3) ? .manual : .timer
            let seconds = source == .manual
                ? ManualDuration.thirtyMinutes.seconds
                : 600
            let grams = source == .manual
                ? ManualDuration.thirtyMinutes.grams
                : 100
            context.insert(StudySession(
                startAt: end.addingTimeInterval(-TimeInterval(seconds)),
                endAt: end,
                seconds: seconds,
                source: source,
                grams: grams,
                deviceDayKey: "fixture",
                dataEpochID: currentEpoch
            ))
        }
        context.insert(StudySession(
            startAt: reference.addingTimeInterval(-600),
            endAt: reference,
            seconds: 600,
            source: .timer,
            grams: 100,
            deviceDayKey: "stale",
            dataEpochID: staleEpoch
        ))
        let previousWeek = reference.addingTimeInterval(-8 * 86_400)
        context.insert(StudySession(
            startAt: previousWeek.addingTimeInterval(-600),
            endAt: previousWeek,
            seconds: 600,
            source: .timer,
            grams: 100,
            deviceDayKey: "outside",
            dataEpochID: currentEpoch
        ))
        try context.save()

        let weekly = try AccumulationOverviewLoaderPolicy.weeklySessions(
            context: context,
            currentEpochID: currentEpoch,
            referenceDate: reference,
            calendar: calendar
        )

        XCTAssertEqual(weekly.count, 721)
        XCTAssertTrue(weekly.allSatisfy { $0.dataEpochID == currentEpoch })
        XCTAssertEqual(weekly.filter { $0.source == .manual }.count, 241)
    }

    private func makeLeafAggregateFixture() throws -> (
        request: JarAggregateRequest,
        sessions: [StudySession]
    ) {
        let base = Date(timeIntervalSince1970: 70_000)
        var sessions: [StudySession] = []
        sessions.reserveCapacity(Constants.Jar.aggregateFanIn)
        for index in 0..<Constants.Jar.aggregateFanIn {
            let session = StudySession(
                startAt: base.addingTimeInterval(Double(index * 1_500)),
                endAt: base.addingTimeInterval(Double((index + 1) * 1_500)),
                seconds: 1_500,
                source: .timer,
                pebbleKind: index == 0 ? .gold : .normal,
                grams: 250,
                deviceDayKey: "fixture"
            )
            sessions.append(session)
        }
        let request = try XCTUnwrap(JarAggregateRequest(
            pebbles: sessions.map(PebbleDescriptor.init(session:)),
            innerWidth: 320
        ))
        return (request, sessions)
    }

    private func makeHigherLevelAggregateFixture() throws -> (
        request: JarAggregateRequest,
        children: [AggregatePebble]
    ) {
        let base = Date(timeIntervalSince1970: 90_000)
        var children: [AggregatePebble] = []
        children.reserveCapacity(Constants.Jar.aggregateFanIn)
        for index in 0..<Constants.Jar.aggregateFanIn {
            let sessionIDs = (0..<10).map { _ in UUID() }
            let child = AggregatePebble(
                createdAt: base.addingTimeInterval(Double(index)),
                level: 1,
                pebbleCount: 10,
                grams: 2_500,
                measuredPebbleCount: 10,
                manualPebbleCount: 0,
                goldPebbleCount: index == 0 ? 1 : 0,
                prismPebbleCount: 0,
                colorMixJSON: "[]",
                subjectMixJSON: "[]",
                periodStart: base.addingTimeInterval(Double(index * 10)),
                periodEnd: base.addingTimeInterval(Double(index * 10 + 9)),
                sessionIDs: sessionIDs
            )
            children.append(child)
        }
        let request = try XCTUnwrap(JarAggregateRequest(
            pebbles: children.map(PebbleDescriptor.init(aggregate:)),
            innerWidth: 320
        ))
        return (request, children)
    }

    private func aggregateRows(
        id: UUID,
        context: ModelContext
    ) throws -> [AggregatePebble] {
        let aggregateID = id
        return try context.fetch(FetchDescriptor<AggregatePebble>(
            predicate: #Predicate { aggregate in aggregate.id == aggregateID }
        ))
    }

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
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                "HomeProjectionTests-\(UUID().uuidString)",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )]
        )
    }
}

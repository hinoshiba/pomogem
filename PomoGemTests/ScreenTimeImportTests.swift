import Foundation
import SwiftData
import XCTest
@testable import PomoGem

@MainActor
final class ScreenTimeImportTests: XCTestCase {
    private func container() throws -> ModelContainer {
        let schema = Schema([Subject.self, StudySession.self, ActivityResetMarker.self])
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    }
    private func receipt(id: UUID = UUID(), epoch: UUID? = nil, owner: String = "local", themeID: UUID? = nil) -> ScreenTimeLearningImport {
        let now = Date.now
        return .init(id: id, themeID: themeID, startedAt: now.addingTimeInterval(-1_200),
                     endedAt: now, contextKey: owner, dataEpochID: epoch)
    }
    func testTenMinuteReceiptsAreSavedOnceAcrossAcknowledgementRetry() throws {
        let store = try container()
        let values = [receipt(), receipt(), receipt()]
        let first = try ScreenTimeImportCoordinator.insert(values, container: store, contextKey: "local", dataEpochID: nil)
        XCTAssertEqual(first.count, 3)
        XCTAssertTrue(try ScreenTimeImportCoordinator.insert(values, container: store, contextKey: "local", dataEpochID: nil).isEmpty)
        let sessions = try ModelContext(store).fetch(FetchDescriptor<StudySession>())
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.seconds }, 1_800)
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.grams }, 300)
        XCTAssertTrue(sessions.allSatisfy { $0.effectiveSource.isMeasured && $0.effectiveSource == .screenTime && $0.persistedSource == .manual && $0.rareRewardParticipated == false && $0.rareRewardCreditedGrams == 0 })
    }
    func testAccountAndResetMismatchesCannotImportOrRebindOldReceipts() throws {
        let store = try container()
        XCTAssertThrowsError(try ScreenTimeImportCoordinator.insert([receipt(owner: "another")], container: store, contextKey: "local", dataEpochID: nil))
        let epoch = UUID()
        let context = store.mainContext
        context.insert(ActivityResetMarker(epochID: epoch, sequence: 1, resetAt: .now, writerDeviceID: "test"))
        try context.save()
        XCTAssertThrowsError(try ScreenTimeImportCoordinator.insert([receipt()], container: store, contextKey: "local", dataEpochID: nil))
        XCTAssertThrowsError(try ScreenTimeImportCoordinator.insert([receipt()], container: store, contextKey: "local", dataEpochID: epoch))
        XCTAssertEqual(try ScreenTimeImportCoordinator.insert([receipt(epoch: epoch)], container: store, contextKey: "local", dataEpochID: epoch).count, 1)
    }
    func testInvalidReceiptRollsBackEntireBatch() throws {
        let store = try container()
        let now = Date.now
        let invalid = ScreenTimeLearningImport(id: UUID(), themeID: nil, startedAt: now, endedAt: now, contextKey: "local", dataEpochID: nil)
        XCTAssertThrowsError(try ScreenTimeImportCoordinator.insert([receipt(), invalid], container: store, contextKey: "local", dataEpochID: nil))
        XCTAssertEqual(try ModelContext(store).fetchCount(FetchDescriptor<StudySession>()), 0)
    }
    func testThemeIsFrozenInReceiptAndDeletedThemeKeepsLearning() throws {
        let store = try container()
        let missingTheme = UUID()
        _ = try ScreenTimeImportCoordinator.insert([receipt(themeID: missingTheme)], container: store, contextKey: "local", dataEpochID: nil)
        let session = try XCTUnwrap(ModelContext(store).fetch(FetchDescriptor<StudySession>()).first)
        XCTAssertEqual(session.subjectIDSnapshot, missingTheme)
        XCTAssertEqual(session.displaySubjectName, "スクリーンタイムの勉強")
    }
    func testSourceParticipatesInMeasuredTotalsAndShareButOnlyExactChunksAreValid() {
        XCTAssertTrue(SessionSource.screenTime.isMeasured)
        XCTAssertFalse(SessionSource.screenTime.isSelfReported)
        XCTAssertTrue(FairnessPolicy.isIncludedInShareByDefault(source: .screenTime))
        for seconds in [60, 599, 601, 1_200] {
            XCTAssertFalse(StudySessionIntegrityPolicy.isSupported(startAt: .now.addingTimeInterval(-3_600), endAt: .now, seconds: seconds, source: .screenTime, grams: StudySession.grams(for: seconds)))
        }
    }
    func testStoredScreenTimeRowsUseTheVersion102DecodableEncoding() throws {
        let store = try container()
        _ = try ScreenTimeImportCoordinator.insert([receipt()], container: store, contextKey: "local", dataEpochID: nil)
        let session = try XCTUnwrap(ModelContext(store).fetch(FetchDescriptor<StudySession>()).first)
        XCTAssertTrue(SessionSource.legacyPersistableRawValues.contains(session.persistedSource.rawValue))
        XCTAssertFalse(session.hasLegacySourceEncoding)
        XCTAssertEqual(session.effectiveSource, .screenTime)
        XCTAssertTrue(StudySessionIntegrityPolicy.isSupported(session))
    }

    func testPreReleaseRowForTheSameReceiptIsRecognisedInsteadOfConflicting() throws {
        let store = try container()
        let value = receipt()
        let context = ModelContext(store)
        let legacy = StudySession(
            id: value.id, startAt: value.startedAt, endAt: value.endedAt,
            seconds: 600, source: .manual, grams: 100, deviceDayKey: "day"
        )
        legacy.overwriteStoredSourceForTesting(.screenTime)
        context.insert(legacy)
        try context.save()
        XCTAssertTrue(try ScreenTimeImportCoordinator.insert([value], container: store, contextKey: "local", dataEpochID: nil).isEmpty)
        // A real manual entry sharing the ID is still a conflict.
        let manualStore = try container()
        let manualContext = ModelContext(manualStore)
        manualContext.insert(StudySession(
            id: value.id, startAt: value.startedAt, endAt: value.endedAt,
            seconds: ManualDuration.thirtyMinutes.seconds, source: .manual,
            grams: ManualDuration.thirtyMinutes.grams, deviceDayKey: "day"
        ))
        try manualContext.save()
        XCTAssertThrowsError(try ScreenTimeImportCoordinator.insert([value], container: manualStore, contextKey: "local", dataEpochID: nil))
    }

    /// Inside `legacySourceEncodingInterval`, when pre-release builds ran.
    private let preReleaseEnd = Date(timeIntervalSince1970: 1_789_873_200) // 2026-09-20 12:00 JST

    func testNormalizationRewritesOnlyPreReleaseRowsAcrossPages() async throws {
        let store = try container()
        let context = ModelContext(store)
        let end = preReleaseEnd
        let start = end.addingTimeInterval(-1_200)
        var legacyIDs = Set<UUID>()
        for _ in 0..<5 {
            let row = StudySession(startAt: start, endAt: end, seconds: 600, source: .manual, grams: 100, deviceDayKey: "day")
            row.overwriteStoredSourceForTesting(.screenTime)
            legacyIDs.insert(row.id)
            context.insert(row)
        }
        let timers = (0..<3).map { _ in
            StudySession(startAt: start, endAt: end, seconds: 600, source: .timer, deviceDayKey: "day")
        }
        timers.forEach(context.insert)
        let manual = StudySession(
            startAt: end.addingTimeInterval(-3_600), endAt: end,
            seconds: ManualDuration.sixtyMinutes.seconds, source: .manual,
            grams: ManualDuration.sixtyMinutes.grams, deviceDayKey: "day"
        )
        context.insert(manual)
        try context.save()
        XCTAssertEqual(try ScreenTimeImportCoordinator.legacySourceEncodingCandidateCount(container: store), 8)

        let rewritten = try await ScreenTimeImportCoordinator.normalizeLegacySourceEncoding(container: store, pageSize: 2)
        XCTAssertEqual(rewritten, 5)
        let rows = try ModelContext(store).fetch(FetchDescriptor<StudySession>())
        XCTAssertFalse(rows.contains(where: \.hasLegacySourceEncoding))
        for row in rows {
            XCTAssertTrue(SessionSource.legacyPersistableRawValues.contains(row.persistedSource.rawValue))
            if legacyIDs.contains(row.id) {
                XCTAssertEqual(row.effectiveSource, .screenTime)
            } else if row.id == manual.id {
                XCTAssertEqual(row.effectiveSource, .manual)
            } else {
                XCTAssertEqual(row.effectiveSource, .timer)
            }
        }
        // Rewriting the encoding never changes the rows the count selects.
        XCTAssertEqual(try ScreenTimeImportCoordinator.legacySourceEncodingCandidateCount(container: store), 8)
    }

    func testNormalizationScanIsBoundedToThePreReleaseWindow() async throws {
        let store = try container()
        let context = ModelContext(store)
        // Written by the fixed build long after the window: never scanned,
        // however many accumulate. (A pre-release value cannot be this late.)
        let later = ScreenTimeImportCoordinator.legacySourceEncodingInterval.end.addingTimeInterval(86_400)
        let outside = StudySession(startAt: later.addingTimeInterval(-1_200), endAt: later, seconds: 600, source: .manual, grams: 100, deviceDayKey: "day")
        outside.overwriteStoredSourceForTesting(.screenTime)
        context.insert(outside)
        try context.save()
        XCTAssertEqual(try ScreenTimeImportCoordinator.legacySourceEncodingCandidateCount(container: store), 0)
        let rewritten = try await ScreenTimeImportCoordinator.normalizeLegacySourceEncoding(container: store)
        XCTAssertEqual(rewritten, 0)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "ScreenTimeImportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    @discardableResult
    private func insertPreReleaseRow(into store: ModelContainer) throws -> UUID {
        let context = ModelContext(store)
        let row = StudySession(
            startAt: preReleaseEnd.addingTimeInterval(-1_200), endAt: preReleaseEnd,
            seconds: 600, source: .manual, grams: 100, deviceDayKey: "day"
        )
        row.overwriteStoredSourceForTesting(.screenTime)
        context.insert(row)
        try context.save()
        return row.id
    }

    /// Rewrites a normalized row back to the pre-release value without
    /// changing the candidate count, so a skipped scan is observable.
    private func revertEncoding(of id: UUID, in store: ModelContainer) throws {
        let context = ModelContext(store)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<StudySession>(predicate: #Predicate { $0.id == id })).first)
        row.overwriteStoredSourceForTesting(.screenTime)
        try context.save()
    }

    private func hasLegacyRows(_ store: ModelContainer) throws -> Bool {
        try ModelContext(store).fetch(FetchDescriptor<StudySession>()).contains(where: \.hasLegacySourceEncoding)
    }

    /// The view that runs this is rebuilt on every iCloud-mode foreground, so
    /// the clean pass must come from defaults, not from the caller.
    func testCleanPassSkipsTheScanUntilTheCountChanges() async throws {
        let store = try container()
        let defaults = try isolatedDefaults()
        let now = preReleaseEnd.addingTimeInterval(3_600)
        let first = try insertPreReleaseRow(into: store)

        let initial = try await ScreenTimeImportCoordinator.normalizeLegacySourceEncodingIfChanged(
            container: store, ownerKey: "owner", defaults: defaults, now: now, isStillOwner: { true }
        )
        XCTAssertEqual(initial, 1)
        XCTAssertEqual(ScreenTimeLegacyEncodingCleanPass.load(defaults: defaults)?.candidateCount, 1)

        // Same count: the scan is skipped, so this reverted row is left alone.
        try revertEncoding(of: first, in: store)
        let skipped = try await ScreenTimeImportCoordinator.normalizeLegacySourceEncodingIfChanged(
            container: store, ownerKey: "owner", defaults: defaults,
            now: now.addingTimeInterval(60), isStillOwner: { true }
        )
        XCTAssertNil(skipped)
        XCTAssertTrue(try hasLegacyRows(store))

        // A late CloudKit arrival changes the count, and the rescan fixes both.
        try insertPreReleaseRow(into: store)
        let rescanned = try await ScreenTimeImportCoordinator.normalizeLegacySourceEncodingIfChanged(
            container: store, ownerKey: "owner", defaults: defaults,
            now: now.addingTimeInterval(120), isStillOwner: { true }
        )
        XCTAssertEqual(rescanned, 2)
        XCTAssertFalse(try hasLegacyRows(store))
        XCTAssertEqual(ScreenTimeLegacyEncodingCleanPass.load(defaults: defaults)?.candidateCount, 2)
    }

    func testUnchangedCountIsRescannedForAnotherOwnerAfterADayOrABackwardClock() async throws {
        let store = try container()
        let defaults = try isolatedDefaults()
        let now = preReleaseEnd.addingTimeInterval(3_600)
        let id = try insertPreReleaseRow(into: store)
        let initial = try await ScreenTimeImportCoordinator.normalizeLegacySourceEncodingIfChanged(
            container: store, ownerKey: "owner", defaults: defaults, now: now, isStillOwner: { true }
        )
        XCTAssertEqual(initial, 1)

        for (owner, checkedAt) in [
            ("another-owner", now.addingTimeInterval(60)),
            ("another-owner", now.addingTimeInterval(60 + ScreenTimeLegacyEncodingCleanPass.maximumAge)),
            ("another-owner", now)
        ] {
            try revertEncoding(of: id, in: store)
            let rewritten = try await ScreenTimeImportCoordinator.normalizeLegacySourceEncodingIfChanged(
                container: store, ownerKey: owner, defaults: defaults, now: checkedAt, isStillOwner: { true }
            )
            XCTAssertEqual(rewritten, 1, "\(owner) at \(checkedAt)")
            XCTAssertFalse(try hasLegacyRows(store))
        }
    }

    func testPassThatEndsAfterTheOwnerChangedRecordsNothing() async throws {
        let store = try container()
        let defaults = try isolatedDefaults()
        try insertPreReleaseRow(into: store)
        let rewritten = try await ScreenTimeImportCoordinator.normalizeLegacySourceEncodingIfChanged(
            container: store, ownerKey: "owner", defaults: defaults, isStillOwner: { false }
        )
        XCTAssertEqual(rewritten, 1)
        XCTAssertNil(ScreenTimeLegacyEncodingCleanPass.load(defaults: defaults))
        let next = try await ScreenTimeImportCoordinator.normalizeLegacySourceEncodingIfChanged(
            container: store, ownerKey: "owner", defaults: defaults, isStillOwner: { true }
        )
        XCTAssertEqual(next, 0, "Without a recorded pass the next activation scans again")
    }

    func testCleanPassVouchesOnlyForTheSameStore() {
        let pass = ScreenTimeLegacyEncodingCleanPass(
            ownerKey: "owner", storeIdentity: "PomoGemLocal-a.store|PomoGemProjection-a.store",
            candidateCount: 3, checkedAt: preReleaseEnd
        )
        var current = pass
        current.checkedAt = preReleaseEnd.addingTimeInterval(60)
        XCTAssertTrue(pass.vouches(for: current))
        current.storeIdentity = "PomoGemLocal-b.store|PomoGemProjection-b.store"
        XCTAssertFalse(pass.vouches(for: current))
    }

    func testPreReleaseWindowCoversEveryBuildThatWroteTheOldValue() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let interval = ScreenTimeImportCoordinator.legacySourceEncodingInterval
        XCTAssertEqual(interval.start, calendar.date(from: DateComponents(year: 2026, month: 9, day: 12)))
        XCTAssertEqual(interval.end, calendar.date(from: DateComponents(year: 2026, month: 12, day: 1)))
        // The Screen Time writer first ran on 2026-09-13 (JST).
        XCTAssertTrue(interval.contains(try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 13)))))
        XCTAssertTrue(interval.contains(preReleaseEnd))
    }

    /// Every reader classifies the stored `.manual` signature as Screen Time,
    /// exactly as it did the former `screenTime` raw value.
    func testStoredSignatureKeepsScreenTimePresentationEverywhere() {
        let start = Date.now.addingTimeInterval(-1_200)
        let session = StudySession(startAt: start, endAt: .now, seconds: 600, source: .screenTime, deviceDayKey: "day")
        XCTAssertEqual(session.persistedSource, .manual)
        XCTAssertTrue(FairnessPolicy.isIncludedInShareByDefault(source: session.effectiveSource))
        XCTAssertEqual(session.effectiveSource.displayName, "スクリーンタイム")
        XCTAssertEqual(ShareStratumVisual.radius(for: session), Double(Constants.Jar.measuredRadius))
        let descriptor = PebbleDescriptor(session: session)
        XCTAssertEqual(descriptor.source, .screenTime)
        XCTAssertTrue(descriptor.isMeasured)
        XCTAssertTrue(descriptor.accessibilityDescription.contains("Screen Time"))
        let token = StudySessionSyncPolicy.changeToken(for: session)
        XCTAssertEqual(token.source, .screenTime)
        let legacy = StudySession(startAt: start, endAt: .now, seconds: 600, source: .manual, deviceDayKey: "day")
        legacy.overwriteStoredSourceForTesting(.screenTime)
        XCTAssertEqual(StudySessionSyncPolicy.changeToken(for: legacy), StudySessionSyncPolicy.changeToken(for: {
            let copy = StudySession(id: legacy.id, startAt: start, endAt: legacy.endAt, seconds: 600, source: .screenTime,
                                    deviceDayKey: "day", syncRecordID: legacy.syncRecordID)
            return copy
        }()), "Rewriting the encoding must not look like a changed record to projections")
    }

    func testAnimationQueueDeduplicatesAndRemovesWithoutChangingStudyData() throws {
        let suite = "ScreenTimeImportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ids = [UUID(), UUID()]
        ScreenTimeGemDropStore.append(ids + ids, defaults: defaults)
        XCTAssertEqual(ScreenTimeGemDropStore.load(defaults: defaults), ids)
        ScreenTimeGemDropStore.remove(ids[0], defaults: defaults)
        XCTAssertEqual(ScreenTimeGemDropStore.load(defaults: defaults), [ids[1]])
        ScreenTimeGemDropStore.removeAll(defaults: defaults)
        XCTAssertTrue(ScreenTimeGemDropStore.load(defaults: defaults).isEmpty)
    }

    func testCompleteErasureRemovesLedgerAndCannotReviveDelayedAwards() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScreenTimeStore(directory: directory)
        try store.update { state in
            state.contextKey = "old-owner"
            state.contextIsActive = true
            state.configuration.enabled = true
            state.negativeGemCount = 12
        }
        let oldEpoch = try store.snapshot().epoch
        var stopCount = 0
        try store.eraseAllData { stopCount += 1 }
        let erased = try store.snapshot()
        XCTAssertEqual(stopCount, 1)
        XCTAssertNotEqual(erased.epoch, oldEpoch)
        XCTAssertNil(erased.contextKey)
        XCTAssertFalse(erased.contextIsActive)
        XCTAssertFalse(erased.configuration.enabled)
        XCTAssertEqual(erased.negativeGemCount, 0)
        try store.record(runID: UUID(), threshold: 12, now: .now)
        XCTAssertEqual(try store.snapshot().negativeGemCount, 0)

        let ledger = directory.appendingPathComponent("ScreenTime/ledger.json")
        try Data("invalid ledger".utf8).write(to: ledger)
        XCTAssertThrowsError(try store.snapshot())
        try store.eraseAllData { stopCount += 1 }
        XCTAssertTrue(try store.snapshot().isValid)
        try ScreenTimeStore(directory: nil).eraseAllData { stopCount += 1 }
        XCTAssertEqual(stopCount, 3)
    }
}

/// screentime-09: what Home says when Screen Time pebbles and black stones
/// arrive — one attributed line instead of a generic toast per 10 minutes,
/// and a plain count for black stones instead of silence.
@MainActor
final class ScreenTimeArrivalSummaryTests: XCTestCase {
    func testOneThemeIsNamedWithItsMinutesAndPebbles() {
        var tally = ScreenTimeArrivalTally()
        XCTAssertNil(tally.message)
        for _ in 0..<3 { tally.addLearning(subjectName: "英語") }
        XCTAssertEqual(tally.message, "スクリーンタイム：英語 +30分（3粒）")
        tally.addBlackStones(2)
        XCTAssertEqual(tally.message, "スクリーンタイム：英語 +30分（3粒）、黒い石 +2")
    }

    func testSeveralThemesAreSummedAndBlackStonesAloneStayNeutral() {
        var tally = ScreenTimeArrivalTally()
        tally.addLearning(subjectName: "英語")
        tally.addLearning(subjectName: "数学")
        XCTAssertEqual(tally.message, "スクリーンタイム：勉強アプリの時間 +20分（2粒）")
        var stones = ScreenTimeArrivalTally()
        stones.addBlackStones(1)
        XCTAssertEqual(stones.message, "スクリーンタイム：黒い石 +1（控えたいアプリ 10分）")
        for word in ["ダメ", "注意", "失敗", "使いすぎ"] {
            XCTAssertFalse(stones.message?.contains(word) == true, "No judgement: \(word)")
        }
    }

    func testOnlyARiseSinceTheLastAcknowledgedCountIsAnnounced() {
        typealias Tally = ScreenTimeArrivalTally
        XCTAssertEqual(Tally.blackStoneStep(acknowledged: nil, current: 12).newStones, 0,
                       "The first sighting is remembered, not announced")
        XCTAssertEqual(Tally.blackStoneStep(acknowledged: nil, current: 12).acknowledge, 12)
        XCTAssertEqual(Tally.blackStoneStep(acknowledged: 12, current: 12).newStones, 0)
        XCTAssertEqual(Tally.blackStoneStep(acknowledged: 12, current: 14).newStones, 2)
        XCTAssertEqual(Tally.blackStoneStep(acknowledged: 14, current: 0).newStones, 0, "A clear or reset says nothing")
        XCTAssertEqual(Tally.blackStoneStep(acknowledged: 14, current: 0).acknowledge, 0)
    }

    func testTheAnnouncerWaitsForQuietAndIgnoresAnUnboundZero() async throws {
        let suite = "ScreenTimeArrivalTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let announcer = ScreenTimeArrivalAnnouncer(defaults: defaults, acknowledgedKey: { "stones" })
        var spoken: [String] = []
        let announce: (String, String) -> Void = { text, _ in spoken.append(text) }

        announcer.noteBlackStoneCount(5, isBound: true, announce: announce)
        // Before binding the controller publishes 0; that must not be stored.
        announcer.noteBlackStoneCount(0, isBound: false, announce: announce)
        announcer.noteBlackStoneCount(7, isBound: true, announce: announce)
        announcer.noteLearningLanding(subjectName: "英語", announce: announce)
        announcer.noteLearningLanding(subjectName: "英語", announce: announce)
        XCTAssertTrue(spoken.isEmpty, "Nothing is said while pebbles are still landing")
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(spoken, ["スクリーンタイム：英語 +20分（2粒）、黒い石 +2"])
        XCTAssertEqual(defaults.integer(forKey: "stones"), 7)
    }
}

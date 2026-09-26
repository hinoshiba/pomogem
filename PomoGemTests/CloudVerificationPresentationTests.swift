import SwiftData
import XCTest
@testable import PomoGem

/// sync-03. iCloud verification no longer hides the jar's mass or the reward
/// card, and on iOS 18+ the app's own writes no longer revoke trust.
@MainActor
final class CloudVerificationPresentationTests: XCTestCase {
    // MARK: Reward card

    func testTheRewardCardShowsFrozenValuesWhileVerifyingAndReStampsAfter() {
        typealias Policy = PostDropProjectionPolicy
        XCTAssertEqual(Policy.source(usesCloudPersistence: false, isVerificationPending: false,
            receiptWasCloudUnverified: false, receiptStampIsCurrentVerified: false,
            verifiedProjectionIsLoaded: true), .receipt, "Local-only storage has no remote blind spot")
        for receiptWasUnverified in [false, true] {
            for stampIsCurrent in [false, true] {
                XCTAssertEqual(Policy.source(usesCloudPersistence: true, isVerificationPending: true,
                    receiptWasCloudUnverified: receiptWasUnverified, receiptStampIsCurrentVerified: stampIsCurrent,
                    verifiedProjectionIsLoaded: true), .receiptWhileVerifying,
                    "While iCloud is checked the card always carries the caption")
            }
        }
        XCTAssertEqual(Policy.source(usesCloudPersistence: true, isVerificationPending: false,
            receiptWasCloudUnverified: false, receiptStampIsCurrentVerified: true,
            verifiedProjectionIsLoaded: true), .receipt, "A receipt frozen under the current projection is published")
        XCTAssertEqual(Policy.source(usesCloudPersistence: true, isVerificationPending: false,
            receiptWasCloudUnverified: false, receiptStampIsCurrentVerified: false,
            verifiedProjectionIsLoaded: true), .verifiedProjection,
            "The app's own save bumped the epoch: re-stamp instead of hiding the progress forever")
        XCTAssertEqual(Policy.source(usesCloudPersistence: true, isVerificationPending: false,
            receiptWasCloudUnverified: true, receiptStampIsCurrentVerified: false,
            verifiedProjectionIsLoaded: true), .verifiedProjection)
        XCTAssertEqual(Policy.source(usesCloudPersistence: true, isVerificationPending: false,
            receiptWasCloudUnverified: true, receiptStampIsCurrentVerified: false,
            verifiedProjectionIsLoaded: false), .receiptWhileVerifying,
            "Never an empty total while the verified page is still being read")
    }

    func testFrozenLowerBoundProgressNeverInventsAFraction() {
        // While iCloud is checked the card shows a position only for a total
        // this device can stand behind; a lower bound shows 「今回の +250g は
        // 保存済みです…」 instead (HomeView.postDropFusionProgress).
        let snapshot = EffortProgressPolicy.snapshot(totalGrams: 320, latestContributionGrams: 250)
        let display = EffortProgressPresentation.display(snapshot: snapshot, projectionIsLowerBound: true)
        XCTAssertNil(display.progressFraction,
                     "A receipt frozen from an incomplete projection shows the contribution, not a guessed position")
        XCTAssertTrue(display.progressLabel.contains("今回"))
    }

    // MARK: Pending headline (review of PR #40)

    private typealias Mass = PendingMassPresentationPolicy
    private let epoch = UUID()

    private func sessions(_ count: Int, newestEnd: Date = Date(timeIntervalSince1970: 1_800_000_000),
                          grams: Int = 250) -> [Mass.Session] {
        (0..<count).map { index in
            Mass.Session(id: UUID(), endAt: newestEnd.addingTimeInterval(-3_600 * Double(index)), grams: grams)
        }
    }

    private func record(grams: Int, pebbles: Int, lowerBound: Bool = false, epochID: UUID?,
                        frontier: Mass.Session) -> VerifiedMassRecord {
        VerifiedMassRecord(grams: grams, pebbleCount: pebbles, isLowerBound: lowerBound, epochID: epochID,
                           frontierSessionID: frontier.id, frontierEndAt: frontier.endAt)
    }

    /// A multi-year jar: 1,000 kg verified, of which pending Home holds only
    /// the newest 128 sessions (32 kg) and no aggregate. The headline is the
    /// verified total plus the two focus records saved since — never 32 kg.
    func testAPendingHeadlineNeverDropsAMultiYearJarToItsNewestSessions() {
        let held = sessions(128)
        let frontier = held[2]
        let lastVerified = record(grams: 1_000_000, pebbles: 4_000, epochID: epoch, frontier: frontier)
        let device = HomeProjectionPolicy.Totals(grams: 128 * 250, pebbleCount: 128)
        XCTAssertEqual(Mass.headline(lastVerified: lastVerified, currentEpochID: epoch, deviceSessions: held,
                                     deviceTotals: device, deviceCoversEverySession: false),
                       .lastVerified(grams: 1_000_500, pebbleCount: 4_002, isLowerBound: false))

        let partial = record(grams: 1_000_000, pebbles: 4_000, lowerBound: true, epochID: epoch, frontier: frontier)
        XCTAssertEqual(Mass.headline(lastVerified: partial, currentEpochID: epoch, deviceSessions: held,
                                     deviceTotals: device, deviceCoversEverySession: false).isLowerBound, true,
                       "A last verified 「以上」 stays a lower bound")
    }

    func testWithoutAVerifiedTotalAPartialDeviceSumIsHidden() {
        let held = sessions(128)
        let device = HomeProjectionPolicy.Totals(grams: 128 * 250, pebbleCount: 128)
        XCTAssertEqual(Mass.headline(lastVerified: nil, currentEpochID: epoch, deviceSessions: held,
                                     deviceTotals: device, deviceCoversEverySession: false), .hidden,
                       "More history than Home holds, and no verified total: 「再集計中」, not 32 kg")
        XCTAssertEqual(Mass.headline(lastVerified: nil, currentEpochID: epoch, deviceSessions: sessions(3),
                                     deviceTotals: .init(grams: 750, pebbleCount: 3),
                                     deviceCoversEverySession: true), .device(grams: 750, pebbleCount: 3),
                       "A device sum that covers every session is exact")
    }

    func testAVerifiedTotalOfOtherDataIsNeverShown() {
        let held = sessions(128)
        let device = HomeProjectionPolicy.Totals(grams: 128 * 250, pebbleCount: 128)
        let otherEpoch = record(grams: 1_000_000, pebbles: 4_000, epochID: UUID(), frontier: held[0])
        XCTAssertEqual(Mass.headline(lastVerified: otherEpoch, currentEpochID: epoch, deviceSessions: held,
                                     deviceTotals: device, deviceCoversEverySession: false), .hidden,
                       "Records were reset since")
        let gone = record(grams: 1_000_000, pebbles: 4_000, epochID: epoch, frontier: sessions(1)[0])
        XCTAssertEqual(Mass.headline(lastVerified: gone, currentEpochID: epoch, deviceSessions: held,
                                     deviceTotals: device, deviceCoversEverySession: false), .hidden,
                       "Its newest session is not here: deleted, replaced, or another account's data")
        let smaller = record(grams: 1_000, pebbles: 4, epochID: epoch, frontier: held[0])
        XCTAssertEqual(Mass.headline(lastVerified: smaller, currentEpochID: epoch, deviceSessions: held,
                                     deviceTotals: device, deviceCoversEverySession: false),
                       .lastVerified(grams: 128 * 250, pebbleCount: 128, isLowerBound: true),
                       "Never less than this device can already count")
    }

    func testAVerifiedHomeRecordsItsNewestCountedSession() throws {
        let held = sessions(5)
        let made = try XCTUnwrap(Mass.record(grams: 1_250, pebbleCount: 5, isLowerBound: false, epochID: epoch,
                                              countedSessions: held.shuffled(),
                                              newestAggregatedEnd: held[4].endAt.addingTimeInterval(-60)))
        XCTAssertEqual(made.frontierSessionID, held[0].id)
        XCTAssertEqual(made.frontierEndAt, held[0].endAt)
        XCTAssertNil(Mass.record(grams: 0, pebbleCount: 0, isLowerBound: false, epochID: epoch, countedSessions: [],
                                 newestAggregatedEnd: nil))
        // An aggregate newer than every session Home can name (its members
        // are outside the counted list): pending would count them twice.
        XCTAssertNil(Mass.record(grams: 1_250, pebbleCount: 5, isLowerBound: false, epochID: epoch,
                                 countedSessions: [held[4]], newestAggregatedEnd: held[0].endAt),
                     "An aggregate reaching past every session Home can name is never anchored")
        XCTAssertEqual(Mass.record(grams: 1_250, pebbleCount: 5, isLowerBound: false, epochID: epoch,
                                   countedSessions: held, newestAggregatedEnd: held[0].endAt)?.frontierSessionID,
                       held[0].id, "A fusion that just folded the newest session in still anchors on it")

        let suite = "VerifiedMassRecordStoreTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(VerifiedMassRecordStore.load(defaults: defaults))
        VerifiedMassRecordStore.save(made, defaults: defaults)
        XCTAssertEqual(VerifiedMassRecordStore.load(defaults: defaults), made)
    }

    // MARK: History filter — policy

    private typealias Summary = SyncHistoryTransactionSummary
    private let ui = SyncMaintenanceNotificationPolicy.uiAuthor
    private let maintenance = SyncMaintenanceNotificationPolicy.maintenanceAuthor

    func testOwnUIAndMaintenanceWritesNeverRevokeTrust() {
        let own: [Summary] = [
            Summary(author: ui, changedEntityNames: ["Prefs"]),
            Summary(author: ui, changedEntityNames: ["SyncedFocusTimer", "FocusTimerDeviceClaim"]),
            Summary(author: maintenance, changedEntityNames: ["StudySession", "AggregatePebble"]),
            Summary(author: ui, changedEntityNames: ["StudySession"]),
        ]
        XCTAssertEqual(SyncRemoteChangeHistoryPolicy.verdict(transactions: own, cursorHadToken: true), .ignoreOwnWrites)
        XCTAssertEqual(SyncRemoteChangeHistoryPolicy.verdict(transactions: own, cursorHadToken: false), .ignoreOwnWrites)
    }

    func testAnyForeignChangeToASourceModelStillRevokesTrust() {
        for entity in SyncRemoteChangeHistoryPolicy.sourceEntityNames {
            for author in [nil, "NSCloudKitMirroringDelegate.import", "com.example.other"] as [String?] {
                let transactions = [Summary(author: ui, changedEntityNames: ["Prefs"]),
                                    Summary(author: author, changedEntityNames: [entity])]
                XCTAssertEqual(SyncRemoteChangeHistoryPolicy.verdict(transactions: transactions, cursorHadToken: true),
                               .invalidate, "\(entity) by \(author ?? "nil")")
            }
        }
    }

    func testForeignChangesOutsideTheSourceModelsAndAmbiguousAnswers() {
        XCTAssertEqual(SyncRemoteChangeHistoryPolicy.verdict(
            transactions: [Summary(author: nil, changedEntityNames: ["AggregatePebble", "Stratum"])],
            cursorHadToken: true), .ignoreOwnWrites, "Local projection rebuilds are not imports")
        XCTAssertEqual(SyncRemoteChangeHistoryPolicy.verdict(transactions: [], cursorHadToken: true), .ignoreOwnWrites,
                       "With a token, an empty answer was already classified")
        XCTAssertEqual(SyncRemoteChangeHistoryPolicy.verdict(transactions: [], cursorHadToken: false), .invalidate,
                       "A time window cannot prove the change was already seen")
        XCTAssertEqual(SyncRemoteChangeHistoryPolicy.verdict(
            transactions: [Summary(author: ui, changedEntityNames: ["Prefs"])], cursorHadToken: true,
            readWasTruncated: true), .invalidate, "Too much to classify in one read")
        XCTAssertEqual(SyncRemoteChangeHistoryPolicy.sourceEntityNames,
                       ["Subject", "StudySession", "AchievementStone", "Prefs", "ActivityResetMarker",
                        "SyncedFocusTimer", "FocusTimerDeviceClaim"])
    }

    // MARK: History filter — real SwiftData history (iOS 18+)

    private func makeContainer() throws -> (ModelContainer, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryFilter-\(UUID())",
                                                                                       isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configurations = PersistenceStoreTopology.readOnlyCloudConfigurations(
            accountNamespace: AccountDataNamespace(), directory: directory).map {
                ModelConfiguration($0.name, schema: $0.schema, url: $0.url, allowsSave: true, cloudKitDatabase: .none)
            }
        return (try ModelContainer(for: PersistenceStoreTopology.shippingSchema, configurations: configurations), directory)
    }

    func testTheRealHistoryIgnoresOwnWritesAndCatchesAnUnauthoredSourceChange() throws {
        guard #available(iOS 18, *) else { throw XCTSkip("SwiftData History is iOS 18+; iOS 17 keeps escalating") }
        let (container, directory) = try makeContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let main = container.mainContext
        main.author = ui
        main.autosaveEnabled = false
        var cursor = SyncRemoteChangeHistoryCursor(since: .now.addingTimeInterval(-1))

        // A settings toggle and a timer write on the UI context.
        main.insert(Prefs())
        main.insert(Subject(name: "own theme", colorHex: "#abcdef", sortOrder: 0))
        try main.save()
        XCTAssertEqual(SyncRemoteChangeHistoryReader.classify(context: main, cursor: &cursor), .ignoreOwnWrites)
        XCTAssertNotNil(cursor.tokenData, "The first read moves the cursor from a time to a token")

        // Nothing new since: already classified.
        XCTAssertEqual(SyncRemoteChangeHistoryReader.classify(context: main, cursor: &cursor), .ignoreOwnWrites)

        // The maintenance worker's own save.
        let worker = ModelContext(container)
        worker.author = maintenance
        worker.insert(Subject(name: "maintenance write", colorHex: "#123456", sortOrder: 1))
        try worker.save()
        XCTAssertEqual(SyncRemoteChangeHistoryReader.classify(context: main, cursor: &cursor), .ignoreOwnWrites)

        // An unauthored write of a source model (an import looks like this).
        let foreign = ModelContext(container)
        foreign.insert(Subject(name: "arrived from elsewhere", colorHex: "#654321", sortOrder: 2))
        try foreign.save()
        XCTAssertEqual(SyncRemoteChangeHistoryReader.classify(context: main, cursor: &cursor), .invalidate)
        XCTAssertEqual(SyncRemoteChangeHistoryReader.classify(context: main, cursor: &cursor), .ignoreOwnWrites,
                       "Classified once, not re-escalated by the next notification")
    }

    // MARK: History filter — two stores

    /// The shipping container has a source store and a projection store, and
    /// History tokens are per store. A cursor that moved to a projection token
    /// used to hide every later source transaction (review of PR #40).
    func testAProjectionWriteBeforeTheFirstReadNeverHidesALaterImport() throws {
        guard #available(iOS 18, *) else { throw XCTSkip("SwiftData History is iOS 18+") }
        let (container, directory) = try makeContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let main = container.mainContext
        main.author = ui
        main.autosaveEnabled = false
        var cursor = SyncRemoteChangeHistoryCursor(since: .now.addingTimeInterval(-1))

        // An unauthored projection write, then the app's own settings write.
        let projection = ModelContext(container)
        projection.insert(GachaState())
        try projection.save()
        XCTAssertEqual(SyncRemoteChangeHistoryReader.classify(context: main, cursor: &cursor), .invalidate,
                       "No source transaction yet: a time window proves nothing")
        main.insert(Prefs())
        try main.save()
        XCTAssertEqual(SyncRemoteChangeHistoryReader.classify(context: main, cursor: &cursor), .ignoreOwnWrites)

        let foreign = ModelContext(container)
        foreign.insert(Subject(name: "arrived from elsewhere", colorHex: "#654321", sortOrder: 2))
        try foreign.save()
        XCTAssertEqual(SyncRemoteChangeHistoryReader.classify(context: main, cursor: &cursor), .invalidate,
                       "An unauthored source write after a projection write is still an import")
    }

    func testAMixedFirstReadNeverHidesALaterImport() throws {
        guard #available(iOS 18, *) else { throw XCTSkip("SwiftData History is iOS 18+") }
        for projectionFirst in [true, false] {
            for extraProjectionWrites in [0, 5] {
                let (container, directory) = try makeContainer()
                defer { try? FileManager.default.removeItem(at: directory) }
                let main = container.mainContext
                main.author = ui
                main.autosaveEnabled = false
                var cursor = SyncRemoteChangeHistoryCursor(since: .now.addingTimeInterval(-1))
                let worker = ModelContext(container)
                worker.author = maintenance
                func projectionWrites() throws {
                    for _ in 0...extraProjectionWrites {
                        worker.insert(GachaState())
                        try worker.save()
                    }
                }
                if projectionFirst { try projectionWrites() }
                main.insert(Prefs())
                try main.save()
                if !projectionFirst { try projectionWrites() }
                let label = "projectionFirst=\(projectionFirst) extra=\(extraProjectionWrites)"
                XCTAssertEqual(SyncRemoteChangeHistoryReader.classify(context: main, cursor: &cursor),
                               .ignoreOwnWrites, label)

                // More maintenance on the projection store after the cursor.
                try projectionWrites()
                XCTAssertEqual(SyncRemoteChangeHistoryReader.classify(context: main, cursor: &cursor),
                               .ignoreOwnWrites, label)

                let foreign = ModelContext(container)
                foreign.insert(Subject(name: "x", colorHex: "#654321", sortOrder: 2))
                try foreign.save()
                XCTAssertEqual(SyncRemoteChangeHistoryReader.classify(context: main, cursor: &cursor),
                               .invalidate, label)
            }
        }
    }

    /// The maintenance worker writes the projection store all the time. Its
    /// transactions must never pile up in the source cursor's reads until
    /// every classification is a truncated read.
    func testManyProjectionWritesDoNotTruncateTheSourceCursor() throws {
        guard #available(iOS 18, *) else { throw XCTSkip("SwiftData History is iOS 18+") }
        let (container, directory) = try makeContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let main = container.mainContext
        main.author = ui
        main.autosaveEnabled = false
        var cursor = SyncRemoteChangeHistoryCursor(since: .now.addingTimeInterval(-1))
        main.insert(Prefs())
        try main.save()
        XCTAssertEqual(SyncRemoteChangeHistoryReader.classify(context: main, cursor: &cursor), .ignoreOwnWrites)

        let worker = ModelContext(container)
        worker.author = maintenance
        for _ in 0..<(SyncRemoteChangeHistoryPolicy.maximumTransactionsPerRead + 20) {
            worker.insert(GachaState())
            try worker.save()
        }
        main.insert(Subject(name: "own theme", colorHex: "#abcdef", sortOrder: 0))
        try main.save()
        XCTAssertEqual(SyncRemoteChangeHistoryReader.classify(context: main, cursor: &cursor), .ignoreOwnWrites,
                       "Projection transactions are not part of the source cursor's window")
    }

    func testTheSourceStoreIsTheOneThatChangesSourceModels() {
        typealias Policy = SyncRemoteChangeHistoryPolicy
        let source = Summary(author: ui, changedEntityNames: ["Prefs"], storeIdentifier: "S")
        let projection = Summary(author: maintenance, changedEntityNames: ["GachaState"], storeIdentifier: "P")
        XCTAssertEqual(Policy.sourceTransactions([projection, source], knownSourceStore: nil),
                       .source(identifier: "S", transactions: [source]))
        XCTAssertEqual(Policy.sourceTransactions([projection], knownSourceStore: nil),
                       .source(identifier: nil, transactions: []),
                       "Projection work alone never identifies, or advances, the source cursor")
        XCTAssertEqual(Policy.sourceTransactions([projection], knownSourceStore: "S"),
                       .source(identifier: "S", transactions: []))
        let elsewhere = Summary(author: nil, changedEntityNames: ["Subject"], storeIdentifier: "X")
        XCTAssertEqual(Policy.sourceTransactions([source, elsewhere], knownSourceStore: nil), .ambiguous,
                       "Two stores changing source models is a doubt")
        XCTAssertEqual(Policy.sourceTransactions([elsewhere], knownSourceStore: "S"), .ambiguous,
                       "A source model changing in another store than the cursor's is a doubt")
    }

    func testAnUnreadableCursorFailsClosedAndStartsANewWindow() throws {
        guard #available(iOS 18, *) else { throw XCTSkip("SwiftData History is iOS 18+") }
        let (container, directory) = try makeContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        var cursor = SyncRemoteChangeHistoryCursor(since: .now.addingTimeInterval(-1))
        cursor.corruptTokenForTesting()
        let now = Date.now
        XCTAssertEqual(SyncRemoteChangeHistoryReader.classify(context: container.mainContext, cursor: &cursor, now: now),
                       .invalidate)
        XCTAssertNil(cursor.tokenData)
        XCTAssertEqual(cursor.since, now)
    }
}

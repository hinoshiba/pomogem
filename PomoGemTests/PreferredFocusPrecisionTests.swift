import Foundation
import SwiftData
import XCTest
@testable import PomoGem

@MainActor
final class PreferredFocusPrecisionTests: XCTestCase {
    private func container() throws -> ModelContainer {
        let schema = Schema([Prefs.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(
            "PreferredFocusPrecision-\(UUID())", schema: schema,
            isStoredInMemoryOnly: true, cloudKitDatabase: .none
        )])
        container.mainContext.autosaveEnabled = false
        return container
    }

    private func row(minutes: Int = 1, seconds: Int? = nil,
                     revision: Int = 1, mutationID: UUID = UUID(),
                     writer: String = "writer-a") -> Prefs {
        let value = Prefs(preferredFocusMinutes: minutes, settingsWriterID: writer)
        value.preferredFocusMinutesRevision = revision
        value.preferredFocusMinutesMutationID = mutationID
        value.preferredFocusSeconds = seconds
        value.preferredFocusSecondsMutationID = seconds == nil ? nil : mutationID
        return value
    }

    private func resolve(_ rows: [Prefs]) throws -> PrefsSyncPolicy.ResolvedState {
        try PrefsSyncPolicy.resolvedState(in: rows, currentEpochID: nil,
                                         writerID: "writer-a", currentDay: "day")
    }

    func testLegacyMinutesAndEmptyStoreRetainTheirExactMeaning() throws {
        XCTAssertEqual(try resolve([]).preferredFocusSeconds, 1_500)
        for minutes in [1, 25, 47, 360] {
            let legacy = Prefs(preferredFocusMinutes: minutes)
            XCTAssertNil(legacy.preferredFocusSeconds)
            XCTAssertNil(legacy.preferredFocusSecondsMutationID)
            XCTAssertEqual(try resolve([legacy]).preferredFocusMinutes, minutes)
            XCTAssertEqual(try resolve([legacy]).preferredFocusSeconds, minutes * 60)
        }
    }

    func testSecondsMutationPersistsThroughFreshContextWithoutChangingForeignWriter() throws {
        let container = try container()
        let context = container.mainContext
        let foreign = row(minutes: 47, revision: 4, writer: "writer-b")
        let foreignID = foreign.syncRecordID
        let foreignStamp = foreign.preferredFocusMinutesMutationID
        context.insert(foreign)
        try context.save()
        let mutationID = UUID()
        let epoch = UUID()
        let writer = try PrefsSyncPolicy.setPreferredFocusSeconds(
            90, context: context, writerID: "writer-a", currentEpochID: epoch,
            currentDay: "day", mutationID: mutationID
        )
        XCTAssertEqual(writer.preferredFocusMinutes, 1)
        XCTAssertEqual(writer.preferredFocusSeconds, 90)
        XCTAssertEqual(writer.preferredFocusMinutesRevision, 5)
        XCTAssertEqual(writer.preferredFocusMinutesMutationID, mutationID)
        XCTAssertEqual(writer.preferredFocusSecondsMutationID, mutationID)
        XCTAssertEqual(writer.activityEpochID, epoch)
        try context.save()
        let reader = ModelContext(container)
        let rows = try reader.fetch(FetchDescriptor<Prefs>())
        XCTAssertEqual(rows.count, 2)
        let foreignAgain = try XCTUnwrap(rows.first { $0.syncRecordID == foreignID })
        XCTAssertEqual(foreignAgain.preferredFocusMinutes, 47)
        XCTAssertEqual(foreignAgain.preferredFocusMinutesRevision, 4)
        XCTAssertEqual(foreignAgain.preferredFocusMinutesMutationID, foreignStamp)
        XCTAssertNil(foreignAgain.preferredFocusSeconds)
        XCTAssertEqual(try resolve(rows).preferredFocusSeconds, 90)
    }

    func testNewLegacyMinuteMutationInvalidatesRetainedSecondsEvenWhenMinutesChangeBack() throws {
        let originalID = UUID()
        let precise = row(seconds: 90, mutationID: originalID)
        // Old code can retain unknown columns while changing only its known
        // minutes and stamp. The extra seconds must follow neither new stamp.
        let oldClient = row(minutes: 2, seconds: 90, revision: 2,
                            mutationID: UUID(), writer: "writer-b")
        oldClient.preferredFocusSecondsMutationID = originalID
        for values in [[precise, oldClient], [oldClient, precise]] {
            XCTAssertEqual(try resolve(values).preferredFocusSeconds, 120)
        }
        oldClient.preferredFocusMinutes = 1
        oldClient.preferredFocusMinutesRevision = 3
        oldClient.preferredFocusMinutesMutationID = UUID()
        XCTAssertEqual(try resolve([precise, oldClient]).preferredFocusSeconds, 60)
        XCTAssertEqual(oldClient.preferredFocusSeconds, 90, "Retain raw stale evidence")
        XCTAssertEqual(oldClient.preferredFocusSecondsMutationID, originalID)
    }

    func testExistingMinuteMutationPathCannotReattachSeconds() throws {
        let container = try container()
        let context = container.mainContext
        _ = try PrefsSyncPolicy.setPreferredFocusSeconds(
            90, context: context, writerID: "writer-a", currentEpochID: nil
        )
        try context.save()
        let writer = try PrefsSyncPolicy.mutate(
            .preferredFocusMinutes, context: context, writerID: "writer-a",
            currentEpochID: nil
        ) { $0.preferredFocusMinutes = 25 }
        XCTAssertNotEqual(writer.preferredFocusSecondsMutationID,
                          writer.preferredFocusMinutesMutationID)
        XCTAssertEqual(try resolve([writer]).preferredFocusSeconds, 1_500)
    }

    func testSameStampOldReplicaPreservesAttachedPrecisionDuringAnotherGroupMutation() throws {
        let container = try container()
        let context = container.mainContext
        let mutationID = UUID()
        let precise = row(seconds: 119, mutationID: mutationID, writer: "writer-a")
        let oldCopy = row(mutationID: mutationID, writer: "writer-b")
        context.insert(precise)
        context.insert(oldCopy)
        try context.save()
        for values in [[precise, oldCopy], [oldCopy, precise]] {
            XCTAssertEqual(try resolve(values).preferredFocusSeconds, 119)
        }
        let writer = try PrefsSyncPolicy.mutate(
            .sound, context: context, writerID: "writer-b", currentEpochID: nil
        ) { $0.soundOn = false }
        XCTAssertEqual(writer.preferredFocusSeconds, 119)
        XCTAssertEqual(writer.preferredFocusSecondsMutationID, mutationID)
        XCTAssertEqual(writer.preferredFocusMinutesMutationID, mutationID)
        XCTAssertEqual(precise.soundOn, true)
    }

    func testDifferentValidSecondsForOneStampAreRejectedEvenWithMissingReplicaFirst() throws {
        let mutationID = UUID()
        let missing = row(mutationID: mutationID, writer: "legacy")
        let first = row(seconds: 90, mutationID: mutationID)
        let second = row(seconds: 119, mutationID: mutationID, writer: "writer-b")
        for values in [[missing, first, second], [missing, second, first],
                       [first, missing, second], [second, first, missing]] {
            XCTAssertThrowsError(try resolve(values)) { error in
                XCTAssertEqual(error as? PrefsSyncError, .conflictingStampedValues)
            }
        }
        let container = try container()
        for value in [missing, first, second] { container.mainContext.insert(value) }
        try container.mainContext.save()
        XCTAssertThrowsError(try PrefsSyncPolicy.setPreferredFocusSeconds(
            100, context: container.mainContext, writerID: "new-writer", currentEpochID: nil
        ))
        XCTAssertFalse(container.mainContext.hasChanges)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Prefs>()), 3)
        XCTAssertEqual(first.preferredFocusSeconds, 90)
        XCTAssertEqual(second.preferredFocusSeconds, 119)
    }

    func testConcurrentWritersUseExistingRevisionAndMutationOrdering() throws {
        let lower = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let higher = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = row(seconds: 90, revision: 5, mutationID: lower)
        let second = row(seconds: 119, revision: 5, mutationID: higher, writer: "writer-b")
        for values in [[first, second], [second, first]] {
            XCTAssertEqual(try resolve(values).preferredFocusSeconds, 119)
        }
        first.preferredFocusMinutesRevision = 6
        XCTAssertEqual(try resolve([second, first]).preferredFocusSeconds, 90)
    }

    func testUnattachedInvalidOrInconsistentPrecisionFallsBackWithoutRepairingRawValues() throws {
        for seconds in [-1, 0, 59, 120, 21_601, Int.max] {
            let value = row(seconds: seconds)
            XCTAssertEqual(try resolve([value]).preferredFocusSeconds, 60)
            XCTAssertEqual(value.preferredFocusSeconds, seconds)
        }
        let missingAnchor = row(seconds: 90)
        missingAnchor.preferredFocusSecondsMutationID = nil
        XCTAssertEqual(try resolve([missingAnchor]).preferredFocusSeconds, 60)
        let zeroStamp = Prefs(preferredFocusMinutes: 1)
        zeroStamp.preferredFocusSeconds = 90
        XCTAssertEqual(try resolve([zeroStamp]).preferredFocusSeconds, 60)
        let mismatchedAnchor = row(seconds: 90)
        mismatchedAnchor.preferredFocusSecondsMutationID = UUID()
        XCTAssertEqual(try resolve([mismatchedAnchor]).preferredFocusSeconds, 60)
    }

    func testBoundsAndRevisionOverflowRejectBeforeAnyMutation() throws {
        let container = try container()
        let context = container.mainContext
        for seconds in [Int.min, 59, 21_601, Int.max] {
            XCTAssertThrowsError(try PrefsSyncPolicy.setPreferredFocusSeconds(
                seconds, context: context, writerID: "writer-a", currentEpochID: nil
            )) { error in XCTAssertEqual(error as? PrefsSyncError, .invalidFocusDuration) }
            XCTAssertFalse(context.hasChanges)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Prefs>()), 0)
        }
        for seconds in [60, 21_600] {
            let writer = try PrefsSyncPolicy.setPreferredFocusSeconds(
                seconds, context: context, writerID: "writer-a", currentEpochID: nil
            )
            XCTAssertEqual(try resolve([writer]).preferredFocusSeconds, seconds)
            try context.save()
        }
        let ceiling = row(seconds: 90, revision: PrefsSyncPolicy.maximumSupportedRevision,
                          writer: "writer-b")
        context.insert(ceiling)
        try context.save()
        XCTAssertThrowsError(try PrefsSyncPolicy.setPreferredFocusSeconds(
            100, context: context, writerID: "writer-a", currentEpochID: nil
        )) { error in XCTAssertEqual(error as? PrefsSyncError, .revisionLimitReached) }
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(ceiling.preferredFocusSeconds, 90)
    }

    func testConsumerWrapperUsesCurrentEpochAndBounds() throws {
        let container = try container()
        let marker = ActivityResetSnapshot(id: UUID(), epochID: UUID(), sequence: 2,
                                           resetAt: .now, writerDeviceID: "reset-writer")
        let writer = try PrefsConsumerPolicy.setPreferredFocusSeconds(
            95, context: container.mainContext, markers: [marker]
        )
        XCTAssertEqual(writer.activityEpochID, marker.epochID)
        XCTAssertEqual(writer.preferredFocusSeconds, 95)
        let resolved = PrefsConsumerPolicy.resolvedState(in: [writer], markers: [marker])
        XCTAssertEqual(resolved?.preferredFocusSeconds, 95)
    }
}

import CloudKit
import CoreData
import XCTest
@testable import PomoGem

/// sync-04. Settings reports what the mounted store's own mirroring said:
/// when records last reached iCloud, full iCloud storage, and export failures
/// that keep repeating. Observational only.
@MainActor
final class CloudKitMirroringActivityTests: XCTestCase {
    private let zone = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone", ownerName: CKCurrentUserDefaultName)

    private func partial(_ errors: [CKError]) -> CKError {
        var byItem: [AnyHashable: Error] = [:]
        for (index, error) in errors.enumerated() {
            byItem[CKRecord.ID(recordName: "item-\(index)", zoneID: zone)] = error
        }
        return CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: byItem])
    }

    private func export(_ succeeded: Bool, _ errorClass: CloudKitMirroringErrorClass? = nil,
                        at seconds: TimeInterval = 0) -> CloudKitMirroringEventSummary {
        .init(kind: .exporting, succeeded: succeeded,
              endDate: Date(timeIntervalSinceReferenceDate: 800_000_000 + seconds), errorClass: errorClass)
    }

    // MARK: Classification

    func testQuotaIsRecognisedAtTheTopAndInsideAPartialFailure() {
        XCTAssertEqual(CloudKitMirroringPolicy.classify(CKError(.quotaExceeded)), .quota)
        XCTAssertEqual(CloudKitMirroringPolicy.classify(partial([CKError(.serverRecordChanged), CKError(.quotaExceeded)])),
                       .quota, "One quota item is enough: the whole export is stuck on storage")
    }

    func testRoutineConflictsAndConnectivityAreTransient() {
        for code in [CKError.Code.networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited,
                     .zoneBusy, .serverResponseLost, .serverRecordChanged, .operationCancelled] {
            XCTAssertEqual(CloudKitMirroringPolicy.classify(CKError(code)), .transient, "\(code)")
        }
        XCTAssertEqual(CloudKitMirroringPolicy.classify(partial([CKError(.serverRecordChanged)])), .transient,
                       "A partial failure of only conflicts is the mirroring engine's normal merge")
        XCTAssertEqual(CloudKitMirroringPolicy.classify(URLError(.notConnectedToInternet)), .transient)
        XCTAssertEqual(CloudKitMirroringPolicy.classify(CancellationError()), .transient)
        XCTAssertNil(CloudKitMirroringPolicy.classify(nil))
    }

    func testEverythingElseIsPersistent() {
        for code in [CKError.Code.permissionFailure, .badContainer, .missingEntitlement, .invalidArguments,
                     .notAuthenticated, .internalError] {
            XCTAssertEqual(CloudKitMirroringPolicy.classify(CKError(code)), .persistent, "\(code)")
        }
        XCTAssertEqual(CloudKitMirroringPolicy.classify(partial([CKError(.serverRecordChanged), CKError(.invalidArguments)])),
                       .persistent)
        XCTAssertEqual(CloudKitMirroringPolicy.classify(NSError(domain: "NSCocoaErrorDomain", code: 134_400)),
                       .persistent)
    }

    // MARK: State

    func testASuccessfulExportRecordsTheLatestSendAndClearsAnyIssue() {
        var state = CloudKitMirroringState()
        state.apply(export(true, at: 10))
        state.apply(export(true, at: 5))
        XCTAssertEqual(state.lastExportSuccess, Date(timeIntervalSinceReferenceDate: 800_000_010),
                       "A late, older event never moves the last send backwards")
        XCTAssertNil(state.issue)
        XCTAssertFalse(state.mayHaveUnsentChanges)
    }

    func testQuotaIsShownAtOnceAndClearedByTheNextSuccess() {
        var state = CloudKitMirroringState()
        state.apply(export(false, .quota, at: 1))
        XCTAssertEqual(state.issue, .quotaExceeded)
        XCTAssertTrue(state.mayHaveUnsentChanges)
        state.apply(export(false, .persistent, at: 2))
        state.apply(export(false, .persistent, at: 3))
        XCTAssertEqual(state.issue, .quotaExceeded, "The more actionable reason stays")
        state.apply(export(true, at: 4))
        XCTAssertNil(state.issue)
    }

    func testOnlyRepeatedNonTransientFailuresAreReported() {
        var state = CloudKitMirroringState()
        state.apply(export(false, .persistent, at: 1))
        XCTAssertNil(state.issue, "One failure is not worth a warning")
        state.apply(export(false, .transient, at: 2))
        XCTAssertNil(state.issue)
        state.apply(export(false, .persistent, at: 3))
        XCTAssertEqual(state.issue, .persistentExportFailure)
        state.apply(export(true, at: 4))
        XCTAssertNil(state.issue)
        XCTAssertEqual(state.consecutiveExportFailures, 0)
        for index in 0..<10 { state.apply(export(false, .transient, at: 10 + Double(index))) }
        XCTAssertNil(state.issue, "Transient failures CloudKit retries by itself are never reported")
    }

    func testImportsAndSetupNeverRaiseAnExportIssue() {
        var state = CloudKitMirroringState()
        state.apply(.init(kind: .importing, succeeded: true, endDate: Date(timeIntervalSinceReferenceDate: 1), errorClass: nil))
        state.apply(.init(kind: .importing, succeeded: false, endDate: Date(timeIntervalSinceReferenceDate: 2), errorClass: .quota))
        state.apply(.init(kind: .setup, succeeded: false, endDate: Date(timeIntervalSinceReferenceDate: 3), errorClass: .persistent))
        state.apply(.init(kind: .setup, succeeded: false, endDate: Date(timeIntervalSinceReferenceDate: 4), errorClass: .persistent))
        XCTAssertEqual(state.lastImportSuccess, Date(timeIntervalSinceReferenceDate: 1))
        XCTAssertNil(state.issue)
        XCTAssertNil(state.lastExportSuccess)
    }

    // MARK: Lifetime

    func testTheActivityStartsCleanAndForgetsEverythingWhenTheSessionRetires() {
        let center = NotificationCenter()
        let activity = CloudKitMirroringActivity(center: center)
        XCTAssertFalse(activity.isObserving)
        activity.start()
        XCTAssertTrue(activity.isObserving)
        activity.record(export(false, .quota))
        XCTAssertEqual(activity.state.issue, .quotaExceeded)
        activity.stop()
        XCTAssertFalse(activity.isObserving)
        XCTAssertEqual(activity.state, CloudKitMirroringState(),
                       "Nothing observed for one session or account describes the next")
        activity.record(export(true))
        activity.start()
        XCTAssertEqual(activity.state, CloudKitMirroringState())
        // A notification without an event, or with something else, changes nothing.
        center.post(name: NSPersistentCloudKitContainer.eventChangedNotification, object: nil,
                    userInfo: [NSPersistentCloudKitContainer.eventNotificationUserInfoKey: "not an event"])
        XCTAssertEqual(activity.state, CloudKitMirroringState())
        activity.stop()
    }

    func testTheCopyIsHonestAboutWhereTheRecordsAre() {
        XCTAssertTrue(CloudKitMirroringCopy.quotaDetail.contains("このiPhoneに保存されています"))
        XCTAssertTrue(CloudKitMirroringCopy.persistentFailure.contains("このiPhoneに保存されています"))
        XCTAssertEqual(CloudKitMirroringCopy.lastExport("3分前"), "iCloudへの最終送信：3分前")
        XCTAssertFalse(CloudKitMirroringCopy.lastExport("3分前").contains("完了"),
                       "A send is not a claim that every record is synchronized")
    }
}

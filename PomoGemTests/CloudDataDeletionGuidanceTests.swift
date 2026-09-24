import XCTest
@testable import PomoGem

/// settings-03 / transfer-09. In iCloud mode the reset is refused on purpose,
/// but the refusal may not be the last word: the page it points to must name
/// the routes that still work, using the labels the user will actually see.
final class CloudDataDeletionGuidanceTests: XCTestCase {
    func testTheGuidanceIsOfferedExactlyWhereTheResetIsRefusedForICloud() {
        XCTAssertTrue(ActivityResetAdmissionPolicy.offersCloudDeletionGuidance(in: .cloudKit))
        for mode in [PersistenceLaunchMode.localOnly, .inMemoryPreview, .persistentSimulator] {
            XCTAssertFalse(ActivityResetAdmissionPolicy.offersCloudDeletionGuidance(in: mode), "\(mode)")
            XCTAssertTrue(ActivityResetAdmissionPolicy.permitsUserReset(in: mode), "\(mode)")
        }
        XCTAssertFalse(ActivityResetAdmissionPolicy.permitsUserReset(in: .cloudKit),
                       "The gate itself is unchanged")
        XCTAssertTrue(ActivityResetAdmissionPolicy.cloudResetUnavailableMessage
            .contains("iCloudのリセットは一時的に利用できません"),
            "The real-device UI test pins this substring")
    }

    func testTheStartOverRouteNamesTheControlsSettingsActuallyShows() {
        let text = CloudDataDeletionGuidanceCopy.startOver
        XCTAssertTrue(text.contains("「\(StorageTransferSettingsSection.cloudEntryTitle)」"), text)
        XCTAssertTrue(text.contains("「このiPhoneへ引き継ぐ」"))
        XCTAssertTrue(text.contains("「表示中の記録をリセット」"))
        XCTAssertTrue(text.contains("iCloudの記録は削除されずに残り"),
                      "It must say the iCloud copy survives this route")
    }

    func testTheDeletionRouteIsHonestAboutReachAndIrreversibility() {
        XCTAssertTrue(CloudDataDeletionGuidanceCopy.delete.contains("すべての端末から消え"))
        XCTAssertTrue(CloudDataDeletionGuidanceCopy.delete.contains("元に戻せません"))
        XCTAssertEqual(CloudDataDeletionGuidanceCopy.steps.count, 3)
        XCTAssertTrue(CloudDataDeletionGuidanceCopy.steps[0].contains("すべての端末"),
            "Apps still running elsewhere would re-upload, so they go first")
        XCTAssertTrue(CloudDataDeletionGuidanceCopy.exportNote.contains("読み込めません"),
            "The export is a keepsake, never a restore path")
        for text in [CloudDataDeletionGuidanceCopy.startOver, CloudDataDeletionGuidanceCopy.delete,
                     CloudDataDeletionGuidanceCopy.why] + CloudDataDeletionGuidanceCopy.steps {
            XCTAssertFalse(text.contains("一時的"), "No promise of a timeline: \(text)")
        }
    }
}

import SwiftData
import XCTest
@testable import PomoGem

/// launch-06: a reinstall or a second iPhone in iCloud mode. Finishing the
/// new-user tutorial must not overwrite what the user's other devices
/// already decided.
@MainActor
final class CloudRestoreOnboardingTests: XCTestCase {
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
            FocusTimerDeviceClaim.self,
            RareRewardPendingCommit.self,
            RareRewardLedgerCursor.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    // MARK: - Imported presets

    func testICloudOnboardingLeavesUnselectedImportedPresetsAsTheyArrived() throws {
        var historyReads = 0
        for isArchived in [false, true] {
            let change = OnboardingThemePolicy.builtInPresetChange(
                isSelected: false, isArchived: isArchived, storesInCloud: true
            ) {
                historyReads += 1
                return false
            }
            // Never a tombstone or an archive that would sync back to the
            // devices this preset came from, even with no history imported yet.
            XCTAssertEqual(change, .keep)
        }
        XCTAssertEqual(historyReads, 0, "iCloud mode does not need to inspect history")
    }

    func testSelectedPresetIsShownInEveryMode() {
        for storesInCloud in [false, true] {
            XCTAssertEqual(OnboardingThemePolicy.builtInPresetChange(
                isSelected: true, isArchived: true, storesInCloud: storesInCloud) { false },
                .unarchive)
            XCTAssertEqual(OnboardingThemePolicy.builtInPresetChange(
                isSelected: true, isArchived: false, storesInCloud: storesInCloud) { false },
                .keep)
        }
    }

    func testLocalOnboardingKeepsTheOriginalPresetCleanup() {
        XCTAssertEqual(OnboardingThemePolicy.builtInPresetChange(
            isSelected: false, isArchived: false, storesInCloud: false) { false }, .retire)
        XCTAssertEqual(OnboardingThemePolicy.builtInPresetChange(
            isSelected: false, isArchived: true, storesInCloud: false) { false }, .retire)
        XCTAssertEqual(OnboardingThemePolicy.builtInPresetChange(
            isSelected: false, isArchived: false, storesInCloud: false) { true }, .archive)
        XCTAssertEqual(OnboardingThemePolicy.builtInPresetChange(
            isSelected: false, isArchived: true, storesInCloud: false) { true }, .keep)
    }

    // MARK: - Synced settings

    /// The reported clobber: phone A turned the daily reminder on during its
    /// onboarding (revision 1). Phone B is set up without touching the
    /// switch before A's settings row arrives. At a revision tie reminder-off
    /// wins, so B used to switch A's reminder off on every device.
    func testOnboardingWithoutTheReminderKeepsAnotherDevicesReminder() throws {
        let container = try makeContainer()
        let context = container.mainContext

        try PrefsConsumerPolicy.recordOnboardingCompletion(
            context: context, markers: [], remindersGranted: false,
            rareRewardMode: .off, changedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        try context.save()
        let local = try XCTUnwrap(context.fetch(FetchDescriptor<Prefs>()).first)
        XCTAssertTrue(local.hasCompletedOnboarding)
        XCTAssertEqual(local.reminderEnabledRevision, 0, "An untouched switch is not a choice")
        XCTAssertEqual(local.reminderTimeRevision, 0)

        // Phone A's row, as the import delivers it: its own revision-1 stamp.
        try PrefsSyncPolicy.mutate(.reminderEnabled, in: [], context: context,
                                   writerID: "phone-a", currentEpochID: nil) {
            $0.reminderEnabled = true
        }
        try context.save()

        let rows = try PrefsSyncPolicy.fetchBounded(from: context)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(try PrefsSyncPolicy.resolvedState(in: rows, currentEpochID: nil).reminderEnabled,
                      "Setting up another iPhone must not switch this reminder off")
    }

    func testTheOldUnconditionalStampWouldHaveSwitchedItOff() throws {
        // Pins why the stamp is conditional: the same tie with an explicit
        // "off" from this device resolves to off.
        let container = try makeContainer()
        let context = container.mainContext
        try PrefsSyncPolicy.mutate(.reminderEnabled, in: [], context: context,
                                   writerID: "phone-b", currentEpochID: nil) {
            $0.reminderEnabled = false
        }
        try PrefsSyncPolicy.mutate(.reminderEnabled, in: [], context: context,
                                   writerID: "phone-a", currentEpochID: nil) {
            $0.reminderEnabled = true
        }
        try context.save()
        let rows = try PrefsSyncPolicy.fetchBounded(from: context)
        XCTAssertFalse(try PrefsSyncPolicy.resolvedState(in: rows, currentEpochID: nil).reminderEnabled)
    }

    func testOnboardingWithAGrantedReminderStampsIt() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try PrefsConsumerPolicy.recordOnboardingCompletion(
            context: context, markers: [], remindersGranted: true, rareRewardMode: .off)
        try context.save()
        let rows = try PrefsSyncPolicy.fetchBounded(from: context)
        let state = try PrefsSyncPolicy.resolvedState(in: rows, currentEpochID: nil)
        XCTAssertTrue(state.reminderEnabled)
        XCTAssertEqual(state.reminderHour, Constants.Notification.defaultReminderHour)
        XCTAssertEqual(state.reminderMinute, Constants.Notification.defaultReminderMinute)
        XCTAssertTrue(state.hasCompletedOnboarding)
        XCTAssertNotNil(state.rareRewardModeUpdatedAt, "Informed-choice evidence is still written")
    }
}

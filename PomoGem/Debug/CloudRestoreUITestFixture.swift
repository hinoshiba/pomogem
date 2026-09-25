#if DEBUG
import Foundation
import SwiftData

/// launch-06. Exercises the shipping first-run gate as a returning iCloud
/// user sees it, inside the explicit in-memory UI-test store: RootView treats
/// the session as a restore from an account that holds earlier records. No
/// account, container or CloudKit call exists in the process.
enum CloudRestoreUITestFixture {
    private static let environmentKey = "POMOGEM_UI_TEST_CLOUD_RESTORE"

    enum Scenario: String {
        /// Nothing arrives: the screen waits, and 「新しく始める」 is the way on.
        case waiting
        /// Another device's finished onboarding arrives a few seconds in, as
        /// an import would deliver it, so the jar must open on its own.
        case arrives
    }

    static var scenario: Scenario? {
        guard LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess,
              LocalPreviewLaunchPolicy.persistenceModeForCurrentProcess == .inMemoryPreview,
              let value = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
        return Scenario(rawValue: value)
    }

    static let arrivalDelay: Duration = .seconds(4)

    /// Writes what an import of another device's settings row carries: the
    /// onboarding flag. The auto-exit under test reads only that flag.
    @MainActor
    static func deliverOtherDevicesOnboarding(context: ModelContext) throws {
        let row = try PrefsSyncPolicy.ensureWriterRow(
            context: context,
            writerID: "ui-test-other-iphone",
            currentEpochID: nil
        )
        row.hasCompletedOnboarding = true
        try context.save()
    }
}
#endif

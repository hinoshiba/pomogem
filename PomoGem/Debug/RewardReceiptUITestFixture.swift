#if DEBUG && targetEnvironment(simulator)
import Foundation
import SwiftData

/// UI tests only. Seeds one reward receipt into a local preview launch, so a
/// UI test can see what Home does with a receipt whose gem can never land
/// (`HomeProjectionPolicy.orphanedPendingRewardReceiptIDs`). Production
/// reaches that state only when the dataset under a receipt is replaced or
/// purged; a UI test cannot do either.
///
/// It runs once the new in-memory store exists and after
/// `UITestLocalStateIsolation` has cleared the queues, before Home reads them,
/// so the seeded receipt is the only one. Compiled out of Release and device
/// builds; CI rejects a Release bundle that contains the environment key.
@MainActor
enum RewardReceiptUITestFixture {
    static let environmentKey = "POMOGEM_UI_TEST_REWARD_RECEIPT"

    enum Scenario: String {
        /// Waiting for its gem to land; no StudySession row has its ID.
        case landingWithoutSession = "landing-without-session"
        /// Its card waits for 「閉じる」; no StudySession row has its ID.
        case cardWithoutSession = "card-without-session"
        /// Waiting for its gem to land. Its row exists, in an epoch whose
        /// reset marker has not arrived, so it does not resolve yet.
        case landingWithSessionInAnotherEpoch = "landing-with-session-in-another-epoch"
    }

    static func seedIfRequested(
        in container: ModelContainer,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard LocalPreviewLaunchPolicy.isUITestMode(
                environment: environment,
                isDebugBuild: true
              ),
              let rawValue = environment[environmentKey],
              let scenario = Scenario(rawValue: rawValue)
        else { return }
        let id = UUID()
        let endedAt = Date.now
        let subjectName = "英語"
        if scenario == .landingWithSessionInAnotherEpoch {
            let context = ModelContext(container)
            context.insert(StudySession(
                id: id,
                startAt: endedAt.addingTimeInterval(-1_500),
                endAt: endedAt,
                seconds: 1_500,
                source: .timer,
                deviceDayKey: "ui-test-reward-receipt",
                subjectNameSnapshot: subjectName,
                subjectColorHexSnapshot: Constants.Color.english,
                dataEpochID: UUID()
            ))
            do {
                try context.save()
            } catch {
                assertionFailure("Could not seed the receipt's session: \(error)")
            }
        }
        PendingRewardReceiptStore.insert(PendingRewardReceipt(
            id: id,
            createdAt: endedAt,
            breakMinutes: 5,
            grams: 250,
            subjectName: subjectName,
            colorHex: Constants.Color.english,
            weeklyCompletionCount: 1,
            weeklyStudyGrams: 250,
            kind: .normal,
            totalPebbleCount: 1,
            totalStudyGrams: 250,
            projectionIsLowerBound: false,
            dropPhase: scenario == .cardWithoutSession
                ? .awaitingAcknowledgement
                : .awaitingLanding
        ))
    }
}
#endif

#if DEBUG && targetEnvironment(simulator)
import Foundation

/// settings-05. UI tests only. StoreKit cannot approve an Ask to Buy request
/// in the Simulator run, so two seconds after a focus timer opens this records
/// what `Transaction.updates` would when an approval lands mid-focus: an open
/// wait answered by a grant, which owes the person one notice. It grants no
/// entitlement, writes nothing to disk, fires at most once per process, and is
/// compiled out of Release and device builds.
@MainActor
enum ApprovalArrivalUITestFixture {
    static let environmentKey = "POMOGEM_UI_TEST_APPROVAL_ARRIVES_DURING_FOCUS"

    private static var hasArrived = false

    static func focusPresentationChanged(
        isActive: Bool,
        purchase: PurchaseManager,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard isActive, !hasArrived,
              environment[environmentKey] == "1",
              LocalPreviewLaunchPolicy.isUITestMode(environment: environment, isDebugBuild: true)
        else { return }
        hasArrived = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            purchase.recordApprovalArrivalForUITest()
        }
    }
}
#endif

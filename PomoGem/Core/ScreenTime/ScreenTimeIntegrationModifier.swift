import FamilyControls
import SwiftData
import SwiftUI

/// Runs only inside the admitted persistence host. Collection itself belongs to
/// the OS extension; this task transfers confirmed chunks while the UI is active.
struct ScreenTimeIntegrationModifier: ViewModifier {
    let isReady: Bool
    let timerPresented: Bool
    let contextKey: String
    let dataEpochID: UUID?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var controller: ScreenTimeController
    @State private var purchase = PurchaseManager.shared
    @State private var importError: String?
    @State private var lastPresentedError: String?
    @State private var lastBoundKey: String?
    @State private var lastMonitoringKey: String?

    /// Production always uses the shared controller; the parameter exists so a
    /// mount/unmount regression test can drive a temporary ledger instead of
    /// the App Group one.
    @MainActor
    init(
        isReady: Bool,
        timerPresented: Bool,
        contextKey: String,
        dataEpochID: UUID?,
        controller: ScreenTimeController? = nil
    ) {
        self.isReady = isReady
        self.timerPresented = timerPresented
        self.contextKey = contextKey
        self.dataEpochID = dataEpochID
        _controller = ObservedObject(wrappedValue: controller ?? .shared)
    }

    private var isCurrentOwner: Bool {
        contextKey == AccountScopedLocalState.defaultsKey(base: "screen-time-owner")
    }
    private var taskKey: String {
        "\(isReady):\(scenePhase == .active):\(timerPresented):\(contextKey):\(dataEpochID?.uuidString ?? "legacy")"
    }
    private var timerRunning: Bool {
        timerPresented || FocusPersistence.load().map {
            $0.dataEpochID == dataEpochID && $0.engine.snapshot(at: .now).phase.isRunning
        } == true
    }

    func body(content: Content) -> some View {
        content
            .task(id: taskKey) {
                guard isReady, scenePhase == .active else { return }
                await refresh(forceReconcile: true)
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(3)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    await refresh()
                }
            }
            .onChange(of: timerPresented) { _, _ in
                guard isReady, isCurrentOwner else { return }
                controller.reconcileInBackground(
                    contextKey: contextKey, dataEpochID: dataEpochID,
                    isPro: purchase.isPro, timerRunning: timerRunning
                )
            }
            .onChange(of: purchase.isPro) { _, _ in
                guard isReady, isCurrentOwner else { return }
                controller.reconcileInBackground(
                    contextKey: contextKey, dataEpochID: dataEpochID,
                    isPro: purchase.isPro, timerRunning: timerRunning
                )
            }
            // Deliberately no `.onDisappear` retirement: PomoGemApp drops the
            // cloud session on every ordinary backgrounding, which removes this
            // view. Collection belongs to the OS extension and must continue
            // while the app is not running. A changed owner or activity epoch
            // is retired by bindContext, by the owner guard in refresh(), by
            // the readiness change below, and by reset / complete deletion.
            .onChange(of: isReady) { _, ready in
                if !ready { controller.suspendForContextRetirement(contextKey: contextKey, dataEpochID: dataEpochID) }
            }
            .alert("Screen Timeの記録を保留しています", isPresented: Binding(
                get: { importError != nil }, set: { if !$0 { importError = nil } }
            )) {
                Button("閉じる", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
    }

    @MainActor
    private var canContinueRefresh: Bool {
        !Task.isCancelled && isCurrentOwner
            && controller.isBound(contextKey: contextKey, dataEpochID: dataEpochID)
    }

    @MainActor
    private func refresh(forceReconcile: Bool = false) async {
        guard isReady, scenePhase == .active else { return }
        guard isCurrentOwner else {
            controller.suspendForContextRetirement(contextKey: contextKey, dataEpochID: dataEpochID)
            return
        }
        do {
            let bindingKey = "\(contextKey):\(dataEpochID?.uuidString ?? "legacy")"
            if forceReconcile || lastBoundKey != bindingKey {
                try await controller.bindContext(contextKey: contextKey, dataEpochID: dataEpochID)
                guard canContinueRefresh else { return }
                lastBoundKey = bindingKey
            } else {
                controller.reload()
            }
            guard canContinueRefresh else { return }
            try await retireDeletedLearningThemeIfNeeded()
            guard canContinueRefresh else { return }
            let monitoringKey = "\(bindingKey):\(purchase.isPro):\(timerRunning):\(controller.authorizationGranted):\(FairnessPolicy.deviceDayKey(for: .now))"
            if forceReconcile || lastMonitoringKey != monitoringKey {
                await controller.reconcile(isPro: purchase.isPro, timerRunning: timerRunning)
                guard canContinueRefresh else { return }
                lastMonitoringKey = monitoringKey
            }
            guard canContinueRefresh else { return }
            // Keep the saved animation backlog bounded, while every usage
            // receipt remains durable in the extension until acknowledged.
            let freeSlots = ScreenTimeGemDropStore.maximumCount - ScreenTimeGemDropStore.load().count
            guard freeSlots > 0 else { return }
            let receipts = try controller.store.pendingLearningReceipts(limit: min(32, freeSlots))
            guard !receipts.isEmpty else { return }
            let imports = receipts.map {
                ScreenTimeLearningImport(id: $0.id, themeID: $0.themeID,
                    startedAt: $0.startedAt, endedAt: $0.endedAt,
                    contextKey: $0.contextKey, dataEpochID: $0.dataEpochID)
            }
            let inserted = try ScreenTimeImportCoordinator.insert(
                imports, container: modelContext.container,
                contextKey: contextKey, dataEpochID: dataEpochID
            )
            ScreenTimeGemDropStore.append(inserted)
            try controller.store.acknowledgeLearningReceipts(ids: receipts.map(\.id))
            controller.reload()
            lastPresentedError = nil
        } catch {
            // Missing signing/App Group is explained in the opt-in settings,
            // never an alert at ordinary launch for users who did not enable it.
            guard !Task.isCancelled, isCurrentOwner,
                  controller.isBound(contextKey: contextKey, dataEpochID: dataEpochID),
                  controller.configuration.enabled else { return }
            if lastPresentedError != error.localizedDescription {
                lastPresentedError = error.localizedDescription
                importError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func retireDeletedLearningThemeIfNeeded() async throws {
        guard controller.authorizationGranted,
              let themeID = controller.configuration.themeID,
              !controller.configuration.learningSelection.applicationTokens.isEmpty else { return }
        var descriptor = FetchDescriptor<Subject>(predicate: #Predicate { $0.id == themeID })
        descriptor.fetchLimit = SubjectSyncPolicy.maximumPhysicalRows + 1
        let candidates = try modelContext.fetch(descriptor)
        guard candidates.count <= SubjectSyncPolicy.maximumPhysicalRows else {
            throw ScreenTimeImportCoordinator.ImportError.invalidReceipt
        }
        guard SubjectSyncPolicy.presentationSubjects(from: candidates).isEmpty else { return }
        var configuration = controller.configuration
        configuration.learningSelection = FamilyActivitySelection(includeEntireCategory: false)
        configuration.themeID = nil
        if configuration.distractionSelection.applicationTokens.isEmpty { configuration.enabled = false }
        // Existing receipts retain the original theme ID; future use is no
        // longer silently attributed to a theme the user has removed.
        try await controller.save(configuration: configuration, isPro: purchase.isPro)
    }
}

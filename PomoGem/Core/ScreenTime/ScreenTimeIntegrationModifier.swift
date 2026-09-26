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
    /// Optional so a host without the app's router (a unit-test mount) still
    /// works; RootView always provides it.
    @Environment(AppRouter.self) private var router: AppRouter?
    @ObservedObject private var controller: ScreenTimeController
    @State private var purchase = PurchaseManager.shared
    @State private var importError: String?
    @State private var lastPresentedError: String?
    @State private var lastBoundKey: String?
    @State private var lastMonitoringKey: String?
    /// The hold last handed over because the saved timer changed. Saves that
    /// leave it as it was (a notification witness, a recovery re-save) need
    /// no ledger write.
    @State private var lastNotifiedLearningPause: ScreenTimeLearningPause?

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
    /// The encoding rewrite is independent of timers and reset generations:
    /// it re-runs only when the admitted store or its activation changes.
    private var legacyEncodingTaskKey: String {
        "\(isReady):\(scenePhase == .active):\(contextKey)"
    }
    /// nil until StoreKit has answered in this process. See
    /// `ScreenTimeController.reconcile(isPro:learningPause:now:)`: an unknown
    /// entitlement must never retire a Pro user's learning run.
    private var resolvedIsPro: Bool? {
        purchase.hasResolvedEntitlements ? purchase.isPro : nil
    }

    /// Read from the saved timer itself, never from whether the Focus cover is
    /// on screen: the cover stays up on the completion screen, and holding the
    /// learning lane until the user dismissed it (with PomoGem often closed
    /// by then) is what kept study-app time from counting for days.
    private func currentLearningPause(at now: Date = .now) -> ScreenTimeLearningPause {
        ScreenTimeTimerHold.learningPause(for: FocusPersistence.load(), dataEpochID: dataEpochID, at: now)
    }

    func body(content: Content) -> some View {
        content
            .task(id: legacyEncodingTaskKey) {
                await normalizeLegacySourceEncodingIfNeeded()
            }
            .task(id: taskKey) {
                guard isReady, scenePhase == .active else { return }
                // `taskKey` carries `scenePhase == .active`, so this loop is
                // torn down on every deactivation while the controller is a
                // singleton that survives it. Announce the new observation
                // session: the settling window must measure continuous
                // foreground samples, never the gap the app spent away.
                controller.beginAuthorizationObservation()
                await refresh(forceReconcile: true)
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(3)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    await refresh()
                }
            }
            .onChange(of: timerPresented) { _, _ in
                reconcileNow()
            }
            // Every start, pause, resume, break, completion and stop saves or
            // clears the timer, so the ledger learns the new hold — with its
            // end date — in the same turn. The three-second loop alone left a
            // window in which a user who started a focus and left the app at
            // once kept the old hold.
            .onReceive(NotificationCenter.default.publisher(for: FocusPersistence.didChange)) { _ in
                let pause = currentLearningPause()
                guard pause != lastNotifiedLearningPause else { return }
                lastNotifiedLearningPause = pause
                reconcileNow(learningPause: pause)
            }
            .onChange(of: resolvedIsPro) { _, _ in
                // Also fires when StoreKit first answers, which is when a gate
                // held open for an unknown entitlement may finally close.
                reconcileNow()
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
            .alert(String(localized: "スクリーンタイムの記録を保留しています", table: "ScreenTime",
                          comment: "Alert title: imported Screen Time records are on hold"), isPresented: Binding(
                get: { importError != nil }, set: { if !$0 { importError = nil } }
            )) {
                Button("閉じる", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
    }

    /// Runs regardless of whether Screen Time is set up on this device: a
    /// store can hold pre-release rows from an earlier configuration, or
    /// receive them late through CloudKit, and the rewrite must not wait for
    /// the user to re-enable the feature. Each activation costs one count
    /// query; the bounded window is scanned only when the count changed or
    /// the last clean pass is a day old (`ScreenTimeLegacyEncodingCleanPass`).
    @MainActor
    private func normalizeLegacySourceEncodingIfNeeded() async {
        guard isReady, scenePhase == .active, isCurrentOwner else { return }
        do {
            _ = try await ScreenTimeImportCoordinator.normalizeLegacySourceEncodingIfChanged(
                container: modelContext.container,
                ownerKey: contextKey,
                isStillOwner: { isCurrentOwner }
            )
        } catch {
            // Retried on the next activation. The rows stay readable here;
            // nothing is shown because the user has nothing to act on.
        }
    }

    @MainActor
    private func reconcileNow(learningPause: ScreenTimeLearningPause? = nil) {
        guard isReady, isCurrentOwner else { return }
        controller.reconcileInBackground(
            contextKey: contextKey, dataEpochID: dataEpochID,
            isPro: resolvedIsPro, learningPause: learningPause ?? currentLearningPause()
        )
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
            // A revocation performed while the app was not running reads as a
            // plain .notDetermined status with no transition to react to, so
            // this pass — not reconcile — is what notices it.
            await controller.invalidateAuthorizationIfRevoked()
            guard canContinueRefresh else { return }
            try await retireDeletedLearningThemeIfNeeded()
            guard canContinueRefresh else { return }
            let learningPause = currentLearningPause()
            let monitoringKey = "\(bindingKey):\(resolvedIsPro.map(String.init) ?? "unresolved"):\(ScreenTimeTimerHold.key(learningPause)):\(controller.authorizationGranted):\(FairnessPolicy.deviceDayKey(for: .now))"
            if forceReconcile || lastMonitoringKey != monitoringKey {
                await controller.reconcile(isPro: resolvedIsPro, learningPause: learningPause)
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
        let outcome = await controller.retireLearningSelection(ofRemovedTheme: themeID, isPro: purchase.isPro)
        // Clearing the selection is documented; doing it without a word read
        // as a broken feature. Say it once the study apps are gone, even when
        // registering what is left then failed: nothing retries after that.
        if outcome.cleared {
            router?.showToast(
                String(localized: "記録先のテーマが削除されたため、勉強アプリの記録を止めました", table: "ScreenTime",
                       comment: "Toast: the Screen Time destination theme was deleted, so study-app recording stopped"),
                symbol: "exclamationmark.triangle"
            )
        }
        if let failure = outcome.failure { throw failure }
    }
}

/// Which timer state holds the Screen Time learning lane, and until when.
///
/// A running focus or in-timer break holds it until the phase's end date; a
/// paused timer holds it with no end; anything else — including the
/// completion screen and a phase whose end has passed but that the app has
/// not advanced yet — holds nothing. Breaks timed from Home (`BreakTimerView`)
/// have their own persistence and never hold the lane, as before.
enum ScreenTimeTimerHold {
    static func learningPause(
        for envelope: FocusRecoveryEnvelope?,
        dataEpochID: UUID?,
        at now: Date
    ) -> ScreenTimeLearningPause {
        // A timer frozen under an earlier reset generation is being retired,
        // not run, so it cannot hold the new generation's lane.
        guard let envelope, envelope.dataEpochID == dataEpochID,
              envelope.pendingCompletion == nil else { return .none }
        switch envelope.engine.phase {
        case .focusing, .shortBreak, .longBreak:
            guard let end = envelope.engine.endDate else { return .none }
            return ScreenTimeLearningPause.until(end).normalized(at: now)
        case .paused:
            return .indefinite
        case .idle, .focusCompleted, .breakCompleted:
            return .none
        }
    }

    /// Stable text for the refresh loop's change key.
    static func key(_ pause: ScreenTimeLearningPause) -> String {
        switch pause {
        case .none: "none"
        case let .until(end): "until-\(end.timeIntervalSinceReferenceDate)"
        case .indefinite: "indefinite"
        }
    }
}

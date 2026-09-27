import Foundation

extension FocusEndAlarmOwner {
    /// The phase end this iPhone's saved timer owns, for the launch and
    /// activation reconcile. A running focus has its end; a paused one has
    /// none (a stale alarm must go); a focus waiting to be saved
    /// (`pendingCompletion`) owns nothing new, but reconcile still keeps the
    /// alarm that rang for it as the delivery witness. Otherwise a saved
    /// break owns its end.
    static func current(
        focus: FocusRecoveryEnvelope?,
        rest: BreakRecoveryEnvelope?
    ) -> FocusEndAlarmOwner? {
        if let focus,
           focus.pendingCompletion == nil,
           let sessionID = focus.engine.currentSessionID {
            switch focus.engine.phase {
            case .focusing:
                return FocusEndAlarmOwner(
                    sessionID: sessionID,
                    phase: .focus,
                    endDate: focus.engine.endDate
                )
            case .paused:
                return FocusEndAlarmOwner(sessionID: sessionID, phase: .focus, endDate: nil)
            default:
                break
            }
        }
        if let rest {
            return FocusEndAlarmOwner(sessionID: rest.id, phase: .breakTime, endDate: rest.endDate)
        }
        return nil
    }
}

/// F5 upkeep the app host runs outside any timer screen.
@MainActor
enum FocusEndAlarmMaintenance {
    private static var didMaintainFilesThisProcess = false

    /// Launch and every foreground activation, inside the admitted
    /// persistence host (the saved timer's key names the active account).
    /// Cancels orphan and stale alarms (never a ringing one) and retries
    /// failed cancels. It never books: when the owner needs an alarm
    /// (`ownerNeedsBooking`), the timer screen books it through
    /// `TimerEndAnnouncementBooker` (part 2).
    @discardableResult
    static func reconcileOnActivation(
        scheduler: FocusEndAlarmScheduler? = nil,
        focus: FocusRecoveryEnvelope? = FocusPersistence.load(),
        rest: BreakRecoveryEnvelope? = FocusPersistence.loadBreak()
    ) -> FocusEndAlarmReconciliation {
        (scheduler ?? .shared).reconcile(
            owner: FocusEndAlarmOwner.current(focus: focus, rest: rest)
        )
    }

    /// Once per process: removes ringtones an older version wrote, and
    /// renders the chosen sound ahead of the first end (its in-app loop and
    /// the notification file for the chosen strength), all off the main
    /// thread.
    static func maintainSoundFilesOncePerProcess(
        preferences: AlarmPreferences = AlarmPreferences()
    ) {
        guard !didMaintainFilesThisProcess else { return }
        didMaintainFilesThisProcess = true
        Task.detached(priority: .utility) {
            _ = try? AlarmSoundLibrary.removeStaleRingtoneFiles()
        }
        // Only a sound chosen on this iPhone is known here; a synced chime
        // renders in a few milliseconds when its first end needs it.
        if let choice = preferences.storedSound {
            prepare(choice, strength: preferences.strength)
        }
    }

    /// A new sound or strength was chosen in Settings.
    static func prepare(_ choice: AlarmSoundChoice, strength: AlarmStrength) {
        SoundSynth.shared.prepareAlarmSound(choice)
        let kind: AlarmSoundFileKind? = strength.usesLongNotificationSound
            ? .ringtone
            : (choice.synthesizedSound != nil ? .cue : nil)
        guard let kind else { return }
        Task { @MainActor in
            _ = try? await AlarmSoundLibrary.preparedFile(kind, for: choice)
        }
    }

    /// Complete data deletion: nothing of this app may ring afterwards, and
    /// no rendered sound stays on this iPhone. The `alarm.` defaults go with
    /// the standard domain.
    static func eraseForCompleteDataDeletion(
        scheduler: FocusEndAlarmScheduler? = nil,
        libraryDirectory: URL? = nil
    ) {
        (scheduler ?? .shared).cancelAll()
        try? AlarmSoundLibrary.removeAllRingtoneFiles(libraryDirectory: libraryDirectory)
    }
}

#if DEBUG
/// UI tests never meet iOS's Alarms prompt: the app answers its own request
/// (`POMOGEM_UI_TEST_ALARMKIT` = `granted`, `denied` or `unsupported`;
/// default `denied`) and books nothing.
@MainActor
final class UITestFocusEndAlarmClient: FocusEndAlarmClient {
    static let environmentKey = "POMOGEM_UI_TEST_ALARMKIT"

    struct Unavailable: Error {}

    private let answer: AlarmKitAuthorization
    private(set) var authorization: AlarmKitAuthorization

    init(environment: [String: String]) {
        switch environment[Self.environmentKey] {
        case "granted": answer = .authorized
        case "unsupported": answer = .unsupported
        default: answer = .denied
        }
        authorization = answer == .unsupported ? .unsupported : .notDetermined
    }

    func requestAuthorization() async -> AlarmKitAuthorization {
        authorization = answer
        return answer
    }

    func schedule(_ request: FocusEndAlarmRequest) async throws { throw Unavailable() }
    func cancel(id: UUID) throws {}
    func stop(id: UUID) throws {}
    func alarms() throws -> [FocusEndAlarmSnapshot] { [] }
}

extension AlarmPreferences {
    /// Like `FocusLeavePreferences.startUITestProcessFromItsDefault`: a UI
    /// test that picks a sound or strength writes the shared Simulator's
    /// persistent domain, so every UI-test process starts from the defaults.
    static func startUITestProcessFromItsDefault(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard LocalPreviewLaunchPolicy.isUITestMode(environment: environment, isDebugBuild: true)
        else { return }
        AlarmPreferences(defaults: defaults).removeAll()
    }
}
#endif

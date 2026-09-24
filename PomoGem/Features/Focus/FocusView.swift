import Combine
import SwiftData
import SwiftUI
import UIKit

enum FocusCompletionPersistenceResult: Equatable, Sendable {
    case inserted(PebbleKind)
    case alreadyMaterialized
    case cancelledBeforeCompletion
    case awaitingMaterializedCompletion
    case discardedByReset
    case rejectedOwnership

    /// A remote owner can still be materializing the same logical completion.
    /// Only outcomes that prove a StudySession exists may retire recovery data.
    var mayRetireRecovery: Bool {
        switch self {
        case .inserted, .alreadyMaterialized, .cancelledBeforeCompletion,
             .discardedByReset:
            true
        case .awaitingMaterializedCompletion, .rejectedOwnership:
            false
        }
    }
}

private enum ExplicitFocusActivityState: Equatable {
    case focusing(endDate: Date)
    case paused(remainingSeconds: Int)
}

/// Decides which in-app cue an elapsed focus or break timer still needs.
/// A persisted delivery date is trusted only while wall and monotonic clocks
/// still agree; a relative OS notification may remain pending after a manual
/// wall-clock jump.
enum TimerCompletionForegroundFeedbackPolicy {
    /// The in-app cue for one resolved completion.
    enum Cue: Equatable, Sendable {
        /// The timer ended while the app was on screen. Repeat the chosen
        /// sound and haptic until the person stops it, like an alarm clock:
        /// they may have stepped away from a phone kept awake on the desk.
        case repeating
        /// The person has just brought the app back, nothing else announced
        /// the end, and it ended moments ago. Mark the moment once.
        case single
        /// A notification already announced the end, or the person returned
        /// long after it. They are looking at the screen, so go straight to
        /// the saved result without any cue.
        case none
    }

    /// A return within this window still counts as "at the end" for the
    /// single cue. Later returns are old news and stay silent.
    static let lateReturnGrace: TimeInterval = 60

    static func notificationMayHaveDelivered(
        isAuthorized: Bool,
        expectedDeliveryDate: Date?,
        now: Date
    ) -> Bool {
        isAuthorized
            && (expectedDeliveryDate ?? .distantFuture) <= now
    }

    /// A repeating alarm exists to reach someone who is not looking at the
    /// screen. An app only becomes active again because the person brought
    /// it forward, so a completion resolved on a return or a recovery never
    /// loops: it is either marked once or shown silently.
    static func cue(
        recoveredAfterExpiration: Bool,
        returnedFromBackground: Bool,
        notificationMayHaveDelivered: Bool,
        endedAt: Date,
        now: Date
    ) -> Cue {
        guard recoveredAfterExpiration || returnedFromBackground else {
            return .repeating
        }
        guard !notificationMayHaveDelivered else { return .none }
        let elapsed = now.timeIntervalSince(endedAt)
        guard elapsed.isFinite, elapsed <= lateReturnGrace else { return .none }
        return .single
    }

    static func notificationTimingIsTrustworthy(
        source: SessionSource,
        clockAnchor: ClockAnchor?,
        now: Date,
        uptime: TimeInterval
    ) -> Bool {
        guard source == .timer,
              let clockAnchor,
              case let .valid(drift) = FairnessPolicy.clockIntegrity(
                from: clockAnchor,
                completionDate: now,
                completionUptime: uptime
              ) else { return false }
        return drift <= IntegrationConstants.notificationClockDriftTolerance
    }
}

/// Constructs the only StudySession shape written while the optional rare
/// reward feature is disabled for release. Keeping this factory independent of
/// SwiftUI makes the shipping invariant directly unit-testable.
enum FocusCompletionSessionFactory {
    static func normalSession(
        completion: PomodoroCompletion,
        subject: Subject?,
        subjectSnapshot: FocusSubjectSnapshot,
        dataEpochID: UUID?
    ) -> StudySession {
        let persistedStartAt: Date
        let persistedSeconds: Int
        let persistedGrams: Int
#if DEBUG
        let demoElapsed = completion.endedAt.timeIntervalSince(
            completion.startedAt
        )
        let hasCanonicalDemoPayload: Bool = {
            guard case .demo = completion.duration else { return false }
            return completion.seconds == Constants.Timer.demoSeconds
                && completion.grams == Constants.Mass.measuredPebbleGrams
                && (completion.source == .timer
                    || completion.source == .timerDemoted)
                && completion.startedAt.timeIntervalSinceReferenceDate.isFinite
                && completion.endedAt.timeIntervalSinceReferenceDate.isFinite
                && demoElapsed.isFinite
                && demoElapsed >= TimeInterval(Constants.Timer.demoSeconds)
        }()
        if hasCanonicalDemoPayload {
            // The accelerated 12-second UI-test timer is not a shipping
            // activity shape. Persist one canonical 25-minute completion so
            // Debug end-to-end tests exercise the same integrity boundary,
            // projections, and reward flow as a real free timer.
            persistedSeconds = Constants.Timer.twentyFiveMinutes
                * Constants.Timer.secondsPerMinute
            persistedGrams = StudySession.grams(for: persistedSeconds)
            persistedStartAt = completion.endedAt.addingTimeInterval(
                -TimeInterval(persistedSeconds)
            )
        } else {
            persistedStartAt = completion.startedAt
            persistedSeconds = completion.seconds
            persistedGrams = completion.grams
        }
#else
        persistedStartAt = completion.startedAt
        persistedSeconds = completion.seconds
        persistedGrams = completion.grams
#endif

        return StudySession(
            id: completion.sessionID,
            subject: subject,
            startAt: persistedStartAt,
            endAt: completion.endedAt,
            seconds: persistedSeconds,
            source: completion.source,
            pebbleKind: .normal,
            grams: persistedGrams,
            deviceDayKey: FairnessPolicy.deviceDayKey(for: completion.endedAt),
            subjectNameSnapshot: subjectSnapshot.name,
            subjectColorHexSnapshot: subjectSnapshot.colorHex,
            subjectIDSnapshot: subjectSnapshot.id,
            rareRewardRuleVersion: nil,
            rareRewardParticipated: nil,
            rareRewardCreditedGrams: nil,
            rareRewardOutcomesRawValue: nil,
            dataEpochID: dataEpochID
        )
    }
}

struct FocusView: View {
    private let subject: Subject?
    private let subjectSnapshot: FocusSubjectSnapshot
    private let recoveryOrigin: FocusRecoveryOrigin
    private let allowsLocalNotifications: Bool
    private let deviceID: String
    private let preparedSessionID: UUID?
    let duration: PomodoroDuration

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.pomogemReduceMotionOverride) private var reduceMotionOverride
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppRouter.self) private var router
    @Query private var preferences: [Prefs]
    @Query private var gachaStates: [GachaState]
    @Query private var syncedFocusTimers: [SyncedFocusTimer]
    @Query private var currentSessionCompletedTimers: [SyncedFocusTimer]
    @Query private var currentSessionCancellationTimers: [SyncedFocusTimer]
    @Query private var currentSessionStudySessions: [StudySession]
    @Query private var focusDeviceClaims: [FocusTimerDeviceClaim]
    @Query private var activityResetMarkers: [ActivityResetMarker]

    @State private var engine: PomodoroEngine
    @State private var orientationSessionID = UUID()
    @State private var displayNow = Date.now
    @State private var didStart = false
    @State private var didActivate = false
    @State private var didSignalCompletion = false
    @State private var completionAlert = TimerCompletionAlertController.shared
    @State private var completionAlertWasAcknowledged = false
    @State private var completionPersistenceSucceeded = false
    @State private var isFinishingCompletion = false
    @State private var clockAnchor: ClockAnchor?
    @State private var completion: CompletedDrop?
    @State private var pendingCompletion: PomodoroCompletion?
    @State private var completionSaveError: String?
    @State private var completionWasRejectedForOwnership = false
    @State private var isCommittingCompletion = false
    @State private var breakFinished = false
    @State private var showGiveUpConfirmation = false
    @State private var fairnessNotice = false
    @State private var setupErrorMessage: String?
    @State private var operationErrorMessage: String?
    @State private var rareRewardChoice: RareRewardMode?
    @State private var rareRewardChoiceError: String?
    @State private var isSavingRareRewardChoice = false
    @State private var dataEpochID: UUID?
    @State private var notifications = NotificationManager.shared
    @State private var notificationScheduleState: FocusNotificationScheduleState = .idle
    @State private var notificationScheduleGeneration: UInt64 = 0
    @State private var didEnterBackgroundSinceLastActive = false
    @State private var isAwaitingRecoveryActivation = false
    @State private var scheduledCompletionNotificationDeliveryDate: Date? = nil
    @State private var notificationAuthorizationIsCurrent = false
    @State private var notificationAuthorizationRefreshGeneration: UInt64 = 0
    @State private var viewLifecycleGeneration: UInt64 = 0
    @State private var isViewActive = false
    @AccessibilityFocusState private var completionSaveRetryFocused: Bool

    private let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    /// `sessionID` must be owned by the presenting item, not created here.
    /// SwiftUI re-runs this initializer whenever Home re-renders the cover, and
    /// the session-scoped queries below adopt each new descriptor while the
    /// `@State` engine keeps the first ID. A per-init UUID would silently point
    /// ownership, handoff and cancellation queries at a session with no rows.
    init(
        subject: Subject,
        duration: PomodoroDuration,
        sessionID: UUID,
        dataEpochID: UUID? = nil
    ) {
        self.subject = subject
        self.subjectSnapshot = FocusSubjectSnapshot(subject: subject)
        self.recoveryOrigin = .local
        self.allowsLocalNotifications = true
        self.deviceID = FocusDeviceIdentity.current()
        self.preparedSessionID = sessionID
        self.duration = duration
        _engine = State(initialValue: PomodoroEngine(selectedDuration: duration))
        _dataEpochID = State(initialValue: dataEpochID)
        _preferences = Query(Self.preferencesDescriptor())
        _gachaStates = Query(Self.gachaDescriptor())
        _syncedFocusTimers = Query(Self.timerDescriptor(
            sessionID: sessionID,
            dataEpochID: dataEpochID
        ))
        _currentSessionCompletedTimers = Query(Self.completedTimerDescriptor(
            sessionID: sessionID,
            dataEpochID: dataEpochID
        ))
        _currentSessionCancellationTimers = Query(Self.cancellationTimerDescriptor(
            sessionID: sessionID,
            dataEpochID: dataEpochID
        ))
        _currentSessionStudySessions = Query(Self.studySessionDescriptor(
            sessionID: sessionID,
            dataEpochID: dataEpochID
        ))
        _focusDeviceClaims = Query(Self.claimDescriptor(
            sessionID: sessionID,
            dataEpochID: dataEpochID
        ))
        _activityResetMarkers = Query(Self.resetMarkerDescriptor())
    }

    init(recovery request: RecoveredFocusRequest) {
        subject = request.subject
        subjectSnapshot = request.subjectSnapshot
        recoveryOrigin = request.origin
        allowsLocalNotifications = request.allowsLocalNotifications
        deviceID = FocusDeviceIdentity.current()
        duration = request.engine.selectedDuration
        _engine = State(initialValue: request.engine)
        _didStart = State(initialValue: true)
        _clockAnchor = State(initialValue: request.clockAnchor)
        _pendingCompletion = State(initialValue: request.pendingCompletion)
        _dataEpochID = State(initialValue: request.dataEpochID)
        _didSignalCompletion = State(initialValue: request.pendingCompletion != nil)
        _completionAlertWasAcknowledged = State(
            initialValue: request.pendingCompletion.map {
                TimerCompletionAlertAcknowledgementStore.contains(
                    sessionID: $0.sessionID
                )
            } ?? false
        )
        _isAwaitingRecoveryActivation = State(initialValue: true)
        _scheduledCompletionNotificationDeliveryDate = State(
            initialValue: request.scheduledCompletionNotificationDeliveryDate
        )
        _fairnessNotice = State(initialValue: request.engine.currentSource == .timerDemoted)
        let sessionID = request.pendingCompletion?.sessionID
            ?? request.engine.currentSessionID
        preparedSessionID = sessionID
        _preferences = Query(Self.preferencesDescriptor())
        _gachaStates = Query(Self.gachaDescriptor())
        _syncedFocusTimers = Query(Self.timerDescriptor(
            sessionID: sessionID,
            dataEpochID: request.dataEpochID
        ))
        _currentSessionCompletedTimers = Query(Self.completedTimerDescriptor(
            sessionID: sessionID,
            dataEpochID: request.dataEpochID
        ))
        _currentSessionCancellationTimers = Query(Self.cancellationTimerDescriptor(
            sessionID: sessionID,
            dataEpochID: request.dataEpochID
        ))
        _currentSessionStudySessions = Query(Self.studySessionDescriptor(
            sessionID: sessionID,
            dataEpochID: request.dataEpochID
        ))
        _focusDeviceClaims = Query(Self.claimDescriptor(
            sessionID: sessionID,
            dataEpochID: request.dataEpochID
        ))
        _activityResetMarkers = Query(Self.resetMarkerDescriptor())
    }

    private static func preferencesDescriptor() -> FetchDescriptor<Prefs> {
        PrefsConsumerPolicy.descriptor()
    }

    private static func gachaDescriptor() -> FetchDescriptor<GachaState> {
        var descriptor = FetchDescriptor<GachaState>()
        descriptor.fetchLimit = 4
        return descriptor
    }

    private static func timerDescriptor(
        sessionID: UUID?,
        dataEpochID: UUID?
    ) -> FetchDescriptor<SyncedFocusTimer> {
        var descriptor: FetchDescriptor<SyncedFocusTimer>
        if let sessionID, let dataEpochID {
            let targetID = sessionID
            let targetEpochID = dataEpochID
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.sessionID == targetID && $0.dataEpochID == targetEpochID
                },
                sortBy: [
                    SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.revision, order: .reverse)
                ]
            )
        } else if let sessionID {
            let targetID = sessionID
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.sessionID == targetID && $0.dataEpochID == nil
                },
                sortBy: [
                    SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.revision, order: .reverse)
                ]
            )
        } else if let dataEpochID {
            let targetEpochID = dataEpochID
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.dataEpochID == targetEpochID },
                sortBy: [
                    SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.revision, order: .reverse)
                ]
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.dataEpochID == nil },
                sortBy: [
                    SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.revision, order: .reverse)
                ]
            )
        }
        descriptor.fetchLimit = FocusCloudSyncStore.QueryContract
            .matchingSessionRecordLimit
        return descriptor
    }

    private static func claimDescriptor(
        sessionID: UUID?,
        dataEpochID: UUID?
    ) -> FetchDescriptor<FocusTimerDeviceClaim> {
        let maximumSequence = FocusSyncPolicy.maximumSupportedOwnershipSequence
        var descriptor: FetchDescriptor<FocusTimerDeviceClaim>
        if let sessionID, let dataEpochID {
            let targetID = sessionID
            let targetEpochID = dataEpochID
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.sessionID == targetID
                        && $0.dataEpochID == targetEpochID
                        && $0.sequence >= 0
                        && $0.sequence <= maximumSequence
                },
                sortBy: [
                    SortDescriptor(\FocusTimerDeviceClaim.sequence, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.claimedAt, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.deviceID, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.id, order: .reverse)
                ]
            )
        } else if let sessionID {
            let targetID = sessionID
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.sessionID == targetID
                        && $0.dataEpochID == nil
                        && $0.sequence >= 0
                        && $0.sequence <= maximumSequence
                },
                sortBy: [
                    SortDescriptor(\FocusTimerDeviceClaim.sequence, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.claimedAt, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.deviceID, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.id, order: .reverse)
                ]
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.sequence >= 0
                        && $0.sequence <= maximumSequence
                },
                sortBy: [
                    SortDescriptor(\FocusTimerDeviceClaim.sequence, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.claimedAt, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.deviceID, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.id, order: .reverse)
                ]
            )
        }
        descriptor.fetchLimit = FocusCloudSyncStore.QueryContract
            .matchingSessionClaimLimit
        return descriptor
    }

    private static func completedTimerDescriptor(
        sessionID: UUID?,
        dataEpochID: UUID?
    ) -> FetchDescriptor<SyncedFocusTimer> {
        let targetID = sessionID
            ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let completed = SyncedFocusStatus.completed.rawValue
        var descriptor: FetchDescriptor<SyncedFocusTimer>
        if let dataEpochID {
            let targetEpochID = dataEpochID
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.sessionID == targetID
                        && $0.dataEpochID == targetEpochID
                        && $0.statusRaw == completed
                },
                sortBy: [
                    SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.revision, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.id, order: .reverse)
                ]
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.sessionID == targetID
                        && $0.dataEpochID == nil
                        && $0.statusRaw == completed
                },
                sortBy: [
                    SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.revision, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.id, order: .reverse)
                ]
            )
        }
        descriptor.fetchLimit = 1
        return descriptor
    }

    private static func cancellationTimerDescriptor(
        sessionID: UUID?,
        dataEpochID: UUID?
    ) -> FetchDescriptor<SyncedFocusTimer> {
        let targetID = sessionID
            ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let cancelled = SyncedFocusStatus.cancelled.rawValue
        var descriptor: FetchDescriptor<SyncedFocusTimer>
        let ordering = [
            SortDescriptor(\SyncedFocusTimer.terminalAt),
            SortDescriptor(\SyncedFocusTimer.ownershipSequence, order: .reverse),
            SortDescriptor(\SyncedFocusTimer.revision, order: .reverse),
            SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse),
            SortDescriptor(\SyncedFocusTimer.writerDeviceID, order: .reverse),
            SortDescriptor(\SyncedFocusTimer.id, order: .reverse)
        ]
        if let dataEpochID {
            let targetEpochID = dataEpochID
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.sessionID == targetID
                        && $0.dataEpochID == targetEpochID
                        && $0.statusRaw == cancelled
                },
                sortBy: ordering
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.sessionID == targetID
                        && $0.dataEpochID == nil
                        && $0.statusRaw == cancelled
                },
                sortBy: ordering
            )
        }
        descriptor.fetchLimit = 1
        return descriptor
    }

    private static func studySessionDescriptor(
        sessionID: UUID?,
        dataEpochID: UUID?
    ) -> FetchDescriptor<StudySession> {
        let targetID = sessionID
            ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        var descriptor: FetchDescriptor<StudySession>
        if let dataEpochID {
            let targetEpochID = dataEpochID
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.id == targetID && $0.dataEpochID == targetEpochID
                }
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.id == targetID && $0.dataEpochID == nil
                }
            )
        }
        descriptor.fetchLimit = 2
        return descriptor
    }

    private static func resetMarkerDescriptor() -> FetchDescriptor<ActivityResetMarker> {
        ActivityResetPolicy.currentMarkerDescriptor()
    }

    private var resolvedPreferences: PrefsSyncPolicy.ResolvedState? {
        PrefsConsumerPolicy.resolvedState(
            in: preferences,
            markers: resetSnapshots
        )
    }
    private var sensoryPreferences: PrefsSyncPolicy.ResolvedSensoryState {
        PrefsConsumerPolicy.resolvedSensoryState(in: preferences)
    }
    private var rareRewardMode: RareRewardMode {
        PrefsConsumerPolicy.rareRewardMode(from: resolvedPreferences)
    }
    private var timerDisplayMode: TimerDisplayMode {
        resolvedPreferences?.timerDisplayMode ?? .ringAndTime
    }
    private var needsRareRewardChoice: Bool {
        RareRewardReleasePolicy.isEnabled
            && recoveryOrigin == .local
            && !didStart
            && !PrefsConsumerPolicy.hasExplicitRareRewardSelection(
                in: resolvedPreferences
            )
    }
    private var snapshot: PomodoroSnapshot { engine.snapshot(at: displayNow) }
    private var accent: Color { Color(hex: subjectSnapshot.colorHex) }
    private var resetSnapshots: [ActivityResetSnapshot] {
        activityResetMarkers.map(\.policySnapshot)
    }
    private var preferencesFingerprint: [String] {
        preferences.map { PrefsConsumerPolicy.fingerprint(for: $0) }
    }
    private var currentSyncedFocusTimers: [SyncedFocusTimer] {
        syncedFocusTimers.filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetSnapshots)
        }
    }
    private var currentFocusDeviceClaims: [FocusTimerDeviceClaim] {
        focusDeviceClaims.filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetSnapshots)
        }
    }
    private var currentGachaStates: [GachaState] {
        gachaStates.filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetSnapshots)
        }
    }
    private var currentGachaState: GachaState? {
        currentGachaStates.max { lhs, rhs in
            if lhs.rewardCreditGrams != rhs.rewardCreditGrams {
                return lhs.rewardCreditGrams < rhs.rewardCreditGrams
            }
            let lhsIsCanonical = lhs.id == BoundedLaunchPreparation.canonicalGachaID
            let rhsIsCanonical = rhs.id == BoundedLaunchPreparation.canonicalGachaID
            if lhsIsCanonical != rhsIsCanonical {
                return !lhsIsCanonical && rhsIsCanonical
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
    private var currentSessionID: UUID? {
        pendingCompletion?.sessionID ?? engine.currentSessionID
    }
    private var focusSyncFingerprint: [String] {
        let timerValues = syncedFocusTimers.map {
            "timer-\($0.sessionID.uuidString)-\($0.statusRaw)-\($0.revision)-\($0.updatedAt.timeIntervalSince1970)"
        }
        let completedValues = currentSessionCompletedTimers.map {
            "completed-\($0.id.uuidString)-\($0.revision)-\($0.updatedAt.timeIntervalSince1970)"
        }
        let cancellationValues = currentSessionCancellationTimers.map {
            "cancelled-\($0.id.uuidString)-\($0.revision)-\($0.updatedAt.timeIntervalSince1970)-\($0.terminalAt?.timeIntervalSince1970 ?? -1)"
        }
        let materializedValues = currentSessionStudySessions.map {
            "materialized-\($0.id.uuidString)-\($0.endAt.timeIntervalSince1970)-\($0.grams)"
        }
        let claimValues = focusDeviceClaims.map {
            "claim-\($0.sessionID.uuidString)-\($0.deviceID)-\($0.sequence)-\($0.releasedAt?.timeIntervalSince1970 ?? -1)"
        }
        return (timerValues + completedValues + cancellationValues
            + materializedValues + claimValues)
            .sorted()
    }
    private var ownsCurrentTimer: Bool {
        guard allowsLocalNotifications, let currentSessionID else { return false }
        let claims = currentFocusDeviceClaims.map(\.policySnapshot)
        guard let owner = FocusSyncPolicy.notificationOwner(
            for: currentSessionID,
            claims: claims
        ) else {
            // A just-created local timer can render before its inserted claim
            // reaches @Query. Cloud recoveries never enter FocusView until the
            // explicit adoption transaction has inserted a claim.
            return recoveryOrigin == .local
        }
        return owner == deviceID
    }

    var body: some View {
#if DEBUG
        let _ = assertStableSessionIdentity()
#endif
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(
                colors: [accent.opacity(0.10), .clear],
                center: .center,
                startRadius: 10,
                endRadius: 330
            )
            .ignoresSafeArea()

            if needsRareRewardChoice {
                RareRewardPreFocusChoiceView(
                    selection: $rareRewardChoice,
                    errorMessage: rareRewardChoiceError,
                    isSaving: isSavingRareRewardChoice,
                    onConfirm: saveRareRewardChoiceAndStart,
                    onCancel: { dismiss() }
                )
                .transition(.opacity)
            } else if let completion {
                FocusCompletionView(
                    completion: completion,
                    subjectColor: accent,
                    reduceMotion: reduceMotion,
                    onStartBreak: startBreak,
                    onReturnToJar: { dismiss() }
                )
                .transition(.opacity)
            } else if let pendingCompletion {
                completionCommitView(pendingCompletion)
                    .transition(.opacity)
            } else if breakFinished {
                BreakFinishedView { dismiss() }
                    .transition(.opacity)
            } else {
                timerContent
            }
        }
        .foregroundStyle(PomoGemTheme.text)
        .interactiveDismissDisabled()
        .statusBarHidden()
        .onAppear { router.beginFocusPresentation() }
        .task { await beginActivation() }
        .onReceive(ticker) { date in
            displayNow = date
            updateIdleTimer(at: date)
            // Absolute end dates keep advancing while locked/backgrounded. Do
            // not consume completion in the brief inactive run-loop window:
            // doing so can cancel the already-scheduled OS notification before
            // it is delivered. The active transition resolves the same end date.
            guard scenePhase == .active,
                  notificationAuthorizationIsCurrent else { return }
            let completionIsElapsed = (engine.endDate ?? .distantFuture) <= date
            if completionIsElapsed {
                // Resolve a foreground return only after an in-flight
                // Notification Center add has a definite success/failure.
                guard !notificationScheduleState.isScheduling else { return }
                let completionUptime = ContinuousUptime.now()
                let cue = completionCueForElapsedTimer(
                    at: date,
                    uptime: completionUptime,
                    returnedFromBackground:
                        didEnterBackgroundSinceLastActive
                )
                didEnterBackgroundSinceLastActive = false
                advanceIfNeeded(
                    at: date,
                    uptime: completionUptime,
                    cue: cue
                )
                return
            }
            advanceIfNeeded(
                at: date,
                uptime: ContinuousUptime.now()
            )
        }
        .onChange(of: scenePhase) { _, newPhase in
            notificationAuthorizationRefreshGeneration &+= 1
            let refreshGeneration = notificationAuthorizationRefreshGeneration
            guard newPhase == .active else {
                notificationAuthorizationIsCurrent = false
                handleScenePhase(to: newPhase)
                return
            }
            notificationAuthorizationIsCurrent = false
            Task { @MainActor in
                await notifications.refreshAuthorizationStatus()
                guard !Task.isCancelled,
                      refreshGeneration
                        == notificationAuthorizationRefreshGeneration,
                      scenePhase == .active else { return }
                notificationAuthorizationIsCurrent = true
                handleScenePhase(to: .active)
                if pendingCompletion == nil,
                   completion == nil,
                   engine.snapshot(at: .now).phase == .focusing,
                   let endDate = engine.endDate,
                   endDate > .now {
                    await scheduleCurrentCompletionNotification()
                }
            }
        }
        .onChange(of: focusSyncFingerprint) { _, _ in
            let retired = enforceCloudOwnership()
            if !retired, ownsCurrentTimer {
                Task { await refreshExternalTimerPresentation() }
            }
        }
        .onChange(of: preferencesFingerprint) { _, _ in
            configureSensoryPreferences()
            updateIdleTimer()
            guard ownsCurrentTimer else { return }
            Task { await refreshExternalTimerPresentation() }
        }
        .onChange(of: resetSnapshots) { _, _ in
            enforceActivityReset()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            // RootView may be torn down solely to revalidate the CloudKit
            // account. Keep the accepted OS request, but fence every callback
            // owned by this disappearing view from rewriting recovery later.
            notificationAuthorizationIsCurrent = false
            notificationAuthorizationRefreshGeneration &+= 1
            notificationScheduleGeneration &+= 1
            viewLifecycleGeneration &+= 1
            isViewActive = false
            if !didStart { didActivate = false }
        }
        .alert("今日はここまで", isPresented: $showGiveUpConfirmation) {
            Button("続ける", role: .cancel) {}
            Button(Constants.UIStrings.giveUp, role: .destructive) { giveUp() }
        } message: {
            Text("この回の粒は積まれません。これまでの瓶はそのままです。")
        }
        .alert("タイマーを開始できませんでした", isPresented: Binding(
            get: { setupErrorMessage != nil },
            set: { if !$0 { setupErrorMessage = nil } }
        )) {
            Button("閉じる", role: .cancel) { dismiss() }
        } message: {
            Text(setupErrorMessage ?? "")
        }
        .alert("操作を完了できませんでした", isPresented: Binding(
            get: { operationErrorMessage != nil },
            set: { if !$0 { operationErrorMessage = nil } }
        )) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(operationErrorMessage ?? "")
        }
    }

#if DEBUG
    /// Guards the query/engine identity contract documented on `init`. A
    /// re-created view must keep targeting the session its engine is running.
    private func assertStableSessionIdentity() {
        guard let runningSessionID = engine.currentSessionID,
              pendingCompletion == nil else { return }
        assert(
            runningSessionID == preparedSessionID,
            "FocusView re-initialized with a different session ID than its running engine"
        )
    }
#endif

    private var timerOrientationSessionID: AnyHashable {
        // The legacy engine break has no UUID. Its original start remains
        // stable through pause/resume and persisted view reconstruction.
        if engine.containsRecoverableBreak, let startedAt = engine.phaseStartedAt {
            return AnyHashable(startedAt)
        }
        return AnyHashable(preparedSessionID ?? orientationSessionID)
    }

    private var timerContent: some View {
        TimerOrientationContainer(sessionID: timerOrientationSessionID) { context in
            let usesColumns = context.isLandscape && !dynamicTypeSize.isAccessibilitySize
            let ringSize = FocusTimerLayoutPolicy.ringSize(in: context.size)
            ScrollView {
                VStack(spacing: 0) {
                    timerHeader

                    if usesColumns {
                        HStack(spacing: 32) {
                            timerDisplay(size: ringSize)
                                .frame(maxWidth: .infinity)
                            VStack(spacing: 20) {
                                timerNotice
                                timerActions
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .frame(maxHeight: .infinity)
                    } else {
                        Spacer(minLength: 18)
                        timerDisplay(size: ringSize)
                        timerNotice
                            .padding(.horizontal, 24)
                            .padding(.top, 24)
                        Spacer(minLength: 18)
                        timerActions
                            .padding(.horizontal, 24)
                            .padding(.bottom, 24)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: context.size.height)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var timerHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Circle().fill(accent).frame(width: 8, height: 8)
                    Text(subjectSnapshot.name)
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("focus.subject")
                }
                Text(phaseLabel)
                    .font(.caption2)
                    .foregroundStyle(PomoGemTheme.muted)
            }
            Spacer(minLength: 0)
            TimerRotationControls()
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    private func timerDisplay(size: CGFloat) -> some View {
        FocusTimerDisplay(
            size: size,
            progress: snapshot.progress,
            remainingTime: formattedTime(snapshot.remainingSeconds),
            accessibleRemainingTime: accessibleTime(snapshot.remainingSeconds),
            modeLabel: timerModeLabel,
            displayMode: timerDisplayMode,
            isBreakMode: snapshot.phase.isBreak || engine.containsRecoverableBreak,
            isPaused: snapshot.phase == .paused,
            accent: accent,
            reduceMotion: reduceMotion
        )
    }

    @ViewBuilder
    private var timerNotice: some View {
        if fairnessNotice {
            Label("端末時刻の大きな変化を検出。この回だけ自己申告あつかいです", systemImage: "clock.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        } else {
            completionNotificationStatus
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var timerActions: some View {
        VStack(spacing: 12) {
            Button(action: togglePause) {
                Label(
                    snapshot.phase == .paused ? Constants.UIStrings.resume : Constants.UIStrings.pause,
                    systemImage: snapshot.phase == .paused ? "play.fill" : "pause.fill"
                )
            }
            .buttonStyle(PomoGemPrimaryButtonStyle(tintHex: subjectSnapshot.colorHex))

            if snapshot.phase.isBreak || engine.containsRecoverableBreak {
                Button("休憩をスキップ", action: skipBreak)
                    .buttonStyle(PomoGemSecondaryButtonStyle())
            } else {
                Button(Constants.UIStrings.giveUp) { showGiveUpConfirmation = true }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PomoGemTheme.muted)
                    .frame(minHeight: 44)
                    .buttonStyle(PomoGemBareButtonStyle())
            }
        }
    }

    private var phaseLabel: String {
        if timerDisplayMode == .filledDial, snapshot.phase != .paused {
            return snapshot.phase.isBreak ? "休憩中" : "集中中"
        }
        return switch snapshot.phase {
        case .shortBreak: "5分休憩"
        case .longBreak: "15分休憩"
        case .paused where completion == nil: engine.currentSource == .timerDemoted ? "自己申告あつかい・一時停止" : "一時停止"
        default: durationTitle
        }
    }

    private var durationTitle: String {
#if DEBUG
        if duration == .demo { return "12秒デモ" }
#endif
        return "\(duration.displayLabel)集中"
    }

    private var timerModeLabel: String {
        switch snapshot.phase {
        case .shortBreak, .longBreak:
            "BREAK"
        case .paused:
            "一時停止"
        default:
            "FOCUS"
        }
    }

    @ViewBuilder
    private var completionNotificationStatus: some View {
        switch notificationScheduleState {
        case .scheduled where notifications.isAuthorized:
            Label("画面を閉じてもタイマーは進み、終了時に通知します", systemImage: "bell.badge.fill")
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
        case .scheduling:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("終了通知を設定しています")
                    .font(.caption)
            }
            .foregroundStyle(PomoGemTheme.muted)
        case let .failed(message):
            VStack(spacing: 7) {
                Button {
                    Task { await synchronizeCompletionNotificationIfNeeded() }
                } label: {
                    Label("通知を予約できませんでした。もう一度試す", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(PomoGemBareButtonStyle())
                .frame(minHeight: 44)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(PomoGemTheme.muted)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(PomoGemTheme.amber)
            .padding(.horizontal, 24)
        default:
            notificationPermissionAction
        }
    }

    @ViewBuilder
    private var notificationPermissionAction: some View {
        if notifications.authorizationStatus == .denied {
            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            } label: {
                Label("画面を閉じても進みます。終了通知は端末の設定から", systemImage: "bell.slash")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(PomoGemBareButtonStyle())
            .frame(minHeight: 44)
            .foregroundStyle(PomoGemTheme.amber)
        } else if notifications.isAuthorized {
            Button {
                Task { await scheduleCurrentCompletionNotification() }
            } label: {
                Label("終了通知を設定", systemImage: "bell")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(PomoGemBareButtonStyle())
            .frame(minHeight: 44)
            .foregroundStyle(PomoGemTheme.amber)
        } else {
            Button {
                Task { await enableCompletionNotification() }
            } label: {
                Label("画面を閉じても進みます。終了通知を許可", systemImage: "bell")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(PomoGemBareButtonStyle())
            .frame(minHeight: 44)
            .foregroundStyle(PomoGemTheme.amber)
        }
    }

    @MainActor
    private func beginActivation() async {
        guard !Task.isCancelled else { return }
        isViewActive = true
        viewLifecycleGeneration &+= 1
        await activate(lifecycleGeneration: viewLifecycleGeneration)
    }

    @MainActor
    private func activate(lifecycleGeneration: UInt64) async {
        guard !Task.isCancelled,
              isViewActive,
              lifecycleGeneration == viewLifecycleGeneration else { return }
        guard !didActivate else { return }
        // No local timer begins until an informed choice is synchronized.
        // Recovery must continue even for a legacy envelope; its completion is
        // deterministically normal because unresolved preferences resolve off.
        guard !needsRareRewardChoice else { return }
        didActivate = true
        configureSensoryPreferences()
        await notifications.refreshAuthorizationStatus()
        guard !Task.isCancelled,
              lifecycleGeneration == viewLifecycleGeneration else { return }
        notificationAuthorizationIsCurrent = scenePhase == .active

        if didStart {
            guard ActivityResetPolicy.state(
                of: dataEpochID,
                markers: resetSnapshots
            ) == .current else {
                enforceActivityReset()
                return
            }
            let now = Date.now
            let completionUptime = ContinuousUptime.now()
            displayNow = now
            updateIdleTimer(at: now)

            if let pendingCompletion {
                resumeCompletionAlertIfNeeded(pendingCompletion)
                await commitCompletion(pendingCompletion)
                return
            }

            saveRecoveryState()
            let completionIsAlreadyElapsed = engine.snapshot(at: now)
                .remainingSeconds == 0
            // Never consume an elapsed recovery while inactive/backgrounded:
            // doing so cancels the OS request before it can notify the user.
            guard !completionIsAlreadyElapsed || scenePhase == .active else {
                return
            }
            let cue: TimerCompletionForegroundFeedbackPolicy.Cue
            if completionIsAlreadyElapsed {
                cue = completionCueForElapsedTimer(
                    at: now,
                    uptime: completionUptime,
                    returnedFromBackground: false
                )
            } else {
                isAwaitingRecoveryActivation = false
                cue = .repeating
            }
            advanceIfNeeded(
                at: now,
                uptime: completionUptime,
                cue: cue
            )
            if pendingCompletion == nil {
                await scheduleCurrentCompletionNotification()
                guard !Task.isCancelled,
                      lifecycleGeneration == viewLifecycleGeneration
                else { return }
                if recoveryOrigin == .iCloud,
                   let sessionID = engine.currentSessionID {
                    await startLiveActivityForExplicitTimer(
                        sessionID: sessionID
                    )
                    guard !Task.isCancelled,
                          lifecycleGeneration == viewLifecycleGeneration
                    else { return }
                    await refreshExternalTimerPresentation(
                        synchronizesCompletionNotification: false
                    )
                } else {
                    await refreshExternalTimerPresentation(
                        synchronizesCompletionNotification: false
                    )
                }
            }
            return
        }

        didStart = true
        let now = Date.now
        let sessionID = preparedSessionID ?? UUID()
        do {
            let latestEpochID = try ActivityResetStore.currentEpochID(context: modelContext)
            guard latestEpochID == dataEpochID else {
                throw FocusCloudSyncError.activityWasReset
            }
            try engine.startFocus(
                duration: duration,
                isPro: PurchaseManager.shared.isPro,
                now: now,
                sessionID: sessionID
            )
            displayNow = now
            clockAnchor = ClockAnchor(
                wallDate: now,
                systemUptime: ContinuousUptime.now()
            )
            saveRecoveryState()
            updateIdleTimer(at: now)

            await scheduleCurrentCompletionNotification()
            guard !Task.isCancelled,
                  lifecycleGeneration == viewLifecycleGeneration else { return }
            await startLiveActivityForExplicitTimer(sessionID: sessionID)
            guard !Task.isCancelled,
                  lifecycleGeneration == viewLifecycleGeneration,
                  engine.currentSessionID == sessionID else { return }
            await refreshExternalTimerPresentation(
                synchronizesCompletionNotification: false
            )
        } catch {
            setupErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func saveRareRewardChoiceAndStart() {
        guard let rareRewardChoice, !isSavingRareRewardChoice else { return }
        guard resolvedPreferences != nil else {
            rareRewardChoiceError = "設定の保存先を準備できませんでした。いったん戻り、もう一度お試しください。"
            return
        }

        isSavingRareRewardChoice = true
        rareRewardChoiceError = nil
        let changedAt = Date.now
        do {
            try PrefsConsumerPolicy.mutate(
                .rareReward,
                context: modelContext,
                markers: resetSnapshots
            ) {
                $0.rareRewardModeRawValue = rareRewardChoice.rawValue
                $0.rareRewardModeUpdatedAt = changedAt
            }
            try modelContext.save()
            isSavingRareRewardChoice = false
            let lifecycleGeneration = viewLifecycleGeneration
            Task {
                await activate(lifecycleGeneration: lifecycleGeneration)
            }
        } catch {
            modelContext.rollback()
            isSavingRareRewardChoice = false
            rareRewardChoiceError = "レア粒の選択を保存できませんでした。タイマーはまだ始まっていません。\n\(error.localizedDescription)"
        }
    }

    @MainActor
    private func enableCompletionNotification() async {
        let granted = await notifications.requestAuthorization()
        guard granted else {
            if let error = notifications.lastErrorDescription {
                notificationScheduleState = .failed(message: error)
            } else {
                notificationScheduleState = .idle
            }
            return
        }
        await scheduleCurrentCompletionNotification()
    }

    @MainActor
    private func synchronizeCompletionNotificationIfNeeded() async {
        await notifications.refreshAuthorizationStatus()
        await scheduleCurrentCompletionNotification()
    }

    /// Creates a Live Activity only at an explicit local start or accepted
    /// iCloud handoff. ActivityKit cleanup can suspend while pause/resume/cancel
    /// stays interactive, so retry against the newest stable engine state. The
    /// bound prevents a person rapidly tapping the control from keeping this
    /// activation task alive indefinitely; later controls still update any
    /// activity that was successfully created.
    @MainActor
    private func startLiveActivityForExplicitTimer(
        sessionID: UUID
    ) async {
        let manager = FocusActivityManager.shared
        for _ in 0..<3 {
            manager.refreshAuthorization()
            guard ownsCurrentTimer,
                  manager.activitiesEnabled,
                  let intendedState = explicitFocusActivityState(
                    sessionID: sessionID,
                    at: .now
                  )
            else {
                if engine.currentSessionID != sessionID {
                    await manager.cancel(sessionID: sessionID)
                }
                return
            }

            do {
                switch intendedState {
                case let .focusing(endDate):
                    _ = try await manager.start(
                        sessionID: sessionID,
                        durationSeconds: duration.seconds,
                        endDate: endDate
                    )
                case let .paused(remainingSeconds):
                    _ = try await manager.startPaused(
                        sessionID: sessionID,
                        durationSeconds: duration.seconds,
                        remainingSeconds: remainingSeconds
                    )
                }
            } catch {
                // Live Activity is an optional system-owned surface. Keep the
                // authoritative in-app timer running if ActivityKit refuses it.
                return
            }

            guard let currentState = explicitFocusActivityState(
                sessionID: sessionID,
                at: .now
            ) else {
                await manager.cancel(sessionID: sessionID)
                return
            }
            if manager.currentSessionID == sessionID,
               currentState == intendedState {
                return
            }
        }
    }

    private func explicitFocusActivityState(
        sessionID: UUID,
        at now: Date
    ) -> ExplicitFocusActivityState? {
        guard engine.currentSessionID == sessionID else { return nil }
        let currentSnapshot = engine.snapshot(at: now)
        switch currentSnapshot.phase {
        case .focusing:
            guard let endDate = engine.endDate, endDate > now else { return nil }
            return .focusing(endDate: endDate)
        case .paused:
            return .paused(
                remainingSeconds: currentSnapshot.remainingSeconds
            )
        default:
            return nil
        }
    }

    @MainActor
    private func scheduleCurrentCompletionNotification() async {
        guard isViewActive else { return }
        notificationScheduleGeneration &+= 1
        let generation = notificationScheduleGeneration
        guard ownsCurrentTimer,
              notifications.isAuthorized,
              engine.snapshot(at: .now).phase == .focusing,
              let sessionID = engine.currentSessionID,
              let endDate = engine.endDate
        else {
            invalidateScheduledCompletionNotificationWitness()
            notificationScheduleState = .idle
            return
        }
        guard endDate > .now else {
            // Keep a matching success witness until the elapsed completion is
            // consumed; Notification Center may already have delivered it.
            notificationScheduleState = .idle
            return
        }

        // The replacement request has a new registration origin. Persisting
        // the old, earlier delivery Date while this add is in flight could
        // suppress the in-app cue before the replacement has actually fired.
        invalidateScheduledCompletionNotificationWitness()
        notificationScheduleState = .scheduling
        do {
            let scheduleResult = try await notifications
                .scheduleFocusCompletion(
                sessionID: sessionID,
                endDate: endDate,
                playsSound: sensoryPreferences.soundOn,
                completionSound: sensoryPreferences.timerCompletionSound
            )
            guard case let .accepted(notificationDeliveryDate) = scheduleResult
            else { return }
            guard !Task.isCancelled,
                  isViewActive,
                  notificationScheduleGeneration == generation else { return }
            // Scheduling crosses into Notification Center and can suspend this
            // task. A pause, cancellation, ownership handoff, or reschedule may
            // win while it is awaiting. NotificationManager already converges
            // the actual pending request; keep the visible status equally
            // honest by accepting success only for the same active intent.
            let currentSnapshot = engine.snapshot(at: .now)
            if ownsCurrentTimer,
               engine.currentSessionID == sessionID,
               currentSnapshot.phase == .focusing,
               engine.endDate == endDate {
                scheduledCompletionNotificationDeliveryDate =
                    notificationDeliveryDate
                notificationScheduleState = .scheduled
                saveRecoveryState()
            } else {
                scheduledCompletionNotificationDeliveryDate = nil
                notificationScheduleState = .idle
            }
        } catch {
            guard !Task.isCancelled,
                  isViewActive,
                  notificationScheduleGeneration == generation else { return }
            if ownsCurrentTimer,
               engine.currentSessionID == sessionID,
               engine.snapshot(at: .now).phase == .focusing,
               engine.endDate == endDate {
                notificationScheduleState = .failed(message: error.localizedDescription)
            } else {
                scheduledCompletionNotificationDeliveryDate = nil
                notificationScheduleState = .idle
            }
        }
    }

    @MainActor
    private func refreshExternalTimerPresentation(
        synchronizesCompletionNotification: Bool = true
    ) async {
        // Both local notifications and Live Activities belong only to the
        // winning device claim. This guard also covers the narrow handoff race
        // where ownership changes after RootView creates this screen but before
        // its first activation task runs.
        guard isViewActive else { return }
        guard ownsCurrentTimer else {
            enforceCloudOwnership()
            return
        }
        let currentSnapshot = engine.snapshot(at: .now)
        guard let sessionID = engine.currentSessionID else { return }
        registerFocusReturnReminderIfNeeded()
        switch currentSnapshot.phase {
        case .focusing:
            if synchronizesCompletionNotification {
                await synchronizeCompletionNotificationIfNeeded()
            }
            guard isViewActive else { return }
            guard let endDate = engine.endDate, endDate > .now else { return }
            await FocusActivityManager.shared.updateIfPresent(
                sessionID: sessionID,
                endDate: endDate
            )
        case .paused:
            NotificationManager.shared.cancelFocusCompletion(sessionID: sessionID)
            scheduledCompletionNotificationDeliveryDate = nil
            notificationScheduleState = .idle
            await FocusActivityManager.shared.pause(
                sessionID: sessionID,
                remainingSeconds: currentSnapshot.remainingSeconds
            )
        default:
            return
        }
    }

    private func configureSensoryPreferences() {
        SoundSynth.shared.isEnabled = sensoryPreferences.soundOn
        Haptics.shared.isEnabled = sensoryPreferences.hapticsOn
    }

    @MainActor
    private func updateIdleTimer(at date: Date = .now) {
        let currentSnapshot = engine.snapshot(at: date)
        let shouldKeepScreenAwake =
            TimerScreenAwakePolicy.shouldKeepScreenAwake(
                preferenceEnabled:
                    resolvedPreferences?.keepScreenAwake ?? false,
                sceneIsActive: scenePhase == .active,
                timerIsRunning:
                    isViewActive && currentSnapshot.phase.isRunning,
                remainingSeconds: currentSnapshot.remainingSeconds
            )
        guard UIApplication.shared.isIdleTimerDisabled != shouldKeepScreenAwake
        else { return }
        UIApplication.shared.isIdleTimerDisabled = shouldKeepScreenAwake
    }

    private func advanceIfNeeded(
        at now: Date,
        uptime: TimeInterval,
        cue: TimerCompletionForegroundFeedbackPolicy.Cue = .repeating
    ) {
        // Freeze an elapsed completion before consulting mutable CloudKit
        // ownership. A handoff followed by a cancellation at/after the frozen
        // scheduled end must not erase effort merely because those foreign
        // rows arrived while this device was suspended. Ownership still gates
        // StudySession materialization in `persistCompletion`.
        reconcileClockIntegrity(at: now, uptime: uptime)
        guard let event = engine.advance(at: now, observedUptime: uptime) else { return }
        switch event {
        case let .focusCompleted(result):
            notificationScheduleState = .idle
            let finalized = FairnessPolicy.finalizedCompletion(
                result,
                clockAnchor: clockAnchor
            )
            fairnessNotice = finalized.source == .timerDemoted
            handleFocusCompletion(finalized, cue: cue)
        case .breakCompleted:
            FocusPersistence.clear()
            UIApplication.shared.isIdleTimerDisabled = false
            withAnimation { breakFinished = true }
        }
    }

    /// Backgrounding is not a fairness event. Wall time continues against the
    /// saved absolute end date. The continuous clock is consulted separately
    /// only to catch a clear wall-clock jump while preserving normal lock,
    private func reconcileClockIntegrity(
        at now: Date,
        uptime: TimeInterval
    ) {
        guard engine.snapshot(at: now).phase == .focusing,
              let clockAnchor
        else { return }

        let integrity = FairnessPolicy.clockIntegrity(
            from: clockAnchor,
            completionDate: now,
            completionUptime: uptime
        )

        switch integrity {
        case .valid:
            break
        case .changed, .uptimeReset, .unverifiable:
            guard engine.currentSource == .timer else { return }
            do {
                try engine.demoteCurrentFocus()
                fairnessNotice = true
                // Keep a valid local anchor for diagnostics and for coherent
                // recovery bytes. The source is already irreversibly demoted,
                // so re-anchoring cannot restore measured-only rewards.
                self.clockAnchor = ClockAnchor(
                    wallDate: now,
                    systemUptime: uptime
                )
                saveRecoveryState()
            } catch {
                operationErrorMessage = error.localizedDescription
            }
        }
    }

    private func handleFocusCompletion(
        _ result: PomodoroCompletion,
        cue: TimerCompletionForegroundFeedbackPolicy.Cue
    ) {
        guard pendingCompletion == nil else { return }
        pendingCompletion = result
        saveRecoveryState(pendingCompletion: result)
        signalCompletionIfNeeded(result, cue: cue)
        Task { await commitCompletion(result) }
    }

    @MainActor
    private func commitCompletion(_ result: PomodoroCompletion) async {
        guard !isCommittingCompletion else { return }
        isCommittingCompletion = true
        defer { isCommittingCompletion = false }
        completionSaveError = nil
        completionWasRejectedForOwnership = false
        let persistenceResult: FocusCompletionPersistenceResult
        do {
            persistenceResult = try await persistCompletion(result)
        } catch {
            modelContext.rollback()
            saveRecoveryState(pendingCompletion: result)
            completionSaveError = error.localizedDescription
            announceCompletionSaveFailure()
            return
        }

        if !persistenceResult.mayRetireRecovery {
            // Another device may still be committing the same logical focus.
            // Keep the local envelope until its StudySession arrives and a retry
            // can resolve as `alreadyMaterialized`; never present rejection as a
            // successful local save.
            saveRecoveryState(pendingCompletion: result)
            completionWasRejectedForOwnership = true
            completionSaveError = switch persistenceResult {
            case .awaitingMaterializedCompletion:
                "完了状態が先に届き、履歴本体が保存領域へ反映されるのを待っています。この端末の復元情報は保持しています。しばらく待ってから保存状態を確認してください。"
            default:
                "この完走は別の保存処理が担当しています。記録が保存領域へ反映されるまで、この端末の復元情報を保持します。しばらく待ってから保存状態を確認してください。"
            }
            announceCompletionSaveFailure()
            return
        }

        if persistenceResult == .cancelledBeforeCompletion
            || persistenceResult == .discardedByReset {
            retireCompletionRecovery(result)
            completionAlert.stop(sessionID: result.sessionID)
            NotificationManager.shared.cancelFocusCompletion(
                sessionID: result.sessionID
            )
            await FocusActivityManager.shared.cancel(sessionID: result.sessionID)
            dismiss()
            return
        }

        UserDefaults.standard.set(
            result.sessionID.uuidString.lowercased(),
            forKey: FocusPersistence.localCompletionIDKey
        )

        if case let .inserted(awardedKind) = persistenceResult {
            Analytics.shared.track(.pomodoroComplete)
            Analytics.shared.track(.drop)
            if awardedKind == .gold { Analytics.shared.track(.gold) }
        }

        await FocusActivityManager.shared.complete(
            sessionID: result.sessionID
        )
        completionPersistenceSucceeded = true
        guard completionAlertWasAcknowledged
                || !completionAlert.isActive(sessionID: result.sessionID)
        else { return }
        await finishCommittedCompletion(result)
    }

    @MainActor
    private func finishCommittedCompletion(
        _ result: PomodoroCompletion
    ) async {
        guard !isFinishingCompletion else { return }
        isFinishingCompletion = true
        retireCompletionRecovery(result)
        try? await Task.sleep(for: .seconds(Constants.Jar.completionDropDelay))
        // The presentation host releases Home only after this cover closes.
        // Home shows the saved completion message, then drops the gem when
        // that message is acknowledged.
        dismiss()
    }

    private func retireCompletionRecovery(_ result: PomodoroCompletion) {
        FocusPersistence.clear()
        DeferredFocusCompletionStore.clear(sessionID: result.sessionID)
        if router.deferredFocusRecovery?.id == result.sessionID {
            router.deferredFocusRecovery = nil
        }
    }

    @MainActor
    private func acknowledgeCompletionAlert(_ result: PomodoroCompletion) {
        markCompletionAlertAcknowledged(result)
        completionAlert.stop(sessionID: result.sessionID)
        guard completionPersistenceSucceeded else { return }
        Task { await finishCommittedCompletion(result) }
    }

    @MainActor
    private func persistCompletion(
        _ result: PomodoroCompletion
    ) async throws -> FocusCompletionPersistenceResult {
        guard ActivityResetPolicy.state(
            of: dataEpochID,
            markers: resetSnapshots
        ) == .current else {
            throw FocusCloudSyncError.activityWasReset
        }
        let source = result.source

        let completionID = result.sessionID
        let descriptor = FetchDescriptor<StudySession>(
            predicate: #Predicate { $0.id == completionID }
        )
        let existingSessions = try modelContext.fetch(descriptor).filter {
            ActivityResetPolicy.isCurrent(
                $0.dataEpochID,
                markers: resetSnapshots
            )
                && StudySessionIntegrityPolicy.isSupported($0)
        }
        let existingSessionIDs = Set(existingSessions.map(\.id))

        if !RareRewardReleasePolicy.isEnabled {
            guard existingSessions.isEmpty else {
                // CloudKit may deliver the StudySession before its timer
                // tombstone. The exact StudySession is already an irreversible
                // closure sentinel; also append a completed row when the
                // shared timer payload is available so old clients converge.
                try? FocusCloudSyncStore.markTerminal(
                    sessionID: result.sessionID,
                    status: .completed,
                    context: modelContext,
                    deviceID: deviceID,
                    at: result.observedAt,
                    enforceOwnership: false
                )
                if modelContext.hasChanges { try modelContext.save() }
                return .alreadyMaterialized
            }
            switch try FocusCloudSyncStore.completionGate(
                sessionID: completionID,
                context: modelContext
            ) {
            case .open:
                break
            case .cancelledBeforeCompletion:
                return .cancelledBeforeCompletion
            case .completedAwaitingSession:
                return .awaitingMaterializedCompletion
            case .materialized:
                return .alreadyMaterialized
            }
            guard try claimCompletionMaterialization(
                completionID: completionID,
                existingSessionIDs: existingSessionIDs
            ) else {
                return .rejectedOwnership
            }

            modelContext.insert(FocusCompletionSessionFactory.normalSession(
                completion: result,
                subject: subject,
                subjectSnapshot: subjectSnapshot,
                dataEpochID: dataEpochID
            ))
            try FocusCloudSyncStore.markTerminal(
                sessionID: result.sessionID,
                status: .completed,
                context: modelContext,
                deviceID: deviceID,
                at: result.observedAt
            )
#if DEBUG && targetEnvironment(simulator)
            if UITestFaultInjection.consumeFocusCompletionSaveFailure() {
                throw UITestInjectedPersistenceError.focusCompletionSaveOnce
            }
#endif
            // StudySession and the terminal focus record share the ordinary
            // SwiftData/iCloud transaction. No rare outbox, cursor, random draw,
            // or raw CloudKit coordinator participates in this release path.
            try modelContext.save()
            return .inserted(.normal)
        }

        let pendingRows = try rareRewardPendingRows(sessionID: completionID)
        let versionTwoSessions = existingSessions.filter {
            $0.rareRewardRuleVersion == RareRewardLedgerV2.ruleVersion
        }
        if versionTwoSessions.contains(where: {
            $0.rareRewardParticipated != nil
        }) {
            if !pendingRows.isEmpty {
                pendingRows.forEach(modelContext.delete)
                try modelContext.save()
            }
            return .alreadyMaterialized
        }
        if !existingSessions.isEmpty && versionTwoSessions.isEmpty {
            guard pendingRows.isEmpty else {
                throw RareRewardLedgerError.duplicateSessionPayloadMismatch
            }
            return .alreadyMaterialized
        }

        if !versionTwoSessions.isEmpty {
            guard !pendingRows.isEmpty else {
                throw RareRewardLedgerLocalStateError.missingPendingCommit
            }
            let payload = try rareRewardPendingPayload(from: pendingRows)
            try validatePendingSubmission(payload.submission, for: result)
            return try await finalizeRareReward(
                payload: payload
            )
        }

        guard try claimCompletionMaterialization(
            completionID: completionID,
            existingSessionIDs: existingSessionIDs
        ) else {
            return .rejectedOwnership
        }

        // A missing GachaState is an unsaved local projection until after the
        // cloud-authoritative StudySession/outbox transaction commits.
        let payload: (
            submission: RareRewardLedgerSubmission,
            migration: RareRewardLedgerMigration
        )
        if pendingRows.isEmpty {
            let migration = try rareRewardMigration()
            payload = (
                RareRewardLedgerSubmission(
                    epochID: migration.epochID,
                    sessionID: result.sessionID,
                    source: source,
                    completedSeconds: result.seconds,
                    completedGrams: result.grams,
                    mode: rareRewardMode
                ),
                migration
            )
        } else {
            payload = try rareRewardPendingPayload(from: pendingRows)
            try validatePendingSubmission(payload.submission, for: result)
        }
        let session = StudySession(
            id: result.sessionID,
            subject: subject,
            startAt: result.startedAt,
            endAt: result.endedAt,
            seconds: result.seconds,
            source: source,
            pebbleKind: .normal,
            grams: result.grams,
            deviceDayKey: FairnessPolicy.deviceDayKey(for: result.endedAt),
            subjectNameSnapshot: subjectSnapshot.name,
            subjectColorHexSnapshot: subjectSnapshot.colorHex,
            subjectIDSnapshot: subjectSnapshot.id,
            rareRewardRuleVersion: RareRewardLedgerV2.ruleVersion,
            rareRewardParticipated: nil,
            rareRewardCreditedGrams: nil,
            rareRewardOutcomesRawValue: nil,
            dataEpochID: dataEpochID
        )
        modelContext.insert(session)
        if pendingRows.isEmpty {
            let pending = RareRewardPendingCommit(
                id: result.sessionID,
                dataEpochID: dataEpochID,
                submission: payload.submission,
                migration: payload.migration,
                createdAt: result.observedAt
            )
            modelContext.insert(pending)
        }
        try FocusCloudSyncStore.markTerminal(
            sessionID: result.sessionID,
            status: .completed,
            context: modelContext,
            deviceID: deviceID,
            at: result.observedAt
        )
#if DEBUG && targetEnvironment(simulator)
        if UITestFaultInjection.consumeFocusCompletionSaveFailure() {
            throw UITestInjectedPersistenceError.focusCompletionSaveOnce
        }
#endif
        // The measured StudySession and retryable outbox are one cloud-store
        // transaction. No rare outcome is exposed until the custom-zone CAS
        // returns its durable, idempotent receipt.
        try modelContext.save()
        return try await finalizeRareReward(
            payload: payload
        )
    }

    @MainActor
    private func claimCompletionMaterialization(
        completionID: UUID,
        existingSessionIDs: Set<UUID>
    ) throws -> Bool {
        var claims = try FocusCloudSyncStore.claims(
            sessionID: completionID,
            context: modelContext
        )
            .map(\.policySnapshot)
        var owner = FocusSyncPolicy.notificationOwner(
            for: completionID,
            claims: claims
        )
        if owner == nil, recoveryOrigin == .local {
            let claim = try FocusCloudSyncStore.claimOwnership(
                sessionID: completionID,
                context: modelContext,
                deviceID: deviceID
            )
            claims.append(claim.policySnapshot)
            owner = deviceID
        }

        let decision = FocusSyncPolicy.completionMaterializationDecision(
            sessionID: completionID,
            existingSessionIDs: existingSessionIDs,
            currentDeviceID: deviceID,
            claims: claims
        )
        return decision == .insert && owner == deviceID
    }

    @MainActor
    private func rareRewardPendingRows(
        sessionID: UUID
    ) throws -> [RareRewardPendingCommit] {
        let epochID = RareRewardLedgerV2.normalizedEpochID(dataEpochID)
        var descriptor = FetchDescriptor<RareRewardPendingCommit>(
            predicate: #Predicate {
                $0.sessionID == sessionID && $0.epochID == epochID
            },
            sortBy: [
                SortDescriptor(\RareRewardPendingCommit.createdAt),
                SortDescriptor(\RareRewardPendingCommit.id)
            ]
        )
        descriptor.fetchLimit = 32
        return try modelContext.fetch(descriptor).filter {
            ActivityResetPolicy.isCurrent(
                $0.dataEpochID,
                markers: resetSnapshots
            )
        }
    }

    @MainActor
    private func rareRewardPendingPayload(
        from rows: [RareRewardPendingCommit]
    ) throws -> (
        submission: RareRewardLedgerSubmission,
        migration: RareRewardLedgerMigration
    ) {
        guard let first = rows.first else {
            throw RareRewardLedgerLocalStateError.missingPendingCommit
        }
        let payload = try first.payload()
        for row in rows.dropFirst() {
            let candidate = try row.payload()
            guard candidate.submission == payload.submission,
                  candidate.migration == payload.migration else {
                throw RareRewardLedgerError.duplicateSessionPayloadMismatch
            }
        }
        return payload
    }

    private func validatePendingSubmission(
        _ submission: RareRewardLedgerSubmission,
        for result: PomodoroCompletion
    ) throws {
        guard submission.epochID
                == RareRewardLedgerV2.normalizedEpochID(dataEpochID),
              submission.sessionID == result.sessionID,
              submission.source == result.source,
              submission.completedSeconds == max(0, result.seconds),
              submission.completedGrams == max(0, result.grams) else {
            throw RareRewardLedgerError.duplicateSessionPayloadMismatch
        }
    }

    @MainActor
    private func rareRewardMigration() throws -> RareRewardLedgerMigration {
        if let cursor = try canonicalRareRewardCursor() {
            return try cursor.migration()
        }

        // A finalized V2 StudySession may reach this device before the cursor
        // that preserves its immutable V1 migration baseline. Deriving a fresh
        // fingerprint from the already-advanced GachaState would fork the
        // account, so wait for the cursor instead.
        let version = RareRewardLedgerV2.ruleVersion
        let finalizedPredicate: Predicate<StudySession>
        if let dataEpochID {
            finalizedPredicate = #Predicate {
                $0.dataEpochID == dataEpochID
                    && $0.rareRewardRuleVersion == version
                    && $0.rareRewardParticipated != nil
            }
        } else {
            finalizedPredicate = #Predicate {
                $0.dataEpochID == nil
                    && $0.rareRewardRuleVersion == version
                    && $0.rareRewardParticipated != nil
            }
        }
        let batchSize = 64
        var offset = 0
        while true {
            var descriptor = FetchDescriptor<StudySession>(
                predicate: finalizedPredicate,
                sortBy: [SortDescriptor(\StudySession.id)]
            )
            descriptor.fetchLimit = batchSize
            descriptor.fetchOffset = offset
            let batch = try modelContext.fetch(descriptor)
            if batch.contains(where: { StudySessionIntegrityPolicy.isSupported($0) }) {
                throw RareRewardLedgerLocalStateError.missingSynchronizedCursor
            }
            guard batch.count == batchSize else { break }
            offset = NonnegativeIntPolicy.adding(offset, batch.count)
        }

        return RareRewardLedgerMigration.canonicalV2(dataEpochID: dataEpochID)
    }

    @MainActor
    private func currentRareRewardCursors() throws -> [RareRewardLedgerCursor] {
        let epochID = RareRewardLedgerV2.normalizedEpochID(dataEpochID)
        var descriptor = FetchDescriptor<RareRewardLedgerCursor>(
            predicate: #Predicate { $0.epochID == epochID },
            sortBy: [
                SortDescriptor(\RareRewardLedgerCursor.revision, order: .reverse),
                SortDescriptor(\RareRewardLedgerCursor.updatedAt, order: .reverse),
                SortDescriptor(\RareRewardLedgerCursor.id)
            ]
        )
        descriptor.fetchLimit = 32
        return try modelContext.fetch(descriptor).filter {
            ActivityResetPolicy.isCurrent(
                $0.dataEpochID,
                markers: resetSnapshots
            )
        }
    }

    @MainActor
    private func canonicalRareRewardCursor(
        matching expectedMigration: RareRewardLedgerMigration? = nil
    ) throws -> RareRewardLedgerCursor? {
        let cursors = try currentRareRewardCursors()
        guard let canonical = cursors.first else { return nil }
        let migration = try canonical.migration()
        for cursor in cursors.dropFirst() {
            guard try cursor.migration() == migration else {
                throw RareRewardLedgerLocalStateError.conflictingCursors
            }
        }
        if let expectedMigration, migration != expectedMigration {
            throw RareRewardLedgerLocalStateError.conflictingCursors
        }
        return canonical
    }

    @MainActor
    private func finalizeRareReward(
        payload: (
            submission: RareRewardLedgerSubmission,
            migration: RareRewardLedgerMigration
        )
    ) async throws -> FocusCompletionPersistenceResult {
        _ = try canonicalRareRewardCursor(matching: payload.migration)
        let receipt = try await RareRewardLedgerRuntime.coordinator.commit(
            payload.submission,
            migration: payload.migration
        )
        guard receipt.epochID == payload.submission.epochID,
              receipt.sessionID == payload.submission.sessionID,
              receipt.submissionFingerprint == payload.submission.fingerprint
        else {
            throw RareRewardLedgerRepositoryError.corruptRecord
        }

        // CloudKit suspension is a re-entrancy boundary. A reset from another
        // device, or an import that replaces a duplicate row, may have happened
        // while the raw-ledger CAS was in flight. Never mutate the pre-await
        // SwiftData objects.
        let freshResetSnapshots = try ActivityResetStore.snapshots(
            context: modelContext
        )
        guard ActivityResetPolicy.state(
            of: dataEpochID,
            markers: freshResetSnapshots
        ) == .current else {
            let stalePending = try rareRewardPendingRowsUnfiltered(
                sessionID: payload.submission.sessionID,
                epochID: payload.submission.epochID
            )
            stalePending.forEach(modelContext.delete)
            try modelContext.save()
            return .discardedByReset
        }

        let sessionID = payload.submission.sessionID
        let freshSessions = try modelContext.fetch(
            FetchDescriptor<StudySession>(
                predicate: #Predicate { $0.id == sessionID }
            )
        ).filter {
            ActivityResetPolicy.isCurrent(
                $0.dataEpochID,
                markers: freshResetSnapshots
            )
        }
        guard !freshSessions.isEmpty,
              freshSessions.allSatisfy({
                  $0.id == payload.submission.sessionID
                      && $0.dataEpochID == dataEpochID
                      && $0.source == payload.submission.source
                      && $0.seconds == payload.submission.completedSeconds
                      && $0.grams == payload.submission.completedGrams
              }) else {
            throw RareRewardLedgerError.duplicateSessionPayloadMismatch
        }

        guard let mutationTarget = StudySessionSyncPolicy.canonicalSession(
            from: freshSessions
        ) else {
            throw RareRewardLedgerError.duplicateSessionPayloadMismatch
        }
        // This feature is disabled for 1.0. If it is re-enabled, never fan a
        // receipt out to CloudKit copies owned by other devices. Preserve every
        // other physical row as concurrent evidence and update one deterministic
        // source record only.
        mutationTarget.pebbleKind = receipt.representativeKind
        mutationTarget.rareRewardRuleVersion = RareRewardLedgerV2.ruleVersion
        mutationTarget.rareRewardParticipated = receipt.participated
        mutationTarget.rareRewardCreditedGrams = receipt.acceptedGrams
        mutationTarget.rareRewardOutcomesRawValue = RareRewardOutcomeCodec.encode(
            receipt.outcomes
        )

        let cursor: RareRewardLedgerCursor
        let previousRevision: Int64
        if let existing = try canonicalRareRewardCursor(
            matching: payload.migration
        ) {
            cursor = existing
            previousRevision = existing.revision
            cursor.apply(receipt, updatedAt: .now)
        } else {
            cursor = RareRewardLedgerCursor(
                id: payload.migration.epochID,
                dataEpochID: dataEpochID,
                migration: payload.migration,
                receipt: receipt
            )
            previousRevision = -1
            modelContext.insert(cursor)
        }
        // Refetch after the network suspension so an outbox duplicate delivered
        // by SwiftData/CloudKit while the CAS was in flight is retired too.
        let allPendingRows = try rareRewardPendingRowsUnfiltered(
            sessionID: payload.submission.sessionID,
            epochID: payload.submission.epochID
        )
        for row in allPendingRows {
            modelContext.delete(row)
        }
        // Session, cursor, and outbox are all assigned to the cloud store and
        // cross one atomic SQLite save boundary. GachaState is a rebuildable
        // local projection and must not participate in that transaction.
        try modelContext.save()

        if receipt.revisionAfter >= previousRevision {
            do {
                let epochID = dataEpochID
                let predicate: Predicate<GachaState>
                if let epochID {
                    predicate = #Predicate { $0.dataEpochID == epochID }
                } else {
                    predicate = #Predicate { $0.dataEpochID == nil }
                }
                let gachaRows = try modelContext.fetch(
                    FetchDescriptor<GachaState>(predicate: predicate)
                )
                let gacha = gachaRows.first(where: {
                    $0.id == BoundedLaunchPreparation.canonicalGachaID
                }) ?? gachaRows.first ?? GachaState(dataEpochID: dataEpochID)
                if gachaRows.isEmpty { modelContext.insert(gacha) }
                gacha.id = BoundedLaunchPreparation.canonicalGachaID
                gacha.dataEpochID = dataEpochID
                gacha.rewardCreditGrams = cursor.totalCreditedGrams
                gacha.sinceLastGold = cursor.sinceLastGold
                for duplicate in gachaRows where duplicate !== gacha {
                    modelContext.delete(duplicate)
                }
                try modelContext.save()
            } catch {
                // The synchronized cursor is authoritative. A launch or
                // maintenance pass reconstructs this disposable cache.
                modelContext.rollback()
            }
        }
        return .inserted(receipt.representativeKind)
    }

    @MainActor
    private func rareRewardPendingRowsUnfiltered(
        sessionID: UUID,
        epochID: UUID
    ) throws -> [RareRewardPendingCommit] {
        var descriptor = FetchDescriptor<RareRewardPendingCommit>(
            predicate: #Predicate {
                $0.sessionID == sessionID && $0.epochID == epochID
            },
            sortBy: [
                SortDescriptor(\RareRewardPendingCommit.createdAt),
                SortDescriptor(\RareRewardPendingCommit.id)
            ]
        )
        descriptor.fetchLimit = 32
        return try modelContext.fetch(descriptor)
    }

    private func signalCompletionIfNeeded(
        _ result: PomodoroCompletion,
        cue: TimerCompletionForegroundFeedbackPolicy.Cue
    ) {
        guard !didSignalCompletion else { return }
        didSignalCompletion = true
        NotificationManager.shared.cancelFocusCompletion(sessionID: result.sessionID)
        scheduledCompletionNotificationDeliveryDate = nil
        notificationScheduleState = .idle
        let soundOn = sensoryPreferences.soundOn
        let hapticsOn = sensoryPreferences.hapticsOn
        SoundSynth.shared.isEnabled = soundOn
        Haptics.shared.isEnabled = hapticsOn
        completionAlertWasAcknowledged =
            TimerCompletionAlertAcknowledgementStore.contains(
                sessionID: result.sessionID
            )
        let configuration = TimerCompletionAlertConfiguration(
            sessionID: result.sessionID,
            sound: soundOn ? sensoryPreferences.timerCompletionSound : nil,
            haptic: hapticsOn ? sensoryPreferences.timerCompletionHaptic : nil
        )
        if !completionAlertWasAcknowledged {
            switch cue {
            case .repeating:
                completionAlert.start(configuration)
            case .single:
                // The person is already looking at the screen. Mark the end
                // once and let the saved result continue to Home by itself.
                markCompletionAlertAcknowledged(result)
                completionAlert.playOnce(configuration)
            case .none:
                markCompletionAlertAcknowledged(result)
            }
        }
        UIApplication.shared.isIdleTimerDisabled = false
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(
                notification: .announcement,
                argument: "集中が完了しました。\(subjectSnapshot.name)、\(result.grams)グラムを保存しています"
            )
        }
    }

    /// A pending completion restored into a new view was consumed earlier,
    /// while the app was in the foreground. Reaching it again means the app
    /// was relaunched or its iCloud container remounted, which in practice
    /// happens only after the person left and came back. They are looking at
    /// the screen, so never re-arm the loop; the return is the acknowledgement.
    /// A loop still alive in this process keeps its Stop control instead.
    private func resumeCompletionAlertIfNeeded(
        _ result: PomodoroCompletion
    ) {
        completionAlertWasAcknowledged =
            TimerCompletionAlertAcknowledgementStore.contains(
                sessionID: result.sessionID
            )
        guard !completionAlertWasAcknowledged,
              !completionAlert.isActive(sessionID: result.sessionID)
        else { return }
        markCompletionAlertAcknowledged(result)
    }

    private func markCompletionAlertAcknowledged(_ result: PomodoroCompletion) {
        TimerCompletionAlertAcknowledgementStore.mark(
            sessionID: result.sessionID
        )
        completionAlertWasAcknowledged = true
    }

    /// A failed commit replaces a passive progress state with recovery
    /// controls. Move VoiceOver to the retry action after SwiftUI has mounted
    /// it, while leaving sighted keyboard/switch users' focus untouched.
    private func announceCompletionSaveFailure() {
        guard UIAccessibility.isVoiceOverRunning else { return }
        Task { @MainActor in
            await Task.yield()
            completionSaveRetryFocused = true
            UIAccessibility.post(
                notification: .announcement,
                argument: "記録をまだ安全に保存できていません。完走は端末に保護されています"
            )
        }
    }

    private func saveRecoveryState(pendingCompletion: PomodoroCompletion? = nil) {
        let envelope = makeRecoveryEnvelope(
            pendingCompletion: pendingCompletion
        )
        FocusPersistence.save(envelope)
        registerFocusReturnReminderIfNeeded(
            pendingCompletion: envelope.pendingCompletion
        )

        let resolvedPendingCompletion = envelope.pendingCompletion
        let status: SyncedFocusStatus
        if resolvedPendingCompletion != nil {
            status = .completionPending
        } else {
            switch engine.snapshot(at: .now).phase {
            case .focusing:
                status = .running
            case .paused:
                status = .paused
            default:
                return
            }
        }

        do {
            _ = try FocusCloudSyncStore.upsert(
                envelope: envelope,
                status: status,
                context: modelContext,
                deviceID: deviceID,
                claimIfUnowned: allowsLocalNotifications,
                now: envelope.savedAt
            )
            try modelContext.save()
        } catch {
            // Local recovery remains authoritative while offline. SwiftData
            // retries CloudKit transport after the local transaction succeeds;
            // serialization/store failures surface through the existing timer
            // retry path rather than discarding a running focus.
        }
    }

    private func makeRecoveryEnvelope(
        pendingCompletion: PomodoroCompletion? = nil
    ) -> FocusRecoveryEnvelope {
        let resolvedPendingCompletion = pendingCompletion ?? self.pendingCompletion
        return FocusRecoveryEnvelope(
            engine: engine,
            subject: subjectSnapshot,
            clockAnchor: clockAnchor,
            pendingCompletion: resolvedPendingCompletion,
            savedAt: .now,
            scheduledCompletionNotificationDeliveryDate:
                resolvedPendingCompletion == nil
                ? currentNotificationDeliveryWitness
                : nil,
            dataEpochID: dataEpochID
        )
    }

    /// Retain only a locally owned, running timer in the process-level
    /// notification manager. The CloudKit launch host can remove this view
    /// on inactive, before the subsequent background notification is sent.
    private func registerFocusReturnReminderIfNeeded(
        pendingCompletion: PomodoroCompletion? = nil
    ) {
        guard isViewActive,
              ownsCurrentTimer,
              pendingCompletion == nil,
              self.pendingCompletion == nil,
              completion == nil,
              engine.snapshot(at: .now).phase == .focusing,
              let sessionID = engine.currentSessionID,
              let endDate = engine.endDate,
              endDate > .now else { return }
        NotificationManager.shared.registerFocusReturnReminder(
            sessionID: sessionID,
            endDate: endDate,
            playsSound: sensoryPreferences.soundOn
        )
    }

    private func invalidateScheduledCompletionNotificationWitness() {
        guard scheduledCompletionNotificationDeliveryDate != nil else { return }
        scheduledCompletionNotificationDeliveryDate = nil
        guard engine.containsRecoverableFocus else { return }
        // This is device-local delivery evidence. Do not mutate CloudKit just
        // because notification permission changed outside the app.
        FocusPersistence.save(makeRecoveryEnvelope())
    }

    private var currentNotificationDeliveryWitness: Date? {
        guard let deliveryDate = scheduledCompletionNotificationDeliveryDate,
              let endDate = engine.endDate,
              deliveryDate >= endDate.addingTimeInterval(-0.01),
              deliveryDate <= endDate.addingTimeInterval(
                IntegrationConstants.notificationMinimumDelay
                    + IntegrationConstants
                        .notificationWitnessRegistrationAllowance
              )
        else { return nil }
        return deliveryDate
    }

    private func completionCommitView(_ result: PomodoroCompletion) -> some View {
        let isAlerting = completionAlert.isActive(sessionID: result.sessionID)
        let completionIcon = if completionSaveError != nil {
            "exclamationmark.arrow.triangle.2.circlepath"
        } else if isAlerting {
            "bell.and.waves.left.and.right.fill"
        } else if completionPersistenceSucceeded {
            "checkmark.circle.fill"
        } else {
            "arrow.down.to.line.compact"
        }

        return ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 42)
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.16))
                        .frame(width: 116, height: 116)
                    Image(systemName: completionIcon)
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(completionSaveError == nil ? accent : PomoGemTheme.amber)
                }
                VStack(spacing: 8) {
                    Text(completionSaveError == nil ? "粒を瓶へ運んでいます" : "記録をまだ安全に保存できていません")
                        .font(PomoGemTheme.brand(25))
                        .multilineTextAlignment(.center)
                    Text("\(subjectSnapshot.name)  +\(result.grams)g")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(PomoGemTheme.muted)
                }

                if isAlerting {
                    VStack(spacing: 8) {
                        Label(
                            "終了アラート中",
                            systemImage: "bell.and.waves.left.and.right.fill"
                        )
                        .font(.headline.weight(.bold))
                        .foregroundStyle(PomoGemTheme.amber)
                        Text("アプリが前面にある間、有効な音と触覚を停止するまで繰り返します")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)

                    Button {
                        acknowledgeCompletionAlert(result)
                    } label: {
                        Label("終了アラートを止める", systemImage: "stop.fill")
                    }
                    .buttonStyle(PomoGemPrimaryButtonStyle())
                    .padding(.horizontal, 24)
                    .accessibilityHint("音と触覚を止めます。記録の保存中でも操作できます")
                    .accessibilityIdentifier("focus.completion-alert.stop")
                }

                if let completionSaveError {
                    Text(completionSaveError)
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .accessibilityIdentifier("focus.completion-save.error")
                    Button {
                        Task { await commitCompletion(result) }
                    } label: {
                        Label(
                            completionWasRejectedForOwnership
                                ? "保存状態を確認する"
                                : "もう一度保存する",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(PomoGemPrimaryButtonStyle(tintHex: subjectSnapshot.colorHex))
                    .padding(.horizontal, 24)
                    .disabled(isCommittingCompletion)
                    .accessibilityFocused($completionSaveRetryFocused)
                    .accessibilityIdentifier("focus.completion-save.retry")

                    Button {
                        returnHomeKeepingCompletion(result)
                    } label: {
                        Label("完走を保護してホームへ戻る", systemImage: "house.fill")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(PomoGemBareButtonStyle())
                    .foregroundStyle(PomoGemTheme.text)
                    .padding(.horizontal, 24)
                    .accessibilityHint("完走は端末に残り、ホームから保存を再試行できます")
                    .accessibilityIdentifier("focus.completion-save.protect")
                } else if !completionPersistenceSucceeded {
                    ProgressView()
                        .tint(accent)
                        .controlSize(.large)
                        .accessibilityLabel("記録を保存中")
                } else if !isAlerting {
                    ProgressView()
                        .tint(accent)
                        .controlSize(.large)
                        .accessibilityLabel("瓶へ戻ります")
                }
                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: UIScreen.main.bounds.height)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func returnHomeKeepingCompletion(_ result: PomodoroCompletion) {
        TimerCompletionAlertAcknowledgementStore.mark(
            sessionID: result.sessionID
        )
        completionAlertWasAcknowledged = true
        completionAlert.stop(sessionID: result.sessionID)
        saveRecoveryState(pendingCompletion: result)
        DeferredFocusCompletionStore.mark(sessionID: result.sessionID)
        router.deferredFocusRecovery = RecoveredFocusRequest(
            subject: subject,
            subjectSnapshot: subjectSnapshot,
            engine: engine,
            clockAnchor: clockAnchor,
            pendingCompletion: result,
            dataEpochID: dataEpochID,
            origin: recoveryOrigin,
            allowsLocalNotifications: allowsLocalNotifications
        )
        UIApplication.shared.isIdleTimerDisabled = false
        router.showToast(
            "完走は端末に保護されています。ホームから保存を再試行できます",
            symbol: "checkmark.shield.fill",
            duration: .seconds(6)
        )
        dismiss()
    }

    private func togglePause() {
        let now = Date.now
        do {
            if snapshot.phase == .paused {
                try engine.resume(at: now)
                if let sessionID = engine.currentSessionID, let endDate = engine.endDate {
                    Task {
                        if notifications.isAuthorized {
                            await scheduleCurrentCompletionNotification()
                        }
                        await FocusActivityManager.shared.resume(sessionID: sessionID, endDate: endDate)
                    }
                }
            } else {
                try engine.pause(at: now)
                if let sessionID = engine.currentSessionID {
                    NotificationManager.shared.cancelFocusCompletion(sessionID: sessionID)
                    scheduledCompletionNotificationDeliveryDate = nil
                    notificationScheduleState = .idle
                    Task {
                        await FocusActivityManager.shared.pause(
                            sessionID: sessionID,
                            remainingSeconds: engine.snapshot(at: now).remainingSeconds
                        )
                    }
                }
            }
            updateIdleTimer(at: now)
            saveRecoveryState()
            displayNow = now
        } catch {
            operationErrorMessage = error.localizedDescription
        }
    }

    private func startBreak() {
        do {
            try engine.startBreak(now: .now)
            completion = nil
            displayNow = .now
            saveRecoveryState()
            updateIdleTimer()
        } catch {
            operationErrorMessage = error.localizedDescription
        }
    }

    private func skipBreak() {
        try? engine.skipBreak()
        FocusPersistence.clear()
        UIApplication.shared.isIdleTimerDisabled = false
        breakFinished = true
    }

    private func giveUp() {
        operationErrorMessage = nil
        let sessionID = engine.currentSessionID
        if let sessionID {
            do {
                // Persist the shared cancellation before mutating the local
                // engine or clearing its recovery envelope. If the local store
                // cannot commit the tombstone, the visible timer, notification
                // and recovery state all remain live and retryable.
                try FocusCloudSyncStore.markTerminal(
                    sessionID: sessionID,
                    status: .cancelled,
                    context: modelContext,
                    deviceID: deviceID
                )
                try modelContext.save()
            } catch {
                modelContext.rollback()
                operationErrorMessage = "終了状態を安全に保存できませんでした。タイマーは継続しています。もう一度お試しください。"
                return
            }
        }
        _ = engine.cancel()
        FocusPersistence.clear()
        UIApplication.shared.isIdleTimerDisabled = false
        if let sessionID {
            NotificationManager.shared.cancelFocusCompletion(sessionID: sessionID)
            scheduledCompletionNotificationDeliveryDate = nil
            Task { await FocusActivityManager.shared.cancel(sessionID: sessionID) }
        }
        dismiss()
    }

    @discardableResult
    private func enforceCloudOwnership() -> Bool {
        let now = Date.now
        if pendingCompletion == nil,
           completion == nil,
           engine.containsRecoverableFocus,
           engine.snapshot(at: now).remainingSeconds == 0 {
            // The fingerprint callback can run before scene activation after a
            // background CloudKit import. Preserve the deterministic completion
            // witness first; the current owner will be the only device allowed
            // to turn it into a StudySession.
            // A query callback can arrive while Notification Center is about
            // to deliver the same end. Defer local completion until active so
            // the pending request is not cancelled from the background.
            guard scenePhase == .active,
                  notificationAuthorizationIsCurrent,
                  !notificationScheduleState.isScheduling else {
                // Do not let a remote terminal row erase an already elapsed
                // local completion while delivery state is still unresolved.
                return false
            }
            let completionUptime = ContinuousUptime.now()
            advanceIfNeeded(
                at: now,
                uptime: completionUptime,
                cue: completionCueForElapsedTimer(
                    at: now,
                    uptime: completionUptime,
                    returnedFromBackground:
                        didEnterBackgroundSinceLastActive
                )
            )
            if pendingCompletion != nil { return false }
        }
        guard pendingCompletion == nil,
              completion == nil,
              let sessionID = engine.currentSessionID else { return false }

        let owner = try? FocusCloudSyncStore.notificationOwner(
            sessionID: sessionID,
            context: modelContext
        )
        let canonicalSessionID: UUID?
        do {
            canonicalSessionID = try FocusCloudSyncStore.canonicalActive(
                context: modelContext
            )?.sessionID
        } catch {
            // A bounded-query or maintenance failure cannot prove this local
            // timer lost. Keep its recovery bytes, notification, and Live
            // Activity until a later import/maintenance pass can decide.
            return false
        }
        let lostOwnership = owner != nil && owner != deviceID
        let superseded: Bool
        if let canonicalSessionID {
            superseded = canonicalSessionID != sessionID
        } else {
            // No global candidate is not, by itself, proof of supersession: a
            // partial CloudKit import can expose closure witnesses before the
            // matching StudySession. Only exact irreversible closure may retire
            // the active local UI here.
            guard let gate = try? FocusCloudSyncStore.completionGate(
                sessionID: sessionID,
                context: modelContext
            ) else { return false }
            superseded = gate == .cancelledBeforeCompletion
                || gate == .materialized
        }
        guard lostOwnership || superseded else { return false }

        NotificationManager.shared.cancelFocusCompletion(sessionID: sessionID)
        completionAlert.stop(sessionID: sessionID)
        scheduledCompletionNotificationDeliveryDate = nil
        notificationScheduleState = .idle
        FocusPersistence.clear()
        UIApplication.shared.isIdleTimerDisabled = false
        Task { await FocusActivityManager.shared.cancel(sessionID: sessionID) }
        router.showToast(
            lostOwnership
                ? "タイマーは別の端末へ引き継がれました"
                : "先に始めた別端末のタイマーを残しました",
            symbol: "icloud.and.arrow.up"
        )
        dismiss()
        return true
    }

    private func enforceActivityReset() {
        guard ActivityResetPolicy.state(
            of: dataEpochID,
            markers: resetSnapshots
        ) != .current else { return }
        if let sessionID = currentSessionID {
            NotificationManager.shared.cancelFocusCompletion(sessionID: sessionID)
            completionAlert.stop(sessionID: sessionID)
            scheduledCompletionNotificationDeliveryDate = nil
            Task { await FocusActivityManager.shared.cancel(sessionID: sessionID) }
        }
        notificationScheduleState = .idle
        FocusPersistence.clear()
        UIApplication.shared.isIdleTimerDisabled = false
        router.showToast(
            "別の端末で記録がリセットされたため、このタイマーを終了しました",
            symbol: "trash"
        )
        dismiss()
    }

    private func handleScenePhase(to newPhase: ScenePhase) {
        if newPhase == .background {
            didEnterBackgroundSinceLastActive = true
        }
        if newPhase == .inactive || newPhase == .background {
            saveRecoveryState()
            UIApplication.shared.isIdleTimerDisabled = false
            return
        }

        guard newPhase == .active else { return }

        if didEnterBackgroundSinceLastActive,
           let pendingCompletion,
           completionAlert.isActive(sessionID: pendingCompletion.sessionID) {
            // The phone locked or the person switched apps while the alarm was
            // repeating. Coming back is the acknowledgement: stop it and let
            // the saved result continue instead of ringing at them again.
            acknowledgeCompletionAlert(pendingCompletion)
        }

        let returnDate = Date.now
        let returnUptime = ContinuousUptime.now()
        let completionIsElapsed = (engine.endDate ?? .distantFuture) <= returnDate
        if completionIsElapsed, notificationScheduleState.isScheduling {
            // The ticker consumes this once add succeeds or fails. Keep the
            // background-return flag until delivery possibility is known.
            displayNow = returnDate
            UIApplication.shared.isIdleTimerDisabled = false
            return
        }
        let cue: TimerCompletionForegroundFeedbackPolicy.Cue
        if completionIsElapsed {
            cue = completionCueForElapsedTimer(
                at: returnDate,
                uptime: returnUptime,
                returnedFromBackground: didEnterBackgroundSinceLastActive
            )
        } else {
            isAwaitingRecoveryActivation = false
            cue = .repeating
        }
        didEnterBackgroundSinceLastActive = false
        displayNow = returnDate
        updateIdleTimer(at: returnDate)
        advanceIfNeeded(
            at: returnDate,
            uptime: returnUptime,
            cue: cue
        )
    }

    private func completionCueForElapsedTimer(
        at now: Date,
        uptime: TimeInterval,
        returnedFromBackground: Bool
    ) -> TimerCompletionForegroundFeedbackPolicy.Cue {
        let recoveredAfterExpiration = isAwaitingRecoveryActivation
        isAwaitingRecoveryActivation = false
        // Time-interval notifications run against elapsed time, while the
        // persisted witness is a wall-clock Date. If the wall clock moved,
        // never suppress the foreground cue based on that Date: the OS request
        // can still be pending on its relative clock.
        let notificationTimingIsTrustworthy =
            TimerCompletionForegroundFeedbackPolicy
                .notificationTimingIsTrustworthy(
                    source: engine.currentSource,
                    clockAnchor: clockAnchor,
                    now: now,
                    uptime: uptime
                )
        return TimerCompletionForegroundFeedbackPolicy.cue(
            recoveredAfterExpiration: recoveredAfterExpiration,
            returnedFromBackground: returnedFromBackground,
            notificationMayHaveDelivered:
                TimerCompletionForegroundFeedbackPolicy
                    .notificationMayHaveDelivered(
                        isAuthorized: notifications.isAuthorized,
                        expectedDeliveryDate:
                            notificationTimingIsTrustworthy
                            ? currentNotificationDeliveryWitness
                            : nil,
                        now: now
                    ),
            endedAt: engine.endDate ?? now,
            now: now
        )
    }

    private func formattedTime(_ total: Int) -> String {
        let safe = max(0, total)
        return String(format: "%02d:%02d", safe / 60, safe % 60)
    }

    private func accessibleTime(_ total: Int) -> String {
        let safe = max(0, total)
        return "残り\(safe / 60)分\(safe % 60)秒"
    }
}

private struct RareRewardPreFocusChoiceView: View {
    @Binding var selection: RareRewardMode?
    let errorMessage: String?
    let isSaving: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                RareRewardChoicePanel(
                    selection: $selection,
                    eyebrow: "BEFORE YOUR FIRST FOCUS",
                    title: "タイマーの前に、1つだけ。",
                    introduction: "まだレア粒の扱いを選んでいません。説明なしで抽選creditを貯め始めないため、最初の実測タイマーより前に確認します。"
                )

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("focus.rare-reward-choice.error")
                }

                Button(action: onConfirm) {
                    if isSaving {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Text("この選択でタイマーへ")
                    }
                }
                .buttonStyle(PomoGemPrimaryButtonStyle())
                .disabled(selection == nil || isSaving)
                .accessibilityHint(
                    selection == nil
                        ? "3つの選択肢から1つ選んでください"
                        : "選択を保存領域へ確定してからタイマーを開始します"
                )
                .accessibilityIdentifier("focus.rare-reward-choice.confirm")

                Button("今は戻る", action: onCancel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PomoGemTheme.muted)
                    .frame(minHeight: 44)
                    .buttonStyle(PomoGemBareButtonStyle())
                    .disabled(isSaving)
                    .accessibilityHint("選択やタイマーを開始せず瓶へ戻ります")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.black.ignoresSafeArea())
        .accessibilityIdentifier("focus.rare-reward-choice")
    }
}

enum FocusTimerLayoutPolicy {
    static func ringSize(in container: CGSize) -> CGFloat {
        guard container.width.isFinite,
              container.height.isFinite,
              container.width > 0,
              container.height > 0
        else { return 1 }

        if container.width > container.height {
            return max(1, min(286, container.height - 84, (container.width - 88) / 2))
        }
        let heightCap: CGFloat = container.height < 650 ? 214 : 286
        return max(1, min(container.width - 64, heightCap))
    }
}

enum FocusTimerDisplayPolicy {
    static func normalizedProgress(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        return min(1, max(0, progress))
    }

    static func remainingFraction(for progress: Double) -> Double {
        1 - normalizedProgress(progress)
    }
}

/// Both ring and dial begin full and remove elapsed time clockwise from
/// twelve o'clock. The remaining colored area always represents time left.
struct FocusTimerDisplay: View {
    let size: CGFloat
    let progress: Double
    let remainingTime: String
    let accessibleRemainingTime: String
    let modeLabel: String
    let displayMode: TimerDisplayMode
    let isBreakMode: Bool
    let isPaused: Bool
    let accent: Color
    let reduceMotion: Bool

    @ScaledMetric(relativeTo: .largeTitle) private var scaledTimerSize = Constants.Typography.timerSize
    @ScaledMetric(relativeTo: .body) private var scaledLineWidth: CGFloat = 9

    private var normalizedProgress: Double {
        FocusTimerDisplayPolicy.normalizedProgress(progress)
    }

    private var remainingPercent: Int {
        Int((FocusTimerDisplayPolicy.remainingFraction(for: progress) * 100).rounded())
    }

    private var lineWidth: CGFloat {
        min(14, max(8, scaledLineWidth))
    }

    private var timerSize: CGFloat {
        min(scaledTimerSize, size * 0.33)
    }

    private var arcHeadOffset: CGSize {
        let radius = max(0, Double((size - lineWidth) / 2))
        let angle = normalizedProgress * 2 * Double.pi
        return CGSize(
            width: CGFloat(sin(angle) * radius),
            height: CGFloat(-cos(angle) * radius)
        )
    }

    private var accessibleMode: String {
        isBreakMode ? "休憩タイマー" : "集中タイマー"
    }

    var body: some View {
        ZStack {
            switch displayMode {
            case .ringAndTime:
                remainingRing
                currentLabels
            case .filledDial:
                remainingDial
            case .timeOnly:
                remainingTimeLabel
                    .padding(max(24, lineWidth * 2.5))
            case .ringOnly:
                remainingRing
                statusLabel
                    .padding(max(24, lineWidth * 2.5))
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleMode)
        .accessibilityValue(
            "\(accessibleRemainingTime)、\(remainingPercent)パーセント残り"
                + (isPaused ? "、一時停止中" : "")
        )
        .accessibilityHint(isPaused ? "再開ボタンでタイマーを再開できます" : "一時停止ボタンでタイマーを止められます")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("focus.timer-display")
    }

    private var remainingRing: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.09), lineWidth: lineWidth)

            Circle()
                .trim(from: normalizedProgress, to: 1)
                .stroke(
                    accent,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: accent.opacity(0.38), radius: 14)
                .animation(
                    reduceMotion ? nil : .linear(duration: 0.25),
                    value: normalizedProgress
                )

            // The boundary advances clockwise as the remaining arc shrinks.
            Circle()
                .fill(accent.opacity(normalizedProgress < 1 ? 0.58 : 0))
                .frame(
                    width: max(5, lineWidth * 0.58),
                    height: max(5, lineWidth * 0.58)
                )
                .offset(y: -(size - lineWidth) / 2)
                .accessibilityHidden(true)

            if normalizedProgress > 0, normalizedProgress < 1 {
                Circle()
                    .fill(isPaused ? PomoGemTheme.amber : .white)
                    .overlay {
                        Circle().stroke(accent, lineWidth: 2)
                    }
                    .frame(width: lineWidth, height: lineWidth)
                    .shadow(color: accent.opacity(0.72), radius: 7)
                    .offset(arcHeadOffset)
                    .animation(
                        reduceMotion ? nil : .linear(duration: 0.25),
                        value: normalizedProgress
                    )
                    .accessibilityHidden(true)
            }
        }
    }

    private var remainingDial: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.055))

            FocusRemainingDialShape(elapsedProgress: normalizedProgress)
                .fill(accent.opacity(isPaused ? 0.72 : 0.92))
                .shadow(color: accent.opacity(0.34), radius: 18)
                .animation(
                    reduceMotion ? nil : .linear(duration: 0.25),
                    value: normalizedProgress
                )

            Circle()
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
    }

    private var currentLabels: some View {
        VStack(spacing: 9) {
            remainingTimeLabel
            statusLabel
        }
        .padding(max(24, lineWidth * 2.5))
    }

    private var statusLabel: some View {
        Text("\(modeLabel)  ·  \(remainingPercent)% 残り")
            .font(.caption2.weight(.bold))
            .tracking(1.2)
            .foregroundStyle(
                isPaused ? PomoGemTheme.amber : PomoGemTheme.muted
            )
            .minimumScaleFactor(0.72)
            .lineLimit(1)
    }

    private var remainingTimeLabel: some View {
        Text(remainingTime)
            .font(.system(size: timerSize, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(PomoGemTheme.text)
            .minimumScaleFactor(0.62)
            .lineLimit(1)
            .contentTransition(
                reduceMotion ? .identity : .numericText(countsDown: true)
            )
    }
}

struct FocusRemainingDialShape: Shape {
    var elapsedProgress: Double

    var animatableData: Double {
        get { elapsedProgress }
        set { elapsedProgress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let normalizedProgress = FocusTimerDisplayPolicy.normalizedProgress(
            elapsedProgress
        )
        let remaining = FocusTimerDisplayPolicy.remainingFraction(
            for: normalizedProgress
        )
        guard remaining > 0 else { return Path() }

        if remaining >= 1 {
            var path = Path()
            path.addEllipse(in: rect)
            return path
        }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let startDegrees = -90 + (360 * normalizedProgress)
        let startRadians = CGFloat(startDegrees * .pi / 180)
        var path = Path()
        path.move(to: center)
        path.addLine(to: CGPoint(
            x: center.x + (radius * cos(startRadians)),
            y: center.y + (radius * sin(startRadians))
        ))
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(startDegrees),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

private enum FocusNotificationScheduleState: Equatable {
    case idle
    case scheduling
    case scheduled
    case failed(message: String)

    var isScheduling: Bool {
        if case .scheduling = self { return true }
        return false
    }
}

private struct CompletedDrop: Equatable {
    let kind: PebbleKind
    let grams: Int
    let message: String
    let isDemoted: Bool
}

private struct FocusCompletionView: View {
    let completion: CompletedDrop
    let subjectColor: Color
    let reduceMotion: Bool
    let onStartBreak: () -> Void
    let onReturnToJar: () -> Void

    @State private var landed = false

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            SectionEyebrow(text: "THE DROP")
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(.white.opacity(0.025))
                    .overlay {
                        RoundedRectangle(cornerRadius: 34, style: .continuous)
                            .stroke(PomoGemTheme.glassEdge, lineWidth: 2)
                    }
                Circle()
                    .fill(pebbleFill)
                    .overlay {
                        if completion.isDemoted {
                            Circle().stroke(.white.opacity(0.72), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                        } else {
                            Circle().fill(
                                RadialGradient(colors: [.white.opacity(0.62), .clear], center: .topLeading, startRadius: 0, endRadius: 20)
                            )
                        }
                    }
                    .frame(width: 46, height: 46)
                    .shadow(color: completion.kind == .normal ? .clear : PomoGemTheme.amber.opacity(0.55), radius: 20)
                    .offset(y: landed ? -16 : -300)
                    .animation(
                        reduceMotion ? .none : .interpolatingSpring(stiffness: 125, damping: 13),
                        value: landed
                    )
            }
            .frame(width: 230, height: 330)

            VStack(spacing: 8) {
                Text(completion.message)
                    .font(PomoGemTheme.brand(22))
                    .multilineTextAlignment(.center)
                if completion.isDemoted {
                    Text(Constants.UIStrings.interruptionNote)
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()
            VStack(spacing: 11) {
                Button("休憩をはじめる", action: onStartBreak)
                    .buttonStyle(PomoGemPrimaryButtonStyle())
                Button("瓶を見る", action: onReturnToJar)
                    .buttonStyle(PomoGemSecondaryButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .task {
            if reduceMotion {
                landed = true
            } else {
                try? await Task.sleep(for: .milliseconds(120))
                landed = true
            }
        }
    }

    private var pebbleFill: AnyShapeStyle {
        switch completion.kind {
        case .normal:
            AnyShapeStyle(subjectColor)
        case .gold:
            AnyShapeStyle(RadialGradient(colors: [.white, Color("pebble.gold"), .orange], center: .topLeading, startRadius: 0, endRadius: 46))
        case .prism:
            AnyShapeStyle(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
        }
    }
}

private struct BreakFinishedView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 44))
                .foregroundStyle(PomoGemTheme.amber)
            Text("休憩はここまで")
                .font(PomoGemTheme.brand(30))
            Text("瓶の粒は、そのまま待っています。")
                .foregroundStyle(PomoGemTheme.muted)
            Spacer()
            Button("瓶へ戻る", action: onClose)
                .buttonStyle(PomoGemPrimaryButtonStyle())
                .padding(24)
        }
    }
}

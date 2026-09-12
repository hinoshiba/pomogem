import Foundation

enum PomodoroDuration: Hashable, Codable, Sendable {
    case twentyFiveMinutes
    case sixtyMinutes
    /// Keep this case's synthesized Codable payload in minutes for existing
    /// local and iCloud recovery data. Precise durations use an additive case.
    case custom(minutes: Int)
    case customSeconds(totalSeconds: Int)

#if DEBUG
    case demo
#endif

    static let freePresets: [PomodoroDuration] = [
        .twentyFiveMinutes,
        .custom(minutes: Constants.Timer.fortyFiveMinutes),
        .sixtyMinutes,
        .custom(minutes: Constants.Timer.ninetyMinutes)
    ]

    /// An exact whole-minute duration, never a rounded value. Consumers that
    /// present or persist arbitrary durations must use seconds instead.
    var minutes: Int? {
        switch self {
        case .twentyFiveMinutes:
            Constants.Timer.twentyFiveMinutes
        case .sixtyMinutes:
            Constants.Timer.sixtyMinutes
        case let .custom(minutes):
            minutes
        case let .customSeconds(totalSeconds):
            totalSeconds.isMultiple(of: Constants.Timer.secondsPerMinute)
                ? totalSeconds / Constants.Timer.secondsPerMinute
                : nil
#if DEBUG
        case .demo:
            nil
#endif
        }
    }

    var seconds: Int {
        switch self {
        case let .customSeconds(totalSeconds):
            return totalSeconds
#if DEBUG
        case .demo:
            return Constants.Timer.demoSeconds
#endif
        default:
            // A synthesized Codable value can contain any Int. Presentation
            // must not trap before the admission checks reject invalid data.
            let result = (minutes ?? 0).multipliedReportingOverflow(
                by: Constants.Timer.secondsPerMinute
            )
            return result.overflow ? 0 : result.partialValue
        }
    }

    var displayLabel: String {
        guard isValid else { return "設定できない時間" }
        let wholeMinutes = seconds / Constants.Timer.secondsPerMinute
        let remainder = seconds % Constants.Timer.secondsPerMinute
        if wholeMinutes == 0 { return "\(remainder)秒" }
        if remainder == 0 { return "\(wholeMinutes)分" }
        return "\(wholeMinutes)分\(remainder)秒"
    }

    var grams: Int {
#if DEBUG
        if case .demo = self {
            return Constants.Mass.measuredPebbleGrams
        }
#endif
        return seconds / Constants.Timer.secondsPerMinute * Constants.Mass.gramsPerMinute
    }

    var requiresPro: Bool {
#if DEBUG
        if case .demo = self { return false }
#endif
        return !IntegrationConstants.isFreeFocusDuration(seconds)
    }

    var isValid: Bool {
        switch self {
        case let .custom(minutes):
            return (Constants.Timer.customMinimumMinutes ... Constants.Timer.customMaximumMinutes)
                .contains(minutes)
        case let .customSeconds(totalSeconds):
            let minimumSeconds = Constants.Timer.customMinimumMinutes * Constants.Timer.secondsPerMinute
            let maximumSeconds = Constants.Timer.customMaximumMinutes * Constants.Timer.secondsPerMinute
            return (minimumSeconds ... maximumSeconds).contains(totalSeconds)
        default:
            return true
        }
    }

    init(minutes: Int) {
        switch minutes {
        case Constants.Timer.twentyFiveMinutes:
            self = .twentyFiveMinutes
        case Constants.Timer.sixtyMinutes:
            self = .sixtyMinutes
        default:
            self = .custom(minutes: minutes)
        }
    }

    /// Whole minutes keep their existing representation; invalid input stays
    /// invalid rather than being clamped into a different timer duration.
    init(totalSeconds: Int) {
        if totalSeconds.isMultiple(of: Constants.Timer.secondsPerMinute) {
            self.init(minutes: totalSeconds / Constants.Timer.secondsPerMinute)
        } else {
            self = .customSeconds(totalSeconds: totalSeconds)
        }
    }

    var normalized: PomodoroDuration {
        switch self {
        case let .custom(minutes):
            PomodoroDuration(minutes: minutes)
        case let .customSeconds(totalSeconds):
            PomodoroDuration(totalSeconds: totalSeconds)
        default:
            self
        }
    }
}

enum PomodoroPhase: String, Codable, Sendable {
    case idle
    case focusing
    case shortBreak
    case longBreak
    case paused
    case focusCompleted
    case breakCompleted

    var isRunning: Bool {
        self == .focusing || self == .shortBreak || self == .longBreak
    }

    var isBreak: Bool {
        self == .shortBreak || self == .longBreak
    }
}

enum TimerScreenAwakePolicy {
    static func shouldKeepScreenAwake(
        preferenceEnabled: Bool,
        sceneIsActive: Bool,
        timerIsRunning: Bool,
        remainingSeconds: Int
    ) -> Bool {
        preferenceEnabled
            && sceneIsActive
            && timerIsRunning
            && remainingSeconds > 0
    }
}

struct PomodoroSnapshot: Equatable, Sendable {
    let phase: PomodoroPhase
    let remainingSeconds: Int
    let progress: Double
    let endDate: Date?
    let sessionID: UUID?
    let source: SessionSource
}

struct PomodoroCompletion: Codable, Equatable, Sendable {
    let sessionID: UUID
    let startedAt: Date
    /// The scheduled end is used instead of a late display tick, keeping the
    /// recorded duration stable when the app resumes from the background.
    let endedAt: Date
    let observedAt: Date
    /// Monotonic time captured at the same instant as `observedAt`.
    ///
    /// This value travels with a pending completion so a delayed SwiftData
    /// save (or a retry after relaunch) never compares an old wall-clock date
    /// with a new process uptime. It is optional solely for recovery payloads
    /// written by app versions predating this field.
    let observedUptime: TimeInterval?
    let duration: PomodoroDuration
    let seconds: Int
    let grams: Int
    let source: SessionSource

    init(
        sessionID: UUID,
        startedAt: Date,
        endedAt: Date,
        observedAt: Date,
        observedUptime: TimeInterval? = nil,
        duration: PomodoroDuration,
        seconds: Int,
        grams: Int,
        source: SessionSource
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.observedAt = observedAt
        self.observedUptime = observedUptime
        self.duration = duration
        self.seconds = seconds
        self.grams = grams
        self.source = source
    }

    func replacingSource(with source: SessionSource) -> PomodoroCompletion {
        PomodoroCompletion(
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: endedAt,
            observedAt: observedAt,
            observedUptime: observedUptime,
            duration: duration,
            seconds: seconds,
            grams: grams,
            source: source
        )
    }
}

enum PomodoroEvent: Equatable, Sendable {
    case focusCompleted(PomodoroCompletion)
    case breakCompleted
}

enum PomodoroRecoveryResult: Equatable, Sendable {
    case nothingToRecover
    case interruptedFocus(sessionID: UUID)
    case discardedBreak
}

enum PomodoroEngineError: Error, Equatable, Sendable {
    case invalidTransition(from: PomodoroPhase)
    case customDurationRequiresPro
    case invalidCustomDuration
    case phaseAlreadyElapsed
}

/// A deterministic Pomodoro state machine. It never decrements a counter:
/// every snapshot is derived from an absolute `endDate`, so display-timer
/// drift, daylight-saving changes and delayed background ticks do not alter
/// completion time.
struct PomodoroEngine: Codable, Equatable, Sendable {
    /// No shipping focus can exceed this interval. Besides keeping presentation
    /// arithmetic bounded, this is the ceiling used when inspecting decoded
    /// recovery data before it reaches a `Double`-to-`Int` conversion.
    static let maximumSupportedRemainingSeconds =
        Constants.Timer.customMaximumMinutes * Constants.Timer.secondsPerMinute

    /// More than 475 years of nonstop 25-minute sessions. Real state never
    /// approaches this ceiling; it exists so a decoded integer cannot be
    /// advanced into an overflow on a later completion.
    static let maximumSupportedCompletedFocusCount = 10_000_000

    private(set) var phase: PomodoroPhase
    private(set) var selectedDuration: PomodoroDuration
    private(set) var completedFocusCount: Int
    private(set) var phaseStartedAt: Date?
    private(set) var endDate: Date?
    private(set) var currentSessionID: UUID?
    private(set) var currentSource: SessionSource

    private var phaseDuration: TimeInterval
    private var pausedPhase: PomodoroPhase?
    private var pausedRemaining: TimeInterval?

    var containsRecoverableFocus: Bool {
        phase == .focusing || (phase == .paused && pausedPhase == .focusing)
    }

    var containsRecoverableBreak: Bool {
        phase.isBreak || (phase == .paused && pausedPhase?.isBreak == true)
    }

    /// Structural validation for a running focus decoded from persistence or
    /// CloudKit. This deliberately performs no snapshot calculation: decoded
    /// `Date` and `Double` values are untrusted until every conversion-sensitive
    /// field has been checked.
    var hasValidRunningFocusPayloadState: Bool {
        guard hasValidFocusPayloadBase,
              phase == .focusing,
              pausedPhase == nil,
              pausedRemaining == nil,
              let phaseStartedAt,
              let endDate,
              Self.isSafePersistedDate(phaseStartedAt),
              Self.isSafePersistedDate(endDate)
        else { return false }

        let wallSpan = endDate.timeIntervalSince(phaseStartedAt)
        return wallSpan.isFinite && wallSpan >= phaseDuration
    }

    /// Structural validation for a paused focus decoded from persistence or
    /// CloudKit. Paused remaining time has an explicit product-domain ceiling,
    /// so resuming it cannot manufacture an unbounded future date.
    var hasValidPausedFocusPayloadState: Bool {
        guard hasValidFocusPayloadBase,
              phase == .paused,
              pausedPhase == .focusing,
              endDate == nil,
              let phaseStartedAt,
              Self.isSafePersistedDate(phaseStartedAt),
              let pausedRemaining,
              pausedRemaining.isFinite,
              pausedRemaining > 0,
              pausedRemaining <= TimeInterval(Self.maximumSupportedRemainingSeconds)
        else { return false }
        return true
    }

    /// A pending completion normally retains its session identifier. Version 1
    /// recovery bytes that cleared only that identifier remain admissible, but
    /// all other terminal engine fields must still be inert and bounded.
    var hasValidCompletedFocusPayloadState: Bool {
        guard hasValidPayloadCommonFields,
              phase == .focusCompleted,
              phaseStartedAt == nil,
              endDate == nil,
              phaseDuration == 0,
              pausedPhase == nil,
              pausedRemaining == nil
        else { return false }
        return true
    }

    /// Breaks are persisted in the same recovery envelope after a completed
    /// focus. They do not award mass, but still need bounded dates and numeric
    /// fields before a decoded engine reaches snapshot/resume code.
    var hasValidRecoverableBreakPayloadState: Bool {
        guard hasValidPayloadCommonFields,
              currentSessionID == nil,
              let phaseStartedAt,
              Self.isSafePersistedDate(phaseStartedAt)
        else { return false }

        let breakPhase: PomodoroPhase
        if phase.isBreak {
            guard pausedPhase == nil,
                  pausedRemaining == nil,
                  let endDate,
                  Self.isSafePersistedDate(endDate),
                  endDate.timeIntervalSince(phaseStartedAt).isFinite,
                  endDate > phaseStartedAt
            else { return false }
            breakPhase = phase
        } else {
            guard phase == .paused,
                  let pausedPhase,
                  pausedPhase.isBreak,
                  endDate == nil,
                  let pausedRemaining,
                  pausedRemaining.isFinite,
                  pausedRemaining > 0
            else { return false }
            breakPhase = pausedPhase
        }

        let expectedSeconds: Int
        switch breakPhase {
        case .shortBreak:
            expectedSeconds = Constants.Timer.shortBreakMinutes
                * Constants.Timer.secondsPerMinute
        case .longBreak:
            expectedSeconds = Constants.Timer.longBreakMinutes
                * Constants.Timer.secondsPerMinute
        default:
            return false
        }
        guard phaseDuration == TimeInterval(expectedSeconds) else { return false }
        if let pausedRemaining {
            return pausedRemaining <= TimeInterval(expectedSeconds)
        }
        return true
    }

    /// Validates the frozen award and the terminal engine that produced it.
    /// Callers use this before materializing decoded completion data into a
    /// StudySession or performing duration-derived integer arithmetic.
    func hasValidPersistedCompletion(_ completion: PomodoroCompletion) -> Bool {
        guard completion.duration.isValid,
              completion.seconds == completion.duration.seconds,
              completion.grams == completion.duration.grams,
              completion.seconds > 0,
              Self.isSafePersistedDate(completion.startedAt),
              Self.isSafePersistedDate(completion.endedAt),
              Self.isSafePersistedDate(completion.observedAt),
              completion.endedAt > completion.startedAt,
              completion.endedAt.timeIntervalSince(completion.startedAt).isFinite,
              completion.endedAt.timeIntervalSince(completion.startedAt)
                >= TimeInterval(completion.seconds),
              completion.observedAt >= completion.endedAt,
              completion.observedUptime.map({ $0.isFinite && $0 >= 0 }) ?? true,
              hasValidCompletedFocusPayloadState,
              selectedDuration.normalized == completion.duration.normalized,
              currentSource == completion.source
        else { return false }

        // Version 1 recovery bytes may have cleared only this identifier.
        return currentSessionID == nil || currentSessionID == completion.sessionID
    }

    static func isSafePersistedDate(_ date: Date) -> Bool {
        let value = date.timeIntervalSinceReferenceDate
        return value.isFinite
            && value >= Date.distantPast.timeIntervalSinceReferenceDate
            && value <= Date.distantFuture.timeIntervalSinceReferenceDate
    }

    private var hasValidFocusPayloadBase: Bool {
        guard hasValidPayloadCommonFields,
              currentSessionID != nil
        else { return false }
        return phaseDuration == TimeInterval(selectedDuration.seconds)
            && phaseDuration > 0
            && phaseDuration <= TimeInterval(Self.maximumSupportedRemainingSeconds)
    }

    private var hasValidPayloadCommonFields: Bool {
        selectedDuration.isValid
            && completedFocusCount >= 0
            && completedFocusCount <= Self.maximumSupportedCompletedFocusCount
            && phaseDuration.isFinite
            && currentSource != .manual
    }

    init(
        selectedDuration: PomodoroDuration = .twentyFiveMinutes,
        completedFocusCount: Int = 0
    ) {
        self.phase = .idle
        self.selectedDuration = selectedDuration
        self.completedFocusCount = min(
            max(0, completedFocusCount),
            Self.maximumSupportedCompletedFocusCount
        )
        self.phaseStartedAt = nil
        self.endDate = nil
        self.currentSessionID = nil
        self.currentSource = .timer
        self.phaseDuration = 0
        self.pausedPhase = nil
        self.pausedRemaining = nil
    }

    mutating func startFocus(
        duration: PomodoroDuration? = nil,
        isPro: Bool,
        now: Date,
        sessionID: UUID = UUID()
    ) throws {
        guard phase == .idle || phase == .focusCompleted || phase == .breakCompleted else {
            throw PomodoroEngineError.invalidTransition(from: phase)
        }

        let requestedDuration = (duration ?? selectedDuration).normalized
        guard requestedDuration.isValid else {
            throw PomodoroEngineError.invalidCustomDuration
        }
        guard isPro || !requestedDuration.requiresPro else {
            throw PomodoroEngineError.customDurationRequiresPro
        }

        selectedDuration = requestedDuration
        phase = .focusing
        phaseStartedAt = now
        phaseDuration = TimeInterval(requestedDuration.seconds)
        endDate = now.addingTimeInterval(phaseDuration)
        currentSessionID = sessionID
        currentSource = .timer
        pausedPhase = nil
        pausedRemaining = nil
    }

    /// Starts the correct break after a completed focus. Every fourth
    /// completion receives the long break.
    mutating func startBreak(now: Date) throws {
        guard phase == .focusCompleted else {
            throw PomodoroEngineError.invalidTransition(from: phase)
        }

        let takesLongBreak = completedFocusCount.isMultiple(
            of: Constants.Timer.focusSetsBeforeLongBreak
        )
        let minutes = takesLongBreak
            ? Constants.Timer.longBreakMinutes
            : Constants.Timer.shortBreakMinutes

        phase = takesLongBreak ? .longBreak : .shortBreak
        phaseStartedAt = now
        phaseDuration = TimeInterval(minutes * Constants.Timer.secondsPerMinute)
        endDate = now.addingTimeInterval(phaseDuration)
        currentSessionID = nil
        pausedPhase = nil
        pausedRemaining = nil
    }

    @discardableResult
    mutating func advance(
        at now: Date,
        observedUptime: TimeInterval? = nil
    ) -> PomodoroEvent? {
        guard phase.isRunning, let scheduledEnd = endDate, now >= scheduledEnd else {
            return nil
        }

        if phase == .focusing {
            guard let sessionID = currentSessionID, let startedAt = phaseStartedAt else {
                // A decoded malformed state cannot award a pebble.
                reset()
                return nil
            }

            let completion = PomodoroCompletion(
                sessionID: sessionID,
                startedAt: startedAt,
                endedAt: scheduledEnd,
                observedAt: now,
                observedUptime: observedUptime,
                duration: selectedDuration,
                seconds: selectedDuration.seconds,
                grams: selectedDuration.grams,
                source: currentSource
            )

            if completedFocusCount < Self.maximumSupportedCompletedFocusCount {
                completedFocusCount += 1
            } else {
                // Decoded/local state may already be at the product-domain
                // ceiling. Saturate instead of ever trapping on integer add.
                completedFocusCount = Self.maximumSupportedCompletedFocusCount
            }
            phase = .focusCompleted
            phaseStartedAt = nil
            endDate = nil
            phaseDuration = 0
            pausedPhase = nil
            pausedRemaining = nil
            return .focusCompleted(completion)
        }

        phase = .breakCompleted
        phaseStartedAt = nil
        endDate = nil
        phaseDuration = 0
        pausedPhase = nil
        pausedRemaining = nil
        return .breakCompleted
    }

    mutating func pause(at now: Date) throws {
        guard phase.isRunning, let scheduledEnd = endDate else {
            throw PomodoroEngineError.invalidTransition(from: phase)
        }

        let remaining = scheduledEnd.timeIntervalSince(now)
        guard remaining > 0 else {
            throw PomodoroEngineError.phaseAlreadyElapsed
        }

        pausedPhase = phase
        pausedRemaining = remaining
        phase = .paused
        endDate = nil
    }

    mutating func resume(at now: Date) throws {
        guard
            phase == .paused,
            let resumedPhase = pausedPhase,
            let remaining = pausedRemaining
        else {
            throw PomodoroEngineError.invalidTransition(from: phase)
        }

        phase = resumedPhase
        let resumedEnd = now.addingTimeInterval(remaining)
        if resumedPhase == .focusing,
           let startedAt = phaseStartedAt,
           resumedEnd.timeIntervalSince(startedAt) < phaseDuration {
            // The wall clock moved backwards while paused. Preserve the
            // remaining countdown, but rebase the untrusted wall timestamps
            // so the eventual self-reported completion still has a coherent
            // [start, end] interval for persistence and CloudKit validation.
            currentSource = .timerDemoted
            phaseStartedAt = resumedEnd.addingTimeInterval(-phaseDuration)
        }
        endDate = resumedEnd
        pausedPhase = nil
        pausedRemaining = nil
    }

    mutating func skipBreak() throws {
        let activePhase = phase == .paused ? pausedPhase : phase
        guard activePhase?.isBreak == true else {
            throw PomodoroEngineError.invalidTransition(from: phase)
        }

        phase = .breakCompleted
        phaseStartedAt = nil
        endDate = nil
        phaseDuration = 0
        currentSessionID = nil
        pausedPhase = nil
        pausedRemaining = nil
    }

    /// Marks the active focus as self-reported without discarding its effort.
    mutating func demoteCurrentFocus() throws {
        let activePhase = phase == .paused ? pausedPhase : phase
        guard activePhase == .focusing else {
            throw PomodoroEngineError.invalidTransition(from: phase)
        }
        currentSource = .timerDemoted
    }

    /// Cancels either focus or break and returns to a clean idle state.
    /// The returned focus identifier lets callers cancel pending notifications.
    @discardableResult
    mutating func cancel() -> UUID? {
        let cancelledSessionID = currentSessionID
        reset()
        return cancelledSessionID
    }

    /// Restoring a running focus after process death never grants a pebble.
    /// This is intentionally different from merely returning from background.
    mutating func recoverAfterProcessRelaunch() -> PomodoroRecoveryResult {
        let activePhase = phase == .paused ? pausedPhase : phase
        let result: PomodoroRecoveryResult

        if activePhase == .focusing, let sessionID = currentSessionID {
            result = .interruptedFocus(sessionID: sessionID)
        } else if activePhase?.isBreak == true {
            result = .discardedBreak
        } else {
            result = .nothingToRecover
        }

        if result != .nothingToRecover {
            reset()
        }
        return result
    }

    func snapshot(at now: Date) -> PomodoroSnapshot {
        let rawRemaining: TimeInterval
        if phase == .paused {
            rawRemaining = pausedRemaining ?? 0
        } else if let endDate, phase.isRunning {
            rawRemaining = endDate.timeIntervalSince(now)
        } else {
            rawRemaining = 0
        }

        let remaining: TimeInterval
        if rawRemaining.isNaN || rawRemaining <= 0 {
            remaining = 0
        } else {
            remaining = min(
                rawRemaining,
                TimeInterval(Self.maximumSupportedRemainingSeconds)
            )
        }

        let progress: Double
        if phaseDuration.isFinite, phaseDuration > 0, remaining.isFinite {
            progress = min(1, max(0, 1 - remaining / phaseDuration))
        } else {
            progress = 0
        }

        return PomodoroSnapshot(
            phase: phase,
            remainingSeconds: Int(ceil(remaining)),
            progress: progress,
            endDate: endDate,
            sessionID: currentSessionID,
            source: currentSource
        )
    }

    private mutating func reset() {
        phase = .idle
        phaseStartedAt = nil
        endDate = nil
        currentSessionID = nil
        currentSource = .timer
        phaseDuration = 0
        pausedPhase = nil
        pausedRemaining = nil
    }
}

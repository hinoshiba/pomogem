import Foundation

enum PomodoroDuration: Hashable, Codable, Sendable {
    case twentyFiveMinutes
    case sixtyMinutes
    case custom(minutes: Int)

#if DEBUG
    case demo
#endif

    static let freePresets: [PomodoroDuration] = [
        .twentyFiveMinutes,
        .sixtyMinutes
    ]

    var minutes: Int? {
        switch self {
        case .twentyFiveMinutes:
            Constants.Timer.twentyFiveMinutes
        case .sixtyMinutes:
            Constants.Timer.sixtyMinutes
        case let .custom(minutes):
            minutes
#if DEBUG
        case .demo:
            nil
#endif
        }
    }

    var seconds: Int {
        switch self {
#if DEBUG
        case .demo:
            Constants.Timer.demoSeconds
#endif
        default:
            (minutes ?? 0) * Constants.Timer.secondsPerMinute
        }
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
        switch normalized {
        case .custom:
            true
        default:
            false
        }
    }

    var isValid: Bool {
        guard case let .custom(minutes) = self else { return true }
        return (Constants.Timer.customMinimumMinutes ... Constants.Timer.customMaximumMinutes)
            .contains(minutes)
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

    var normalized: PomodoroDuration {
        switch self {
        case let .custom(minutes):
            PomodoroDuration(minutes: minutes)
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

    init(
        selectedDuration: PomodoroDuration = .twentyFiveMinutes,
        completedFocusCount: Int = 0
    ) {
        self.phase = .idle
        self.selectedDuration = selectedDuration
        self.completedFocusCount = max(0, completedFocusCount)
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

            completedFocusCount += 1
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
        endDate = now.addingTimeInterval(remaining)
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
        let remaining: TimeInterval
        if phase == .paused {
            remaining = pausedRemaining ?? 0
        } else if let endDate, phase.isRunning {
            remaining = max(0, endDate.timeIntervalSince(now))
        } else {
            remaining = 0
        }

        let progress: Double
        if phaseDuration > 0 {
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

import CryptoKit
import FamilyControls
import Foundation

enum ScreenTimeLane: String, Codable, CaseIterable {
    case learning, distraction
}

struct ScreenTimeConfiguration: Codable, Equatable {
    var enabled = false
    var learningSelection = FamilyActivitySelection(includeEntireCategory: false)
    var distractionSelection = FamilyActivitySelection(includeEntireCategory: false)
    var themeID: UUID?
}

enum ScreenTimeError: LocalizedError {
    case unavailable, unauthorized, unboundContext, applicationsOnly, overlappingApplications
    case freeApplicationLimit, missingTheme, corruptedState

    var errorDescription: String? {
        switch self {
        case .unavailable: return "この環境ではスクリーンタイムを利用できません。対応するiPhoneのアプリでお試しください。"
        case .unauthorized: return "スクリーンタイムへのアクセスを許可してください。"
        case .unboundContext: return "データの準備が完了してから、もう一度お試しください。"
        case .applicationsOnly: return "カテゴリやWebサイトではなく、個別のアプリを選んでください。"
        case .overlappingApplications: return "同じアプリを学習用と黒い石用の両方には登録できません。"
        case .freeApplicationLimit: return "無料で登録できる学習アプリは5つまでです。5つ以下にするか、Proをご利用ください。"
        case .missingTheme: return "学習時間を記録するテーマを選んでください。"
        case .corruptedState: return "スクリーンタイムの記録を読み込めませんでした。記録の上書きは行っていません。"
        }
    }
}

enum ScreenTimePolicy {
    /// Every DeviceActivity name we register starts with this. One definition,
    /// so `ScreenTimeMonitoring`, `ScreenTimeRun` and `ScreenTimeActivityKind`
    /// cannot drift apart over what counts as ours.
    static let activityPrefix = "pomogem.screen-time."
    /// What follows the prefix for the one recurring day-boundary activity.
    static let schedulerInfix = "scheduler."
    static let minutesPerGem = 10
    static let freeLearningApplicationLimit = 5
    // Apple documents a maximum of 20 simultaneous activities. Keep each batch
    // small (18 events), with eight batches per lane plus one daily scheduler.
    // https://developer.apple.com/documentation/deviceactivity/deviceactivitycenter/monitoringerror/excessiveactivities
    static let eventsPerActivity = 18
    static let maximumDailyThreshold = 144
    static let batchesPerLane = 8
    static let maximumActivities = batchesPerLane * 2 + 1

    static func validate(_ configuration: ScreenTimeConfiguration, isPro: Bool) throws {
        guard configuration.enabled else { return }
        let learning = configuration.learningSelection
        let distraction = configuration.distractionSelection
        guard learning.categoryTokens.isEmpty, learning.webDomainTokens.isEmpty,
              distraction.categoryTokens.isEmpty, distraction.webDomainTokens.isEmpty else {
            throw ScreenTimeError.applicationsOnly
        }
        guard learning.applicationTokens.isDisjoint(with: distraction.applicationTokens) else {
            throw ScreenTimeError.overlappingApplications
        }
        try validateLearningCount(learning.applicationTokens.count, isPro: isPro)
        if !learning.applicationTokens.isEmpty, configuration.themeID == nil {
            throw ScreenTimeError.missingTheme
        }
    }

    static func validateLearningCount(_ count: Int, isPro: Bool) throws {
        if !isPro, count > freeLearningApplicationLimit { throw ScreenTimeError.freeApplicationLimit }
    }

    /// The learning lane's subscription gate. `isPro == nil` means StoreKit
    /// has not answered yet: the gate the ledger already holds is kept (or
    /// relaxed when the selection fits the free plan anyway), never tightened,
    /// because retiring a run cannot be undone — its unfinished 10 minutes are
    /// gone. Only a real answer may close it.
    static func learningAllowedBySubscription(
        isPro: Bool?,
        learningApplicationCount: Int,
        previouslyAllowed: Bool
    ) -> Bool {
        let fitsFreePlan = learningApplicationCount <= freeLearningApplicationLimit
        guard let isPro else { return previouslyAllowed || fitsFreePlan }
        return isPro || fitsFreePlan
    }

    static func thresholds(batch: Int) -> ClosedRange<Int> {
        (batch * eventsPerActivity + 1)...min((batch + 1) * eventsPerActivity, maximumDailyThreshold)
    }

    static func receiptID(epoch: UUID, runID: UUID, threshold: Int) -> UUID {
        let input = "\(epoch.uuidString):\(runID.uuidString):\(threshold)"
        let bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

struct ScreenTimeReceipt: Identifiable, Equatable {
    var id: UUID
    var themeID: UUID
    var contextKey: String
    var dataEpochID: UUID?
    /// Bounds of the monitoring window, not a claimed continuous usage session.
    var startedAt: Date
    var endedAt: Date
    var minutes: Int { ScreenTimePolicy.minutesPerGem }
}

struct ScreenTimeRun: Codable, Equatable {
    var id = UUID()
    var lane: ScreenTimeLane
    var dayStart: Date
    var dayEnd: Date
    var startedAt: Date
    var timeZoneID: String
    var includesPastActivity: Bool
    var themeID: UUID?
    var highestThreshold = 0
    var acknowledgedThrough = 0
    var observedAt: Date?
    var active = true

    var activityPrefix: String { "\(ScreenTimePolicy.activityPrefix)\(id.uuidString)." }
}

/// Calendar continuity belongs to the existing registration, not to which
/// process happens to notice midnight first. Controller edits, explicit stop,
/// timer pauses and subscription changes retire the affected run before this
/// policy is evaluated, so their earlier usage cannot be replayed.
enum ScreenTimeRolloverPolicy {
    static func includesPastActivity(
        lane: ScreenTimeLane,
        previousRuns: [ScreenTimeRun],
        dayStart: Date,
        timeZoneID: String,
        learningPausedByTimer: Bool,
        learningAllowedBySubscription: Bool,
        supportsPastActivity: Bool
    ) -> Bool {
        guard supportsPastActivity,
              lane == .distraction || (!learningPausedByTimer && learningAllowedBySubscription)
        else { return false }
        return previousRuns.contains { run in
            run.active && run.lane == lane && run.dayStart < dayStart
                && run.dayEnd <= dayStart && run.timeZoneID == timeZoneID
        }
    }
}

struct ScreenTimeState: Codable {
    var version = 1
    var epoch = UUID()
    var contextKey: String?
    var contextIsActive = false
    var dataEpochID: UUID?
    var configuration = ScreenTimeConfiguration()
    var runs: [ScreenTimeRun] = []
    var negativeGemCount = 0
    var learningPausedByTimer = false
    var learningAllowedBySubscription = true
    var monitoringError: String?
    /// When the monitor extension last ran a repair pass that the framework
    /// refused. A short-lived extension process has no memory of its own, so
    /// without this a refused registration would be retried on every threshold
    /// callback for the rest of the day.
    var lastRepairAttemptAt: Date?
    /// Diagnostics only: how many callbacks the OS delivered and what each one
    /// did. Optional on purpose — the synthesized decoder does NOT fall back to
    /// a property's default value, so a non-optional field would make every
    /// ledger written before it existed decode as `corruptedState`.
    var callbackCounters: ScreenTimeCallbackCounters?

    /// Evidence in the ledger that a Family Controls approval once existed.
    /// `ScreenTimeController.save` refuses to write `enabled` while the status
    /// is not approved, and FamilyActivityPicker cannot hand out an
    /// application token without one — so either is proof enough to treat a
    /// settled not-approved status as a revocation. Recording being switched
    /// off does not make the stored opaque tokens any less voided by the OS.
    var recordsAnApproval: Bool {
        configuration.enabled
            || !configuration.learningSelection.applicationTokens.isEmpty
            || !configuration.distractionSelection.applicationTokens.isEmpty
    }

    /// Diagnostics only. Deliberately outside every fence `record` applies:
    /// what the OS delivered is worth knowing precisely when the ledger refuses
    /// it, and a counter can neither award a gem nor retire a run.
    mutating func countIntervalCallback(
        kind: ScreenTimeActivityKind,
        phase: ScreenTimeCallbackCounters.IntervalPhase,
        now: Date
    ) {
        var counters = countersForCallback(at: now)
        counters.countInterval(kind: kind, phase: phase, at: now)
        callbackCounters = counters
    }

    mutating func countThresholdCallback(
        _ outcome: ScreenTimeCallbackCounters.ThresholdOutcome,
        statusUnknown: Bool = false,
        now: Date
    ) {
        var counters = countersForCallback(at: now)
        counters.countThreshold(outcome, statusUnknown: statusUnknown, at: now)
        callbackCounters = counters
    }

    /// The counter set this callback belongs in. A count is only readable next
    /// to what it was counted under, so a new device day or a new ledger epoch
    /// starts a fresh set with a higher `generation` instead of adding to
    /// yesterday's totals — otherwise "laneStart=1" on a day when the lane
    /// interval never started would refute the very hypothesis it is there to
    /// settle. A set stamped by an older build carries neither stamp; it adopts
    /// the current ones rather than discarding evidence already on the device.
    private func countersForCallback(at now: Date) -> ScreenTimeCallbackCounters {
        let day = Calendar.current.startOfDay(for: now)
        guard var counters = callbackCounters else {
            var fresh = ScreenTimeCallbackCounters()
            fresh.epoch = epoch
            fresh.dayStart = day
            return fresh
        }
        if counters.epoch == nil { counters.epoch = epoch }
        if counters.dayStart == nil { counters.dayStart = day }
        guard counters.epoch == epoch, counters.dayStart == day else {
            return counters.restarted(epoch: epoch, dayStart: day)
        }
        return counters
    }

    mutating func record(runID: UUID, threshold: Int, now: Date) {
        guard (1...ScreenTimePolicy.maximumDailyThreshold).contains(threshold),
              let index = runs.firstIndex(where: { $0.id == runID && $0.active }),
              configuration.enabled, contextKey != nil, contextIsActive else { return }
        let run = runs[index]
        guard now >= run.startedAt,
              // A previous day's delayed callback is safely ignored. Event names
              // carry the run UUID, so it can never award today's usage instead.
              now < run.dayEnd,
              now.timeIntervalSince(run.startedAt) >= Double(threshold * 600),
              threshold > run.highestThreshold else { return }
        if run.lane == .learning, learningPausedByTimer || !learningAllowedBySubscription { return }
        let delta = threshold - run.highestThreshold
        if run.lane == .distraction {
            let (total, overflow) = negativeGemCount.addingReportingOverflow(delta)
            guard !overflow else { return }
            negativeGemCount = total
        }
        runs[index].highestThreshold = threshold
        runs[index].observedAt = now
    }

    func pendingLearningReceipts(limit: Int) -> [ScreenTimeReceipt] {
        guard let contextKey, limit > 0 else { return [] }
        let limit = min(limit, 512)
        var result: [ScreenTimeReceipt] = []
        for run in runs where run.lane == .learning && run.highestThreshold > run.acknowledgedThrough {
            guard let themeID = run.themeID, let observedAt = run.observedAt else { continue }
            for threshold in (run.acknowledgedThrough + 1)...run.highestThreshold {
                result.append(ScreenTimeReceipt(
                    id: ScreenTimePolicy.receiptID(epoch: epoch, runID: run.id, threshold: threshold),
                    themeID: themeID, contextKey: contextKey, dataEpochID: dataEpochID,
                    startedAt: run.startedAt, endedAt: observedAt
                ))
                if result.count == limit { return result }
            }
        }
        return result
    }

    mutating func acknowledge(_ ids: Set<UUID>) {
        for index in runs.indices where runs[index].lane == .learning {
            while runs[index].acknowledgedThrough < runs[index].highestThreshold {
                let next = runs[index].acknowledgedThrough + 1
                let id = ScreenTimePolicy.receiptID(epoch: epoch, runID: runs[index].id, threshold: next)
                guard ids.contains(id) else { break }
                runs[index].acknowledgedThrough = next
            }
        }
        pruneConsumedRuns()
    }

    mutating func pruneConsumedRuns() {
        runs.removeAll { !$0.active && ($0.lane == .distraction || $0.acknowledgedThrough == $0.highestThreshold) }
    }

    /// Apple voids existing opaque selections when authorization is revoked.
    /// Keep confirmed awards, but require a fresh picker selection and opt-in.
    /// https://developer.apple.com/documentation/familycontrols/familyactivityselection
    @discardableResult
    mutating func invalidateAuthorization() -> Bool {
        let learning = configuration.learningSelection
        let distraction = configuration.distractionSelection
        let hadSelection = !learning.applicationTokens.isEmpty || !learning.categoryTokens.isEmpty ||
            !learning.webDomainTokens.isEmpty || !distraction.applicationTokens.isEmpty ||
            !distraction.categoryTokens.isEmpty || !distraction.webDomainTokens.isEmpty
        guard configuration.enabled || hadSelection || runs.contains(where: \.active) else { return false }
        let themeID = configuration.themeID
        configuration = ScreenTimeConfiguration()
        configuration.themeID = themeID
        for index in runs.indices { runs[index].active = false }
        pruneConsumedRuns()
        monitoringError = "スクリーンタイムの許可が解除されました。再び許可して、アプリを選び直してください。"
        return true
    }

    var isValid: Bool {
        guard version == 1, negativeGemCount >= 0,
              lastRepairAttemptAt?.timeIntervalSince1970.isFinite != false,
              callbackCounters?.isValid != false,
              Set(runs.map(\.id)).count == runs.count,
              runs.filter(\.active).count <= ScreenTimeLane.allCases.count else { return false }
        return runs.allSatisfy { run in
            run.dayStart.timeIntervalSince1970.isFinite && run.dayEnd.timeIntervalSince1970.isFinite &&
            run.startedAt.timeIntervalSince1970.isFinite && run.dayEnd > run.dayStart &&
            run.startedAt >= run.dayStart && run.startedAt < run.dayEnd &&
            (0...ScreenTimePolicy.maximumDailyThreshold).contains(run.highestThreshold) &&
            (0...run.highestThreshold).contains(run.acknowledgedThrough) &&
            (run.observedAt == nil || (run.observedAt!.timeIntervalSince1970.isFinite &&
                                      run.observedAt! >= run.startedAt && run.observedAt! < run.dayEnd)) &&
            (run.highestThreshold == 0 || run.observedAt != nil) &&
            (run.lane != .learning || run.highestThreshold == 0 || run.themeID != nil)
        }
    }
}

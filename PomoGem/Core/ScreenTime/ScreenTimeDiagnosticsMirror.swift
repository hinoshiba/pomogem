import Foundation

/// A read-only copy of the Screen Time callback diagnostics, written where a
/// connected Mac can actually fetch it.
///
/// The counters live in the App Group ledger, because that is the only place
/// the monitor extension can reach — and that is exactly why they cannot be
/// read off a phone. The 2026-09-20/21 device audit lost every channel at
/// once: `devicectl device copy from --domain-type appGroupDataContainer`
/// resolves the ledger's file node and then fails the transfer,
/// `log collect --device-udid` and `sysdiagnose` both want host root, and
/// Console.app needs the owner at the Mac. The audit finished with no reading
/// of the counters at all, so "the extension never ran" and "we could not look"
/// were indistinguishable.
///
/// So the app mirrors the numbers into its OWN data container, under
/// `Library/Application Support/ScreenTimeDiagnostics/counters.json`, which an
/// ordinary `devicectl device copy from --domain-type appDataContainer` pulls
/// from a development-signed install with no root and no unified log.
///
/// The extension cannot write here. `Library/Application Support` resolves
/// inside whichever bundle asks for it, so the appex would write into its own
/// container, not the app's; the App Group is the one directory both processes
/// share and the one this file exists to work around. The mirror is therefore
/// written by the APP, on its own synchronize and reload passes — that is,
/// while it is in the foreground — and is only ever as fresh as the last time
/// the user opened the app. A callback the extension counts at 03:00 appears
/// here on the app's next pass, not when it was counted; `writtenAt` says which
/// instant this file describes and the counters' own instants say when the OS
/// delivered something.
///
/// Deliberately narrower than the ledger it copies: counts, booleans, ISO-8601
/// instants and second offsets, and nothing else. No run or event identifier,
/// no ledger epoch, no opaque token, no gem count, no theme, no context key —
/// the rule `ScreenTimeCallbackCounters` and `ScreenTimeLog` already state,
/// applied once more at this boundary because, unlike the ledger, this file is
/// meant to leave the device. The payload is built field by field into
/// `ScreenTimeDiagnosticsReport` rather than by encoding ledger types, so a
/// field added to the ledger cannot arrive here by itself.
///
/// Writing diagnostics never throws. A file that cannot be written must not
/// disturb a pass that has real work to do, and it never creates a ledger:
/// `ScreenTimeController` only calls it for a ledger that already exists, the
/// same rule as `ScreenTimeStore.countCallback`. Complete deletion does surface
/// a failed removal, so it cannot report success while this usage history remains.
final class ScreenTimeDiagnosticsMirror {
    static let directoryName = "ScreenTimeDiagnostics"
    static let fileName = "counters.json"

    /// `<app container>/Library/Application Support/ScreenTimeDiagnostics`.
    /// nil only where the sandbox has no Application Support at all, in which
    /// case the mirror does nothing.
    static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(directoryName, isDirectory: true)
    }

    private let directory: URL?
    /// The reload pass runs every 3 seconds while the app is in the foreground,
    /// and almost every one of them reads a ledger that has not changed. Write
    /// when the ledger changes, and otherwise at most this often, so the file
    /// still proves the app was running without a file write every 3 seconds.
    private let heartbeat: TimeInterval
    private var lastDigest: LedgerDigest?
    private var lastWriteAt: Date?

    /// Everything the report says that does NOT move with the clock.
    ///
    /// Comparing this, instead of the previous report, is what makes the
    /// heartbeat mean anything: the offsets and ages in a report are measured
    /// against the instant it was written, so every pass produces a different
    /// report and a report-to-report comparison would write the file every
    /// three seconds — exactly what the heartbeat is here to avoid.
    private struct LedgerDigest: Equatable {
        struct Run: Equatable {
            var lane: ScreenTimeLane
            var dayStart: Date
            var dayEnd: Date
            var startedAt: Date
            var includesPastActivity: Bool
        }

        var enabled: Bool
        var contextIsActive: Bool
        var counters: ScreenTimeCallbackCounters?
        var activeRuns: [Run]

        init(_ state: ScreenTimeState) {
            enabled = state.configuration.enabled
            contextIsActive = state.contextIsActive
            counters = state.callbackCounters
            activeRuns = state.runs.filter(\.active).map {
                Run(lane: $0.lane, dayStart: $0.dayStart, dayEnd: $0.dayEnd,
                    startedAt: $0.startedAt, includesPastActivity: $0.includesPastActivity)
            }
        }
    }

    init(directory: URL? = ScreenTimeDiagnosticsMirror.defaultDirectory(), heartbeat: TimeInterval = 60) {
        self.directory = directory
        self.heartbeat = heartbeat
    }

    var fileURL: URL? { directory?.appendingPathComponent(Self.fileName) }

    /// Complete deletion includes the copy in the app container, not only the
    /// App Group ledger. Clear the heartbeat cache so a later admitted owner
    /// can immediately write even when its empty ledger has the same digest.
    func eraseAllData() throws {
        if let fileURL {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Idempotent when deletion resumes or no mirror was written.
            }
        }
        lastDigest = nil
        lastWriteAt = nil
    }

    /// Copies what this pass read. Silent on every failure by design.
    func write(_ state: ScreenTimeState, now: Date = Date()) {
        guard let directory else { return }
        let digest = LedgerDigest(state)
        guard shouldWrite(digest, now: now) else { return }
        let report = ScreenTimeDiagnosticsReport(state: state, now: now)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // The ledger it copies is excluded from backups; so is this.
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            let encoder = JSONEncoder()
            // Sorted and indented: this file is read by a person off a device,
            // not parsed by the app, which never reads it back.
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(
                to: directory.appendingPathComponent(Self.fileName),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            lastDigest = digest
            lastWriteAt = now
        } catch {
            // Diagnostics only: a pass must not fail because evidence could not
            // be copied, and a mirror that cannot be written cannot record that
            // either.
        }
    }

    private func shouldWrite(_ digest: LedgerDigest, now: Date) -> Bool {
        guard let lastDigest, let lastWriteAt else { return true }
        // `abs`, so a clock moved backwards cannot stall the heartbeat.
        return digest != lastDigest || abs(now.timeIntervalSince(lastWriteAt)) >= heartbeat
    }
}

/// The mirrored document, and the whole of what leaves the device.
///
/// Every field is a count, a boolean, an ISO-8601 instant or a second offset.
/// Adding anything else here is the mistake this type exists to make visible:
/// `ScreenTimeCallbackDiagnosticsTests` asserts the key set exactly, and that
/// no identifier the ledger holds appears anywhere in the encoded bytes.
struct ScreenTimeDiagnosticsReport: Codable, Equatable {
    /// Bumped when a field is added, renamed or given a new meaning, so a file
    /// pulled off a phone can be read against the right description.
    static let schemaVersion = 2

    /// What one lane's registration looks like in the ledger this pass read.
    struct LaneSchedule: Codable, Equatable {
        /// 0 or 1 in a valid ledger: `ScreenTimeState.isValid` allows at most
        /// one active run per lane.
        var activeRuns: Int
        /// The fields below describe that active run, and are absent without
        /// one.
        ///
        /// `intervalStartOffsetSec` / `intervalEndOffsetSec` are measured from
        /// `writtenAt`, NOT from the moment the registration was made — this
        /// file is written by passes that register nothing. A large positive
        /// `intervalStartOffsetSec` therefore means "the interval began this
        /// long before this file was written", which is the ordinary state of
        /// an afternoon pass, and says nothing on its own about how late in the
        /// interval the registration happened. `runStartedAtOffsetSec` is the
        /// one registration-time fact the ledger keeps: 0 means the run counts
        /// from midnight (a day rollover that continued the previous day's
        /// registration), a positive value is how far into the day the run was
        /// created.
        var intervalStartOffsetSec: Int?
        var intervalEndOffsetSec: Int?
        var runStartedAtOffsetSec: Int?
        var includesPastActivity: Bool?
        /// Pinned from the registration site: a lane's schedule is dated and
        /// non-repeating (`ScreenTimeMonitoring.synchronizeLocked`).
        var repeats: Bool?

        static let inactive = LaneSchedule(activeRuns: 0)
    }

    /// `ScreenTimeCallbackCounters` minus its `epoch`, which is a ledger
    /// identifier and stays on the device; `generation` already says how many
    /// times the set was restarted by a new epoch, a new device day or the
    /// in-app reset.
    struct Counters: Codable, Equatable {
        var generation: Int
        /// The device day these counts were accumulated under.
        var dayStart: String?
        var schedulerIntervalStarts: Int
        var laneIntervalStarts: Int
        var otherIntervalStarts: Int
        var schedulerIntervalEnds: Int
        var laneIntervalEnds: Int
        var otherIntervalEnds: Int
        var thresholds: Int
        var thresholdsRecorded: Int
        var thresholdsIgnoredByLedger: Int
        var thresholdsIgnoredByName: Int
        var thresholdsDenied: Int
        /// An observation, not an outcome: how many of the thresholds above
        /// arrived in a process that could not read its own Family Controls
        /// authorization. Each one is also counted under whatever the ledger
        /// decided, so this never sums with the outcomes.
        var statusUnknownAtCallback: Int
        var lastCallbackAt: String?
        var lastLaneIntervalStartAt: String?
        var lastSchedulerIntervalStartAt: String?
        var lastThresholdAt: String?
        /// Seconds between `writtenAt` and each instant above, so the file can
        /// be read without doing date arithmetic. `-1` means that kind of
        /// callback has never been counted — the same convention as
        /// `ScreenTimeCallbackCounters.logDescription`. `9223372036854775807`
        /// or `-9223372036854775808` beside a missing instant means the stored
        /// date is not a real one (see `ScreenTimeDiagnosticSeconds`).
        var lastCallbackAgeSec: Int
        var laneIntervalStartAgeSec: Int
        var schedulerIntervalStartAgeSec: Int
        var thresholdAgeSec: Int
    }

    var schemaVersion: Int
    /// When this file was written, i.e. which app pass it describes.
    var writtenAt: String?
    var configurationEnabled: Bool
    var contextIsActive: Bool
    var learning: LaneSchedule
    var distraction: LaneSchedule
    /// Absent when the ledger has never counted a callback.
    var counters: Counters?

    init(state: ScreenTimeState, now: Date) {
        schemaVersion = Self.schemaVersion
        writtenAt = Self.instant(now)
        configurationEnabled = state.configuration.enabled
        contextIsActive = state.contextIsActive
        learning = Self.laneSchedule(for: .learning, in: state, now: now)
        distraction = Self.laneSchedule(for: .distraction, in: state, now: now)
        counters = state.callbackCounters.map { Self.counters($0, now: now) }
    }

    private static func laneSchedule(
        for lane: ScreenTimeLane, in state: ScreenTimeState, now: Date
    ) -> LaneSchedule {
        let active = state.runs.filter { $0.active && $0.lane == lane }
        guard let run = active.first else { return .inactive }
        return LaneSchedule(
            activeRuns: active.count,
            intervalStartOffsetSec: ScreenTimeDiagnosticSeconds.between(now, run.dayStart),
            // The registration ends the interval one second before the next
            // day starts (`ScreenTimeMonitoring.synchronizeLocked`).
            intervalEndOffsetSec: ScreenTimeDiagnosticSeconds.between(
                now, run.dayEnd.addingTimeInterval(-1)
            ),
            runStartedAtOffsetSec: ScreenTimeDiagnosticSeconds.between(run.startedAt, run.dayStart),
            includesPastActivity: run.includesPastActivity,
            repeats: false
        )
    }

    private static func counters(_ counters: ScreenTimeCallbackCounters, now: Date) -> Counters {
        func age(_ instant: Date?) -> Int {
            instant.map { ScreenTimeDiagnosticSeconds.between(now, $0) } ?? -1
        }
        return Counters(
            generation: counters.generation,
            dayStart: instant(counters.dayStart),
            schedulerIntervalStarts: counters.schedulerIntervalStarts,
            laneIntervalStarts: counters.laneIntervalStarts,
            otherIntervalStarts: counters.otherIntervalStarts,
            schedulerIntervalEnds: counters.schedulerIntervalEnds,
            laneIntervalEnds: counters.laneIntervalEnds,
            otherIntervalEnds: counters.otherIntervalEnds,
            thresholds: counters.thresholds,
            thresholdsRecorded: counters.thresholdsRecorded,
            thresholdsIgnoredByLedger: counters.thresholdsIgnoredByLedger,
            thresholdsIgnoredByName: counters.thresholdsIgnoredByName,
            thresholdsDenied: counters.thresholdsDenied,
            statusUnknownAtCallback: counters.statusUnknownAtCallback,
            lastCallbackAt: instant(counters.lastCallbackAt),
            lastLaneIntervalStartAt: instant(counters.lastLaneIntervalStartAt),
            lastSchedulerIntervalStartAt: instant(counters.lastSchedulerIntervalStartAt),
            lastThresholdAt: instant(counters.lastThresholdAt),
            lastCallbackAgeSec: age(counters.lastCallbackAt),
            laneIntervalStartAgeSec: age(counters.lastLaneIntervalStartAt),
            schedulerIntervalStartAgeSec: age(counters.lastSchedulerIntervalStartAt),
            thresholdAgeSec: age(counters.lastThresholdAt)
        )
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// `nil` for a stored date that is not a real instant. `ScreenTimeState`
    /// only asks a date to be finite, so a ledger a device audit copied,
    /// hand-edited or wrote partially can hold one that no calendar can
    /// render; the matching `…AgeSec` carries the clamped sentinel instead.
    private static func instant(_ date: Date?) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince1970
        // Comfortably wider than any device clock and far inside the range the
        // formatter and the calendar agree on.
        guard seconds.isFinite, abs(seconds) < 40_000_000_000 else { return nil }
        return formatter.string(from: date)
    }
}

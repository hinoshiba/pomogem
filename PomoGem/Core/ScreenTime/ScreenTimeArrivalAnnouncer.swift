import Foundation

/// Home's one line about what Screen Time just added.
///
/// Every imported 10 minutes lands as its own 100 g pebble, 180 ms apart, and
/// each landing used to show the generic 「英語 +100g 積んだ」: one flickering
/// toast per pebble, nothing saying where it came from, and VoiceOver reading
/// only the first. Black stones arrived with no word at all. This gathers the
/// learning landings and any rise in the black-stone count, waits until they
/// stop, and hands Home a single attributed summary. Black stones get a plain
/// count, with no sound, reward framing or judgement (EngagementArchitecture.md
/// §1.1).
@MainActor
final class ScreenTimeArrivalAnnouncer {
    /// How long Home waits after the last arrival before speaking. Pebbles
    /// land 180 ms apart, so this outlasts the gap between two of them.
    /// Nonisolated because it is a default argument, which is evaluated
    /// outside the class's main-actor isolation.
    nonisolated static let defaultQuietInterval: Duration = .milliseconds(600)
    static let acknowledgedBlackStonesBase = "screen-time.acknowledged-black-stones"

    private var learning = ScreenTimeArrivalTally()
    private var flushTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private let acknowledgedKey: () -> String
    private let quietInterval: Duration

    init(
        defaults: UserDefaults = .standard,
        acknowledgedKey: @escaping () -> String = {
            AccountScopedLocalState.defaultsKey(base: ScreenTimeArrivalAnnouncer.acknowledgedBlackStonesBase)
        },
        quietInterval: Duration = ScreenTimeArrivalAnnouncer.defaultQuietInterval
    ) {
        self.defaults = defaults
        self.acknowledgedKey = acknowledgedKey
        self.quietInterval = quietInterval
    }

    /// A Screen Time learning pebble reached the jar.
    func noteLearningLanding(subjectName: String, announce: @escaping (String, String) -> Void) {
        learning.addLearning(subjectName: subjectName)
        scheduleFlush(announce)
    }

    /// Home saw this black-stone count (on appearing, or when it changed).
    /// Only a rise since the last count this iPhone acknowledged is announced;
    /// a first sighting, a clear and a reset are recorded silently. An unbound
    /// controller publishes 0 whatever the ledger holds, so its counts are
    /// ignored: remembering that 0 would announce every existing stone again
    /// at the next launch.
    func noteBlackStoneCount(_ count: Int, isBound: Bool, announce: @escaping (String, String) -> Void) {
        guard isBound else { return }
        let key = acknowledgedKey()
        let stored = defaults.object(forKey: key) as? Int
        let step = ScreenTimeArrivalTally.blackStoneStep(acknowledged: stored, current: count)
        if stored != step.acknowledge { defaults.set(step.acknowledge, forKey: key) }
        guard step.newStones > 0 else { return }
        learning.addBlackStones(step.newStones)
        scheduleFlush(announce)
    }

    func cancel() {
        flushTask?.cancel()
        flushTask = nil
    }

    private func scheduleFlush(_ announce: @escaping (String, String) -> Void) {
        flushTask?.cancel()
        let quietInterval = quietInterval
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: quietInterval)
            guard !Task.isCancelled, let self else { return }
            let tally = self.learning
            self.learning = ScreenTimeArrivalTally()
            self.flushTask = nil
            guard let message = tally.message else { return }
            announce(message, "hourglass")
        }
    }
}

/// What arrived since the last summary, and the one sentence that says it.
struct ScreenTimeArrivalTally: Equatable {
    struct Entry: Equatable {
        let name: String
        var count: Int
    }

    /// Pebbles per theme, in arrival order.
    private(set) var learningBySubject: [Entry] = []
    private(set) var blackStones = 0

    mutating func addLearning(subjectName: String) {
        if let index = learningBySubject.firstIndex(where: { $0.name == subjectName }) {
            learningBySubject[index].count += 1
        } else {
            learningBySubject.append(Entry(name: subjectName, count: 1))
        }
    }

    mutating func addBlackStones(_ count: Int) {
        let (total, overflow) = blackStones.addingReportingOverflow(max(0, count))
        blackStones = overflow ? Int.max : total
    }

    /// `acknowledge` is what to remember; `newStones` is what to announce.
    static func blackStoneStep(acknowledged: Int?, current: Int) -> (newStones: Int, acknowledge: Int) {
        let current = max(0, current)
        guard let acknowledged, current > acknowledged else { return (0, current) }
        return (current - acknowledged, current)
    }

    var message: String? {
        let pebbles = learningBySubject.reduce(0) { $0 + $1.count }
        let minutes = pebbles * ScreenTimePolicy.minutesPerGem
        let stoneMinutes = blackStones.multipliedReportingOverflow(by: ScreenTimePolicy.minutesPerGem)
        switch (pebbles > 0, blackStones > 0) {
        case (false, false):
            return nil
        case (true, false):
            if learningBySubject.count == 1, let subject = learningBySubject.first?.name {
                return String(localized: "スクリーンタイム：\(subject) +\(minutes)分（\(pebbles)粒）", table: "ScreenTime",
                              comment: "Toast: study-app time added. 1 = theme name, 2 = minutes, 3 = pebbles")
            }
            return String(localized: "スクリーンタイム：勉強アプリの時間 +\(minutes)分（\(pebbles)粒）", table: "ScreenTime",
                          comment: "Toast: study-app time added to several themes. 1 = minutes, 2 = pebbles")
        case (false, true):
            if stoneMinutes.overflow {
                return String(localized: "スクリーンタイム：黒い石 +\(blackStones)", table: "ScreenTime",
                              comment: "Toast: black stones added (count only)")
            }
            return String(localized: "スクリーンタイム：黒い石 +\(blackStones)（控えたいアプリ \(stoneMinutes.partialValue)分）",
                          table: "ScreenTime",
                          comment: "Toast: black stones added. 1 = stones, 2 = minutes in the apps to cut down")
        case (true, true):
            if learningBySubject.count == 1, let subject = learningBySubject.first?.name {
                return String(localized: "スクリーンタイム：\(subject) +\(minutes)分（\(pebbles)粒）、黒い石 +\(blackStones)",
                              table: "ScreenTime",
                              comment: "Toast: study time and black stones added. 1 = theme, 2 = minutes, 3 = pebbles, 4 = black stones")
            }
            return String(localized: "スクリーンタイム：勉強アプリの時間 +\(minutes)分（\(pebbles)粒）、黒い石 +\(blackStones)",
                          table: "ScreenTime",
                          comment: "Toast: study time for several themes and black stones added. 1 = minutes, 2 = pebbles, 3 = black stones")
        }
    }
}

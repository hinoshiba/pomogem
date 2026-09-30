import Foundation

// 重さの旅 on Home (GemExperienceDesign §5.5, §5.6, §8.1; D5, D6, D7, D11).
//
// Everything here reads `WeightJourney` (pure arithmetic on lifetime grams)
// and a few device-local facts. Nothing is stored except the celebration
// watermark and the Home toggle, both account-scoped UserDefaults keys that
// never sync and are cleared by an activity reset.

// MARK: - The one line on Home (§5.5, D6, D11)

/// Home's single next-target line: 「つぎの名所　米俵1俵・100時間」 or
/// 「つぎの一里塚　80時間」, then what was stacked in the stretch up to its
/// halfway point (「+3時間10分 積みました」) and what is left past it
/// (「あと4時間50分」), and 「・あと1本」 only when D11 allows it. While the
/// total is provisional it says 「80時間以上・同期中」 and never guesses the
/// stretch.
enum WeightJourneyHomeLine {
    struct Line: Equatable, Sendable {
        enum Target: Equatable, Sendable {
            /// A 名所: its title (comparison, or ゾウN頭ぶん) and its time.
            case landmark(title: String, time: String)
            /// A 一里塚: its time.
            case marker(time: String)
        }

        enum Progress: Equatable, Sendable {
            /// Nothing stacked in the stretch yet (right after a threshold).
            case none
            /// Up to and including half the stretch.
            case accumulated(minutes: Int)
            /// Past half.
            case remaining(minutes: Int)
        }

        /// Nil while the total is provisional.
        let target: Target?
        let progress: Progress
        let showsOneMore: Bool
        /// The floor 「80時間以上・同期中」 names while provisional.
        let provisionalFloorMinutes: Int?
        let text: String
    }

    /// The line for a lifetime total, or nil for an empty jar (its own
    /// message already says what one focus brings) and for a provisional
    /// total that has not reached a threshold yet (there is no floor to
    /// name). `allowsOneMore` receives the minutes left in the stretch.
    static func line(
        grams rawGrams: Int,
        isProvisional: Bool,
        allowsOneMore: (_ remainingMinutes: Int) -> Bool = { _ in false }
    ) -> Line? {
        let grams = max(0, rawGrams)
        guard grams > 0 else { return nil }
        let state = WeightJourney.state(grams: grams, isProvisional: isProvisional)
        guard let segment = state.segment else {
            let floorMinutes = state.segmentStartGrams / WeightJourney.gramsPerMinute
            guard floorMinutes > 0 else { return nil }
            return Line(
                target: nil,
                progress: .none,
                showsOneMore: false,
                provisionalFloorMinutes: floorMinutes,
                text: provisionalText(floorMinutes: floorMinutes)
            )
        }
        let progress: Line.Progress
        if segment.isPastHalf {
            progress = .remaining(minutes: segment.remainingMinutes)
        } else if segment.accumulatedMinutes > 0 {
            progress = .accumulated(minutes: segment.accumulatedMinutes)
        } else {
            progress = .none
        }
        let oneMore = segment.remainingMinutes > 0 && allowsOneMore(segment.remainingMinutes)
        let target = self.target(state.nextTarget)
        return Line(
            target: target,
            progress: progress,
            showsOneMore: oneMore,
            provisionalFloorMinutes: nil,
            text: text(target: target, progress: progress, oneMore: oneMore)
        )
    }

    static func target(_ target: WeightJourney.Target) -> Line.Target {
        switch target {
        case let .landmark(landmark):
            return .landmark(title: landmark.lineTitle, time: landmark.timeText)
        case let .marker(marker):
            return .marker(time: marker.timeText)
        }
    }

    static func provisionalText(floorMinutes: Int) -> String {
        String(
            localized: "\(DurationText.short(minutes: floorMinutes))以上・同期中",
            table: "Home",
            comment: "Home's Weight Journey (重さの旅) line while the lifetime total is still being checked with iCloud: at least this much time is stacked. %@ is a time (80時間). Suggested en: 'At least %@ · syncing'"
        )
    }

    // One format string per whole line (Docs/Localization.md): the target,
    // then the stretch, then 「あと1本」.
    static func text(target: Line.Target, progress: Line.Progress, oneMore: Bool) -> String {
        switch target {
        case let .landmark(title, time):
            return landmarkText(title: title, time: time, progress: progress, oneMore: oneMore)
        case let .marker(time):
            return markerText(time: time, progress: progress, oneMore: oneMore)
        }
    }

    private static func landmarkText(title: String, time: String, progress: Line.Progress, oneMore: Bool) -> String {
        switch (progress, oneMore) {
        case (.none, false):
            return String(localized: "つぎの名所　\(title)・\(time)", table: "Home",
                          comment: "Home's next-target line: the next landmark (名所, suggested en 'landmark'). %1$@ its weight comparison (米俵1俵), %2$@ its time (100時間). Suggested en: 'Next landmark: %1$@ · %2$@'")
        case (.none, true):
            return String(localized: "つぎの名所　\(title)・\(time)・あと1本", table: "Home",
                          comment: "Home's next-target line with D11's one-more note: one focus of the chosen length reaches it. %1$@ comparison, %2$@ time. Suggested en: 'Next landmark: %1$@ · %2$@ · one more focus'")
        case let (.accumulated(minutes), false):
            return String(localized: "つぎの名所　\(title)・\(time)・+\(DurationText.short(minutes: minutes)) 積みました", table: "Home",
                          comment: "Home's next-target line, first half of the stretch: what was stacked since the last landmark or milestone marker. %1$@ comparison, %2$@ time, %3$@ stacked time (3時間10分). Suggested en: 'Next landmark: %1$@ · %2$@ · +%3$@ stacked'")
        case let (.accumulated(minutes), true):
            return String(localized: "つぎの名所　\(title)・\(time)・+\(DurationText.short(minutes: minutes)) 積みました・あと1本", table: "Home",
                          comment: "Home's next-target line, first half of the stretch, with the one-more note. %1$@ comparison, %2$@ time, %3$@ stacked time. Suggested en: 'Next landmark: %1$@ · %2$@ · +%3$@ stacked · one more focus'")
        case let (.remaining(minutes), false):
            return String(localized: "つぎの名所　\(title)・\(time)・あと\(DurationText.short(minutes: minutes))", table: "Home",
                          comment: "Home's next-target line, second half of the stretch: time left to the landmark. %1$@ comparison, %2$@ time, %3$@ time left (4時間50分). Suggested en: 'Next landmark: %1$@ · %2$@ · %3$@ to go'")
        case let (.remaining(minutes), true):
            return String(localized: "つぎの名所　\(title)・\(time)・あと\(DurationText.short(minutes: minutes))・あと1本", table: "Home",
                          comment: "Home's next-target line, second half of the stretch, with the one-more note. %1$@ comparison, %2$@ time, %3$@ time left. Suggested en: 'Next landmark: %1$@ · %2$@ · %3$@ to go · one more focus'")
        }
    }

    private static func markerText(time: String, progress: Line.Progress, oneMore: Bool) -> String {
        switch (progress, oneMore) {
        case (.none, false):
            return String(localized: "つぎの一里塚　\(time)", table: "Home",
                          comment: "Home's next-target line: the next milestone marker (一里塚, one every 10 hours; suggested en 'milestone marker'). %@ its time (80時間). Suggested en: 'Next marker: %@'")
        case (.none, true):
            return String(localized: "つぎの一里塚　\(time)・あと1本", table: "Home",
                          comment: "Home's next-target line with D11's one-more note. %@ the marker's time. Suggested en: 'Next marker: %@ · one more focus'")
        case let (.accumulated(minutes), false):
            return String(localized: "つぎの一里塚　\(time)・+\(DurationText.short(minutes: minutes)) 積みました", table: "Home",
                          comment: "Home's next-target line, first half of the stretch. %1$@ the marker's time, %2$@ stacked time (3時間10分). Suggested en: 'Next marker: %1$@ · +%2$@ stacked'")
        case let (.accumulated(minutes), true):
            return String(localized: "つぎの一里塚　\(time)・+\(DurationText.short(minutes: minutes)) 積みました・あと1本", table: "Home",
                          comment: "Home's next-target line, first half of the stretch, with the one-more note. %1$@ the marker's time, %2$@ stacked time. Suggested en: 'Next marker: %1$@ · +%2$@ stacked · one more focus'")
        case let (.remaining(minutes), false):
            return String(localized: "つぎの一里塚　\(time)・あと\(DurationText.short(minutes: minutes))", table: "Home",
                          comment: "Home's next-target line, second half of the stretch. %1$@ the marker's time, %2$@ time left (4時間50分). Suggested en: 'Next marker: %1$@ · %2$@ to go'")
        case let (.remaining(minutes), true):
            return String(localized: "つぎの一里塚　\(time)・あと\(DurationText.short(minutes: minutes))・あと1本", table: "Home",
                          comment: "Home's next-target line, second half of the stretch, with the one-more note. %1$@ the marker's time, %2$@ time left. Suggested en: 'Next marker: %1$@ · %2$@ to go · one more focus'")
        }
    }
}

extension WeightJourney.Landmark {
    /// What the Home line calls a 名所: its weight comparison
    /// (「米俵1俵」「キャベツ1玉ほど」), or ゾウN頭ぶん for the herd, whose
    /// name leads (§5.1).
    var lineTitle: String {
        if case .elephants = kind { return name }
        return comparison.label
    }
}

extension WeightJourney.Marker {
    /// 「30時間」「1,000時間」.
    var timeText: String { DurationText.short(minutes: minutes) }
}

// MARK: - 「あと1本」 (D11)

/// D11: 「・あと1本」 is a fact about the weight left, shown only when one
/// focus of the chosen length reaches the target, and never when one more
/// would work against rest (EA §3.6):
///
/// - 21:00 to 04:00 (the app's study day turns at 04:00);
/// - after two completions in a row that skipped their break, for the rest
///   of that study day;
/// - once 4 hours are stacked that study day;
/// - right after the long break was suggested (for its length).
///
/// Every signal is derived from records Home already reads and the
/// device-local rest cadence (`FocusRestCadenceStore`); nothing new is
/// stored.
enum WeightJourneyOneMorePolicy {
    /// From 21:00 …
    static let quietStartHour = 21
    /// … to the study day's turn.
    static let quietEndHour = Constants.Fairness.dayBoundaryHour
    /// 4 hours in one study day.
    static let dailyGramsCap = 240 * Constants.Mass.gramsPerMinute
    /// Two break-skipping completions in a row.
    static let skippedBreakRun = 2

    /// One saved focus of the current study day (or the latest one).
    struct Record: Equatable, Sendable {
        let id: UUID
        let startAt: Date
        let endAt: Date
        let grams: Int
        let isTimerCompletion: Bool
    }

    /// What Home resolves on its own pass.
    struct DaySignals: Equatable, Sendable {
        var todayGrams: Int = 0
        /// Two completions in a row today started their next focus before
        /// their break was over.
        var skippedBreakTwiceInARow = false
        /// When the latest completion, offered the long break, ended.
        var longBreakSuggestedAt: Date?

        static let none = DaySignals()
    }

    /// The day's signals from the study day's records (any order) and the
    /// rest cadence's recent suggestions. Records from other study days are
    /// ignored except to find the latest completion.
    static func signals(
        records: [Record],
        restRecords: [FocusRestCadenceSnapshot.Record],
        now: Date,
        timeZone: TimeZone = .current
    ) -> DaySignals {
        let todayKey = FairnessPolicy.deviceDayKey(for: now, timeZone: timeZone)
        let today = records.filter {
            $0.endAt <= now.addingTimeInterval(60)
                && FairnessPolicy.deviceDayKey(for: $0.endAt, timeZone: timeZone) == todayKey
        }
        var signals = DaySignals()
        signals.todayGrams = today.reduce(0) { total, record in
            let sum = total.addingReportingOverflow(max(0, record.grams))
            return sum.overflow ? Int.max : sum.partialValue
        }

        let breakMinutes = Dictionary(
            restRecords.map { ($0.sessionID, $0.breakMinutes) },
            uniquingKeysWith: { _, last in last }
        )
        let completions = today
            .filter(\.isTimerCompletion)
            .sorted { $0.startAt == $1.startAt ? $0.endAt < $1.endAt : $0.startAt < $1.startAt }
        var run = 0
        for (current, next) in zip(completions, completions.dropFirst()) {
            let minutes = breakMinutes[current.id] ?? Constants.Timer.shortBreakMinutes
            let skipped = next.startAt.timeIntervalSince(current.endAt) < TimeInterval(minutes * 60)
            run = skipped ? run + 1 : 0
            if run >= skippedBreakRun {
                signals.skippedBreakTwiceInARow = true
                break
            }
        }

        if let latest = records.filter(\.isTimerCompletion).max(by: { $0.endAt < $1.endAt }),
           breakMinutes[latest.id] == Constants.Timer.longBreakMinutes {
            signals.longBreakSuggestedAt = latest.endAt
        }
        return signals
    }

    /// 21:00 ≤ now or now < 04:00, on the device's clock.
    static func isQuietHour(_ now: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: now)
        return hour >= quietStartHour || hour < quietEndHour
    }

    static func longBreakWindowEnd(_ signals: DaySignals) -> Date? {
        signals.longBreakSuggestedAt.map {
            $0.addingTimeInterval(TimeInterval(Constants.Timer.longBreakMinutes * 60))
        }
    }

    /// Whether 「・あと1本」 goes on the line.
    static func allows(
        remainingMinutes: Int,
        selectedMinutes: Int,
        signals: DaySignals,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard remainingMinutes > 0, selectedMinutes > 0, remainingMinutes <= selectedMinutes else { return false }
        guard !isQuietHour(now, calendar: calendar) else { return false }
        guard !signals.skippedBreakTwiceInARow else { return false }
        guard signals.todayGrams < dailyGramsCap else { return false }
        if let end = longBreakWindowEnd(signals), now < end { return false }
        return true
    }

    /// The instants after `now` at which `allows` can change by itself: the
    /// next 21:00 and 04:00, and the end of a long break's quiet window.
    static func boundaries(after now: Date, signals: DaySignals, calendar: Calendar = .current) -> [Date] {
        var dates: [Date] = []
        for hour in [quietStartHour, quietEndHour] {
            if let date = calendar.nextDate(
                after: now,
                matching: DateComponents(hour: hour, minute: 0, second: 0),
                matchingPolicy: .nextTime
            ) {
                dates.append(date)
            }
        }
        if let end = longBreakWindowEnd(signals), end > now {
            dates.append(end)
        }
        return dates.sorted()
    }
}

// MARK: - Celebration (§5.6, the 小 level)

/// §5.6: arrival is never stored; only how far this device has celebrated
/// (the watermark, in lifetime grams). v1.3a shows the 小 level: a one-line
/// chip on the completion card, and on Home at most one quiet chip for what
/// arrived while away, plus 「重さの旅を読み込みました」 once.
enum WeightJourneyCelebration {
    /// What Home shows once, as a quiet chip.
    enum HomeChip: Equatable, Sendable {
        /// A device without a watermark read the journey for the first time.
        case loaded(reached: String, next: String)
        /// Thresholds crossed through sync or while Home was not looked at:
        /// only the highest is named.
        case crossed(WeightJourney.Threshold)

        var text: String {
            switch self {
            case let .loaded(reached, next):
                return String(
                    localized: "重さの旅を読み込みました。いまは\(reached)、つぎは\(next)です",
                    table: "Home",
                    comment: "Home chip shown once on a device that reads the Weight Journey (重さの旅, suggested en 'Weight Journey') for the first time: a new device, a reinstall or the first run after the update. %1$@ what is reached (5時間, 一里塚 30時間), %2$@ the next target (一里塚 80時間, 名所 米俵1俵・100時間). Suggested en: 'Weight Journey loaded. You are at %1$@; next is %2$@.'"
                )
            case let .crossed(threshold):
                return threshold.homeChipText
            }
        }
    }

    struct Observation: Equatable, Sendable {
        let watermark: Int?
        let chip: HomeChip?
        /// Home has now seen the total it was opened on (a chip was spent,
        /// or there was nothing to say): what arrives later waits for the
        /// next open.
        let consumesArm: Bool
    }

    /// A settled, verified lifetime total on Home (never a lower bound,
    /// never while iCloud is checked, never while a completion's card still
    /// holds its gem). `isArmed`: Home was opened since the last chip.
    static func observe(watermark: Int?, grams rawGrams: Int, isArmed: Bool) -> Observation {
        let grams = max(0, rawGrams)
        guard let watermark else {
            // Adopt what is reached without replaying it (§5.6): a new
            // iPad never plays the 10,000-hour moment again.
            return Observation(watermark: grams, chip: loadedChip(grams: grams), consumesArm: true)
        }
        if grams < watermark {
            // Records were deleted: follow them down, quietly.
            return Observation(watermark: grams, chip: nil, consumesArm: true)
        }
        if grams == watermark {
            return Observation(watermark: watermark, chip: nil, consumesArm: true)
        }
        guard isArmed else {
            // Wait for the next time Home is opened.
            return Observation(watermark: watermark, chip: nil, consumesArm: false)
        }
        let highest = celebrated(WeightJourney.crossing(from: watermark, to: grams)).first
        return Observation(watermark: grams, chip: highest.map(HomeChip.crossed), consumesArm: true)
    }

    /// 「重さの旅を読み込みました…」, or nil before the first 名所 (nothing to
    /// load: a new user's first gem is celebrated on its own card).
    static func loadedChip(grams: Int) -> HomeChip? {
        let state = WeightJourney.state(grams: grams, isProvisional: false)
        let markerGrams = WeightJourney.saturatingProduct(state.markers.count, WeightJourney.markerGrams)
        let reached: String
        if let landmark = state.reachedLandmark, landmark.grams >= markerGrams {
            reached = landmark.name
        } else if state.markers.count > 0 {
            reached = WeightJourney.Marker(ordinal: state.markers.count).markerPhrase
        } else {
            return nil
        }
        return .loaded(reached: reached, next: targetPhrase(state.nextTarget))
    }

    /// 「一里塚 80時間」 or 「名所 米俵1俵・100時間」.
    static func targetPhrase(_ target: WeightJourney.Target) -> String {
        switch target {
        case let .marker(marker):
            return marker.markerPhrase
        case let .landmark(landmark):
            return String(
                localized: "名所 \(landmark.lineTitle)・\(landmark.timeText)",
                table: "Home",
                comment: "Weight Journey: a landmark (名所) named in a sentence. %1$@ its comparison (米俵1俵), %2$@ its time (100時間). Suggested en: 'the %1$@ landmark (%2$@)'"
            )
        }
    }

    struct Completion: Equatable, Sendable {
        let watermark: Int?
        /// What the card's chip names, highest first; empty for none.
        let thresholds: [WeightJourney.Threshold]
    }

    /// A completion's card. Only a receipt that is neither a lower bound nor
    /// read before iCloud was checked, on a device that already holds a
    /// watermark, celebrates; it names what lies between the watermark and
    /// the receipt's total after this focus, and the watermark follows.
    static func completion(watermark: Int?, afterGrams rawAfter: Int, isVerified: Bool) -> Completion {
        guard isVerified, let watermark else { return Completion(watermark: watermark, thresholds: []) }
        let after = max(0, rawAfter)
        guard after > watermark else { return Completion(watermark: watermark, thresholds: []) }
        return Completion(
            watermark: after,
            thresholds: celebrated(WeightJourney.crossing(from: watermark, to: after))
        )
    }

    /// The thresholds a chip may name, highest first: 名所 and 一里塚. A core
    /// stage has its own moment (the card's core line or the fusion sheet),
    /// so one crossed alone gives no chip.
    static func celebrated(_ crossing: WeightJourney.Crossing) -> [WeightJourney.Threshold] {
        crossing.thresholds.filter { $0.landmark != nil || $0.marker != nil }
    }

    /// The card's chip: the highest, then at most `listedOthers` more.
    struct CardChip: Equatable, Sendable {
        let headline: String
        let others: String?

        static let listedOthers = 4

        init?(_ thresholds: [WeightJourney.Threshold]) {
            guard let highest = thresholds.first else { return nil }
            headline = highest.cardHeadline
            let rest = thresholds.dropFirst().prefix(Self.listedOthers).map(\.shortName)
            others = rest.isEmpty ? nil : String(
                localized: "ほかに \(ListText.compact(Array(rest)))",
                table: "Home",
                comment: "Completion card, under the Weight Journey chip: the other landmarks or milestone markers this focus also reached. %@ is a list (5時間・◇ 10時間). Suggested en: 'Also: %@'"
            )
        }
    }
}

extension WeightJourney.Marker {
    /// 「一里塚 30時間」.
    var markerPhrase: String {
        String(
            localized: "一里塚 \(timeText)",
            table: "Home",
            comment: "Weight Journey: a milestone marker (一里塚, one every 10 hours; suggested en 'milestone marker') named in a sentence. %@ its time (30時間). Suggested en: 'the %@ marker'"
        )
    }
}

extension WeightJourney.Threshold {
    /// The card's line (§5.3 小): 「2時間。キャベツ1玉ほどの重さになりました」, or
    /// for a 一里塚 alone 「◇ 30時間」 (with what the ◇ became when it folds).
    var cardHeadline: String {
        if let landmark {
            return landmark.arrivalSentence
        }
        guard let marker else { return "" }
        switch marker.completes {
        case .diamond:
            return String(
                localized: "◇ \(marker.timeText)",
                table: "Home",
                comment: "Completion card chip: this focus reached a milestone marker (一里塚), and its ◇ lights on the time core's orbit. %@ its time (30時間). Suggested en: '◇ %@'"
            )
        case .star:
            return String(
                localized: "◇ \(marker.timeText)。◇10個が星になりました",
                table: "Home",
                comment: "Completion card chip: a milestone marker completed ten ◇, which fold into one 100-hour star (星, suggested en 'star'). %@ its time (300時間). Suggested en: '◇ %@. Ten ◇ became a star.'"
            )
        case .crown, .elephant:
            return String(
                localized: "◇ \(marker.timeText)。星10個が冠になりました",
                table: "Home",
                comment: "Completion card chip: a milestone marker completed ten stars, which fold into one 1,000-hour crown (冠, suggested en 'crown'). %@ its time (3,000時間). Suggested en: '◇ %@. Ten stars became a crown.'"
            )
        }
    }

    /// Home's quiet chip for an arrival it did not see happen.
    var homeChipText: String {
        if let landmark {
            return landmark.arrivalSentence
        }
        guard let marker else { return "" }
        return String(
            localized: "\(marker.markerPhrase)に届きました",
            table: "Home",
            comment: "Home chip: the lifetime total reached a milestone marker while Home was not being looked at (synced from another device, or while away). %@ is 一里塚 30時間. Suggested en: 'Reached %@'"
        )
    }

    /// In a list: 「5時間」「最初の一粒」「◇ 30時間」.
    var shortName: String {
        if let landmark { return landmark.name }
        guard let marker else { return "" }
        return String(
            localized: "◇ \(marker.timeText)",
            table: "Home",
            comment: "Completion card chip: this focus reached a milestone marker (一里塚), and its ◇ lights on the time core's orbit. %@ its time (30時間). Suggested en: '◇ %@'"
        )
    }
}

extension WeightJourney.Landmark {
    /// 「2時間。キャベツ1玉ほどの重さになりました」.
    var arrivalSentence: String {
        String(
            localized: "\(name)。\(comparison.label)の重さになりました",
            table: "Home",
            comment: "Weight Journey chip when a landmark (名所) is reached. %1$@ the landmark's name (2時間, 最初の一粒, ゾウ1頭ぶん), %2$@ its weight comparison (キャベツ1玉ほど). Never claims an exact balance. Suggested en: '%1$@. Now about as heavy as %2$@.'"
        )
    }
}

// MARK: - Device-local state

/// How far this device has celebrated the journey (§5.6), in lifetime
/// grams: account-scoped UserDefaults, never synced (two offline devices
/// would fight over a synced counter), cleared by an activity reset.
enum WeightJourneyCelebrationStore {
    static let defaultsBase = "journey.celebrated-grams.v1"

    static func load(defaults: UserDefaults = .standard) -> Int? {
        let key = AccountScopedLocalState.defaultsKey(base: defaultsBase, defaults: defaults)
        guard let value = defaults.object(forKey: key) as? Int else { return nil }
        return max(0, value)
    }

    static func save(_ grams: Int?, defaults: UserDefaults = .standard) {
        let key = AccountScopedLocalState.defaultsKey(base: defaultsBase, defaults: defaults)
        if let grams {
            defaults.set(max(0, grams), forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    static func removeAll(defaults: UserDefaults = .standard) {
        save(nil, defaults: defaults)
    }
}

/// 設定の「Home に次の目標を表示」 (§5.5): device-local, on by default.
enum WeightJourneyHomePreference {
    static let defaultsBase = "home.shows-next-target.v1"

    static var defaultsKey: String {
        AccountScopedLocalState.defaultsKey(base: defaultsBase)
    }

    static func removeAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: AccountScopedLocalState.defaultsKey(base: defaultsBase, defaults: defaults))
    }
}

// MARK: - Home's inputs

/// The study day's saved focus (and the latest completion), with the rest
/// cadence's recent suggestions: what D11's signals are derived from. Home
/// re-reads them, bounded, when its store changes; nothing here is stored.
struct WeightJourneyDayRecords: Equatable, Sendable {
    var records: [WeightJourneyOneMorePolicy.Record]
    var restRecords: [FocusRestCadenceSnapshot.Record]

    static let empty = WeightJourneyDayRecords(records: [], restRecords: [])
}

/// What the jar's readout needs from Home's own pass for the next-target
/// line (`JarStageSnapshot`), so a landing never re-runs Home for it.
struct WeightJourneyStageInputs: Equatable, Sendable {
    /// 設定の「Home に次の目標を表示」.
    let showsNextTarget: Bool
    /// The focus length chosen on Home, in whole minutes (0 for the Debug
    /// 12-second demo).
    let selectedMinutes: Int
    let day: WeightJourneyDayRecords

    func signals(now: Date) -> WeightJourneyOneMorePolicy.DaySignals {
        WeightJourneyOneMorePolicy.signals(records: day.records, restRecords: day.restRecords, now: now)
    }

    func boundaries(after now: Date) -> [Date] {
        WeightJourneyOneMorePolicy.boundaries(after: now, signals: signals(now: now))
    }

    /// The line for the readout on screen at `now`: nil when the toggle is
    /// off, before Home has read its records, and when the readout has no
    /// mass to stand behind (「再集計中」). A lower bound or a total iCloud
    /// has not checked yet reads 「80時間以上・同期中」.
    func line(readout: LifetimeReadoutContinuityPolicy.Readout, now: Date) -> WeightJourneyHomeLine.Line? {
        guard showsNextTarget, !readout.isLoading, let grams = readout.jarGrams else { return nil }
        let signals = signals(now: now)
        return WeightJourneyHomeLine.line(
            grams: grams,
            isProvisional: readout.isLowerBound || readout.isCloudVerificationPending
        ) { remaining in
            WeightJourneyOneMorePolicy.allows(
                remainingMinutes: remaining,
                selectedMinutes: selectedMinutes,
                signals: signals,
                now: now
            )
        }
    }
}

/// A settled, verified lifetime total Home can celebrate from (§5.6); nil
/// fields never reach the watermark.
struct WeightJourneyObservation: Equatable, Sendable {
    /// Saved grams, when Home may observe them now: settled inputs, not a
    /// lower bound, not while iCloud is checked, and no completion card or
    /// falling timer gem holding a total back.
    let grams: Int?
}

/// Home's memory between observations: a plain reference in `@State`, so
/// arming or observing never re-renders Home.
@MainActor
final class WeightJourneyHomeTracker {
    /// Home was opened (it appeared, came back to the foreground, or a
    /// sheet over it closed) since the last quiet chip.
    var isArmed = true
    var lastObservation = WeightJourneyObservation(grams: nil)
}

/// The completion card's chip for the offer it was resolved for.
struct WeightJourneyCardChipState: Equatable, Sendable {
    let offerID: UUID
    let chip: WeightJourneyCelebration.CardChip?
}

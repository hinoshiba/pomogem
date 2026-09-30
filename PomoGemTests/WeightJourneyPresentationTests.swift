import XCTest
@testable import PomoGem

/// 重さの旅 on Home (GemExperienceDesign §5.5, §5.6; D5, D6, D7, D11): the one
/// next-target line and its 50% rule, 「あと1本」 and when it is held back,
/// the celebration watermark, the readout's placement and the orbit's marks.
final class WeightJourneyPresentationTests: XCTestCase {
    private typealias Line = WeightJourneyHomeLine
    private typealias OneMore = WeightJourneyOneMorePolicy
    private typealias Celebration = WeightJourneyCelebration

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    // MARK: - The line (§5.5, D6)

    /// The showcase fixtures the screenshots use, and what the line says.
    func testTheLineNamesTheNextLandmarkWithinTenHoursAndTheMarkerOtherwise() {
        let cases: [(grams: Int, text: String)] = [
            // 25 min: 最初の一粒 was just reached; the stretch to 1 hour starts.
            (250, "つぎの名所　卵10個ほど・1時間"),
            // 6h15m: past 5 hours, 1h15m of the 5 hours to 10 hours.
            (3_750, "つぎの名所　大玉スイカ1玉ほど・10時間・+1時間15分 積みました"),
            // 16h15m: past half of 10 → 20 hours, so what is left.
            (9_750, "つぎの名所　コーギー1頭ほど・20時間・あと3時間45分"),
            // 48h45m: from the 40-hour marker to the 50-hour landmark.
            (29_250, "つぎの名所　コウテイペンギン1羽ほど・50時間・あと1時間15分"),
            // 418h20m: 500 hours is far, so the next marker.
            (251_000, "つぎの一里塚　420時間・あと1時間40分"),
            // 4,169h10m.
            (2_501_500, "つぎの一里塚　4,170時間・あと50分"),
        ]
        for item in cases {
            let line = Line.line(grams: item.grams, isProvisional: false)
            XCTAssertEqual(line?.text, item.text, "grams=\(item.grams)")
            XCTAssertFalse(line?.showsOneMore ?? true)
        }
    }

    func testTheLineTargetsTheLandmarkOnlyWithinTenHours() {
        // 90 hours: 100 hours (米俵) is exactly 10 hours away → the landmark.
        let atTen = Line.line(grams: 54_000, isProvisional: false)
        XCTAssertEqual(atTen?.target, .landmark(title: "米俵1俵", time: "100時間"))
        XCTAssertEqual(atTen?.text, "つぎの名所　米俵1俵・100時間")
        // 89h50m: 10h10m away → the 90-hour marker.
        let beyond = Line.line(grams: 53_900, isProvisional: false)
        XCTAssertEqual(beyond?.target, .marker(time: "90時間"))
        XCTAssertEqual(beyond?.text, "つぎの一里塚　90時間・あと10分")
        // ゾウ1頭ぶん names the herd, not the comparison.
        let elephant = Line.line(grams: 5_995_000, isProvisional: false)
        XCTAssertEqual(elephant?.target, .landmark(title: "ゾウ1頭ぶん", time: "10,000時間"))
    }

    func testTheFiftyPercentRuleSaysWhatWasStackedUpToHalfAndWhatIsLeftPastIt() {
        // The 80 → 90 hour stretch (6,000 g).
        let start = 48_000
        let atHalf = Line.line(grams: start + 3_000, isProvisional: false)
        XCTAssertEqual(atHalf?.progress, .accumulated(minutes: 300), "Half is still what was stacked")
        XCTAssertEqual(atHalf?.text, "つぎの一里塚　90時間・+5時間 積みました")
        let pastHalf = Line.line(grams: start + 3_010, isProvisional: false)
        XCTAssertEqual(pastHalf?.progress, .remaining(minutes: 299))
        XCTAssertEqual(pastHalf?.text, "つぎの一里塚　90時間・あと4時間59分")
        // A remainder rounds up: never 「あと0分」 before the target.
        let lastGrams = Line.line(grams: start + 5_995, isProvisional: false)
        XCTAssertEqual(lastGrams?.progress, .remaining(minutes: 1))
        // Right on a marker the next stretch has nothing stacked yet.
        let onMarker = Line.line(grams: start, isProvisional: false)
        XCTAssertEqual(onMarker?.progress, Line.Line.Progress.none)
        XCTAssertEqual(onMarker?.text, "つぎの一里塚　90時間")
    }

    func testAProvisionalTotalNamesOnlyItsFloorAndNeverTheStretch() {
        let line = Line.line(grams: 83 * 600, isProvisional: true)
        XCTAssertEqual(line?.text, "80時間以上・同期中")
        XCTAssertNil(line?.target)
        XCTAssertEqual(line?.provisionalFloorMinutes, 80 * 60)
        XCTAssertFalse(line?.showsOneMore ?? true, "No 「あと1本」 from a lower bound")
        // A landmark floor reads as its time.
        XCTAssertEqual(Line.line(grams: 130 * 10, isProvisional: true)?.text, "2時間以上・同期中")
        // Nothing reached yet: nothing to stand behind.
        XCTAssertNil(Line.line(grams: 200, isProvisional: true))
        // An empty jar has its own message.
        XCTAssertNil(Line.line(grams: 0, isProvisional: false))
    }

    func testTheLineReadsTheLandedReadoutAndHonoursTheToggle() {
        var readout = LifetimeReadoutContinuityPolicy.Readout(
            isCloudVerificationPending: false,
            jarGrams: 3_750,
            jarCoreGrams: 3_750,
            jarPebbles: 15,
            jarLoosePebbles: 5,
            menuGrams: 4_000,
            menuPebbles: 16,
            isLowerBound: false,
            jarIsEmpty: false,
            coreColorHex: "#FFFFFF",
            coreColorShares: []
        )
        let noon = date(29, 12)
        let inputs = WeightJourneyStageInputs(showsNextTarget: true, selectedMinutes: 25, day: .empty)
        XCTAssertEqual(
            inputs.line(readout: readout, now: noon)?.text,
            "つぎの名所　大玉スイカ1玉ほど・10時間・+1時間15分 積みました",
            "The landed mass, not the menu's saved one"
        )
        let hidden = WeightJourneyStageInputs(showsNextTarget: false, selectedMinutes: 25, day: .empty)
        XCTAssertNil(hidden.line(readout: readout, now: noon), "「Home に次の目標を表示」 off")

        readout.isCloudVerificationPending = true
        XCTAssertEqual(inputs.line(readout: readout, now: noon)?.text, "5時間以上・同期中")
        readout.isCloudVerificationPending = false
        readout.isLowerBound = true
        XCTAssertEqual(inputs.line(readout: readout, now: noon)?.text, "5時間以上・同期中")
        readout.jarGrams = nil
        XCTAssertNil(inputs.line(readout: readout, now: noon), "「再集計中」 has no line")
        readout.jarGrams = 3_750
        readout.isLoading = true
        XCTAssertNil(inputs.line(readout: readout, now: noon))
    }

    // MARK: - 「あと1本」 (D11)

    func testOneMoreOnlyWhenTheChosenLengthReachesTheTarget() {
        let noon = date(29, 12)
        XCTAssertTrue(OneMore.allows(remainingMinutes: 25, selectedMinutes: 25, signals: .none, now: noon, calendar: calendar))
        XCTAssertFalse(OneMore.allows(remainingMinutes: 26, selectedMinutes: 25, signals: .none, now: noon, calendar: calendar))
        XCTAssertTrue(OneMore.allows(remainingMinutes: 50, selectedMinutes: 60, signals: .none, now: noon, calendar: calendar))
        XCTAssertFalse(OneMore.allows(remainingMinutes: 1, selectedMinutes: 0, signals: .none, now: noon, calendar: calendar),
                       "The 12-second demo never counts as one more")

        // 89h35m with 25 minutes chosen: 「・あと1本」 on the same line.
        let line = Line.line(grams: 53_750, isProvisional: false) { remaining in
            OneMore.allows(remainingMinutes: remaining, selectedMinutes: 25, signals: .none, now: noon, calendar: self.calendar)
        }
        XCTAssertEqual(line?.text, "つぎの一里塚　90時間・あと25分・あと1本")
        XCTAssertTrue(line?.showsOneMore ?? false)
        // In the first half, with a long chosen length.
        let early = Line.line(grams: 250 + 100, isProvisional: false) { remaining in
            OneMore.allows(remainingMinutes: remaining, selectedMinutes: 60, signals: .none, now: noon, calendar: self.calendar)
        }
        XCTAssertEqual(early?.text, "つぎの名所　卵10個ほど・1時間・+10分 積みました・あと1本")
    }

    func testOneMoreRestsFromNinePmToTheStudyDaysTurnAtFour() {
        for (hour, minute, allowed) in [(20, 59, true), (21, 0, false), (23, 30, false), (0, 0, false), (3, 59, false), (4, 0, true)] {
            XCTAssertEqual(
                OneMore.allows(remainingMinutes: 10, selectedMinutes: 25, signals: .none, now: date(29, hour, minute), calendar: calendar),
                allowed,
                "\(hour):\(minute)"
            )
        }
    }

    private func completion(_ start: Date, minutes: Int = 25) -> OneMore.Record {
        OneMore.Record(
            id: UUID(),
            startAt: start,
            endAt: start.addingTimeInterval(TimeInterval(minutes * 60)),
            grams: minutes * 10,
            isTimerCompletion: true
        )
    }

    func testOneMoreRestsAfterTwoBreakSkippingCompletionsInARowThatDay() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let now = date(29, 15)
        // Three focuses back to back: the first two skipped their break.
        let first = completion(date(29, 10))
        let second = completion(first.endAt.addingTimeInterval(60))
        let third = completion(second.endAt.addingTimeInterval(120))
        let skippedTwice = OneMore.signals(records: [third, first, second], restRecords: [], now: now, timeZone: tokyo)
        XCTAssertTrue(skippedTwice.skippedBreakTwiceInARow)
        XCTAssertFalse(OneMore.allows(remainingMinutes: 10, selectedMinutes: 25, signals: skippedTwice, now: now, calendar: calendar))

        // One skip, then a real break: allowed.
        let rested = completion(second.endAt.addingTimeInterval(6 * 60))
        let once = OneMore.signals(records: [first, second, rested], restRecords: [], now: now, timeZone: tokyo)
        XCTAssertFalse(once.skippedBreakTwiceInARow)
        XCTAssertTrue(OneMore.allows(remainingMinutes: 10, selectedMinutes: 25, signals: once, now: now, calendar: calendar))

        // A long break (15 min) was suggested after the second: 6 minutes
        // later is still a skip.
        let longRest = [FocusRestCadenceSnapshot.Record(sessionID: second.id, breakMinutes: 15)]
        let shortAfterLong = OneMore.signals(records: [first, second, rested], restRecords: longRest, now: now, timeZone: tokyo)
        XCTAssertTrue(shortAfterLong.skippedBreakTwiceInARow)

        // Yesterday's run does not carry into today.
        let yesterday = OneMore.signals(records: [first, second, third], restRecords: [], now: date(30, 12), timeZone: tokyo)
        XCTAssertFalse(yesterday.skippedBreakTwiceInARow)
    }

    func testOneMoreRestsOnceFourHoursAreStackedThatStudyDay() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let now = date(29, 18)
        let morning = completion(date(29, 8), minutes: 120)
        let afternoon = completion(date(29, 13), minutes: 119)
        let under = OneMore.signals(records: [morning, afternoon], restRecords: [], now: now, timeZone: tokyo)
        XCTAssertEqual(under.todayGrams, 2_390)
        XCTAssertTrue(OneMore.allows(remainingMinutes: 10, selectedMinutes: 25, signals: under, now: now, calendar: calendar))
        let manual = OneMore.Record(id: UUID(), startAt: date(29, 16), endAt: date(29, 16, 1), grams: 10, isTimerCompletion: false)
        let four = OneMore.signals(records: [morning, afternoon, manual], restRecords: [], now: now, timeZone: tokyo)
        XCTAssertEqual(four.todayGrams, 2_400)
        XCTAssertFalse(OneMore.allows(remainingMinutes: 10, selectedMinutes: 25, signals: four, now: now, calendar: calendar))
        // The study day turns at 04:00: a focus that ended at 03:00 is
        // yesterday's.
        let lateNight = completion(date(29, 1), minutes: 120)
        let nextDay = OneMore.signals(records: [lateNight], restRecords: [], now: date(29, 9), timeZone: tokyo)
        XCTAssertEqual(nextDay.todayGrams, 0)
    }

    func testOneMoreRestsRightAfterTheLongBreakSuggestion() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let focus = completion(date(29, 14))
        let long = [FocusRestCadenceSnapshot.Record(sessionID: focus.id, breakMinutes: 15)]
        let signals = OneMore.signals(records: [focus], restRecords: long, now: focus.endAt, timeZone: tokyo)
        XCTAssertEqual(signals.longBreakSuggestedAt, focus.endAt)
        XCTAssertFalse(OneMore.allows(remainingMinutes: 10, selectedMinutes: 25, signals: signals,
                                      now: focus.endAt.addingTimeInterval(14 * 60), calendar: calendar))
        XCTAssertTrue(OneMore.allows(remainingMinutes: 10, selectedMinutes: 25, signals: signals,
                                     now: focus.endAt.addingTimeInterval(15 * 60), calendar: calendar))
        // A later completion without the long break ends it.
        let next = completion(focus.endAt.addingTimeInterval(20 * 60))
        let later = OneMore.signals(
            records: [focus, next],
            restRecords: long + [FocusRestCadenceSnapshot.Record(sessionID: next.id, breakMinutes: 5)],
            now: next.endAt,
            timeZone: tokyo
        )
        XCTAssertNil(later.longBreakSuggestedAt)
        // The line re-reads the clock at these moments only.
        XCTAssertEqual(
            OneMore.boundaries(after: focus.endAt, signals: signals, calendar: calendar),
            [focus.endAt.addingTimeInterval(15 * 60), date(29, 21), date(30, 4)]
        )
    }

    // MARK: - Celebration watermark (§5.6)

    func testANewDeviceAdoptsWhatIsReachedSilentlyAndSaysSoOnce() {
        let empty = Celebration.observe(watermark: nil, grams: 0, isArmed: true)
        XCTAssertEqual(empty.watermark, 0)
        XCTAssertNil(empty.chip, "A new user has nothing to load")

        let loaded = Celebration.observe(watermark: nil, grams: 3_750, isArmed: true)
        XCTAssertEqual(loaded.watermark, 3_750)
        XCTAssertEqual(
            loaded.chip?.text,
            "重さの旅を読み込みました。いまは5時間、つぎは名所 大玉スイカ1玉ほど・10時間です"
        )
        XCTAssertTrue(loaded.consumesArm)

        // Adopting 10,000 hours plays no zoom-out and names no crossing.
        let veteran = Celebration.observe(watermark: nil, grams: 6_000_000 + 1_000, isArmed: true)
        XCTAssertEqual(veteran.chip, .loaded(reached: "ゾウ1頭ぶん", next: "一里塚 10,010時間"))
        // A marker above the last landmark is named as the marker.
        XCTAssertEqual(
            Celebration.observe(watermark: nil, grams: 29_250, isArmed: false).chip?.text,
            "重さの旅を読み込みました。いまは一里塚 40時間、つぎは名所 コウテイペンギン1羽ほど・50時間です"
        )
    }

    func testWhatArrivedWhileAwayIsNamedOnceOnTheNextOpen() {
        // Synced from another device while Home was not opened: wait.
        let waiting = Celebration.observe(watermark: 3_750, grams: 9_750, isArmed: false)
        XCTAssertEqual(waiting.watermark, 3_750)
        XCTAssertNil(waiting.chip)
        XCTAssertFalse(waiting.consumesArm)

        // Opened: one chip, the highest only.
        let opened = Celebration.observe(watermark: 3_750, grams: 9_750, isArmed: true)
        XCTAssertEqual(opened.watermark, 9_750)
        XCTAssertEqual(opened.chip?.text, "10時間。大玉スイカ1玉ほどの重さになりました")
        XCTAssertTrue(opened.consumesArm)

        // Never twice.
        XCTAssertNil(Celebration.observe(watermark: 9_750, grams: 9_750, isArmed: true).chip)

        // A marker alone.
        XCTAssertEqual(
            Celebration.observe(watermark: 17_000, grams: 18_500, isArmed: true).chip?.text,
            "一里塚 30時間に届きました"
        )
        // A core stage alone has its own moment.
        XCTAssertNil(Celebration.observe(watermark: 2_400, grams: 2_600, isArmed: true).chip)
    }

    func testDeletingRecordsLowersTheWatermarkQuietlyAndARerunCelebratesAgain() {
        let deleted = Celebration.observe(watermark: 6_250, grams: 5_900, isArmed: true)
        XCTAssertEqual(deleted.watermark, 5_900)
        XCTAssertNil(deleted.chip, "No reversal")
        XCTAssertTrue(deleted.consumesArm, "Home has seen the total it opened on")

        let again = Celebration.completion(watermark: 5_900, afterGrams: 6_150, isVerified: true)
        XCTAssertEqual(again.watermark, 6_150)
        XCTAssertEqual(again.thresholds.first?.landmark?.minutes, 600)
    }

    func testTheCompletionCardNamesTheHighestAndListsTheRest() {
        let tenHours = Celebration.completion(watermark: 5_500, afterGrams: 6_250, isVerified: true)
        XCTAssertEqual(tenHours.watermark, 6_250)
        let chip = Celebration.CardChip(tenHours.thresholds)
        XCTAssertEqual(chip?.headline, "10時間。大玉スイカ1玉ほどの重さになりました")
        XCTAssertNil(chip?.others)

        // Several at once (the core stage at 4h10m is the core's own moment).
        let several = Celebration.CardChip(
            Celebration.completion(watermark: 2_400, afterGrams: 6_100, isVerified: true).thresholds
        )
        XCTAssertEqual(several?.headline, "10時間。大玉スイカ1玉ほどの重さになりました")
        XCTAssertEqual(several?.others, "ほかに 5時間")

        // The first gem of all.
        XCTAssertEqual(
            Celebration.CardChip(Celebration.completion(watermark: 0, afterGrams: 250, isVerified: true).thresholds)?.headline,
            "最初の一粒。りんご1個ほどの重さになりました"
        )
        // 一里塚 only, then the folds.
        XCTAssertEqual(
            Celebration.CardChip(Celebration.completion(watermark: 17_750, afterGrams: 18_250, isVerified: true).thresholds)?.headline,
            "◇ 30時間"
        )
        XCTAssertEqual(
            Celebration.CardChip(Celebration.completion(watermark: 179_750, afterGrams: 180_250, isVerified: true).thresholds)?.headline,
            "◇ 300時間。◇10個が星になりました"
        )
        XCTAssertEqual(
            Celebration.CardChip(Celebration.completion(watermark: 1_799_750, afterGrams: 1_800_250, isVerified: true).thresholds)?.headline,
            "◇ 3,000時間。星10個が冠になりました"
        )
        XCTAssertEqual(
            Celebration.CardChip(Celebration.completion(watermark: 119_750, afterGrams: 120_250, isVerified: true).thresholds)?.headline,
            "200時間。ジャイアントパンダ1頭ほどの重さになりました"
        )
        XCTAssertEqual(
            Celebration.CardChip(Celebration.completion(watermark: 59_750, afterGrams: 60_250, isVerified: true).thresholds)?.headline,
            "100時間。米俵1俵の重さになりました",
            "Exact by definition: no ほど"
        )
        // A core stage alone: no chip.
        XCTAssertNil(Celebration.CardChip(Celebration.completion(watermark: 2_400, afterGrams: 2_600, isVerified: true).thresholds))
    }

    func testTheCardCelebratesOnlyAVerifiedReceiptOnADeviceWithAWatermark() {
        let lowerBound = Celebration.completion(watermark: 5_500, afterGrams: 6_250, isVerified: false)
        XCTAssertEqual(lowerBound.watermark, 5_500)
        XCTAssertTrue(lowerBound.thresholds.isEmpty)
        let newDevice = Celebration.completion(watermark: nil, afterGrams: 6_250, isVerified: true)
        XCTAssertNil(newDevice.watermark)
        XCTAssertTrue(newDevice.thresholds.isEmpty)
        // Already celebrated (another device's total arrived first).
        let behind = Celebration.completion(watermark: 7_000, afterGrams: 6_250, isVerified: true)
        XCTAssertEqual(behind.watermark, 7_000)
        XCTAssertTrue(behind.thresholds.isEmpty)
        // What arrived unannounced since the watermark joins the card.
        let joined = Celebration.completion(watermark: 2_900, afterGrams: 6_100, isVerified: true)
        XCTAssertEqual(joined.thresholds.compactMap { $0.landmark?.minutes }, [600, 300])
    }

    func testTheWatermarkIsAccountScopedLocalStateThatAResetClears() {
        let defaults = UserDefaults(suiteName: "WeightJourneyPresentationTests.\(UUID().uuidString)")!
        XCTAssertNil(WeightJourneyCelebrationStore.load(defaults: defaults))
        WeightJourneyCelebrationStore.save(6_250, defaults: defaults)
        XCTAssertEqual(WeightJourneyCelebrationStore.load(defaults: defaults), 6_250)
        WeightJourneyCelebrationStore.removeAll(defaults: defaults)
        XCTAssertNil(WeightJourneyCelebrationStore.load(defaults: defaults))
        // UI tests start from a watermark above anything: Home's first
        // settled total lowers it without 「重さの旅を読み込みました」.
        UITestLocalStateIsolation.seedWeightJourneyWatermark(defaults: defaults, environment: [:])
        XCTAssertEqual(WeightJourneyCelebrationStore.load(defaults: defaults), Int.max)
        XCTAssertNil(Celebration.observe(watermark: Int.max, grams: 3_750, isArmed: true).chip)
        UITestLocalStateIsolation.seedWeightJourneyWatermark(
            defaults: defaults,
            environment: [UITestLocalStateIsolation.journeyEnvironmentKey: "fresh"]
        )
        XCTAssertNil(WeightJourneyCelebrationStore.load(defaults: defaults))
        UITestLocalStateIsolation.seedWeightJourneyWatermark(
            defaults: defaults,
            environment: [UITestLocalStateIsolation.journeyEnvironmentKey: "3750"]
        )
        XCTAssertEqual(WeightJourneyCelebrationStore.load(defaults: defaults), 3_750)
    }

    // MARK: - D5 placement

    func testTheReadoutGoesAboveTheMouthOnlyWhenTheBottleKeepsThreeHundredTwentyPoints() {
        // iPhone 17 Pro: 518 pt of room, a 138 pt readout.
        let pro = JarHUDLayout.resolve(restingRoom: 518, room: 518, readoutHeight: 138)
        XCTAssertEqual(pro.placement, .aboveMouth)
        XCTAssertEqual(pro.cardHeight, 518)
        XCTAssertEqual(pro.stageTop, 144)
        XCTAssertEqual(pro.stageHeight, 374)
        XCTAssertEqual(pro.hudBottom, 138)

        // iPhone SE: 379 pt → the bottle would be 235 pt: inside, as before.
        let se = JarHUDLayout.resolve(restingRoom: 379, room: 379, readoutHeight: 138)
        XCTAssertEqual(se.placement, .inside)
        XCTAssertEqual(se.cardHeight, 379)
        XCTAssertEqual(se.stageTop, 0)
        XCTAssertNil(se.hudBottom)

        // A tall phone: the bottle reaches its 420 pt, the rest is shared.
        let max = JarHUDLayout.resolve(restingRoom: 600, room: 600, readoutHeight: 138)
        XCTAssertEqual(max.stageHeight, 420)
        XCTAssertEqual(max.cardHeight, 600)
        XCTAssertEqual(max.stageTop, 18 + 144)

        // A completion card shortens the room: the readout stays above and
        // the bottle keeps 320 pt.
        let card = JarHUDLayout.resolve(restingRoom: 518, room: 300, readoutHeight: 138)
        XCTAssertEqual(card.placement, .aboveMouth)
        XCTAssertEqual(card.stageHeight, 320)
        XCTAssertEqual(card.cardHeight, 464)

        // The Debug review seam keeps it inside.
        XCTAssertEqual(JarHUDLayout.resolve(keepsReadoutInside: true, restingRoom: 600, room: 600, readoutHeight: 138).placement, .inside)
    }

    // MARK: - D7 orbit

    func testTheOrbitDiamondsAreMilestoneMarkersFoldedIntoStarsCrownsAndElephants() {
        func core(_ grams: Int) -> JarLifetimeCoreState {
            JarLifetimeCorePresentation.state(totalPebbleCount: max(1, grams / 250), totalGrams: grams, projectionIsLowerBound: false)!
        }
        XCTAssertEqual(core(3_750).litOrbitSlotCount, 0, "6h15m: no 一里塚 yet")
        XCTAssertEqual(core(9_750).litOrbitSlotCount, 1)
        XCTAssertEqual(core(29_250).litOrbitSlotCount, 4)
        let heavy = core(2_501_500)
        XCTAssertEqual(heavy.litOrbitSlotCount, 6)
        XCTAssertEqual(heavy.journeyMarkers?.stars, 1)
        XCTAssertEqual(heavy.journeyMarkers?.crowns, 4)
        XCTAssertEqual(heavy.journeyMarkers?.elephants, 0)
        XCTAssertEqual(heavy.orbitCount, 2, "The 星 ring")
        XCTAssertEqual(core(29_250).orbitCount, 1, "Before 100 hours: one ring")
        XCTAssertEqual(core(60_000).orbitCount, 2, "100 hours: the first 星 brings its ring")
        // Forty years at 10 h a day: ◇0 星1 冠6 ゾウ14, still two rings
        // below 25 t's third.
        let forty = core(87_660_000)
        XCTAssertEqual(forty.litOrbitSlotCount, 0)
        XCTAssertEqual(forty.journeyMarkers?.elephants, 14)
        XCTAssertEqual(forty.orbitCount, 3)
        // A lower bound lights nothing: its fold is not the real one.
        let partial = JarLifetimeCorePresentation.state(totalPebbleCount: 40, totalGrams: 9_750, projectionIsLowerBound: true)
        XCTAssertNil(partial?.litOrbitSlotCount)
        XCTAssertNil(partial?.journeyMarkers)
    }
}

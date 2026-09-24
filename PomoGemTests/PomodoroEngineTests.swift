import SwiftUI
import UserNotifications
import XCTest
@testable import PomoGem

final class PomodoroEngineTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_788_000_000)

    func testFocusReturnReminderPreferenceDefaultsOffAndHonorsExplicitChoice() throws {
        let suite = "FocusReturnReminderPolicy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(FocusReturnReminderPolicy.isEnabled(defaults: defaults))
        defaults.set(true, forKey: FocusReturnReminderPolicy.enabledDefaultsKey)
        XCTAssertTrue(FocusReturnReminderPolicy.isEnabled(defaults: defaults))
        defaults.set(false, forKey: FocusReturnReminderPolicy.enabledDefaultsKey)
        XCTAssertFalse(FocusReturnReminderPolicy.isEnabled(defaults: defaults))
    }

    func testFocusReturnReminderRequiresMoreThanSixtySecondsAfterDelivery() {
        XCTAssertEqual(FocusReturnReminderPolicy.delay, 30)
        XCTAssertEqual(FocusReturnReminderPolicy.completionQuietWindow, 60)
        for remaining in [-1.0, 0, 30, 60, 89.999, 90, 90.001, 120] {
            XCTAssertEqual(
                FocusReturnReminderPolicy.shouldSchedule(
                    preferenceEnabled: true,
                    sceneIsBackground: true,
                    phase: .focusing,
                    endDate: referenceDate.addingTimeInterval(remaining),
                    now: referenceDate
                ),
                remaining > 90,
                "remaining=\(remaining) must leave over sixty seconds after the thirty-second reminder"
            )
        }
        for endDate in [nil, Date(timeIntervalSinceReferenceDate: .infinity),
                        Date(timeIntervalSinceReferenceDate: .nan)] as [Date?] {
            XCTAssertFalse(FocusReturnReminderPolicy.shouldSchedule(
                preferenceEnabled: true, sceneIsBackground: true, phase: .focusing,
                endDate: endDate, now: referenceDate
            ))
        }
        XCTAssertFalse(FocusReturnReminderPolicy.shouldSchedule(
            preferenceEnabled: true, sceneIsBackground: true, phase: .focusing,
            endDate: referenceDate.addingTimeInterval(120),
            now: Date(timeIntervalSinceReferenceDate: .nan)
        ))
    }

    func testFocusReturnReminderRequiresOptInActualBackgroundAndRunningFocus() {
        for phase in [PomodoroPhase.idle, .paused, .focusCompleted, .shortBreak,
                      .longBreak, .breakCompleted, .focusing] {
            for enabled in [false, true] {
                for isBackground in [false, true] {
                    XCTAssertEqual(
                        FocusReturnReminderPolicy.shouldSchedule(
                            preferenceEnabled: enabled,
                            sceneIsBackground: isBackground,
                            phase: phase,
                            endDate: referenceDate.addingTimeInterval(120),
                            now: referenceDate
                        ),
                        enabled && isBackground && phase == .focusing
                    )
                }
            }
        }
    }

    @MainActor
    func testFocusReturnReminderCandidateSurvivesForegroundCancellationUntilTimerEnds() async throws {
        let fixture = try FocusReturnReminderFixture()
        defer { fixture.cleanUp() }
        let sessionID = UUID()
        fixture.manager.registerFocusReturnReminder(
            sessionID: sessionID, endDate: .now.addingTimeInterval(300), playsSound: false
        )
        // A temporary inactive-state View unmount must preserve the candidate.
        fixture.manager.cancelFocusReturnReminder()
        let first = try await fixture.manager.scheduleRegisteredFocusReturnReminder()
        guard case .accepted = first else { return XCTFail("Expected the retained running timer") }
        let request = try XCTUnwrap(fixture.recorder.additions.last)
        let trigger = try XCTUnwrap(request.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertFalse(trigger.repeats)
        XCTAssertGreaterThan(trigger.timeInterval, 25)
        XCTAssertLessThanOrEqual(trigger.timeInterval, 30)
        XCTAssertEqual(request.content.body, "集中時間が続いています。タイマーに戻って続けましょう。")
        XCTAssertEqual(
            request.content.interruptionLevel, .active,
            "An opt-in nudge must never break through Focus as Time Sensitive"
        )
        XCTAssertNil(request.content.sound)
        XCTAssertNil(request.content.badge)
        XCTAssertTrue(request.content.userInfo.isEmpty)
        fixture.recorder.delivered.insert(request.identifier)
        fixture.manager.cancelFocusReturnReminder()
        XCTAssertTrue(fixture.recorder.pending.isEmpty)
        XCTAssertTrue(fixture.recorder.delivered.isEmpty)

        // The next actual departure may reuse the candidate, but pause/end
        // cancellation must retire it even after foreground cleared its cue.
        fixture.manager.cancelFocusCompletion(sessionID: sessionID)
        let afterPause = try await fixture.manager.scheduleRegisteredFocusReturnReminder()
        XCTAssertEqual(afterPause, .superseded)
        XCTAssertEqual(fixture.recorder.additions.count, 1)
    }

    @MainActor
    func testFocusReturnReminderLateAddCannotSurviveForegroundCancellation() async throws {
        let fixture = try FocusReturnReminderFixture()
        defer { fixture.cleanUp() }
        fixture.recorder.holdNextAdd = true
        fixture.recorder.deliverOnAdd = true
        let operation = Task { @MainActor in
            try await fixture.manager.scheduleFocusReturnReminder(
                sessionID: UUID(), endDate: .now.addingTimeInterval(300), playsSound: true
            )
        }
        try await fixture.waitForAddCount(1)
        fixture.manager.cancelFocusReturnReminder()
        fixture.recorder.finishHeldAdd()
        let result = try await operation.value
        XCTAssertEqual(result, .superseded)
        XCTAssertTrue(fixture.recorder.pending.isEmpty)
        XCTAssertTrue(fixture.recorder.delivered.isEmpty)
    }

    @MainActor
    func testFocusReturnReminderSerializesNewSessionBehindAnUnfinishedOldAdd() async throws {
        let fixture = try FocusReturnReminderFixture()
        defer { fixture.cleanUp() }
        let oldSession = UUID()
        let newSession = UUID()
        fixture.recorder.holdNextAdd = true
        let oldOperation = Task { @MainActor in
            try await fixture.manager.scheduleFocusReturnReminder(
                sessionID: oldSession, endDate: .now.addingTimeInterval(300), playsSound: false
            )
        }
        try await fixture.waitForAddCount(1)
        fixture.manager.registerFocusReturnReminder(
            sessionID: newSession, endDate: .now.addingTimeInterval(300), playsSound: true
        )
        let newOperation = Task { @MainActor in
            try await fixture.manager.scheduleRegisteredFocusReturnReminder()
        }
        await Task.yield()
        XCTAssertEqual(fixture.recorder.additions.count, 1,
                       "The new add must wait until old add cleanup has finished")
        fixture.manager.cancelFocusCompletion(sessionID: oldSession)
        fixture.recorder.finishHeldAdd()
        let oldResult = try await oldOperation.value
        let newResult = try await newOperation.value
        XCTAssertEqual(oldResult, .superseded)
        guard case .accepted = newResult else { return XCTFail("Expected the new session reminder") }
        XCTAssertEqual(fixture.recorder.additions.count, 2)
        XCTAssertEqual(fixture.recorder.maximumConcurrentAdds, 1)
        XCTAssertEqual(Set(fixture.recorder.additions.map(\.identifier)).count, 1)
        XCTAssertEqual(fixture.recorder.pending.count, 1)
        XCTAssertNotNil(fixture.recorder.pending.values.first?.content.sound)
    }

    @MainActor
    func testFocusReturnReminderAccountBoundaryRetiresCandidateAndInFlightAdd() async throws {
        let fixture = try FocusReturnReminderFixture()
        defer { fixture.cleanUp() }
        fixture.manager.registerFocusReturnReminder(
            sessionID: UUID(), endDate: .now.addingTimeInterval(300), playsSound: true
        )
        fixture.recorder.holdNextAdd = true
        let operation = Task { @MainActor in
            try await fixture.manager.scheduleRegisteredFocusReturnReminder()
        }
        try await fixture.waitForAddCount(1)
        fixture.manager.suspendTimerSchedulingForAccountBoundary()
        fixture.manager.resumeTimerSchedulingAfterAccountBoundary()
        fixture.recorder.finishHeldAdd()
        let result = try await operation.value
        XCTAssertEqual(result, .superseded)
        XCTAssertTrue(fixture.recorder.pending.isEmpty)
        let recovered = try await fixture.manager.scheduleRegisteredFocusReturnReminder()
        XCTAssertEqual(recovered, .superseded)
        XCTAssertEqual(fixture.recorder.additions.count, 1)
    }

    @MainActor
    func testFocusReturnReminderCannotBypassAuthorizationOrPreference() async throws {
        let fixture = try FocusReturnReminderFixture()
        defer { fixture.cleanUp() }
        fixture.manager.registerFocusReturnReminder(
            sessionID: UUID(), endDate: .now.addingTimeInterval(300), playsSound: true
        )
        fixture.recorder.status = .denied
        let denied = try await fixture.manager.scheduleRegisteredFocusReturnReminder()
        XCTAssertEqual(denied, .superseded)
        XCTAssertTrue(fixture.recorder.additions.isEmpty)
        fixture.recorder.status = .authorized
        fixture.defaults.set(false, forKey: FocusReturnReminderPolicy.enabledDefaultsKey)
        let disabled = try await fixture.manager.scheduleRegisteredFocusReturnReminder()
        XCTAssertEqual(disabled, .superseded)
        XCTAssertTrue(fixture.recorder.additions.isEmpty)
    }

    func testScreenAwakePolicyCoversFocusAndBreakOnlyWhileRunningInForeground() {
        for phase in [
            PomodoroPhase.focusing,
            .shortBreak,
            .longBreak
        ] {
            XCTAssertTrue(
                TimerScreenAwakePolicy.shouldKeepScreenAwake(
                    preferenceEnabled: true,
                    sceneIsActive: true,
                    timerIsRunning: phase.isRunning,
                    remainingSeconds: 1
                ),
                "\(phase) should keep the screen awake"
            )
        }

        for phase in [
            PomodoroPhase.idle,
            .paused,
            .focusCompleted,
            .breakCompleted
        ] {
            XCTAssertFalse(
                TimerScreenAwakePolicy.shouldKeepScreenAwake(
                    preferenceEnabled: true,
                    sceneIsActive: true,
                    timerIsRunning: phase.isRunning,
                    remainingSeconds: 1
                ),
                "\(phase) must allow automatic locking"
            )
        }

        XCTAssertFalse(
            TimerScreenAwakePolicy.shouldKeepScreenAwake(
                preferenceEnabled: false,
                sceneIsActive: true,
                timerIsRunning: true,
                remainingSeconds: 1
            )
        )
        XCTAssertFalse(
            TimerScreenAwakePolicy.shouldKeepScreenAwake(
                preferenceEnabled: true,
                sceneIsActive: false,
                timerIsRunning: true,
                remainingSeconds: 1
            )
        )
        XCTAssertFalse(
            TimerScreenAwakePolicy.shouldKeepScreenAwake(
                preferenceEnabled: true,
                sceneIsActive: true,
                timerIsRunning: true,
                remainingSeconds: 0
            )
        )
    }

    func testScreenAwakePolicyFollowsFocusAndBreakLifecycle() throws {
        var engine = PomodoroEngine()

        func keepsScreenAwake(at date: Date) -> Bool {
            let snapshot = engine.snapshot(at: date)
            return TimerScreenAwakePolicy.shouldKeepScreenAwake(
                preferenceEnabled: true,
                sceneIsActive: true,
                timerIsRunning: snapshot.phase.isRunning,
                remainingSeconds: snapshot.remainingSeconds
            )
        }

        XCTAssertFalse(keepsScreenAwake(at: referenceDate))
        try engine.startFocus(isPro: false, now: referenceDate)
        XCTAssertTrue(keepsScreenAwake(at: referenceDate))

        try engine.pause(at: referenceDate.addingTimeInterval(1))
        XCTAssertFalse(keepsScreenAwake(at: referenceDate.addingTimeInterval(1)))
        try engine.resume(at: referenceDate.addingTimeInterval(2))
        XCTAssertTrue(keepsScreenAwake(at: referenceDate.addingTimeInterval(2)))

        let focusEnd = try XCTUnwrap(engine.endDate)
        XCTAssertFalse(keepsScreenAwake(at: focusEnd))
        XCTAssertNotNil(engine.advance(at: focusEnd))
        try engine.startBreak(now: focusEnd)
        XCTAssertTrue(keepsScreenAwake(at: focusEnd))

        try engine.pause(at: focusEnd.addingTimeInterval(1))
        XCTAssertFalse(keepsScreenAwake(at: focusEnd.addingTimeInterval(1)))
        try engine.resume(at: focusEnd.addingTimeInterval(2))
        XCTAssertTrue(keepsScreenAwake(at: focusEnd.addingTimeInterval(2)))

        let breakEnd = try XCTUnwrap(engine.endDate)
        XCTAssertFalse(keepsScreenAwake(at: breakEnd))
        XCTAssertNotNil(engine.advance(at: breakEnd))
        XCTAssertFalse(keepsScreenAwake(at: breakEnd))
    }

    func testTwentyFiveMinuteFocusUsesAbsoluteEndDate() throws {
        let sessionID = UUID()
        var engine = PomodoroEngine()

        try engine.startFocus(
            duration: .twentyFiveMinutes,
            isPro: false,
            now: referenceDate,
            sessionID: sessionID
        )

        XCTAssertEqual(
            engine.endDate,
            referenceDate.addingTimeInterval(TimeInterval(Constants.Timer.twentyFiveMinutes * 60))
        )
        XCTAssertEqual(engine.snapshot(at: referenceDate).remainingSeconds, 1_500)
        XCTAssertEqual(
            engine.snapshot(at: referenceDate.addingTimeInterval(750)).progress,
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(engine.snapshot(at: referenceDate).sessionID, sessionID)
    }

    func testEveryFreePresetStartsWithoutProAndOtherCustomTimesRequirePro() throws {
        XCTAssertEqual(
            PomodoroDuration.freePresets.compactMap(\.minutes),
            [25, 45, 60, 90]
        )

        for duration in PomodoroDuration.freePresets {
            var freePresetEngine = PomodoroEngine()
            XCTAssertNoThrow(
                try freePresetEngine.startFocus(
                    duration: duration,
                    isPro: false,
                    now: referenceDate
                )
            )
            XCTAssertEqual(
                freePresetEngine.snapshot(at: referenceDate).remainingSeconds,
                duration.seconds
            )
        }

        var customEngine = PomodoroEngine()
        XCTAssertThrowsError(
            try customEngine.startFocus(
                duration: .custom(minutes: 40),
                isPro: false,
                now: referenceDate
            )
        ) { error in
            XCTAssertEqual(error as? PomodoroEngineError, .customDurationRequiresPro)
        }

        var proEngine = PomodoroEngine()
        XCTAssertNoThrow(
            try proEngine.startFocus(
                duration: .custom(minutes: 40),
                isPro: true,
                now: referenceDate
            )
        )
        XCTAssertEqual(proEngine.snapshot(at: referenceDate).remainingSeconds, 2_400)
    }

    func testCustomValuesMatchingFreePresetsAreNormalizedAndFree() throws {
        for minutes in [
            Constants.Timer.twentyFiveMinutes,
            Constants.Timer.fortyFiveMinutes,
            Constants.Timer.sixtyMinutes,
            Constants.Timer.ninetyMinutes
        ] {
            var engine = PomodoroEngine()
            try engine.startFocus(
                duration: .custom(minutes: minutes),
                isPro: false,
                now: referenceDate
            )
            XCTAssertFalse(engine.selectedDuration.requiresPro)
            XCTAssertEqual(engine.selectedDuration, PomodoroDuration(minutes: minutes))
        }
    }

    func testSharedFreeDurationContractMatchesEnginePresets() {
        XCTAssertEqual(
            Set(PomodoroDuration.freePresets.map(\.seconds)),
            IntegrationConstants.freeFocusDurations
        )
    }

    func testFocusTimerRingSizeIsAlwaysFiniteAndPositive() {
        let invalidContainers: [CGSize] = [
            .zero,
            CGSize(width: -1, height: 874),
            CGSize(width: 402, height: -1),
            CGSize(width: CGFloat.nan, height: 874),
            CGSize(width: 402, height: CGFloat.infinity)
        ]

        for container in invalidContainers {
            let value = FocusTimerLayoutPolicy.ringSize(in: container)
            XCTAssertTrue(value.isFinite)
            XCTAssertGreaterThan(value, 0)
        }
        XCTAssertEqual(FocusTimerLayoutPolicy.ringSize(in: CGSize(width: 63, height: 640)), 1)
        XCTAssertEqual(FocusTimerLayoutPolicy.ringSize(in: CGSize(width: 64, height: 640)), 1)
        XCTAssertEqual(FocusTimerLayoutPolicy.ringSize(in: CGSize(width: 320, height: 640)), 214)
        XCTAssertEqual(FocusTimerLayoutPolicy.ringSize(in: CGSize(width: 402, height: 874)), 286)
    }

    func testTimerDisplayModeHasFourStableChoicesAndSafeFallback() {
        XCTAssertEqual(
            TimerDisplayMode.allCases,
            [.ringAndTime, .filledDial, .timeOnly, .ringOnly]
        )
        XCTAssertEqual(
            TimerDisplayMode.allCases.map(\.rawValue),
            ["ringAndTime", "filledDial", "timeOnly", "ringOnly"]
        )
        XCTAssertEqual(
            TimerDisplayMode.resolved("future-unknown-mode"),
            .ringAndTime
        )
        XCTAssertEqual(Prefs().timerDisplayModeRawValue, "ringAndTime")
    }

    func testTimerDisplayProgressClampsAndFilledDialCountsDown() {
        XCTAssertEqual(FocusTimerDisplayPolicy.normalizedProgress(-1), 0)
        XCTAssertEqual(FocusTimerDisplayPolicy.normalizedProgress(0.25), 0.25)
        XCTAssertEqual(FocusTimerDisplayPolicy.normalizedProgress(2), 1)
        XCTAssertEqual(FocusTimerDisplayPolicy.normalizedProgress(.nan), 0)
        XCTAssertEqual(FocusTimerDisplayPolicy.normalizedProgress(.infinity), 0)

        XCTAssertEqual(FocusTimerDisplayPolicy.remainingFraction(for: -1), 1)
        XCTAssertEqual(FocusTimerDisplayPolicy.remainingFraction(for: 0), 1)
        XCTAssertEqual(FocusTimerDisplayPolicy.remainingFraction(for: 0.5), 0.5)
        XCTAssertEqual(FocusTimerDisplayPolicy.remainingFraction(for: 1), 0)
        XCTAssertEqual(FocusTimerDisplayPolicy.remainingFraction(for: 2), 0)
    }

    func testFilledDialRemovesElapsedAreaClockwiseFromTwelveOClock() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let full = FocusRemainingDialShape(elapsedProgress: 0).path(in: rect)
        XCTAssertTrue(full.contains(CGPoint(x: 75, y: 25)))
        XCTAssertTrue(full.contains(CGPoint(x: 25, y: 25)))

        let quarterElapsed = FocusRemainingDialShape(
            elapsedProgress: 0.25
        ).path(in: rect)
        XCTAssertFalse(quarterElapsed.contains(CGPoint(x: 75, y: 25)))
        XCTAssertTrue(quarterElapsed.contains(CGPoint(x: 75, y: 75)))
        XCTAssertTrue(quarterElapsed.contains(CGPoint(x: 25, y: 75)))
        XCTAssertTrue(quarterElapsed.contains(CGPoint(x: 25, y: 25)))

        let halfElapsed = FocusRemainingDialShape(
            elapsedProgress: 0.5
        ).path(in: rect)
        XCTAssertFalse(halfElapsed.contains(CGPoint(x: 75, y: 25)))
        XCTAssertFalse(halfElapsed.contains(CGPoint(x: 75, y: 75)))
        XCTAssertTrue(halfElapsed.contains(CGPoint(x: 25, y: 75)))
        XCTAssertTrue(halfElapsed.contains(CGPoint(x: 25, y: 25)))

        let empty = FocusRemainingDialShape(elapsedProgress: 1).path(in: rect)
        XCTAssertTrue(empty.isEmpty)
    }

    @MainActor
    func testRenderedRingsRemoveElapsedArcClockwiseFromTwelveOClock() throws {
        // Sample the middle of each quadrant on the 240-point circle, away
        // from the origin, moving marker, rounded ends, and central labels.
        let quadrantPoints = [
            CGPoint(x: 215, y: 45),  // Upper right
            CGPoint(x: 215, y: 215), // Lower right
            CGPoint(x: 45, y: 215),  // Lower left
            CGPoint(x: 45, y: 45)    // Upper left
        ]
        let cases: [(progress: Double, visible: [Bool])] = [
            (0, [true, true, true, true]),
            (0.25, [false, true, true, true]),
            (0.5, [false, false, true, true]),
            (1, [false, false, false, false])
        ]

        for mode in [TimerDisplayMode.ringAndTime, .ringOnly] {
            for testCase in cases {
                let image = try renderTimerDisplay(mode: mode, progress: testCase.progress)
                let pixels = try XCTUnwrap(image.cgImage)
                let visible = try quadrantPoints.map {
                    try timerAccentIsVisible(in: pixels, at: $0, scale: image.scale)
                }

                XCTAssertEqual(
                    visible,
                    testCase.visible,
                    "\(mode.rawValue), progress \(testCase.progress): clockwise from upper right"
                )
                if visible != testCase.visible {
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "Ring countdown — \(mode.rawValue) — \(testCase.progress)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    @MainActor
    func testEveryTimerDisplayModeRendersAtPhoneScale() throws {
        var renderedImages: [Data] = []

        for mode in TimerDisplayMode.allCases {
            let image = try renderTimerDisplay(mode: mode, progress: 0.25)
            XCTAssertEqual(image.size, CGSize(width: 260, height: 260))
            renderedImages.append(try XCTUnwrap(image.pngData(), mode.rawValue))

            let attachment = XCTAttachment(image: image)
            attachment.name = "Timer display — \(mode.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        XCTAssertEqual(
            Set(renderedImages).count,
            TimerDisplayMode.allCases.count,
            "Each timer mode must produce a distinct visual treatment"
        )
    }

    @MainActor
    private func renderTimerDisplay(mode: TimerDisplayMode, progress: Double) throws -> UIImage {
        let seconds = Int(1_500 * (1 - progress))
        let content = ZStack {
            Color.black
            FocusTimerDisplay(
                size: 240,
                progress: progress,
                remainingTime: String(format: "%02d:%02d", seconds / 60, seconds % 60),
                accessibleRemainingTime: "残り\(seconds / 60)分\(seconds % 60)秒",
                modeLabel: "FOCUS",
                displayMode: mode,
                isBreakMode: false,
                isPaused: false,
                accent: Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1),
                reduceMotion: true
            )
        }
        .frame(width: 260, height: 260)
        .environment(\.dynamicTypeSize, .large)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return try XCTUnwrap(renderer.uiImage, mode.rawValue)
    }

    private func timerAccentIsVisible(
        in image: CGImage,
        at point: CGPoint,
        scale: CGFloat
    ) throws -> Bool {
        // CGImage cropping uses image coordinates with an upper-left origin.
        // Average a small patch wholly inside the stroke, then normalize its
        // channels to sRGB RGBA instead of assuming ImageRenderer's byte order.
        let patch = try XCTUnwrap(image.cropping(to: CGRect(
            x: (point.x - 1) * scale,
            y: (point.y - 1) * scale,
            width: 2 * scale,
            height: 2 * scale
        )))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.interpolationQuality = .high
        context.draw(patch, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)

        // The dim track and red shadow must not count as remaining time.
        return pixel[0] > 160 && pixel[1] < 80 && pixel[2] < 80
    }

    func testInvalidCustomDurationsAreRejected() {
        for minutes in [
            0,
            361,
            Int.max
        ] {
            var engine = PomodoroEngine()
            XCTAssertThrowsError(
                try engine.startFocus(
                    duration: .custom(minutes: minutes),
                    isPro: true,
                    now: referenceDate
                )
            ) { error in
                XCTAssertEqual(error as? PomodoroEngineError, .invalidCustomDuration)
            }
        }
    }

    func testSixHourProTimerPreservesProgressAndAwardAcrossPausedRecovery() throws {
        var freeEngine = PomodoroEngine()
        XCTAssertThrowsError(try freeEngine.startFocus(
            duration: .custom(minutes: 360), isPro: false, now: referenceDate
        )) { error in
            XCTAssertEqual(error as? PomodoroEngineError, .customDurationRequiresPro)
        }

        let sessionID = UUID()
        var engine = PomodoroEngine()
        try engine.startFocus(
            duration: .custom(minutes: 360), isPro: true,
            now: referenceDate, sessionID: sessionID
        )
        XCTAssertEqual(engine.endDate, referenceDate.addingTimeInterval(21_600))
        XCTAssertEqual(engine.snapshot(at: referenceDate).remainingSeconds, 21_600)
        let halfway = referenceDate.addingTimeInterval(10_800)
        XCTAssertEqual(engine.snapshot(at: halfway).remainingSeconds, 10_800)
        XCTAssertEqual(engine.snapshot(at: halfway).progress, 0.5, accuracy: 0.000_001)
        XCTAssertNil(engine.advance(at: halfway), "The former three-hour ceiling must not finish focus")

        try engine.pause(at: halfway.addingTimeInterval(0.25))
        var restored = try JSONDecoder().decode(
            PomodoroEngine.self, from: JSONEncoder().encode(engine)
        )
        XCTAssertTrue(restored.hasValidPausedFocusPayloadState)
        let resumedAt = halfway.addingTimeInterval(3_600.25)
        XCTAssertEqual(restored.snapshot(at: resumedAt).remainingSeconds, 10_800)
        try restored.resume(at: resumedAt)
        let end = referenceDate.addingTimeInterval(25_200)
        XCTAssertEqual(restored.endDate, end)
        XCTAssertNil(restored.advance(at: end.addingTimeInterval(-0.001)))
        guard case let .focusCompleted(completion) = restored.advance(at: end.addingTimeInterval(30)) else {
            return XCTFail("Expected one six-hour completion after the pause")
        }
        XCTAssertEqual(completion.sessionID, sessionID)
        XCTAssertEqual(completion.seconds, 21_600)
        XCTAssertEqual(completion.grams, 3_600)
        XCTAssertEqual(completion.endedAt, end)
        XCTAssertEqual(completion.source, .timer)
        XCTAssertEqual(restored.completedFocusCount, 1)
        XCTAssertNil(restored.advance(at: end.addingTimeInterval(60)))
    }

    func testLateTicksCompleteExactlyOnceWithScheduledEnd() throws {
        let sessionID = UUID()
        var engine = PomodoroEngine()
        try engine.startFocus(
            duration: .twentyFiveMinutes,
            isPro: false,
            now: referenceDate,
            sessionID: sessionID
        )
        let scheduledEnd = referenceDate.addingTimeInterval(1_500)

        XCTAssertNil(engine.advance(at: scheduledEnd.addingTimeInterval(-0.001)))
        let event = engine.advance(
            at: scheduledEnd.addingTimeInterval(42),
            observedUptime: 12_345.5
        )

        guard case let .focusCompleted(completion) = event else {
            return XCTFail("Expected one focus completion")
        }
        XCTAssertEqual(completion.sessionID, sessionID)
        XCTAssertEqual(completion.endedAt, scheduledEnd)
        XCTAssertEqual(completion.observedAt, scheduledEnd.addingTimeInterval(42))
        XCTAssertEqual(completion.observedUptime, 12_345.5)
        XCTAssertEqual(completion.seconds, 1_500)
        XCTAssertEqual(completion.grams, 250)
        XCTAssertNil(engine.advance(at: scheduledEnd.addingTimeInterval(43)))
        XCTAssertNil(engine.advance(at: scheduledEnd.addingTimeInterval(1_000)))
    }

    func testLegacyCompletionPayloadDecodesWithoutMonotonicObservation() throws {
        var engine = PomodoroEngine()
        try engine.startFocus(
            duration: .twentyFiveMinutes,
            isPro: false,
            now: referenceDate
        )
        guard case let .focusCompleted(completion) = engine.advance(
            at: referenceDate.addingTimeInterval(1_500),
            observedUptime: 8_000
        ) else {
            return XCTFail("Expected focus completion")
        }

        let encoded = try JSONEncoder().encode(completion)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "observedUptime")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(PomodoroCompletion.self, from: legacyData)

        XCTAssertNil(decoded.observedUptime)
        XCTAssertEqual(decoded.sessionID, completion.sessionID)
        XCTAssertEqual(decoded.source, completion.source)
    }

    func testPauseAndResumePreserveExactRemainingDuration() throws {
        var engine = PomodoroEngine()
        try engine.startFocus(
            duration: .twentyFiveMinutes,
            isPro: false,
            now: referenceDate
        )
        let pausedAt = referenceDate.addingTimeInterval(321.25)
        try engine.pause(at: pausedAt)

        let paused = engine.snapshot(at: referenceDate.addingTimeInterval(20_000))
        XCTAssertEqual(paused.phase, .paused)
        XCTAssertEqual(paused.remainingSeconds, 1_179)

        let resumedAt = referenceDate.addingTimeInterval(40_000)
        try engine.resume(at: resumedAt)
        let expectedEnd = resumedAt.addingTimeInterval(1_178.75)
        let actualEnd = try XCTUnwrap(engine.endDate)
        XCTAssertEqual(
            actualEnd.timeIntervalSince1970,
            expectedEnd.timeIntervalSince1970,
            accuracy: 0.000_001
        )
        XCTAssertNil(engine.advance(at: expectedEnd.addingTimeInterval(-0.001)))
        XCTAssertNotNil(engine.advance(at: expectedEnd))
    }

    func testBackwardClockWhilePausedRebasesAndDemotesCompletion() throws {
        var engine = PomodoroEngine()
        try engine.startFocus(
            duration: .twentyFiveMinutes,
            isPro: false,
            now: referenceDate
        )
        try engine.pause(at: referenceDate.addingTimeInterval(300))

        let resumedAt = referenceDate.addingTimeInterval(-3_600)
        try engine.resume(at: resumedAt)
        let resumedEnd = try XCTUnwrap(engine.endDate)
        XCTAssertEqual(resumedEnd, resumedAt.addingTimeInterval(1_200))
        XCTAssertEqual(engine.currentSource, .timerDemoted)

        guard case let .focusCompleted(completion) = engine.advance(at: resumedEnd) else {
            return XCTFail("Expected a demoted completion")
        }
        XCTAssertEqual(completion.source, .timerDemoted)
        XCTAssertEqual(
            completion.endedAt.timeIntervalSince(completion.startedAt),
            1_500,
            accuracy: 0.000_001
        )
        XCTAssertEqual(completion.observedAt, completion.endedAt)
    }

    func testDateLineAndDSTDoNotChangeAbsoluteCountdown() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let springForwardStart = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 8,
            hour: 1,
            minute: 55
        )))
        var engine = PomodoroEngine()
        try engine.startFocus(
            duration: .twentyFiveMinutes,
            isPro: false,
            now: springForwardStart
        )

        // Local wall time jumps from 01:59 to 03:00, but ten real minutes are
        // still ten elapsed minutes.
        let tenMinutesLater = springForwardStart.addingTimeInterval(600)
        XCTAssertEqual(engine.snapshot(at: tenMinutesLater).remainingSeconds, 900)
        XCTAssertEqual(
            engine.endDate,
            springForwardStart.addingTimeInterval(1_500)
        )
    }

    func testEveryFourthCompletionGetsLongBreak() throws {
        var engine = PomodoroEngine(completedFocusCount: 3)
        try engine.startFocus(
            duration: .twentyFiveMinutes,
            isPro: false,
            now: referenceDate
        )
        _ = engine.advance(at: referenceDate.addingTimeInterval(1_500))
        try engine.startBreak(now: referenceDate.addingTimeInterval(1_501))

        XCTAssertEqual(engine.phase, .longBreak)
        XCTAssertEqual(
            engine.snapshot(at: referenceDate.addingTimeInterval(1_501)).remainingSeconds,
            Constants.Timer.longBreakMinutes * Constants.Timer.secondsPerMinute
        )
    }

    func testDemotedFocusStillCompletesButIsSelfReported() throws {
        var engine = PomodoroEngine()
        try engine.startFocus(
            isPro: false,
            now: referenceDate
        )
        try engine.demoteCurrentFocus()

        guard case let .focusCompleted(completion) = engine.advance(
            at: referenceDate.addingTimeInterval(1_500)
        ) else {
            return XCTFail("Demoted effort must still complete")
        }
        XCTAssertEqual(completion.source, .timerDemoted)
        XCTAssertEqual(completion.grams, 250)
    }

    func testRelaunchDiscardsRunningFocusWithoutCompletion() throws {
        let sessionID = UUID()
        var engine = PomodoroEngine()
        try engine.startFocus(
            isPro: false,
            now: referenceDate,
            sessionID: sessionID
        )

        XCTAssertEqual(
            engine.recoverAfterProcessRelaunch(),
            .interruptedFocus(sessionID: sessionID)
        )
        XCTAssertEqual(engine.phase, .idle)
        XCTAssertNil(engine.advance(at: referenceDate.addingTimeInterval(10_000)))
    }

    func testCodableRoundTripPreservesEndDateAndCompletionIdempotence() throws {
        let sessionID = UUID()
        var engine = PomodoroEngine()
        try engine.startFocus(
            isPro: false,
            now: referenceDate,
            sessionID: sessionID
        )
        let encodedRunning = try JSONEncoder().encode(engine)
        var restoredRunning = try JSONDecoder().decode(
            PomodoroEngine.self,
            from: encodedRunning
        )
        let end = try XCTUnwrap(restoredRunning.endDate)
        XCTAssertNotNil(restoredRunning.advance(at: end))

        let encodedCompleted = try JSONEncoder().encode(restoredRunning)
        var restoredCompleted = try JSONDecoder().decode(
            PomodoroEngine.self,
            from: encodedCompleted
        )
        XCTAssertNil(restoredCompleted.advance(at: end.addingTimeInterval(1)))
        XCTAssertEqual(restoredCompleted.phase, .focusCompleted)
    }

    func testSnapshotClampsDecodedUnboundedRemainingWithoutTrapping() throws {
        var engine = PomodoroEngine()
        try engine.startFocus(
            isPro: false,
            now: referenceDate,
            sessionID: UUID()
        )
        var encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(engine))
                as? [String: Any]
        )
        encoded["endDate"] = Double.greatestFiniteMagnitude / 4
        let hostile = try JSONDecoder().decode(
            PomodoroEngine.self,
            from: JSONSerialization.data(withJSONObject: encoded)
        )

        let snapshot = hostile.snapshot(at: referenceDate)
        XCTAssertEqual(
            snapshot.remainingSeconds,
            PomodoroEngine.maximumSupportedRemainingSeconds
        )
        XCTAssertTrue(snapshot.progress.isFinite)
        XCTAssertTrue((0 ... 1).contains(snapshot.progress))
    }

    func testCompletionCountSaturatesAtProductCeilingWithoutOverflow() throws {
        let sessionID = UUID()
        var engine = PomodoroEngine(
            completedFocusCount: PomodoroEngine.maximumSupportedCompletedFocusCount
        )
        try engine.startFocus(
            isPro: false,
            now: referenceDate,
            sessionID: sessionID
        )

        guard case .focusCompleted = engine.advance(
            at: referenceDate.addingTimeInterval(1_500)
        ) else {
            return XCTFail("Expected bounded completion")
        }
        XCTAssertEqual(
            engine.completedFocusCount,
            PomodoroEngine.maximumSupportedCompletedFocusCount
        )
        XCTAssertEqual(
            PomodoroEngine(completedFocusCount: Int.max).completedFocusCount,
            PomodoroEngine.maximumSupportedCompletedFocusCount
        )
    }

#if DEBUG
    func testDebugDemoAwardsOneMeasuredPebbleWorthOfMass() throws {
        var engine = PomodoroEngine()
        try engine.startFocus(duration: .demo, isPro: false, now: referenceDate)

        guard case let .focusCompleted(completion) = engine.advance(
            at: referenceDate.addingTimeInterval(TimeInterval(Constants.Timer.demoSeconds))
        ) else {
            return XCTFail("Expected demo completion")
        }
        XCTAssertEqual(completion.seconds, Constants.Timer.demoSeconds)
        XCTAssertEqual(completion.grams, Constants.Mass.measuredPebbleGrams)
    }
#endif

    func testCompletionNotificationIsOfferedOnceAtTheFirstExplicitStart() throws {
        let suiteName = "PomoGemTests.completion-offer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        typealias Policy = FocusCompletionNotificationOfferPolicy

        XCTAssertTrue(Policy.shouldOffer(
            authorizationStatus: .notDetermined, isExplicitStart: true, defaults: defaults
        ))
        // Recovered, relaunched or adopted timers never trigger the dialog.
        XCTAssertFalse(Policy.shouldOffer(
            authorizationStatus: .notDetermined, isExplicitStart: false, defaults: defaults
        ))
        // A decided permission is respected either way.
        for status in [UNAuthorizationStatus.authorized, .denied, .provisional, .ephemeral] {
            XCTAssertFalse(Policy.shouldOffer(
                authorizationStatus: status, isExplicitStart: true, defaults: defaults
            ), "status \(status.rawValue)")
        }

        Policy.markOffered(defaults: defaults)
        XCTAssertFalse(
            Policy.shouldOffer(
                authorizationStatus: .notDetermined, isExplicitStart: true, defaults: defaults
            ),
            "A later start never asks again, whatever the first answer was"
        )
    }
}

@MainActor
private final class FocusReturnReminderFixture {
    let suite = "FocusReturnReminderScheduling.\(UUID().uuidString)"
    let defaults: UserDefaults
    let recorder = FocusReturnReminderRecorder()
    let manager: NotificationManager

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: FocusReturnReminderPolicy.enabledDefaultsKey)
        manager = NotificationManager(
            focusReturnReminderClient: recorder.client,
            focusReturnReminderDefaults: defaults
        )
    }

    func cleanUp() {
        recorder.finishHeldAdd()
        manager.suspendTimerSchedulingForAccountBoundary()
        defaults.removePersistentDomain(forName: suite)
    }

    func waitForAddCount(_ count: Int) async throws {
        let deadline = Date.now.addingTimeInterval(3)
        while recorder.additions.count < count, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard recorder.additions.count == count else {
            XCTFail("Expected \(count) reminder add calls, observed \(recorder.additions.count)")
            throw AddWaitError.didNotReachExpectedCount
        }
    }

    private enum AddWaitError: Error { case didNotReachExpectedCount }
}

@MainActor
private final class FocusReturnReminderRecorder {
    var status: UNAuthorizationStatus = .authorized
    var additions: [UNNotificationRequest] = []
    var pending: [String: UNNotificationRequest] = [:]
    var delivered: Set<String> = []
    var holdNextAdd = false
    var deliverOnAdd = false
    private var activeAddCount = 0
    private(set) var maximumConcurrentAdds = 0
    private var heldAdd: CheckedContinuation<Void, Never>?

    var client: FocusReturnReminderNotificationClient {
        FocusReturnReminderNotificationClient(
            authorizationStatus: { self.status },
            add: { request in
                self.activeAddCount += 1
                self.maximumConcurrentAdds = max(self.maximumConcurrentAdds, self.activeAddCount)
                defer { self.activeAddCount -= 1 }
                self.additions.append(request)
                if self.holdNextAdd {
                    self.holdNextAdd = false
                    await withCheckedContinuation { self.heldAdd = $0 }
                }
                if self.deliverOnAdd {
                    self.delivered.insert(request.identifier)
                } else {
                    self.pending[request.identifier] = request
                }
            },
            removePending: { identifiers in
                for identifier in identifiers { self.pending.removeValue(forKey: identifier) }
            },
            removeDelivered: { identifiers in
                for identifier in identifiers { self.delivered.remove(identifier) }
            }
        )
    }

    func finishHeldAdd() {
        let continuation = heldAdd
        heldAdd = nil
        continuation?.resume()
    }
}

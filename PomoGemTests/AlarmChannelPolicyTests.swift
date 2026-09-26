import XCTest
@testable import PomoGem

/// Which channel announces the end of a focus or break, as pure decisions.
final class AlarmChannelPolicyTests: XCTestCase {
    private let authorizations: [AlarmKitAuthorization] = [.unsupported, .notDetermined, .denied, .authorized]

    // MARK: Booking

    func testOnlyMaximumWithPermissionAndSoundBooksTheSystemAlarm() {
        for strength in AlarmStrength.allCases {
            for systemAlarm in authorizations {
                for soundEnabled in [true, false] {
                    for notificationsAuthorized in [true, false] {
                        let channel = AlarmChannelPolicy.backgroundChannel(
                            strength: strength,
                            soundEnabled: soundEnabled,
                            systemAlarm: systemAlarm,
                            notificationsAuthorized: notificationsAuthorized
                        )
                        let expectsSystemAlarm = strength == .maximum
                            && systemAlarm == .authorized
                            && soundEnabled
                        XCTAssertEqual(
                            channel == .systemAlarm,
                            expectsSystemAlarm,
                            "\(strength) \(systemAlarm) sound:\(soundEnabled) notifications:\(notificationsAuthorized)"
                        )
                    }
                }
            }
        }
    }

    func testNotificationSoundFollowsStrengthAndTheSoundSwitch() {
        XCTAssertEqual(
            AlarmChannelPolicy.backgroundChannel(strength: .gentle, soundEnabled: true, systemAlarm: .authorized, notificationsAuthorized: true),
            .timeSensitiveNotification(.shortChime),
            "gentle keeps today's short chime"
        )
        XCTAssertEqual(
            AlarmChannelPolicy.backgroundChannel(strength: .standard, soundEnabled: true, systemAlarm: .authorized, notificationsAuthorized: true),
            .timeSensitiveNotification(.ringtone)
        )
        XCTAssertEqual(
            AlarmChannelPolicy.backgroundChannel(strength: .maximum, soundEnabled: true, systemAlarm: .denied, notificationsAuthorized: true),
            .timeSensitiveNotification(.ringtone),
            "a denied alarm permission falls back to the notification"
        )
        XCTAssertEqual(
            AlarmChannelPolicy.backgroundChannel(strength: .maximum, soundEnabled: false, systemAlarm: .authorized, notificationsAuthorized: true),
            .timeSensitiveNotification(.silent),
            "an alarm always sounds, so it is never used with the app's sound off"
        )
        XCTAssertEqual(
            AlarmChannelPolicy.backgroundChannel(strength: .standard, soundEnabled: true, systemAlarm: .unsupported, notificationsAuthorized: false),
            .none
        )
        XCTAssertEqual(
            AlarmChannelPolicy.backgroundChannel(strength: .maximum, soundEnabled: true, systemAlarm: .authorized, notificationsAuthorized: false),
            .systemAlarm,
            "AlarmKit does not need notification permission"
        )
    }

    func testAFailedSystemAlarmFallsBackToTheNotificationChannel() {
        XCTAssertEqual(
            AlarmChannelPolicy.notificationChannel(strength: .maximum, soundEnabled: true, notificationsAuthorized: true),
            .timeSensitiveNotification(.ringtone)
        )
    }

    func testSystemAlarmNeedsAFewSecondsOfLead() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertFalse(AlarmChannelPolicy.systemAlarmLeadIsSufficient(endDate: now.addingTimeInterval(4.9), now: now))
        XCTAssertTrue(AlarmChannelPolicy.systemAlarmLeadIsSufficient(endDate: now.addingTimeInterval(5), now: now))
        XCTAssertFalse(AlarmChannelPolicy.systemAlarmLeadIsSufficient(endDate: now.addingTimeInterval(-1), now: now))
    }

    // MARK: The end

    func testTheInAppAlarmTakesOverOnlyWhenActiveAtTheEnd() {
        let end = Date(timeIntervalSinceReferenceDate: 2_000)
        XCTAssertTrue(AlarmChannelPolicy.shouldHandOffToForeground(applicationIsActive: true, endDate: end, now: end.addingTimeInterval(-1.5)))
        XCTAssertTrue(AlarmChannelPolicy.shouldHandOffToForeground(applicationIsActive: true, endDate: end, now: end.addingTimeInterval(0.5)))
        XCTAssertFalse(AlarmChannelPolicy.shouldHandOffToForeground(applicationIsActive: true, endDate: end, now: end.addingTimeInterval(-2)))
        XCTAssertFalse(AlarmChannelPolicy.shouldHandOffToForeground(applicationIsActive: false, endDate: end, now: end))
    }

    func testABookedSystemAlarmIsADeliveryWitness() {
        let now = Date(timeIntervalSinceReferenceDate: 3_000)
        XCTAssertTrue(AlarmChannelPolicy.externalAlertMayHaveFired(
            notificationAuthorized: false,
            notificationDeliveryDate: nil,
            systemAlarmFireDate: now.addingTimeInterval(-1),
            now: now
        ))
        XCTAssertFalse(AlarmChannelPolicy.externalAlertMayHaveFired(
            notificationAuthorized: false,
            notificationDeliveryDate: nil,
            systemAlarmFireDate: now.addingTimeInterval(1),
            now: now
        ))
        XCTAssertTrue(AlarmChannelPolicy.externalAlertMayHaveFired(
            notificationAuthorized: true,
            notificationDeliveryDate: now.addingTimeInterval(-1),
            systemAlarmFireDate: nil,
            now: now
        ), "the notification witness is unchanged")
        XCTAssertFalse(AlarmChannelPolicy.externalAlertMayHaveFired(
            notificationAuthorized: false,
            notificationDeliveryDate: now.addingTimeInterval(-1),
            systemAlarmFireDate: nil,
            now: now
        ))
    }

    func testGentleForegroundAlarmIsTodaysRepeatingCue() {
        let plan = AlarmChannelPolicy.foregroundPlan(cue: .repeating, strength: .gentle, soundEnabled: true, hapticsEnabled: true, hapticStyle: .strong)
        XCTAssertEqual(plan.playback, .repeating(interval: 1.3))
        XCTAssertEqual(plan.audioSession, .ambient)
        XCTAssertFalse(plan.keepsScreenAwake)
        XCTAssertNil(plan.automaticStopInterval)
        XCTAssertEqual(plan.haptic, AlarmHapticPattern.completion(strength: .gentle, style: .strong))
    }

    func testStandardLoopsKeepsTheScreenOnAndStopsAfterThreeMinutes() {
        let plan = AlarmChannelPolicy.foregroundPlan(cue: .repeating, strength: .standard, soundEnabled: true, hapticsEnabled: true, hapticStyle: .standard)
        XCTAssertEqual(plan.playback, .loop)
        XCTAssertEqual(plan.audioSession, .ambient, "standard follows the silent switch")
        XCTAssertTrue(plan.keepsScreenAwake)
        XCTAssertEqual(plan.automaticStopInterval, 180)
        XCTAssertNotNil(plan.haptic?.loopDuration)
    }

    func testMaximumPlaysThroughTheSilentSwitchAndDucksMusic() {
        let plan = AlarmChannelPolicy.foregroundPlan(cue: .repeating, strength: .maximum, soundEnabled: true, hapticsEnabled: true, hapticStyle: .standard)
        XCTAssertEqual(plan.playback, .loop)
        XCTAssertEqual(plan.audioSession, .playbackDuckingOthers)
        let muted = AlarmChannelPolicy.foregroundPlan(cue: .repeating, strength: .maximum, soundEnabled: false, hapticsEnabled: true, hapticStyle: .standard)
        XCTAssertEqual(muted.audioSession, .ambient, "no audio session is taken over without sound")
        XCTAssertFalse(muted.playsSound)
        XCTAssertTrue(muted.playsHaptics)
    }

    func testAReturnNeverLoopsAndAnAnnouncedEndStaysSilent() {
        for strength in AlarmStrength.allCases {
            let single = AlarmChannelPolicy.foregroundPlan(cue: .single, strength: strength, soundEnabled: true, hapticsEnabled: true, hapticStyle: .standard)
            XCTAssertEqual(single.playback, .once, "\(strength)")
            XCTAssertFalse(single.keepsScreenAwake)
            XCTAssertNil(single.automaticStopInterval)
            XCTAssertNil(single.haptic?.loopDuration)

            let none = AlarmChannelPolicy.foregroundPlan(cue: .none, strength: strength, soundEnabled: true, hapticsEnabled: true, hapticStyle: .standard)
            XCTAssertEqual(none, .silent)

            let off = AlarmChannelPolicy.foregroundPlan(cue: .repeating, strength: strength, soundEnabled: false, hapticsEnabled: false, hapticStyle: .standard)
            XCTAssertEqual(off, .silent, "both channels off stays silent, as today")
        }
    }

    func testHapticsOffKeepsTheSoundButDropsTheVibration() {
        let plan = AlarmChannelPolicy.foregroundPlan(cue: .repeating, strength: .standard, soundEnabled: true, hapticsEnabled: false, hapticStyle: .standard)
        XCTAssertTrue(plan.playsSound)
        XCTAssertFalse(plan.playsHaptics)
        XCTAssertNil(plan.haptic)
    }
}

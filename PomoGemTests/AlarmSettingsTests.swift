import CoreHaptics
import XCTest
@testable import PomoGem

/// F5 part 1 Settings: the copy must stay true per strength (the silent
/// switch, the screen, the automatic stop, what rings away from the app),
/// and the choices persist on this iPhone only.
@MainActor
final class AlarmSettingsTests: XCTestCase {
    func testOnlyTheMaximumPresetSaysItPlaysThroughTheSilentSwitch() {
        for strength in AlarmStrength.allCases {
            let subtitle = AlarmSettingsCopy.soundSubtitle(strength: strength)
            let footer = AlarmSettingsCopy.sectionFooter(strength: strength)
            if strength == .maximum {
                XCTAssertTrue(subtitle.contains("オンでも鳴ります"), subtitle)
                // The switch covers every sound; only the end alarm is the
                // exception, so the row must not say the app ignores it.
                XCTAssertTrue(subtitle.hasPrefix("サイレントスイッチに従います"), subtitle)
                XCTAssertTrue(subtitle.contains("終了アラームだけ"), subtitle)
                XCTAssertTrue(footer.contains("サイレントスイッチがオンでも鳴らします"), footer)
                XCTAssertTrue(footer.contains("iOS 26"), footer)
                XCTAssertTrue(footer.contains("小さく"), "Music is lowered, not stopped: \(footer)")
            } else {
                XCTAssertEqual(subtitle, "サイレントスイッチに従います")
                XCTAssertTrue(footer.contains("音はサイレントスイッチに従います"), footer)
                XCTAssertFalse(footer.contains("オンでも"), footer)
            }
            XCTAssertTrue(footer.contains("休憩"), "The break end is included: \(footer)")
            XCTAssertFalse(footer.contains("サイレントモード"), "One name for the switch")
        }
        let standard = AlarmSettingsCopy.sectionFooter(strength: .standard)
        XCTAssertTrue(standard.contains("画面をつけたまま"))
        XCTAssertTrue(standard.contains("3分たつと自動的に止まります"))
        let gentle = AlarmSettingsCopy.sectionFooter(strength: .gentle)
        XCTAssertFalse(gentle.contains("画面をつけたまま"), "控えめ keeps today's behaviour")
        XCTAssertFalse(gentle.contains("自動的に止まります"))
    }

    /// VoiceOver speaks what each option does as part of its label, as the
    /// other option rows in Settings do: hints may be turned off.
    func testEveryOptionSpeaksWhatItDoesInItsLabel() {
        for strength in AlarmStrength.allCases {
            let label = AlarmSettingsCopy.optionLabel(title: strength.title, detail: strength.detail)
            XCTAssertEqual(label, "\(strength.title)。\(strength.detail)")
        }
        XCTAssertTrue(
            AlarmSettingsCopy.optionLabel(title: AlarmStrength.maximum.title, detail: AlarmStrength.maximum.detail)
                .contains("サイレントスイッチ")
        )
        for choice in AlarmSoundChoice.allCases {
            let label = AlarmSettingsCopy.optionLabel(title: choice.title, detail: choice.detail)
            XCTAssertTrue(label.hasPrefix(choice.title), label)
            XCTAssertTrue(label.contains(choice.detail), label)
        }
        XCTAssertEqual(AlarmSettingsCopy.optionLabel(title: "ベル", detail: ""), "ベル")
    }

    /// The Settings row shows one line; the list and the footer keep the
    /// full description. Each line stays true to its strength.
    func testEachStrengthRowSummaryIsOneShortLine() {
        for strength in AlarmStrength.allCases {
            XCTAssertLessThan(strength.summary.count, strength.detail.count, "\(strength)")
            XCTAssertFalse(strength.summary.contains("。"), "One sentence: \(strength.summary)")
        }
        XCTAssertTrue(AlarmStrength.maximum.summary.contains("サイレントスイッチがオンでも"))
        XCTAssertFalse(AlarmStrength.standard.summary.contains("サイレントスイッチ"))
    }

    func testTheMaximumStatusExplainsEachPermissionState() {
        XCTAssertNil(AlarmSettingsCopy.maximumStatus(strength: .standard, authorization: .denied, soundOn: true))
        XCTAssertNil(AlarmSettingsCopy.maximumStatus(strength: .gentle, authorization: .authorized, soundOn: true))

        let old = AlarmSettingsCopy.maximumStatus(strength: .maximum, authorization: .unsupported, soundOn: true)
        XCTAssertEqual(old?.action, MaximumAction.none)
        XCTAssertTrue(old?.message.contains("iOS 26以降が必要") == true)

        let unasked = AlarmSettingsCopy.maximumStatus(strength: .maximum, authorization: .notDetermined, soundOn: true)
        XCTAssertEqual(unasked?.action, .requestPermission)

        let denied = AlarmSettingsCopy.maximumStatus(strength: .maximum, authorization: .denied, soundOn: true)
        XCTAssertEqual(denied?.action, .openSettings, "A denial is undone in the Settings app")
        XCTAssertTrue(denied?.message.contains("通知で知らせます") == true)

        let allowed = AlarmSettingsCopy.maximumStatus(strength: .maximum, authorization: .authorized, soundOn: true)
        XCTAssertEqual(allowed?.action, MaximumAction.none)
        XCTAssertTrue(allowed?.message.contains("アラームで知らせます") == true)

        let muted = AlarmSettingsCopy.maximumStatus(strength: .maximum, authorization: .authorized, soundOn: false)
        XCTAssertTrue(muted?.message.contains("アラームは使わず") == true, "最大 never books an alarm with sound off")
    }

    private typealias MaximumAction = AlarmSettingsCopy.MaximumStatusAction

    func testChoicesPersistOnThisIPhoneOnly() throws {
        let suite = "alarm-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AlarmPreferences(defaults: defaults)

        preferences.setStrength(.maximum)
        XCTAssertEqual(defaults.string(forKey: "alarm.strength"), "maximum")
        XCTAssertEqual(AlarmPreferences(defaults: defaults).strength, .maximum, "Survives a relaunch")

        XCTAssertNil(preferences.select(.schoolChime), "A new sound never touches the synced chime")
        XCTAssertEqual(defaults.string(forKey: "alarm.sound"), "schoolChime")
        XCTAssertEqual(preferences.select(.soft), .soft, "An original chime is written to the synced Prefs")
        XCTAssertNil(defaults.string(forKey: "alarm.sound"))
        XCTAssertEqual(
            Set(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("alarm.") }),
            ["alarm.strength"]
        )
    }

    func testTheLoopingVibrationConvertsEveryEventForTheDeferredPlayer() throws {
        for strength in AlarmStrength.allCases {
            let pattern = AlarmHapticPattern.completion(strength: strength, style: .strong)
            let events = pattern.makeHapticEvents()
            XCTAssertEqual(events.count, pattern.events.count)
            XCTAssertEqual(
                events.filter { $0.type == .hapticContinuous }.count,
                strength == .gentle ? 0 : 1
            )
            _ = try pattern.makeHapticPattern()
        }
    }
}

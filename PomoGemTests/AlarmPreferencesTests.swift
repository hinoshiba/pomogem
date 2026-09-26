import UIKit
import XCTest
@testable import PomoGem

/// Device-local alarm choices and their fallback to the synced chime.
final class AlarmPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var preferences: AlarmPreferences!

    override func setUp() {
        super.setUp()
        suiteName = "alarm-preferences-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        preferences = AlarmPreferences(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        preferences = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: Choices

    func testTheCatalogKeepsTheThreeChimesAndAddsFiveAlarmSounds() {
        XCTAssertEqual(
            AlarmSoundChoice.allCases.map(\.rawValue),
            ["standard", "soft", "bright", "bell", "digital", "marimba", "schoolChime", "alarmClock"],
            "raw values are stored device-locally: keep them stable"
        )
        XCTAssertEqual(AlarmSoundChoice.allCases.compactMap(\.legacySound), TimerCompletionSound.allCases)
        XCTAssertEqual(AlarmSoundChoice.allCases.compactMap(\.synthesizedSound), AlarmSynthesizedSound.allCases)
        for choice in AlarmSoundChoice.allCases {
            XCTAssertTrue((choice.legacySound == nil) != (choice.synthesizedSound == nil), choice.rawValue)
        }
        for sound in AlarmSynthesizedSound.allCases {
            XCTAssertEqual(AlarmSoundChoice(rawValue: sound.rawValue)?.synthesizedSound, sound)
        }
    }

    func testTheOriginalChimesKeepTheirRawValuesAndCopy() {
        for legacy in TimerCompletionSound.allCases {
            let choice = AlarmSoundChoice(legacy: legacy)
            XCTAssertEqual(choice.rawValue, legacy.rawValue)
            XCTAssertEqual(choice.legacySound, legacy)
            XCTAssertEqual(choice.title, legacy.title)
            XCTAssertEqual(choice.detail, legacy.detail)
            XCTAssertEqual(choice.systemImage, legacy.systemImage)
        }
    }

    func testTheNewSoundsHaveJapaneseNamesAndSymbolsThatExist() {
        let expected: [AlarmSoundChoice: String] = [
            .bell: "ベル", .digital: "デジタル", .marimba: "マリンバ",
            .schoolChime: "学校のチャイム", .alarmClock: "目覚まし時計"
        ]
        for (choice, title) in expected {
            XCTAssertEqual(choice.title, title)
            XCTAssertFalse(choice.detail.isEmpty, choice.rawValue)
        }
        XCTAssertEqual(Set(AlarmSoundChoice.allCases.map(\.title)).count, AlarmSoundChoice.allCases.count)
        for choice in AlarmSoundChoice.allCases {
            XCTAssertNotNil(UIImage(systemName: choice.systemImage), "\(choice.rawValue): \(choice.systemImage)")
        }
    }

    // MARK: Sound preference

    func testWithoutADeviceChoiceTheSyncedChimeIsFollowed() {
        for legacy in TimerCompletionSound.allCases {
            XCTAssertEqual(preferences.sound(legacy: legacy), AlarmSoundChoice(legacy: legacy))
        }
        XCTAssertNil(preferences.storedSound)
    }

    func testANewSoundIsStoredOnThisDeviceOnlyAndWins() {
        XCTAssertNil(preferences.select(.schoolChime), "a new sound never reaches the synced enum")
        XCTAssertEqual(defaults.string(forKey: AlarmPreferences.soundDefaultsKey), "schoolChime")
        for legacy in TimerCompletionSound.allCases {
            XCTAssertEqual(preferences.sound(legacy: legacy), .schoolChime)
        }
    }

    func testChoosingAnOriginalChimeReturnsToTheSyncedValue() {
        preferences.select(.bell)
        XCTAssertEqual(preferences.select(.soft), .soft, "the caller writes it through the Prefs sync path")
        XCTAssertNil(defaults.object(forKey: AlarmPreferences.soundDefaultsKey))
        XCTAssertEqual(preferences.sound(legacy: .bright), .bright, "follows the synced chime again")
        XCTAssertEqual(
            AlarmPreferences.selection(for: .standard),
            AlarmPreferences.SoundSelection(deviceLocalRawValue: nil, syncedLegacySound: .standard)
        )
        XCTAssertEqual(
            AlarmPreferences.selection(for: .alarmClock),
            AlarmPreferences.SoundSelection(deviceLocalRawValue: "alarmClock", syncedLegacySound: nil)
        )
    }

    func testAnUnknownStoredSoundFallsBackToTheSyncedChime() {
        defaults.set("recordedFromTheFuture", forKey: AlarmPreferences.soundDefaultsKey)
        XCTAssertEqual(preferences.sound(legacy: .soft), .soft)
    }

    // MARK: Strength

    func testStrengthDefaultsToStandardAndPersists() {
        XCTAssertEqual(AlarmStrength.defaultValue, .standard)
        XCTAssertEqual(preferences.strength, .standard)
        preferences.setStrength(.maximum)
        XCTAssertEqual(AlarmPreferences(defaults: defaults).strength, .maximum)
        defaults.set("louder", forKey: AlarmPreferences.strengthDefaultsKey)
        XCTAssertEqual(preferences.strength, .standard)
        XCTAssertEqual(AlarmStrength.allCases.map(\.rawValue), ["gentle", "standard", "maximum"])
    }

    func testGentleIsExactlyTodaysAlarm() {
        let gentle = AlarmStrength.gentle
        XCTAssertFalse(gentle.loopsPattern)
        XCTAssertFalse(gentle.usesContinuousHaptics)
        XCTAssertFalse(gentle.keepsScreenAwakeWhileRinging)
        XCTAssertNil(gentle.automaticStopInterval, "today's alarm has no limit")
        XCTAssertFalse(gentle.overridesSilentSwitch)
        XCTAssertFalse(gentle.usesSystemAlarmWhenAway)
        XCTAssertFalse(gentle.usesLongNotificationSound)
    }

    func testStandardRingsUntilStoppedButFollowsTheSilentSwitch() {
        let standard = AlarmStrength.standard
        XCTAssertTrue(standard.loopsPattern)
        XCTAssertTrue(standard.usesContinuousHaptics)
        XCTAssertTrue(standard.keepsScreenAwakeWhileRinging)
        XCTAssertEqual(standard.automaticStopInterval, 180)
        XCTAssertFalse(standard.overridesSilentSwitch)
        XCTAssertFalse(standard.usesSystemAlarmWhenAway)
        XCTAssertTrue(standard.usesLongNotificationSound)
    }

    func testMaximumAddsTheSilentSwitchOverrideAndTheSystemAlarm() {
        let maximum = AlarmStrength.maximum
        XCTAssertTrue(maximum.loopsPattern)
        XCTAssertTrue(maximum.keepsScreenAwakeWhileRinging)
        XCTAssertEqual(maximum.automaticStopInterval, 180)
        XCTAssertTrue(maximum.overridesSilentSwitch)
        XCTAssertTrue(maximum.usesSystemAlarmWhenAway)
        for strength in AlarmStrength.allCases {
            XCTAssertFalse(strength.title.isEmpty)
            XCTAssertFalse(strength.detail.isEmpty)
        }
        XCTAssertTrue(AlarmStrength.standard.detail.contains("3分で自動的に止まります"), AlarmStrength.standard.detail)
    }

    // MARK: Storage hygiene

    func testEveryKeyIsDeviceLocalUnderTheAlarmPrefixAndRemovable() {
        preferences.select(.digital)
        preferences.setStrength(.gentle)
        for key in AlarmPreferences.allDefaultsKeys {
            XCTAssertTrue(key.hasPrefix("alarm."), key)
            XCTAssertNotNil(defaults.object(forKey: key), key)
        }
        preferences.removeAll()
        for key in AlarmPreferences.allDefaultsKeys {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
    }

    @MainActor
    func testCompleteDataDeletionClearsTheAlarmKeys() throws {
        preferences.select(.marimba)
        preferences.setStrength(.maximum)
        try CompleteDataDeletionDefaultsCleaner.clear(defaults: defaults, persistentDomainName: suiteName)
        XCTAssertNil(preferences.storedSound)
        XCTAssertEqual(preferences.strength, .standard)
    }
}

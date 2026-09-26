import Foundation

/// The sound that ends a focus or a break. The first three are the original
/// synced completion chimes (same raw values as `TimerCompletionSound`); the
/// other five are alarm-grade sounds synthesized by `AlarmSoundSynthesis`.
///
/// The choice is stored on this iPhone only (`AlarmPreferences`). New raw
/// values are never written to the synced `TimerCompletionSound`, so older app
/// versions and other devices keep reading a value they understand.
enum AlarmSoundChoice: String, CaseIterable, Identifiable, Sendable {
    case standard
    case soft
    case bright
    case bell
    case digital
    case marimba
    case schoolChime
    case alarmClock

    var id: String { rawValue }

    init(legacy sound: TimerCompletionSound) {
        switch sound {
        case .standard: self = .standard
        case .soft: self = .soft
        case .bright: self = .bright
        }
    }

    /// The synced completion chime this choice is, if it is one of the three
    /// original sounds.
    var legacySound: TimerCompletionSound? {
        switch self {
        case .standard: .standard
        case .soft: .soft
        case .bright: .bright
        case .bell, .digital, .marimba, .schoolChime, .alarmClock: nil
        }
    }

    /// The alarm-grade synthesized sound, for the five new choices.
    var synthesizedSound: AlarmSynthesizedSound? {
        switch self {
        case .standard, .soft, .bright: nil
        case .bell: .bell
        case .digital: .digital
        case .marimba: .marimba
        case .schoolChime: .schoolChime
        case .alarmClock: .alarmClock
        }
    }

    var title: String {
        if let legacySound { return legacySound.title }
        switch self {
        case .bell:
            return String(localized: "ベル", table: "Focus", comment: "Alarm sound name: a small struck bell rung three times. Suggested English: Bell")
        case .digital:
            return String(localized: "デジタル", table: "Focus", comment: "Alarm sound name: the four-beep electronic alarm clock. Suggested English: Digital")
        case .marimba:
            return String(localized: "マリンバ", table: "Focus", comment: "Alarm sound name: a rising marimba arpeggio. Suggested English: Marimba")
        case .schoolChime:
            return String(localized: "学校のチャイム", table: "Focus", comment: "Alarm sound name: the Westminster chime Japanese schools play between classes. Suggested English: School chime")
        case .alarmClock:
            return String(localized: "目覚まし時計", table: "Focus", comment: "Alarm sound name: a mechanical twin-bell alarm clock. Suggested English: Alarm clock")
        case .standard, .soft, .bright:
            return ""
        }
    }

    var detail: String {
        if let legacySound { return legacySound.detail }
        switch self {
        case .bell:
            return String(localized: "澄んだ鐘を3回ずつ打ち鳴らします", table: "Focus", comment: "Alarm sound description. Suggested English: A clear bell struck three times, over and over")
        case .digital:
            return String(localized: "ピピピピッと鳴る、電子音の目覚まし", table: "Focus", comment: "Alarm sound description. Suggested English: The beep-beep-beep-beep of a digital alarm clock")
        case .marimba:
            return String(localized: "マリンバの音が軽やかに駆け上がります", table: "Focus", comment: "Alarm sound description. Suggested English: Marimba notes skipping upward")
        case .schoolChime:
            return String(localized: "キーンコーンカーンコーンの鐘の旋律", table: "Focus", comment: "Alarm sound description; the onomatopoeia is how Japanese hear the Westminster chime. Suggested English: The Westminster chime heard at school")
        case .alarmClock:
            return String(localized: "ジリリリと鳴る、ベル式の目覚まし時計", table: "Focus", comment: "Alarm sound description. Suggested English: The ring of a mechanical bell alarm clock")
        case .standard, .soft, .bright:
            return ""
        }
    }

    var systemImage: String {
        if let legacySound { return legacySound.systemImage }
        switch self {
        case .bell: return "bell.fill"
        case .digital: return "dot.radiowaves.left.and.right"
        case .marimba: return "pianokeys"
        case .schoolChime: return "building.columns"
        case .alarmClock: return "alarm.fill"
        case .standard, .soft, .bright: return ""
        }
    }
}

/// How insistently the end of a focus or break is announced. Device-local:
/// the strength that suits a quiet library differs from home.
enum AlarmStrength: String, CaseIterable, Identifiable, Sendable {
    /// Exactly the behaviour before alarm strength existed: a short cue
    /// every 1.3 s while the app is open, the idle timer re-enabled, one
    /// short notification chime when away, sound follows the silent switch.
    case gentle
    /// The default. Loops the chosen sound until Stop with a strong
    /// vibration, keeps the screen awake while ringing, stops by itself
    /// after three minutes, and follows the silent switch.
    case standard
    /// Standard, plus the in-app alarm plays with the silent switch on, and
    /// on iOS 26 or later a system alarm (AlarmKit) rings when the app is not
    /// open at the end, once the person has allowed alarms and while the
    /// app's sound is on (`AlarmChannelPolicy.backgroundChannel`). Otherwise
    /// the end away from the app is the Time Sensitive notification, which
    /// follows the silent switch.
    case maximum

    static let defaultValue: AlarmStrength = .standard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gentle:
            String(localized: "控えめ", table: "Focus", comment: "Alarm strength option: today's short cue. Suggested English: Gentle")
        case .standard:
            String(localized: "標準", table: "Focus", comment: "Alarm strength option (default): rings until stopped. Suggested English: Standard")
        case .maximum:
            String(localized: "最大", table: "Focus", comment: "Alarm strength option: also rings through the silent switch and as a system alarm. Suggested English: Maximum")
        }
    }

    var detail: String {
        switch self {
        case .gentle:
            String(localized: "短い音と振動で知らせます。サイレントスイッチに従います。", table: "Focus", comment: "Alarm strength description. Suggested English: A short sound and vibration. Follows the silent switch.")
        case .standard:
            String(localized: "止めるまで音と強い振動をくり返します。鳴っている間は画面をつけたままにし、\(Self.automaticStopText)で自動的に止まります。サイレントスイッチに従います。", table: "Focus", comment: "Alarm strength description; %@ is a duration such as 3分 (3 min). Suggested English: Repeats the sound and a strong vibration until you stop it. The screen stays on while it rings, and it stops by itself after %@. Follows the silent switch.")
        case .maximum:
            String(localized: "標準に加えて、アプリを開いているときはサイレントスイッチがオンでも音を鳴らします。iOS 26以降でアラームを許可すると、アプリを開いていないときもアラームで知らせます。", table: "Focus", comment: "Alarm strength description. Suggested English: Everything in Standard, and while the app is open the sound plays even with the silent switch on. On iOS 26 or later, once you allow alarms, an alarm also rings when the app is not open.")
        }
    }

    /// How long a ringing alarm lasts at the stronger presets.
    static let automaticStopDuration: TimeInterval = 180

    private static var automaticStopText: String {
        DurationText.short(minutes: Int(automaticStopDuration / 60))
    }

    /// Loops the pattern seamlessly instead of repeating a short cue.
    var loopsPattern: Bool { self != .gentle }
    /// A continuous full-intensity vibration with accents instead of taps.
    var usesContinuousHaptics: Bool { self != .gentle }
    /// Auto-lock would end the alarm (leaving counts as Stop), so the
    /// stronger presets keep the screen on while it rings.
    var keepsScreenAwakeWhileRinging: Bool { self != .gentle }
    /// A ringing alarm stops by itself after this long. The gentle preset
    /// keeps today's behaviour, which has no limit.
    var automaticStopInterval: TimeInterval? { self == .gentle ? nil : Self.automaticStopDuration }
    /// Plays the in-app alarm through the silent switch (`.playback`).
    var overridesSilentSwitch: Bool { self == .maximum }
    /// Books an AlarmKit alarm for the end (iOS 26+, alarms allowed).
    var usesSystemAlarmWhenAway: Bool { self == .maximum }
    /// The notification plays the long (≤ 28 s) ringtone instead of the
    /// short chime.
    var usesLongNotificationSound: Bool { self != .gentle }
}

/// Device-local alarm preferences (`UserDefaults.standard`, `alarm.` prefix).
/// Nothing here is synced: the synced `TimerCompletionSound` stays the source
/// of truth for the three original chimes, and complete data deletion clears
/// these keys with the rest of the standard domain.
struct AlarmPreferences {
    static let soundDefaultsKey = "alarm.sound"
    static let strengthDefaultsKey = "alarm.strength"
    static let allDefaultsKeys = [soundDefaultsKey, strengthDefaultsKey]

    /// What choosing a sound in Settings writes.
    struct SoundSelection: Equatable, Sendable {
        /// The device-local raw value, or nil to follow the synced chime.
        let deviceLocalRawValue: String?
        /// The synced completion chime to write, for one of the original three.
        let syncedLegacySound: TimerCompletionSound?
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The sound this iPhone plays. Without a device-local choice (or with a
    /// value this version does not know), it is the synced completion chime,
    /// so existing people keep hearing what they picked before.
    func sound(legacy: TimerCompletionSound) -> AlarmSoundChoice {
        storedSound ?? AlarmSoundChoice(legacy: legacy)
    }

    var storedSound: AlarmSoundChoice? {
        defaults.string(forKey: Self.soundDefaultsKey).flatMap(AlarmSoundChoice.init(rawValue:))
    }

    /// Choosing one of the original three chimes writes it to the synced
    /// preference and clears the device-local choice, so the device follows
    /// the synced value again (and older versions agree). Choosing a new
    /// sound stores it on this iPhone only.
    static func selection(for choice: AlarmSoundChoice) -> SoundSelection {
        if let legacy = choice.legacySound {
            return SoundSelection(deviceLocalRawValue: nil, syncedLegacySound: legacy)
        }
        return SoundSelection(deviceLocalRawValue: choice.rawValue, syncedLegacySound: nil)
    }

    /// Applies the device-local half of `selection(for:)` and returns the
    /// synced chime the caller must write through the Prefs sync path.
    @discardableResult
    func select(_ choice: AlarmSoundChoice) -> TimerCompletionSound? {
        let selection = Self.selection(for: choice)
        if let rawValue = selection.deviceLocalRawValue {
            defaults.set(rawValue, forKey: Self.soundDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.soundDefaultsKey)
        }
        return selection.syncedLegacySound
    }

    /// The chosen strength; `.standard` until the person picks one.
    var strength: AlarmStrength {
        defaults.string(forKey: Self.strengthDefaultsKey)
            .flatMap(AlarmStrength.init(rawValue:)) ?? .defaultValue
    }

    func setStrength(_ strength: AlarmStrength) {
        defaults.set(strength.rawValue, forKey: Self.strengthDefaultsKey)
    }

    func removeAll() {
        for key in Self.allDefaultsKeys {
            defaults.removeObject(forKey: key)
        }
    }
}

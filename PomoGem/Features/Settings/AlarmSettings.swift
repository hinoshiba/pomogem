import SwiftUI
import UIKit

/// F5 copy for the 音と触覚 section. Pure, so each strength's promise is
/// pinned by tests: the silent switch, the screen, the automatic stop and
/// what rings when the app is not open must stay true per strength.
enum AlarmSettingsCopy {
    /// The subtitle of the 「音」 switch.
    static func soundSubtitle(strength: AlarmStrength) -> String {
        if strength.overridesSilentSwitch {
            return String(
                localized: "アプリを開いているときはサイレントスイッチがオンでも鳴ります",
                table: "Settings",
                comment: "Subtitle of the Sound switch at the Maximum alarm strength. Suggested English: Plays even with the silent switch on while the app is open"
            )
        }
        return String(
            localized: "サイレントスイッチに従います",
            table: "Settings",
            comment: "Subtitle of the Sound switch. Suggested English: Follows the silent switch"
        )
    }

    /// The footer of the 音と触覚 section.
    static func sectionFooter(strength: AlarmStrength) -> String {
        let automaticStop = DurationText.short(minutes: Int(AlarmStrength.automaticStopDuration / 60))
        switch strength {
        case .gentle:
            return String(
                localized: "集中と休憩の終わりを、選んだ音と強さで知らせます。アプリを開いている間にタイマーが終わったときは、短い終了音と触覚を停止操作まで繰り返します。通知で知らせたあとや、あとからアプリに戻ったときは繰り返さず、そのまま記録を表示します。音はサイレントスイッチに従います。通知を許可している場合、ロック中は短い音の通知で1回知らせます。",
                table: "Settings",
                comment: "Footer of the Sound & Haptics section at the Gentle alarm strength. Suggested English: Focus and break ends use the sound and strength you choose. If the timer ends while the app is open, a short sound and haptic repeat until you stop them. After a notification, or when you come back later, nothing repeats and your record appears. Sound follows the silent switch. With notifications allowed, a locked iPhone gets one notification with a short sound."
            )
        case .standard:
            return String(
                localized: "集中と休憩の終わりを、選んだ音と強さで知らせます。アプリを開いている間にタイマーが終わったときは、止めるまで終了音と強い振動を鳴らし続け、その間は画面をつけたままにします。\(automaticStop)たつと自動的に止まります。通知で知らせたあとや、あとからアプリに戻ったときは鳴らさず、そのまま記録を表示します。音はサイレントスイッチに従います。通知を許可している場合、ロック中は長めの終了音の通知で知らせます。",
                table: "Settings",
                comment: "Footer of the Sound & Haptics section at the Standard alarm strength; %@ is a duration such as 3分 (3 min). Suggested English: Focus and break ends use the sound and strength you choose. If the timer ends while the app is open, the sound and a strong vibration continue until you stop them, and the screen stays on meanwhile. They stop by themselves after %@. After a notification, or when you come back later, nothing rings and your record appears. Sound follows the silent switch. With notifications allowed, a locked iPhone gets a notification with a longer sound."
            )
        case .maximum:
            return String(
                localized: "集中と休憩の終わりを、選んだ音と強さで知らせます。標準と同じように鳴らし続け、アプリを開いているときはサイレントスイッチがオンでも鳴らします。ほかのアプリの音楽は止めずに小さくし、止めると元に戻します。iOS 26以降でアラームを許可すると、アプリを開いていないときの終わりもアラームで知らせます。音をオフにしているときや、アラームを許可していないときは、通知で知らせます（音はサイレントスイッチに従います）。",
                table: "Settings",
                comment: "Footer of the Sound & Haptics section at the Maximum alarm strength. Suggested English: Focus and break ends use the sound and strength you choose. Like Standard, it keeps ringing, and while the app is open it plays even with the silent switch on. Music from other apps is lowered, not stopped, and comes back when you stop the alarm. On iOS 26 or later, once you allow alarms, an end while the app is not open rings as an alarm too. With sound off, or without the alarm permission, a notification is used instead (its sound follows the silent switch)."
            )
        }
    }

    enum MaximumStatusAction: Equatable {
        case none
        case requestPermission
        case openSettings
    }

    struct MaximumStatus: Equatable {
        let message: String
        let action: MaximumStatusAction
    }

    /// What the maximum preset can do on this iPhone right now. Nil below
    /// the maximum preset.
    static func maximumStatus(
        strength: AlarmStrength,
        authorization: AlarmKitAuthorization,
        soundOn: Bool
    ) -> MaximumStatus? {
        guard strength.usesSystemAlarmWhenAway else { return nil }
        switch authorization {
        case .unsupported:
            return MaximumStatus(
                message: String(
                    localized: "アプリを開いていないときのアラームには、iOS 26以降が必要です。このiPhoneでは、アプリを開いているときだけサイレントスイッチがオンでも鳴り、ロック中は通知で知らせます。",
                    table: "Settings",
                    comment: "Settings, Maximum alarm strength before iOS 26. Suggested English: An alarm while the app is not open needs iOS 26 or later. On this iPhone, only the in-app alarm plays with the silent switch on, and a locked iPhone gets a notification."
                ),
                action: .none
            )
        case .notDetermined:
            return MaximumStatus(
                message: String(
                    localized: "アプリを開いていないときにアラームで知らせるには、アラームの許可が必要です。",
                    table: "Settings",
                    comment: "Settings, Maximum alarm strength before the Alarms permission was asked. Suggested English: To ring an alarm while the app is not open, allow alarms."
                ),
                action: .requestPermission
            )
        case .denied:
            return MaximumStatus(
                message: String(
                    localized: "アラームが許可されていないため、アプリを開いていないときは通知で知らせます（音はサイレントスイッチに従います）。「設定」アプリでポモジェムのアラームを許可すると、アラームで知らせます。",
                    table: "Settings",
                    comment: "Settings, Maximum alarm strength with the Alarms permission denied. Suggested English: Alarms are not allowed, so while the app is not open a notification is used (its sound follows the silent switch). Allow alarms for PomoGem in the Settings app to ring an alarm."
                ),
                action: .openSettings
            )
        case .authorized:
            guard soundOn else {
                return MaximumStatus(
                    message: String(
                        localized: "音がオフのため、アラームは使わず通知で知らせます。",
                        table: "Settings",
                        comment: "Settings, Maximum alarm strength with the app's sound off. Suggested English: Sound is off, so a notification is used instead of an alarm."
                    ),
                    action: .none
                )
            }
            return MaximumStatus(
                message: String(
                    localized: "アプリを開いていないときは、アラームで知らせます。",
                    table: "Settings",
                    comment: "Settings, Maximum alarm strength with alarms allowed. Suggested English: While the app is not open, an alarm rings."
                ),
                action: .none
            )
        }
    }

    /// VoiceOver value of an option in the two lists, as elsewhere in Settings.
    static func selectionValue(_ isSelected: Bool) -> Text {
        isSelected
            ? Text("選択中", tableName: "Settings", comment: "VoiceOver value of the chosen option in a list. Suggested English: Selected")
            : Text("未選択", tableName: "Settings", comment: "VoiceOver value of an option that is not chosen. Suggested English: Not selected")
    }

    static var soundRowTitle: String {
        String(localized: "タイマー終了音", table: "Settings", comment: "Settings row: the sound that ends a focus or break. Suggested English: Timer End Sound")
    }

    static var strengthRowTitle: String {
        String(localized: "終了アラームの強さ", table: "Settings", comment: "Settings row: how insistently the end rings (Gentle, Standard, Maximum). Suggested English: Alarm Strength")
    }
}

/// Plays one cycle of a sound as the chosen strength would (the maximum
/// preset through the silent switch). The picker is disabled while the
/// app's sound is off.
@MainActor
enum AlarmSoundPreview {
    static func play(_ choice: AlarmSoundChoice, strength: AlarmStrength) {
        SoundSynth.shared.isEnabled = true
        SoundSynth.shared.playAlarmPreview(
            choice,
            session: strength.overridesSilentSwitch ? .playbackDuckingOthers : .ambient
        )
    }
}

/// The eight sounds, the five alarm-grade ones first. Choosing one plays it.
struct AlarmSoundPickerView: View {
    let selection: AlarmSoundChoice
    let strength: AlarmStrength
    let onSelect: (AlarmSoundChoice) -> Void

    private static let alarms: [AlarmSoundChoice] = AlarmSoundChoice.allCases.filter { $0.synthesizedSound != nil }
    private static let chimes: [AlarmSoundChoice] = AlarmSoundChoice.allCases.filter { $0.legacySound != nil }

    var body: some View {
        List {
            Section {
                ForEach(Self.alarms) { row($0) }
            } header: {
                Text("アラーム", tableName: "Settings", comment: "Header of the five alarm-grade timer end sounds. Suggested English: Alarms")
            } footer: {
                Text(
                    "選ぶと1回鳴らして確かめられます。",
                    tableName: "Settings",
                    comment: "Footer under the alarm sounds: choosing a sound plays it once. Suggested English: Choosing a sound plays it once."
                )
            }
            Section {
                ForEach(Self.chimes) { row($0) }
            } header: {
                Text("チャイム", tableName: "Settings", comment: "Header of the three original, softer timer end chimes. Suggested English: Chimes")
            } footer: {
                Text(
                    "「やわらか」は音が小さく、iPhoneのスピーカーでは聞こえにくいことがあります。終わりに気付かないときは、「アラーム」の音から選んでください。",
                    tableName: "Settings",
                    comment: "Footer under the chimes in the timer end sound list. Suggested English: Soft is quiet and can be hard to hear on the iPhone speaker. If you miss the end, choose one of the Alarms."
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background(NightBackground())
        .navigationTitle(Text(verbatim: AlarmSettingsCopy.soundRowTitle))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Rendered off the main thread, so the first tap plays at once.
            for choice in Self.alarms { SoundSynth.shared.prepareAlarmSound(choice) }
        }
    }

    private func row(_ choice: AlarmSoundChoice) -> some View {
        let isSelected = choice == selection
        return Button {
            onSelect(choice)
            AlarmSoundPreview.play(choice, strength: strength)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: choice.systemImage)
                    .foregroundStyle(PomoGemTheme.amber)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: choice.title)
                        .foregroundStyle(PomoGemTheme.text)
                    Text(verbatim: choice.detail)
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(PomoGemTheme.amber)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PomoGemBareButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(verbatim: choice.title))
        .accessibilityValue(AlarmSettingsCopy.selectionValue(isSelected))
        .accessibilityHint(Text(verbatim: choice.detail))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings.completion-sound.\(choice.rawValue)")
        .accessibilityAction {
            onSelect(choice)
            AlarmSoundPreview.play(choice, strength: strength)
        }
    }
}

/// 控えめ・標準・最大, each with what it does.
struct AlarmStrengthPickerView: View {
    let selection: AlarmStrength
    let onSelect: (AlarmStrength) -> Void

    var body: some View {
        List {
            Section {
                ForEach(AlarmStrength.allCases) { strength in
                    row(strength)
                }
            } footer: {
                Text(
                    "休憩の終わりも同じ強さで知らせます。止めるボタン、VoiceOverの2本指のダブルタップ、アプリを離れることは、どの強さでも止める操作になります。",
                    tableName: "Settings",
                    comment: "Footer of the alarm strength list. Suggested English: Break ends use the same strength. The Stop button, a VoiceOver two-finger double-tap, or leaving the app stops the alarm at every strength."
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background(NightBackground())
        .navigationTitle(Text(verbatim: AlarmSettingsCopy.strengthRowTitle))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ strength: AlarmStrength) -> some View {
        let isSelected = strength == selection
        return Button {
            onSelect(strength)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: strength.title)
                        .foregroundStyle(PomoGemTheme.text)
                    Text(verbatim: strength.detail)
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(PomoGemTheme.amber)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PomoGemBareButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(verbatim: strength.title))
        .accessibilityValue(AlarmSettingsCopy.selectionValue(isSelected))
        .accessibilityHint(Text(verbatim: strength.detail))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings.alarm-strength.\(strength.rawValue)")
        .accessibilityAction { onSelect(strength) }
    }
}

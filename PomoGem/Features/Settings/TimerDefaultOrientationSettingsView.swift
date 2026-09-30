import SwiftUI

struct TimerDefaultOrientationSettingsView: View {
    @Binding var selection: TimerDefaultOrientation
    @ScaledMetric(relativeTo: .title3) private var iconSize = 28.0

    var body: some View {
        List {
            Section {
                ForEach(TimerDefaultOrientation.allCases) { option in
                    Button {
                        selection = option
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: option.symbol)
                                .resizable()
                                .scaledToFit()
                                .frame(width: iconSize, height: iconSize)
                                .foregroundStyle(PomoGemTheme.amber)
                            Text(option.title)
                                .foregroundStyle(PomoGemTheme.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            if selection == option {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(PomoGemTheme.amber)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PomoGemBareButtonStyle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(option.title)
                    .accessibilityValue(selection == option
                        ? String(localized: "選択中", table: "Settings", comment: "VoiceOver value: this option is selected")
                        : String(localized: "未選択", table: "Settings", comment: "VoiceOver value: this option is not selected"))
                    .accessibilityAddTraits(selection == option ? .isSelected : [])
                    .accessibilityIdentifier("timer-default-orientation.option.\(option.rawValue)")
                    .accessibilityAction { selection = option }
                }
            } header: {
                Text("新しいタイマーを開く向き", tableName: "Settings", comment: "Section header above the default timer orientation options")
            } footer: {
                // Quotes the first option's own title, so the two cannot drift.
                Text(
                    "「\(TimerDefaultOrientation.automatic.title)」は端末の向きに合わせます。上・右・下・左は、縦に持ったiPhoneの画面内でタイマーの上辺が向く方向です。",
                    tableName: "Settings",
                    comment: "Footer under the default timer orientation options. The argument is the automatic option's title (自動). 上・右・下・左 are the other four options: which way the top of the timer faces on an upright iPhone."
                )
            }

            Section {
                Text("集中・休憩の両方に使います。タイマー画面で一時的に向きを変えても、この既定値は変わりません。", tableName: "Settings")
                Text("このiPhoneに保存され、アプリを再起動しても引き継がれます。", tableName: "Settings")
                Text(
                    "ホームボタンのないiPhoneでは、「下」はタイマーの内容だけが上下逆になり、ホームバーなどの向きは変わりません。",
                    tableName: "Settings",
                    comment: "下 is the upside-down option; the Home indicator (ホームバー) keeps its place"
                )
            }
            .font(.subheadline)
            .foregroundStyle(PomoGemTheme.muted)
        }
        .scrollContentBackground(.hidden)
        .background(NightBackground())
        .navigationTitle(Text("タイマーの既定の向き", tableName: "Settings", comment: "Settings row and page title: the orientation new timers open in"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

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
                    .accessibilityValue(selection == option ? "選択中" : "未選択")
                    .accessibilityAddTraits(selection == option ? .isSelected : [])
                    .accessibilityIdentifier("timer-default-orientation.option.\(option.rawValue)")
                    .accessibilityAction { selection = option }
                }
            } header: {
                Text("新しいタイマーを開く向き")
            } footer: {
                Text("「自動」は端末の向きに合わせます。上・右・下・左は、縦に持ったiPhoneの画面内でタイマーの上辺が向く方向です。")
            }

            Section {
                Text("集中・休憩の両方に使います。タイマー画面で一時的に向きを変えても、この既定値は変わりません。")
                Text("このiPhoneに保存され、アプリを再起動しても引き継がれます。")
            }
            .font(.subheadline)
            .foregroundStyle(PomoGemTheme.muted)
        }
        .scrollContentBackground(.hidden)
        .background(NightBackground())
        .navigationTitle("タイマーの既定の向き")
        .navigationBarTitleDisplayMode(.inline)
    }
}

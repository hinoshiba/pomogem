import SwiftUI

@MainActor
struct CustomDurationView: View {
    private enum InputField: Hashable { case minutes, seconds }

    private let onConfirm: @MainActor (Int) -> Bool
    @State private var editor: CustomDurationEditingState
    @FocusState private var focusedField: InputField?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(initialSeconds: Int, onConfirm: @escaping @MainActor (Int) -> Bool) {
        _editor = State(initialValue: CustomDurationEditingState(initialSeconds: initialSeconds))
        self.onConfirm = onConfirm
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        SectionEyebrow(text: "POMOGEM PRO")
                        Text("集中時間を選ぶ", tableName: "Home", comment: "Custom focus length sheet: title")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                        Text("1分0秒〜360分0秒", tableName: "Home", comment: "Custom focus length sheet: the shortest and longest lengths")
                            .font(.subheadline)
                            .foregroundStyle(PomoGemTheme.muted)
                    }
                    .multilineTextAlignment(.center)

                    durationSummary

                    Picker(
                        String(localized: "時間の選び方", table: "Home", comment: "Custom focus length: label of the type/scroll segmented control"),
                        selection: modeBinding
                    ) {
                        Text("入力", tableName: "Home", comment: "Custom focus length segment: type the minutes and seconds")
                            .tag(CustomDurationEditingState.Mode.input)
                        Text("スクロール", tableName: "Home", comment: "Custom focus length segment: pick the minutes and seconds on wheels")
                            .tag(CustomDurationEditingState.Mode.scroll)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!editor.canChangeMode)
                    .accessibilityIdentifier("custom-timer.mode")

                    if editor.mode == .input {
                        numericInputs
                    } else {
                        wheelInputs
                    }

                    if let message = editor.validationMessage {
                        Text(message)
                            .font(.body)
                            .foregroundStyle(PomoGemTheme.amber)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("custom-timer.validation")
                    }

                    Button(
                        String(localized: "この時間にする", table: "Home", comment: "Custom focus length: confirm button"),
                        action: confirm
                    )
                        .buttonStyle(PomoGemPrimaryButtonStyle())
                        .disabled(!editor.canConfirm)
                        .accessibilityIdentifier("custom-timer.confirm")

                    Text(
                        "秒単位のタイマーを別の端末で引き継ぐには、両方の端末で最新バージョンを利用してください。",
                        tableName: "Home",
                        comment: "Custom focus length: a timer with seconds continues on another device only when both run the latest version"
                    )
                        .font(.footnote)
                        .foregroundStyle(PomoGemTheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("custom-timer.compatibility-note")
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .background(NightBackground())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PomoGemSheetCloseButton(accessibilityIdentifier: "custom-timer.close") {
                        editor.cancel()
                        focusedField = nil
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(String(localized: "入力完了", table: "Home", comment: "Keyboard toolbar button that closes the number pad")) {
                        focusedField = nil
                    }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("custom-timer.keyboard-done")
                }
            }
        }
        .onDisappear { editor.cancel() }
    }

    private var durationSummary: some View {
        Group {
            if let total = editor.totalSeconds {
                Text(
                    "\(total / Constants.Timer.secondsPerMinute)分 \(total % Constants.Timer.secondsPerMinute)秒",
                    tableName: "Home",
                    comment: "Custom focus length summary: minutes, then seconds (25分 0秒)"
                )
            } else {
                Text("分と秒を入力", tableName: "Home", comment: "Custom focus length summary while the input is incomplete")
            }
        }
        .font(.system(.largeTitle, design: .rounded, weight: .heavy))
        .monospacedDigit()
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("custom-timer.summary")
    }

    /// The minutes and seconds fields and wheels share their titles.
    private static var minutesTitle: String {
        String(localized: "分", table: "Home", comment: "Custom focus length: title and VoiceOver label of the minutes field and wheel")
    }

    private static var secondsTitle: String {
        String(localized: "秒", table: "Home", comment: "Custom focus length: title and VoiceOver label of the seconds field and wheel")
    }

    private var modeBinding: Binding<CustomDurationEditingState.Mode> {
        Binding(get: { editor.mode }, set: { mode in
            if editor.selectMode(mode) { focusedField = nil }
        })
    }

    private var numericInputs: some View {
        inputLayout {
            numericField(Self.minutesTitle, text: Binding(get: { editor.minutesText }, set: { editor.editMinutes($0) }),
                         field: .minutes, identifier: "custom-timer.minutes-input")
            numericField(Self.secondsTitle, text: Binding(get: { editor.secondsText }, set: { editor.editSeconds($0) }),
                         field: .seconds, identifier: "custom-timer.seconds-input")
        }
    }

    private func numericField(_ title: String, text: Binding<String>, field: InputField,
                              identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .accessibilityHidden(true)
            TextField(title, text: text)
                .keyboardType(.numberPad)
                .focused($focusedField, equals: field)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .monospacedDigit()
                .padding(.horizontal, 16)
                .frame(minHeight: 56)
                .background(PomoGemTheme.raised, in: RoundedRectangle(cornerRadius: 14))
                .disabled(!editor.isEditing)
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity)
    }

    private var wheelInputs: some View {
        inputLayout {
            Picker(Self.minutesTitle, selection: Binding(get: { editor.wheelMinutes }, set: { editor.selectWheelMinutes($0) })) {
                ForEach(Constants.Timer.customMinimumMinutes...Constants.Timer.customMaximumMinutes, id: \.self) { value in
                    Text("\(value)分", tableName: "Home", comment: "Custom focus length: one row of the minutes wheel")
                        .tag(value)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: 216)
            .clipped()
            .contentShape(Rectangle())
            .disabled(!editor.isEditing)
            .accessibilityLabel(Self.minutesTitle)
            .accessibilityIdentifier("custom-timer.minutes-wheel")

            Picker(Self.secondsTitle, selection: Binding(get: { editor.wheelSeconds }, set: { editor.selectWheelSeconds($0) })) {
                ForEach(0...editor.maximumWheelSeconds, id: \.self) { value in
                    Text("\(value)秒", tableName: "Home", comment: "Custom focus length: one row of the seconds wheel")
                        .tag(value)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: 216)
            .clipped()
            .contentShape(Rectangle())
            .disabled(!editor.isEditing)
            .accessibilityLabel(Self.secondsTitle)
            .accessibilityIdentifier("custom-timer.seconds-wheel")
        }
    }

    @ViewBuilder
    private func inputLayout<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 16, content: content)
        } else {
            HStack(alignment: .top, spacing: 16, content: content)
        }
    }

    private func confirm() {
        guard let seconds = editor.beginConfirmation() else { return }
        focusedField = nil
        let accepted = onConfirm(seconds)
        editor.finishConfirmation(accepted: accepted)
    }
}

import SwiftUI

struct PreferredFocusDurationPicker: View {
    let preferredSeconds: Int
    let isPro: Bool
    let onSelectPreset: (PomodoroDuration) -> Void
    let onCustomDuration: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var selectedDuration: PomodoroDuration {
        let preferred = PomodoroDuration(totalSeconds: preferredSeconds)
        return preferred.requiresPro && !isPro ? .twentyFiveMinutes : preferred
    }

    private var isCustomSelected: Bool {
        selectedDuration.requiresPro
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("既定の集中時間")
                    .font(.headline)
                    .foregroundStyle(PomoGemTheme.text)
                    .accessibilityAddTraits(.isHeader)
                Text("次の集中に使う時間を選びます。")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
            }

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 12),
                    count: dynamicTypeSize.isAccessibilitySize ? 1 : 2
                ),
                spacing: 12
            ) {
                ForEach(PomodoroDuration.freePresets, id: \.self) { duration in
                    presetTile(duration)
                }
            }

            customDurationButton
        }
        .padding(.vertical, 8)
    }

    private func presetTile(_ duration: PomodoroDuration) -> some View {
        let isSelected = selectedDuration.seconds == duration.seconds
        return Button {
            onSelectPreset(duration)
        } label: {
            HStack(spacing: 8) {
                Text(duration.displayLabel)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isSelected ? PomoGemTheme.amber : PomoGemTheme.muted)
            }
            .foregroundStyle(PomoGemTheme.text)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 76)
            .padding(.vertical, 8)
            .background(tileBackground(isSelected: isSelected))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(PomoGemBareButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(duration.displayLabel)
        .accessibilityValue(isSelected ? "選択中" : "未選択")
        .accessibilityHint("既定の集中時間に設定します")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings.focus-preset.\(duration.seconds / Constants.Timer.secondsPerMinute)")
    }

    private var customDurationButton: some View {
        Button(action: onCustomDuration) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Text("カスタム時間")
                        .font(.headline)
                        .foregroundStyle(PomoGemTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Pro")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PomoGemTheme.amber)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(PomoGemTheme.amber.opacity(0.12), in: Capsule())
                        .fixedSize()
                    Spacer(minLength: 0)
                    Image(systemName: isCustomSelected ? "checkmark.circle.fill" : (isPro ? "chevron.right" : "lock.fill"))
                        .font(.body)
                        .foregroundStyle(isCustomSelected ? PomoGemTheme.amber : PomoGemTheme.muted)
                }

                if isCustomSelected {
                    Text(selectedDuration.displayLabel)
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(PomoGemTheme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(Constants.UIStrings.customDurationRange)
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(tileBackground(isSelected: isCustomSelected))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(PomoGemBareButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isCustomSelected ? "選択中" : "未選択")
        .accessibilityAddTraits(isCustomSelected ? .isSelected : [])
        .accessibilityHint(isPro
            ? "分と秒を入力、またはスクロールして設定します"
            : "ポモジェムProのプランを表示します")
        .accessibilityIdentifier(isPro ? "settings.preferred-focus-duration" : "settings.custom-timer")
    }

    private func tileBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(isSelected ? PomoGemTheme.amber.opacity(0.12) : PomoGemTheme.raised)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? PomoGemTheme.amber : PomoGemTheme.glassEdge,
                                  lineWidth: isSelected ? 1.5 : 1)
            }
    }
}

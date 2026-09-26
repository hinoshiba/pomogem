import SwiftUI

/// 演出の強さ (D17, Docs/GemExperienceDesign.md §8.9): 標準 or 控えめ for
/// the jar's light and motion on this iPhone. The choice is a device-local
/// display preference (`JarEffectsIntensity.defaultsKey`), never synced;
/// the jar, the time core, the fusion sheet and share cards follow it at
/// once. Reduce Motion always shows 控えめ, whatever is chosen here.
struct JarEffectsSettingsSection: View {
    @AppStorage(JarEffectsIntensity.defaultsKey)
    private var intensity: JarEffectsIntensity = .standard
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.pomogemReduceMotionOverride) private var reduceMotionOverride
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var reduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // The same header row as the rest of Settings.
                SettingLabel(title: title, subtitle: detail, symbol: "sparkles")

                // Round 14: at accessibility text sizes the two options are
                // a menu, whose labels grow with Dynamic Type (a segmented
                // control keeps caption-sized text).
                if dynamicTypeSize.isAccessibilitySize {
                    picker
                        .pickerStyle(.menu)
                } else {
                    picker
                        .pickerStyle(.segmented)
                }
            }
            .padding(.vertical, 2)

            if reduceMotion {
                Text("「視差効果を減らす」がオンのため、いまは控えめで表示しています。", tableName: "Settings", comment: "Settings note under Effect intensity while the system Reduce Motion setting is on")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .accessibilityIdentifier("settings.effects-intensity.reduce-motion")
            }
        } header: {
            Text("瓶の表示", tableName: "Settings", comment: "Settings section header: how the jar is shown (Jar display)")
        } footer: {
            Text("控えめにしても、粒の重さや数、融合、カットは変わりません。「視差効果を減らす」がオンのときは、常に控えめで表示します。この設定はこのiPhoneだけに保存され、iCloudでは同期しません。", tableName: "Settings", comment: "Settings footer explaining Effect intensity")
        }
    }

    private var picker: some View {
        Picker(selection: $intensity) {
            Text("標準", tableName: "Settings", comment: "Effect intensity option: every light and motion effect (Standard)")
                .tag(JarEffectsIntensity.standard)
                .accessibilityIdentifier("settings.effects-intensity.standard")
            Text("控えめ", tableName: "Settings", comment: "Effect intensity option: calmer light and shorter effects (Subtle)")
                .tag(JarEffectsIntensity.subtle)
                .accessibilityIdentifier("settings.effects-intensity.subtle")
        } label: {
            Text(title)
        }
        .labelsHidden()
        .accessibilityIdentifier("settings.effects-intensity")
    }

    private var title: String {
        String(localized: "演出の強さ", table: "Settings", comment: "Settings row: how much light and motion the jar's rewards use (Effect intensity)")
    }

    private var detail: String {
        switch intensity {
        case .standard:
            String(localized: "自然なきらめきと傾けたときの星、光の広がりをすべて表示します", table: "Settings", comment: "Effect intensity detail for Standard")
        case .subtle:
            String(localized: "きらめきと傾けたときの星を止め、光を弱め、着地と融合を短くします", table: "Settings", comment: "Effect intensity detail for Subtle")
        }
    }
}

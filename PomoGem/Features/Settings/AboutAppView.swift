import SwiftUI

/// The app's version as people and support read it: 「1.1.0 (10)」.
enum AppVersionText {
    static var current: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String

        guard let build, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }
}

/// settings-06. Version, copyright, the typeface credit and licences used to
/// fill a top-level 「クレジット」 card at the end of Settings. They are
/// reference information, so they live one level down, like iOS's own
/// 「情報」 page.
struct AboutAppView: View {
    @State private var showFontLicense = false

    var body: some View {
        List {
            Section {
                LabeledContent(
                    String(localized: "バージョン", table: "Settings", comment: "About page row: app version"),
                    value: AppVersionText.current
                )
                .accessibilityIdentifier("about.version")
                LabeledContent(
                    String(localized: "著作権", table: "Settings", comment: "About page row: copyright"),
                    value: "© 2026 hinoshiba"
                )
            }

            Section {
                LabeledContent(
                    String(localized: "見出し書体", table: "Settings", comment: "About page row: the heading typeface"),
                    value: "Zen Maru Gothic"
                )
                Button(String(
                    localized: "SIL Open Font License 1.1を読む",
                    table: "Settings",
                    comment: "About page button: show the typeface's licence"
                )) {
                    showFontLicense = true
                }
                .accessibilityIdentifier("about.font-license")
            } header: {
                Text("クレジット", tableName: "Settings", comment: "About page section header: credits")
            }

            Section {
                Link(destination: AppLinks.sourceCode) {
                    SettingLabel(
                        title: String(localized: "ソースコードとライセンス", table: "Settings", comment: "About page link title"),
                        subtitle: String(localized: "MIT License・GitHub（Webで開く）", table: "Settings", comment: "About page link subtitle"),
                        symbol: "chevron.left.forwardslash.chevron.right"
                    )
                }
            } header: {
                Text("オープンソース", tableName: "Settings", comment: "About page section header: open source")
            }
        }
        .scrollContentBackground(.hidden)
        .background(NightBackground())
        .pomogemNavigationTitle(String(localized: "このアプリについて", table: "Settings", comment: "About page title"))
        .toolbarTitleDisplayMode(.inline)
        .sheet(isPresented: $showFontLicense) {
            FontLicenseView()
        }
    }
}

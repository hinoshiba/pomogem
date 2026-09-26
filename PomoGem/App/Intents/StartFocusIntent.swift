import AppIntents

/// The length Siri, Spotlight and the Shortcuts app may ask for. Only the free
/// presets exist here; leaving it empty uses the length selected on Home.
enum FocusStartLength: String, AppEnum {
    case twentyFive = "25"
    case fortyFive = "45"
    case sixty = "60"
    case ninety = "90"

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource(
            "集中時間",
            table: "Focus",
            comment: "Shortcuts: the focus length parameter"
        )
    )

    static let caseDisplayRepresentations: [FocusStartLength: DisplayRepresentation] = [
        .twentyFive: DisplayRepresentation(title: LocalizedStringResource(
            "25分", table: "Focus", comment: "Shortcuts and Siri: a 25-minute focus"
        )),
        .fortyFive: DisplayRepresentation(title: LocalizedStringResource(
            "45分", table: "Focus", comment: "Shortcuts and Siri: a 45-minute focus"
        )),
        .sixty: DisplayRepresentation(title: LocalizedStringResource(
            "60分", table: "Focus", comment: "Shortcuts and Siri: a 60-minute focus"
        )),
        .ninety: DisplayRepresentation(title: LocalizedStringResource(
            "90分", table: "Focus", comment: "Shortcuts and Siri: a 90-minute focus"
        ))
    ]

    var preset: FocusStartPreset {
        switch self {
        case .twentyFive: .twentyFive
        case .fortyFive: .fortyFive
        case .sixty: .sixty
        case .ninety: .ninety
        }
    }
}

/// Starts a focus the way Home's start button does (product-04, notify-05
/// phase 1). It opens the app and hands Home one request; nothing runs in the
/// background and nothing is read or returned. Home applies the start
/// button's own rules first, so this can never start a second session, run
/// behind the iCloud check or skip the reward choice.
struct StartFocusIntent: AppIntent {
    static let title = LocalizedStringResource(
        "集中を始める",
        table: "Focus",
        comment: "Siri, Spotlight and Shortcuts: the start-focus action"
    )
    static let description = IntentDescription(LocalizedStringResource(
        "ポモジェムを開き、ホームで選んでいるテーマで集中を始めます。",
        table: "Focus",
        comment: "Shortcuts: what the start-focus action does"
    ))
    static let openAppWhenRun = true

    @Parameter(
        title: LocalizedStringResource(
            "集中時間",
            table: "Focus",
            comment: "Shortcuts: the focus length parameter"
        ),
        description: LocalizedStringResource(
            "空欄なら、ホームで選んでいる時間で始めます。",
            table: "Focus",
            comment: "Shortcuts: what an empty focus length means"
        )
    )
    var length: FocusStartLength?

    init() {}

    init(length: FocusStartLength?) {
        self.length = length
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppEntryInbox.shared.receive(.startFocus(length?.preset))
        return .result()
    }
}

/// Siri, Spotlight, the Shortcuts app and the Action Button offer these with
/// no setup. The phrases are Japanese, the development language; English
/// phrases come with the localization wave in `AppShortcuts.xcstrings`
/// (Docs/Localization.md).
struct PomoGemShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartFocusIntent(),
            // l10n-ignore-begin: App Shortcut phrases are translated in AppShortcuts.xcstrings, not a table (Docs/Localization.md)
            phrases: [
                "\(.applicationName)で集中を始める",
                "\(.applicationName)で集中する",
                "\(.applicationName)で\(\.$length)集中する",
                "\(.applicationName)でポモドーロを始める"
            ],
            // l10n-ignore-end
            shortTitle: LocalizedStringResource(
                "集中を始める",
                table: "Focus",
                comment: "Siri, Spotlight and Shortcuts: the start-focus action"
            ),
            systemImageName: "timer"
        )
    }
}

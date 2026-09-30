import Foundation
import XCTest
@testable import PomoGem

/// English expectations for localization package l10n-07-onboarding-paywall-models (tables: Onboarding, Paywall and Models).
///
/// Only that package edits this file (Docs/Localization.md). Resolve English
/// explicitly with `LocalizationTestSupport.englishBundle()` and
/// `LocalizationTestSupport.english`, which skip until English is activated;
/// never change the process language, because the rest of the suite asserts
/// Japanese.
///
/// The stored Japanese data (built-in theme names, the 「過去の集中」 aggregate
/// names, the 「2026年9月」 month key) is pinned here too: it must never
/// change with the language (L10N D6); only its display is mapped.
final class OnboardingPaywallModelsLocalizationTests: XCTestCase {
    private let en = LocalizationTestSupport.english
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    /// The English value of a key, formatted the way the app formats it.
    private func english(_ table: String, _ key: String, _ arguments: CVarArg...) throws -> String {
        let bundle = try LocalizationTestSupport.englishBundle()
        let format = bundle.localizedString(forKey: key, value: "<missing \(key)>", table: table)
        return arguments.isEmpty ? format : String(format: format, locale: en, arguments: arguments)
    }

    // MARK: Japanese stays byte-identical

    func testJapaneseCopyIsUnchanged() {
        XCTAssertEqual(SeedData.subjects.map(\.displayName), ["英語", "数学", "国語", "理科", "社会"])
        XCTAssertEqual(
            SubjectSuggestionCatalog.presets.map(\.displayName),
            ["英語", "数学", "国語", "理科", "社会", "企画", "開発", "資料作成", "顧客対応"]
        )
        XCTAssertEqual(SubjectSuggestionCatalog.inputPlaceholder, "例：英語、TOEIC、企画、開発")
        XCTAssertEqual(AchievementKind.allCases.map(\.title), ["100点", "試験合格", "仕事の節目"])
        XCTAssertEqual(AchievementKind.examPass.notePlaceholder, "例：簿記2級")
        XCTAssertEqual(RareRewardMode.choiceOrder.map(\.title), ["抽選しない", "控えめ", "標準"])
        XCTAssertEqual(TimerDisplayMode.allCases.map(\.title), ["リング＋時間", "円盤（数字なし）", "時間のみ", "リングのみ"])
        XCTAssertEqual(TimerCompletionHaptic.allCases.map(\.title), ["標準・2回", "やさしい・1回", "しっかり・3回"])
        XCTAssertEqual(SessionSource.timer.displayName, "実測")
        XCTAssertEqual(SessionSource.manual.displayName, "自己申告")
        XCTAssertEqual(SubjectNamePolicy.ValidationError.empty.message, "テーマ名を入力してください。")
        XCTAssertEqual(
            SubjectNamePolicy.ValidationError.tooLong(excessCharacters: 3).message,
            "テーマ名は40文字以内で入力してください（3文字超過）。"
        )
        XCTAssertEqual(
            RareRewardCounts(drawCount: 3, goldCount: 1, prismCount: 0).multiDrawSummary,
            "250gごとの抽選3回（通常2・金1）"
        )
        XCTAssertEqual(RareRewardCounts(drawCount: 2, goldCount: 0, prismCount: 2).multiDrawSummary, "250gごとの抽選2回（虹2）")
        XCTAssertEqual(
            GachaEngine.goldGuaranteeDisclosure,
            "250gごとの抽選で金が20回続けて出なかった場合、次の抽選は金の粒になります。虹はこの回数をリセットしません。"
        )
        XCTAssertEqual(PurchaseManagerError.failedVerification.errorDescription, "購入情報を確認できませんでした。")
        XCTAssertEqual(
            ActivityResetAdmissionPolicy.cloudResetUnavailableMessage,
            "記録を保護するため、iCloudのリセットは一時的に利用できません。"
        )
        XCTAssertEqual(
            RareRewardLedgerRepositoryError.transport("CKError 4").errorDescription,
            "iCloudへレア粒を確定できませんでした。端末内の完走記録は保持されています。\nCKError 4"
        )
    }

    // MARK: Stored names stay Japanese data; only their display is mapped

    func testBuiltInPresetsReadInTheAppLanguageOnlyWhileUntouched() throws {
        let bundle = try LocalizationTestSupport.englishBundle()
        let builtIn = try XCTUnwrap(SeedData.subjects.first)
        XCTAssertEqual(builtIn.name, "英語", "the stored name is data in every language")
        XCTAssertEqual(
            SeedData.subjects.map { $0.displayName(bundle: bundle) },
            ["English", "Math", "Language Arts", "Science", "Social Studies"]
        )

        // Untouched: the fixed ID with its canonical name.
        XCTAssertEqual(SubjectNamePolicy.localizedDisplayName("英語", subjectID: builtIn.id, bundle: bundle), "English")
        // Renamed by the user: their name, in any language.
        XCTAssertEqual(SubjectNamePolicy.localizedDisplayName("TOEIC", subjectID: builtIn.id, bundle: bundle), "TOEIC")
        XCTAssertEqual(SubjectNamePolicy.localizedDisplayName("数学", subjectID: builtIn.id, bundle: bundle), "数学")
        // The same name on the user's own theme (another ID) is theirs.
        XCTAssertEqual(SubjectNamePolicy.localizedDisplayName("英語", subjectID: UUID(), bundle: bundle), "英語")
        for ownName in ["テーマ", "過去の集中", "アーカイブ済みのテーマ"] {
            XCTAssertEqual(
                SubjectNamePolicy.localizedDisplayName(ownName, subjectID: UUID(), bundle: bundle),
                ownName,
                "A custom theme that happens to spell a fallback must keep its chosen name"
            )
        }
        // Snapshots and aggregates carry no ID: the canonical name is enough.
        XCTAssertEqual(SubjectNamePolicy.localizedDisplayName("社会", bundle: bundle), "Social Studies")
        XCTAssertEqual(SubjectNamePolicy.localizedDisplayName("Physics", bundle: bundle), "Physics")

        // A built-in synced from an English-language iPhone is the same row:
        // this Japanese device reads it in Japanese, and nothing was rewritten.
        let row = Subject(id: builtIn.id, name: builtIn.name, colorHex: builtIn.colorHex, sortOrder: 0)
        XCTAssertEqual(row.name, "英語")
        XCTAssertEqual(row.safeDisplayName, "英語")
        XCTAssertEqual(row.localizedDisplayName, "英語")
        let renamed = Subject(id: builtIn.id, name: "英検2級", colorHex: builtIn.colorHex, sortOrder: 0)
        XCTAssertEqual(renamed.localizedDisplayName, "英検2級")
    }

    func testLegacyAggregateNamesStayStoredAndReadInTheAppLanguage() throws {
        let bundle = try LocalizationTestSupport.englishBundle()
        XCTAssertEqual(AggregateSubjectFraction.legacySubjectName(at: 0), "過去の集中")
        XCTAssertEqual(AggregateSubjectFraction.legacySubjectName(at: 2), "過去の集中 3")
        XCTAssertEqual(AggregateSubjectFraction(name: "", colorHex: "#FFFFFF", pebbleCount: 1).name, "過去の集中")

        XCTAssertEqual(SubjectNamePolicy.localizedDisplayName("過去の集中", bundle: bundle), "Earlier focus")
        XCTAssertEqual(SubjectNamePolicy.localizedDisplayName("過去の集中 3", bundle: bundle), "Earlier focus 3")
        XCTAssertEqual(SubjectNamePolicy.localizedDisplayName("過去の集中 03", bundle: bundle), "過去の集中 03",
                       "only names the app itself writes are mapped")
        XCTAssertEqual(SubjectNamePolicy.localizedDisplayName("過去の集中 1", bundle: bundle), "過去の集中 1")
        XCTAssertEqual(SubjectNamePolicy.localizedDisplayName("アーカイブ済みのテーマ", bundle: bundle), "Archived theme")
        XCTAssertEqual(SubjectNamePolicy.localizedDisplayName("テーマ", bundle: bundle), "Theme")
        XCTAssertEqual(SubjectNamePolicy.localizedDisplayName("  ", bundle: bundle), "Theme")

        // Japanese reads exactly what is stored.
        XCTAssertEqual(SubjectNamePolicy.localizedDisplayName("過去の集中 3"), "過去の集中 3")
        XCTAssertEqual(SubjectNamePolicy.localizedDisplayName(""), "テーマ")
        XCTAssertEqual(AggregateSubjectFraction(name: "過去の集中 2", colorHex: "#FFFFFF", pebbleCount: 1).displayName, "過去の集中 2")
        XCTAssertEqual(AggregateSubjectFraction(name: "数学", colorHex: "#FFFFFF", pebbleCount: 1).displayName, "数学")
    }

    func testSuggestionsMatchTheJapaneseAndTheShownSpelling() throws {
        let bundle = try LocalizationTestSupport.englishBundle()
        let suggestions = SubjectSuggestionCatalog.suggestions(bundle: bundle)
        XCTAssertEqual(
            suggestions.map(\.displayName),
            ["English", "Math", "Language Arts", "Science", "Social Studies",
             "Planning", "Development", "Docs & Slides", "Customer Support"]
        )
        // Built-ins keep their fixed-ID row's Japanese name; a work suggestion
        // is saved as shown.
        XCTAssertEqual(
            suggestions.map(\.name),
            ["英語", "数学", "国語", "理科", "社会", "Planning", "Development", "Docs & Slides", "Customer Support"]
        )
        XCTAssertEqual(Set(suggestions.map { SubjectNamePolicy.comparisonKey($0.name) }).count, suggestions.count)
        XCTAssertEqual(Set(suggestions.map { SubjectNamePolicy.comparisonKey($0.displayName) }).count, suggestions.count)

        XCTAssertEqual(SubjectSuggestionCatalog.preset(named: "english", bundle: bundle)?.name, "英語")
        XCTAssertEqual(SubjectSuggestionCatalog.preset(named: "英語", bundle: bundle)?.name, "英語")
        XCTAssertEqual(SubjectSuggestionCatalog.preset(named: " Planning ", bundle: bundle)?.name, "Planning")
        XCTAssertEqual(SubjectSuggestionCatalog.preset(named: "企画", bundle: bundle)?.name, "Planning")
        XCTAssertNil(SubjectSuggestionCatalog.preset(named: "SAT prep", bundle: bundle))

        // A Japanese device: unchanged.
        XCTAssertEqual(SubjectSuggestionCatalog.preset(named: "企画")?.name, "企画")
        XCTAssertEqual(SubjectSuggestionCatalog.preset(named: "英語")?.name, "英語")
        XCTAssertEqual(SubjectSuggestionCatalog.displayName(forChosen: "英語"), "英語")
        XCTAssertEqual(SubjectSuggestionCatalog.displayName(forChosen: "TOEIC"), "TOEIC")
    }

    func testMonthKeyStaysLegacyWhileItsLabelFollowsTheLanguage() throws {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = tokyo
        let date = try XCTUnwrap(gregorian.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 12)))
        XCTAssertEqual(StrataMath.monthLabel(for: date, timeZone: tokyo), "2026年9月")
        XCTAssertEqual(StrataMath.displayMonthLabel(for: date, timeZone: tokyo), "2026年9月")
        XCTAssertEqual(DateText.yearMonth(date, locale: en, timeZone: tokyo), "September 2026")

        let start = try XCTUnwrap(StrataMath.monthStart(fromLegacyLabel: "2026年9月", timeZone: tokyo))
        XCTAssertEqual(start, gregorian.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        XCTAssertEqual(StrataMath.monthLabel(for: start, timeZone: tokyo), "2026年9月")
        XCTAssertEqual(DateText.yearMonth(start, locale: en, timeZone: tokyo), "September 2026")
        XCTAssertNotNil(StrataMath.monthStart(fromLegacyLabel: "1999年12月", timeZone: tokyo))
        XCTAssertNil(StrataMath.monthStart(fromLegacyLabel: "", timeZone: tokyo))
        XCTAssertNil(StrataMath.monthStart(fromLegacyLabel: "2026年13月", timeZone: tokyo))
        XCTAssertNil(StrataMath.monthStart(fromLegacyLabel: "September 2026", timeZone: tokyo))
    }

    // MARK: English

    func testOnboardingInEnglish() throws {
        XCTAssertEqual(try english("Onboarding", "集中を終えると、一粒。"), "Finish a focus, get a gem.")
        XCTAssertEqual(try english("Onboarding", "減らない"), "Nothing shrinks")
        XCTAssertEqual(try english("Onboarding", "責めない"), "No guilt")
        XCTAssertEqual(try english("Onboarding", "次へ"), "Next")
        XCTAssertEqual(try english("Onboarding", "瓶をひらく"), "Open the Jar")
        XCTAssertEqual(try english("Onboarding", "YOUR BOTTLE"), "YOUR JAR", "glossary: jar, never bottle")
        XCTAssertEqual(try english("Onboarding", "最初のテーマを選ぶ"), "Choose Your First Theme")
        XCTAssertEqual(try english("Onboarding", "新しく始める"), "Start Fresh")
        XCTAssertEqual(
            try english("Onboarding", "全%lldページ中、%lldページ。%@", 3, 2, "Try a Gem (Optional)"),
            "Page 2 of 3. Try a Gem (Optional)"
        )
        XCTAssertEqual(try english("Onboarding", "最初のテーマ：%@", "English"), "First theme: English")
        XCTAssertEqual(try english("Onboarding", "%@に、集中を思い出す通知を受け取る", "8:00 PM"), "Get a reminder to focus at 8:00 PM")
        XCTAssertEqual(try english("Onboarding", "レア粒は、自分で選ぶ。"), "Rare gems are your choice.")
    }

    func testOnboardingPluralsInEnglish() throws {
        XCTAssertEqual(try english("Onboarding", "%lld粒、0グラム", 0), "0 gems, 0 grams")
        XCTAssertEqual(try english("Onboarding", "%lld粒、0グラム", 1), "1 gem, 0 grams")
        XCTAssertEqual(try english("Onboarding", "最大%lld文字", 40), "Up to 40 characters")
        XCTAssertEqual(try english("Onboarding", "あと%lld文字入力できます", 1), "1 character left")
        XCTAssertEqual(try english("Onboarding", "あと%lld文字入力できます", 39), "39 characters left")
        XCTAssertEqual(try english("Onboarding", "追加できるテーマは合計最大%lld件です。", 12), "You can have up to 12 themes in all.")
        XCTAssertEqual(
            try english("Onboarding", "テーマ名は%lld文字以内で入力してください（%lld文字超過）。", 40, 3),
            "Theme names can be up to 40 characters (3 over)."
        )
        // The restore screen's VoiceOver summary: two sentences, one count each.
        XCTAssertEqual(try english("Onboarding", "届いた記録：テーマ%lld件。", 1), "Received so far: 1 theme.")
        XCTAssertEqual(try english("Onboarding", "届いた記録：テーマ%lld件。", 3), "Received so far: 3 themes.")
        let elapsed = DurationText.spoken(seconds: 65, units: .minutesSeconds, locale: en)
        XCTAssertEqual(
            SentenceText.join([try english("Onboarding", "届いた記録：テーマ%lld件。", 1),
                               try english("Onboarding", "経過時間%@", elapsed)], locale: en),
            "Received so far: 1 theme. Time elapsed: 1 minute, 5 seconds."
        )
    }

    func testPaywallInEnglish() throws {
        XCTAssertEqual(try english("Paywall", "%@でProを購入", "$2.99"), "Buy Pro for $2.99")
        XCTAssertEqual(try english("Paywall", "ポモジェムPro"), "PomoGem Pro")
        XCTAssertEqual(try english("Paywall", "買い切り"), "One-Time Purchase")
        XCTAssertEqual(try english("Paywall", "購入を復元"), "Restore Purchases")
        XCTAssertEqual(try english("Paywall", "利用規約"), "Terms of Use")
        XCTAssertEqual(try english("Paywall", "プライバシー"), "Privacy")
        XCTAssertEqual(try english("Paywall", "販売条件"), "Terms of Sale")
        XCTAssertEqual(
            try english("Paywall", "購入はApple Accountに請求されます。ポモジェムProは1回限りの買い切りで、自動更新はありません。"),
            "Your purchase is charged to your Apple Account. PomoGem Pro is a one-time purchase and never renews automatically."
        )
        XCTAssertEqual(try english("Paywall", "自動更新・無料トライアルはありません。"), "No auto-renewal and no free trial.")
        XCTAssertEqual(try english("Paywall", "購入情報を確認できませんでした。"), "Couldn’t verify the purchase.")
        // The restore alert names what happened, not the button that did it.
        XCTAssertEqual(
            try english("Paywall", "購入を復元しました。Proの機能を使えます。"),
            "Your purchase has been restored. You can use Pro features."
        )
    }

    func testModelsInEnglish() throws {
        XCTAssertEqual(try english("Models", "100点"), "Perfect score")
        XCTAssertEqual(try english("Models", "試験合格"), "Passed an exam")
        XCTAssertEqual(try english("Models", "仕事の節目"), "Work milestone")
        XCTAssertEqual(try english("Models", "実測"), "Timed")
        XCTAssertEqual(try english("Models", "自己申告"), "Self-reported")
        XCTAssertEqual(try english("Models", "抽選しない"), "No Draws")
        XCTAssertEqual(try english("Models", "リング＋時間"), "Ring + Time")
        XCTAssertEqual(try english("Models", "250gごとの抽選%lld回", 2), "2 draws (one per 250\u{00A0}g)")
        XCTAssertEqual(
            try english("Models", "250gごとの抽選%lld回（%@）", 3, "Standard 2 · Gold 1"),
            "3 draws (one per 250\u{00A0}g): Standard 2 · Gold 1"
        )
        XCTAssertEqual(
            try english("Models", "250gごとの抽選で金が%lld回続けて出なかった場合、次の抽選は金の粒になります。虹はこの回数をリセットしません。",
                        Constants.Gacha.pityMissCount),
            "If 20 draws in a row (one per 250\u{00A0}g) bring no gold, the next draw is a gold gem. A rainbow gem doesn’t reset this count."
        )
        XCTAssertEqual(try english("Models", "集中時間は1分から360分の範囲で指定してください。"), "Choose a focus length from 1 to 360\u{00A0}min.")
    }

    /// A number and its unit never break across lines ("(250 / g)" at AX5 on
    /// a 375 pt screen): the visible English values join them with U+00A0.
    /// VoiceOver-only values ("0 grams") keep an ordinary space.
    func testVisibleUnitsDoNotBreakFromTheirNumberInEnglish() throws {
        let bundle = try LocalizationTestSupport.englishBundle()
        XCTAssertEqual(MassText.grams(value: 250, bundle: bundle, locale: en), "250 g")
        XCTAssertEqual(
            TrialDropPresentation.meaning(bundle: bundle, locale: en),
            "25\u{00A0}min of focus = this gem (+250\u{00A0}g)"
        )
        XCTAssertEqual(
            try english("Onboarding", "%@の集中が、この一粒（%@）になります", "25 min", "250\u{00A0}g"),
            "25 min of focus becomes this gem (250\u{00A0}g)"
        )
        XCTAssertEqual(
            try english("Onboarding", "実測タイマーで250g積むごとに1抽選。端数は次回へ繰り越します。%@", ""),
            "One draw for every 250\u{00A0}g of timed focus. Any remainder carries over to next time. "
        )
        XCTAssertEqual(try english("Onboarding", "25・45・60・90分のタイマーは無料"), "25, 45, 60 and 90\u{00A0}min timers are free")
        XCTAssertEqual(
            try english("Paywall", "無料の25・45・60・90分のほか、%@を秒単位で選べます", "1–360 min"),
            "Besides the free 25, 45, 60 and 90\u{00A0}min timers, choose any length from 1–360 min, down to the second"
        )
        for table in ["Onboarding", "Paywall", "Models"] {
            let catalog = try LocalizationCatalogFile(table: table, relativePath: "PomoGem/Localization/\(table).xcstrings")
            for (key, entry) in catalog.strings where !(entry["comment"] as? String ?? "").hasPrefix("VoiceOver") {
                for unit in LocalizationCatalogFile.localizations(of: entry)["en"].map({ LocalizationCatalogFile.units(of: $0) }) ?? [] {
                    XCTAssertNil(
                        unit.value.range(of: #"\d (g|min)\b"#, options: .regularExpression),
                        "\(table): \(key) \(unit.label) splits a number from its unit: \(unit.value)"
                    )
                }
            }
        }
    }

    /// Every key this package owns has an English value (the strict check in
    /// CI says the same; this fails in the unit suite first).
    func testEveryKeyOfThisPackageHasEnglish() throws {
        _ = try LocalizationTestSupport.englishBundle()
        for table in ["Onboarding", "Paywall", "Models"] {
            let catalog = try LocalizationCatalogFile(table: table, relativePath: "PomoGem/Localization/\(table).xcstrings")
            XCTAssertFalse(catalog.strings.isEmpty, table)
            for (key, entry) in catalog.strings where entry["extractionState"] as? String != "stale" {
                let english = LocalizationCatalogFile.localizations(of: entry)["en"]
                XCTAssertNotNil(english, "\(table): \(key) has no English")
                for unit in english.map({ LocalizationCatalogFile.units(of: $0) }) ?? [] {
                    XCTAssertFalse(LocalizationTestSupport.containsJapanese(unit.value), "\(table): \(key) \(unit.label)")
                }
            }
        }
    }
}

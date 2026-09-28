import Foundation
import UserNotifications
import XCTest
@testable import PomoGem

/// English expectations for localization package l10n-02-focus-system: the
/// Focus, Notifications and ScreenTime tables and the App Shortcut phrases
/// (AppShortcuts.xcstrings). The widgets and the Live Activity moved to
/// l10n-01-home (HomeLocalizationTests).
///
/// Only that package edits this file (Docs/Localization.md). English is
/// resolved explicitly with `LocalizationTestSupport.englishBundle()` and
/// `LocalizationTestSupport.english`; the process stays Japanese, and the
/// Japanese of the same strings is pinned here too.
@MainActor
final class FocusSystemLocalizationTests: XCTestCase {
    private let en = LocalizationTestSupport.english
    private let ja = LocalizationTestSupport.japanese

    /// The English value of a key, formatted like the app formats it.
    private func english(_ key: String, table: String, _ arguments: CVarArg...) throws -> String {
        let bundle = try LocalizationTestSupport.englishBundle()
        let format = bundle.localizedString(forKey: key, value: "<missing \(key)>", table: table)
        return arguments.isEmpty ? format : String(format: format, locale: en, arguments: arguments)
    }

    // MARK: Japanese stays as it was

    func testJapaneseTimerCopyIsUnchanged() {
        XCTAssertEqual(PomodoroDuration.twentyFiveMinutes.displayLabel, "25分")
        XCTAssertEqual(PomodoroDuration.customSeconds(totalSeconds: 90).displayLabel, "1分30秒")
        XCTAssertEqual(PomodoroDuration.custom(minutes: 0).displayLabel, "設定できない時間")

        XCTAssertEqual(TimerRemainingSpeech.text(seconds: 1_500), "残り25分0秒")
        XCTAssertEqual(TimerRemainingSpeech.text(seconds: 59), "残り0分59秒")
        XCTAssertEqual(TimerRemainingSpeech.text(seconds: -5), "残り0分0秒")

        XCTAssertEqual(FocusDemotionNoticeReason.clockChanged.message, "端末時刻の大きな変化を検出。この回だけ自己申告あつかいです")
        XCTAssertEqual(FocusDemotionNoticeReason.unexplained.message, "この回は自己申告あつかいです")
        XCTAssertEqual(
            TimerDefaultOrientation.allCases.map(\.title),
            ["自動", "上（縦）", "右（横）", "下（縦・上下逆）", "左（横）"]
        )
        XCTAssertEqual(TimerOrientation.allCases.map(\.label), ["上", "右", "下", "左"])

        XCTAssertEqual(FocusLeaveNudgeCopy.title, "集中が切れています")
        XCTAssertEqual(
            FocusLeaveNudgeCopy.body(forNudgeAt: 0),
            "タイマーを一時停止しました。ポモジェムに戻ると続きから再開できます。"
        )
    }

    // MARK: Screen Time's stored errors (ledger data, mapped for display)

    func testTheLedgerKeepsStoringTheSameJapaneseBytes() throws {
        XCTAssertEqual(
            ScreenTimeStoredMonitoringError.authorizationRevoked,
            "スクリーンタイムの許可が解除されました。再び許可して、アプリを選び直してください。"
        )
        XCTAssertEqual(
            ScreenTimeStoredMonitoringError.monitoringFailed,
            "スクリーンタイムの監視を開始できませんでした。もう一度お試しください。"
        )

        var state = ScreenTimeState()
        state.configuration.enabled = true
        XCTAssertTrue(state.invalidateAuthorization())
        XCTAssertEqual(state.monitoringError, ScreenTimeStoredMonitoringError.authorizationRevoked)
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(state), encoding: .utf8))
        XCTAssertTrue(encoded.contains(ScreenTimeStoredMonitoringError.authorizationRevoked), "the ledger stores the Japanese sentence")
        let decoded = try JSONDecoder().decode(ScreenTimeState.self, from: Data(encoded.utf8))
        XCTAssertEqual(decoded.monitoringError, ScreenTimeStoredMonitoringError.authorizationRevoked)
    }

    func testStoredErrorsAreShownInTheAppsLanguage() throws {
        let bundle = try LocalizationTestSupport.englishBundle()
        func shown(_ stored: String, in language: Bundle, _ locale: Locale) -> String {
            ScreenTimeStoredMonitoringError.displayText(for: stored, bundle: language, locale: locale)
        }
        XCTAssertEqual(
            shown(ScreenTimeStoredMonitoringError.authorizationRevoked, in: bundle, en),
            "Screen Time access was turned off. Allow it again, then choose your apps again."
        )
        XCTAssertEqual(
            shown(ScreenTimeStoredMonitoringError.monitoringFailed, in: bundle, en),
            "Couldn't start Screen Time monitoring. Please try again."
        )
        // Japanese devices read exactly what the ledger holds.
        for stored in [ScreenTimeStoredMonitoringError.authorizationRevoked, ScreenTimeStoredMonitoringError.monitoringFailed] {
            XCTAssertEqual(ScreenTimeStoredMonitoringError.displayText(for: stored), stored)
        }
        // Anything else (the app's own errors, localized when published) passes through.
        for other in ["Please allow access to Screen Time.", "スクリーンタイムへのアクセスを許可してください。", ""] {
            XCTAssertEqual(shown(other, in: bundle, en), other)
        }
    }

    // MARK: Notifications

    func testDailyReminderSaysWhatSettingsShowsAsItsExample() async throws {
        let recorder = PassiveRequestRecorder()
        try await recorder.makeManager().synchronizePassiveNotifications(
            dailyReminderEnabled: true, wrappedEnabled: false,
            hour: 20, minute: 0, playsSound: false,
            now: Date(timeIntervalSince1970: 1_790_000_000),
            calendar: Calendar(identifier: .gregorian)
        )
        XCTAssertFalse(recorder.requests.isEmpty)
        for request in recorder.requests {
            XCTAssertEqual(request.content.body, Constants.UIStrings.eveningNotification)
            XCTAssertEqual(request.content.title, "ポモジェム")
        }
        // One sentence, one catalog: the body is Common's key, never a Notifications copy.
        let notifications = try LocalizationCatalogFile(
            table: "Notifications", relativePath: "PomoGem/Localization/Notifications.xcstrings"
        )
        XCTAssertNil(notifications.strings["瓶が待ってる。今日のひと粒、積んでいく？"])
        let common = try LocalizationTestSupport.englishBundle()
            .localizedString(forKey: "瓶が待ってる。今日のひと粒、積んでいく？", value: nil, table: "Common")
        XCTAssertEqual(common, "Your jar is here whenever you're ready. Add a gem today?")
    }

    func testNotificationsInEnglish() throws {
        XCTAssertEqual(try english("集中時間が終わりました。おつかれさまでした。", table: "Notifications"), "Your focus time is over. Nice work.")
        XCTAssertEqual(
            try english("休憩はここまで。次の一粒へ、ゆっくり戻りましょう。", table: "Notifications"),
            "Break's over. Ease back in toward your next gem."
        )
        XCTAssertEqual(
            try english("先月の瓶ができた。積み上がりを眺めよう。", table: "Notifications"),
            "Last month's jar is ready. Take a look at your progress."
        )
        XCTAssertEqual(try english("集中が切れています", table: "Notifications"), "Focus paused")
        XCTAssertEqual(
            try english("一時停止して%@たちました。戻れば続きから再開できます。", table: "Notifications",
                        DurationText.short(minutes: 5, locale: en)),
            "Paused for 5 min. Come back any time to pick up where you left off."
        )
        XCTAssertEqual(try english("ポモジェム", table: "Common"), "PomoGem", "the notification title")
    }

    // MARK: Timers

    func testTimerSpeechAndRingInEnglish() throws {
        let bundle = try LocalizationTestSupport.englishBundle()
        XCTAssertEqual(TimerRemainingSpeech.text(seconds: 1_500, bundle: bundle, locale: en), "25 minutes, 0 seconds left")
        XCTAssertEqual(TimerRemainingSpeech.text(seconds: 61, bundle: bundle, locale: en), "1 minute, 1 second left")
        XCTAssertEqual(TimerRemainingSpeech.text(seconds: 0, bundle: bundle, locale: en), "0 minutes, 0 seconds left")

        let focusMode = "FOCUS"
        XCTAssertEqual(
            String(localized: "\(focusMode)  ·  \(42)% 残り", table: "Focus", bundle: bundle, locale: en),
            "FOCUS  ·  42% left"
        )
        XCTAssertEqual(String(localized: "\(7)% 残り", table: "Focus", bundle: bundle, locale: en), "7% left")
        XCTAssertEqual(try english("focus.ring.mode.paused", table: "Focus"), "PAUSED")
        XCTAssertEqual(try english("focus.header.paused", table: "Focus"), "Paused")
        XCTAssertEqual(try english("timer.rotation.automatic", table: "Focus"), "Auto")
        XCTAssertEqual(try english("自動", table: "Focus"), "Automatic")

        let length = DurationText.short(seconds: 25 * 60, units: .minutesSeconds, locale: en)
        XCTAssertEqual(String(localized: "\(length)集中", table: "Focus", bundle: bundle, locale: en), "Focus · 25 min")
        XCTAssertEqual(DurationText.short(seconds: 90, units: .minutesSeconds, locale: en), "1 min 30 sec")

        let remaining = TimerRemainingSpeech.text(seconds: 1_499, bundle: bundle, locale: en)
        XCTAssertEqual(
            String(localized: "\(remaining)、\(98)パーセント残り、一時停止中", table: "Focus", bundle: bundle, locale: en),
            "24 minutes, 59 seconds left, 98 percent remaining, paused"
        )
        XCTAssertEqual(try english("5分休憩", table: "Focus"), "5-Min Break")
        XCTAssertEqual(try english("休憩をスキップ", table: "Focus"), "Skip Break")
        XCTAssertEqual(try english("瓶へ戻る", table: "Focus"), "Back to Jar")
        XCTAssertEqual(try english("集中を完走しました", table: "Focus"), "Focus Complete")
        XCTAssertEqual(
            try english("この回の粒は積まれません。これまでの瓶はそのままです。", table: "Focus"),
            "This session won't add a gem. Everything already in your jar stays."
        )
        XCTAssertEqual(
            try english("画面を離れたので、この回は自己申告あつかいになった", table: "Common"),
            "You left the screen, so this session counts as self-reported."
        )
        XCTAssertEqual(
            try english("集中が完了しました。%@、%@を保存しています", table: "Focus", "Math", MassText.spoken(grams: 250, locale: en)),
            "Focus complete. Saving 250 grams to Math."
        )
    }

    func testAppIntentsInEnglish() throws {
        XCTAssertEqual(try english("集中を始める", table: "Focus"), "Start Focus")
        XCTAssertEqual(try english("集中時間", table: "Focus"), "Focus Length")
        XCTAssertEqual(try ["25分", "45分", "60分", "90分"].map { try english($0, table: "Focus") },
                       ["25 minutes", "45 minutes", "60 minutes", "90 minutes"])
    }

    /// Every App Shortcut phrase must name the app, or Siri never offers it.
    func testAppShortcutPhrasesNameTheAppInBothLanguages() throws {
        let catalog = try LocalizationCatalogFile(table: "AppShortcuts", relativePath: "PomoGem/Localization/AppShortcuts.xcstrings")
        let entry = try XCTUnwrap(catalog.strings["${applicationName}で集中を始める"])
        let localizations = LocalizationCatalogFile.localizations(of: entry)
        func phrases(_ language: String) throws -> [String] {
            let set = try XCTUnwrap(localizations[language]?["stringSet"] as? [String: Any], language)
            return try XCTUnwrap(set["values"] as? [String], language)
        }
        XCTAssertEqual(try phrases("ja"), [
            "${applicationName}で集中を始める",
            "${applicationName}で集中する",
            "${applicationName}で${length}集中する",
            "${applicationName}でポモドーロを始める"
        ])
        let english = try phrases("en")
        // The compiled sets are indexed (#!SET#!_key[i]); ja.lproj must hold every index en.lproj does.
        XCTAssertEqual(english.count, try phrases("ja").count)
        XCTAssertTrue(english.contains("Start focus in ${applicationName}"))
        XCTAssertTrue(english.contains("Focus for ${length} with ${applicationName}"))
        for phrase in english {
            XCTAssertTrue(phrase.contains("${applicationName}"), phrase)
            XCTAssertFalse(LocalizationTestSupport.containsJapanese(phrase), phrase)
        }
    }

    // MARK: Screen Time

    func testScreenTimeCountsInEnglish() throws {
        let bundle = try LocalizationTestSupport.englishBundle()
        func selected(_ count: Int) -> String {
            String(localized: "\(count)アプリ選択中", table: "ScreenTime", bundle: bundle, locale: en)
        }
        XCTAssertEqual(selected(1), "1 app selected")
        XCTAssertEqual(selected(3), "3 apps selected")
        XCTAssertEqual(String(localized: "\(1)アプリ", table: "ScreenTime", bundle: bundle, locale: en), "1 app")
        XCTAssertEqual(String(localized: "\(4)アプリ・無制限", table: "ScreenTime", bundle: bundle, locale: en), "4 apps · no limit")
        XCTAssertEqual(String(localized: "\(3) / 5アプリ", table: "ScreenTime", bundle: bundle, locale: en), "3 / 5 apps")
        XCTAssertEqual(String(localized: "\(1_234)分", table: "ScreenTime", bundle: bundle, locale: en), "1,234 min")
        XCTAssertEqual(
            String(localized: "控えたいアプリが\(51)個あります。集中中に開けないようにできるのは50個までなので、いまは制限していません。",
                   table: "ScreenTime", bundle: bundle, locale: en),
            "You have 51 apps you want to use less. Only up to 50 can be blocked during focus, so none are blocked for now."
        )
        XCTAssertEqual(try english("スクリーンタイムへのアクセスを許可してください。", table: "ScreenTime"), "Please allow access to Screen Time.")
        XCTAssertEqual(try english("集中中は気が散るアプリを開けないようにする", table: "ScreenTime"), "Block Distracting Apps During Focus")
    }

    func testScreenTimeArrivalToastsInBothLanguages() throws {
        let bundle = try LocalizationTestSupport.englishBundle()
        var one = ScreenTimeArrivalTally()
        one.addLearning(subjectName: "Math")
        XCTAssertEqual(one.localizedMessage(bundle: bundle, locale: en), "Screen Time: Math +10 min (1 gem)")
        one.addLearning(subjectName: "Math")
        one.addLearning(subjectName: "Math")
        XCTAssertEqual(one.localizedMessage(bundle: bundle, locale: en), "Screen Time: Math +30 min (3 gems)")
        one.addBlackStones(1)
        XCTAssertEqual(one.localizedMessage(bundle: bundle, locale: en), "Screen Time: Math +30 min (3 gems), +1 black stone")

        var several = ScreenTimeArrivalTally()
        several.addLearning(subjectName: "Math")
        several.addLearning(subjectName: "Science")
        several.addBlackStones(2)
        XCTAssertEqual(several.localizedMessage(bundle: bundle, locale: en), "Screen Time: study apps +20 min (2 gems), +2 black stones")

        var stones = ScreenTimeArrivalTally()
        stones.addBlackStones(1)
        XCTAssertEqual(
            stones.localizedMessage(bundle: bundle, locale: en),
            "Screen Time: +1 black stone (10 min in apps you want to use less)"
        )
        XCTAssertEqual(stones.message, "スクリーンタイム：黒い石 +1（控えたいアプリ 10分）", "Japanese as before")
        var many = ScreenTimeArrivalTally()
        many.addBlackStones(Int.max)
        XCTAssertEqual(many.localizedMessage(bundle: bundle, locale: en), "Screen Time: +\(Int.max.formatted(.number.locale(en))) black stones")
        XCTAssertEqual(several.message, "スクリーンタイム：勉強アプリの時間 +20分（2粒）、黒い石 +2")
    }

    // MARK: Whole tables

    /// Every key of this package's tables resolves to English on an English
    /// device, with no Japanese left in it.
    func testEveryKeyOfThePackageReadsInEnglish() throws {
        let bundle = try LocalizationTestSupport.englishBundle()
        let tables = [
            "Focus": "PomoGem/Localization/Focus.xcstrings",
            "Notifications": "PomoGem/Localization/Notifications.xcstrings",
            "ScreenTime": "PomoGem/Localization/ScreenTime.xcstrings"
        ]
        for (table, path) in tables.sorted(by: { $0.key < $1.key }) {
            let catalog = try LocalizationCatalogFile(table: table, relativePath: path)
            XCTAssertFalse(catalog.strings.isEmpty, table)
            for key in catalog.strings.keys {
                let value = bundle.localizedString(forKey: key, value: "<missing>", table: table)
                XCTAssertNotEqual(value, "<missing>", "\(table): \(key)")
                XCTAssertFalse(LocalizationTestSupport.containsJapanese(value), "\(table): \(key) -> \(value)")
            }
        }
    }
}

/// Collects what the passive schedule books, without touching the real
/// notification center.
@MainActor
private final class PassiveRequestRecorder {
    private(set) var pending: [String: UNNotificationRequest] = [:]

    var requests: [UNNotificationRequest] {
        pending.values.sorted { $0.identifier < $1.identifier }
    }

    func makeManager() -> NotificationManager {
        let client = NotificationRequestClient(
            add: { self.pending[$0.identifier] = $0 },
            pending: { Array(self.pending.values) },
            removePending: { ids in for id in ids { self.pending.removeValue(forKey: id) } }
        )
        return NotificationManager(
            requestClient: client,
            focusReturnReminderClient: FocusReturnReminderNotificationClient(
                authorizationStatus: { .authorized }, add: client.add,
                removePending: client.removePending, removeDelivered: { _ in }
            )
        )
    }
}

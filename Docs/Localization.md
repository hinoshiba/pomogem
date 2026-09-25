# ローカライズ（多言語化）の決まり

状態: 基盤のみ（2026-09-25）。アプリは今も日本語だけで出荷しています。
英語は、各画面の翻訳がそろった時点で専用の統合ブランチから有効化します（「英語を有効にする手順」）。
それまで`main`のどの変更でも、日本語の表示を1文字も変えずに出荷できる状態を保ちます。

## 原則

- 開発言語は日本語です。String Catalog（`.xcstrings`）の`sourceLanguage`は`ja`、キーは日本語の原文そのものです。
  翻訳がない言語ではキーがそのまま表示されるため、日本語の表示はcatalogの中身に左右されません。
- テーブル（catalog）は**文字列を書いたファイル**で決まります。表示される画面では決まりません。
  対応は`Scripts/l10n/table-map.json`の`rules`で、上から順に最初に一致した規則を使います。
  例: `AchievementKind.title`は`Models.swift`にあるので、記録画面に出ても`Models`テーブルです。
- 既定の`Localizable`テーブルは使いません。`Localizable.xcstrings`は作らず、`table:`のない文字列を検出できる状態にします。
- `Common`は共有の単位・区切り・共通ボタン用です。キーを追加できるのは基盤（infra）の変更だけです。
  ほかのファイルは既存の`Common`キーを使えますが、新しい文言は自分のテーブルへ書きます。
- 保存・同期するデータは翻訳しません。プリセットのテーマ名、`Stratum.monthLabel`、「過去の集中」、
  スクリーンタイムの`monitoringError`などはこれまでどおり日本語で保存し、表示するときに対応づけます。
  `localizedDescription`や翻訳済みの文をSwiftData、CloudKit、App Groupへ書きません。
- アクセシビリティ識別子（`accessibilityIdentifier`）は翻訳しません。ASCIIの定数のままにします。

## 書き方

`table:`と`tableName:`には必ず文字列リテラルを渡します。変数を渡すとコンパイラがキーを抽出できません。

| 今 | ローカライズ後 |
|---|---|
| `Text("集中する")` | `Text("集中する", tableName: "Home")` |
| `Text("\(n)粒")` | `Text("\(n)粒", tableName: "Home", comment: "Gem count")`（キーは`%lld粒`） |
| `Button("閉じる") { … }` | `Button(String(localized: "閉じる", table: "Home")) { … }` |
| `Label`・`Toggle`・`Picker`・`Section`・`TextField`のタイトル | `String(localized: "…", table: "X")`を渡す |
| `.navigationTitle("記録")` | `.navigationTitle(Text("記録", tableName: "Log"))` |
| `.accessibilityLabel("…")` | `.accessibilityLabel(Text("…", tableName: "Jar"))` |
| `var title: String { … "深夜" … }`、`static let` | `String(localized: "深夜", table: "Common", comment: "…")` |
| `LocalizedError.errorDescription` | `String(localized: "…", table: "Storage")` |
| ウィジェットの`.configurationDisplayName("…")` | `.configurationDisplayName(Text("…", tableName: "Widgets"))` |
| 利用者が入力した文字列、数値、コード | 翻訳しない。`Text(verbatim:)`か`Text(someString)` |

- `String`型のAPIはそのまま`String`で受け、リテラルの場所で`String(localized:table:comment:)`にします。
  関数の型を変えると、ほかのパッケージの呼び出し側まで直すことになります。
- 1つの文は1つの書式文字列にします。翻訳済みの断片を`+`や`「、」「。」「・」`でつなぎません。
  英語で語順が変わるときは`%1$@`、`%2$lld`の位置指定を使います。
- 数えるものは`Int`をそのまま埋め込みます（`"\(count)粒"` → `%lld粒`）。英語の単数・複数はcatalogの
  plural variationで分けます。`count.formatted()`を埋め込むと`%@`になり、複数形を付けられません。
- 西暦を`Int`で埋め込んではいけません。`"\(2026)年"`は「2,026年」になります。`DateText`を使います。
- `comment:`が必要なのは、4文字以下の文字列、プレースホルダを含む文字列（引数の意味を書く）、
  VoiceOverだけで読まれる文字列（「VoiceOver」と書く）です。
- 同じ日本語に別の英語が必要なときだけ、意味のあるキーと`defaultValue:`を使います:
  `String(localized: "home.menu.metric.focus", defaultValue: "集中", table: "Home", comment: "…")`
- 空文字列は`defaultValue:`にも翻訳にも使えません。値が空だとFoundationはキーそのものを返します。
  言語によって空になる区切りは`SentenceText`のように言語で分けます。

## 数・単位・日付（`Shared/LocalizedDuration.swift`、`PomoGem/Core/Localization/LocalizedFormat.swift`）

| helper | 日本語（今と同じ） | 英語 |
|---|---|---|
| `DurationText.short(seconds:units:)` | 30秒・25分・1分30秒・1時間15分・1,234時間 | 30 sec · 25 min · 1 hr 15 min |
| `DurationText.short(minutes:)` | 0分・25分・1時間15分 | 25 min |
| `DurationText.spoken(…)` | shortと同じ | 1 hour, 15 minutes |
| `MassText.grams(_:)`・`kilograms(_:)` | 250g・2.5kg（数値は各画面が今の書式で渡す） | 250 g · 2.5 kg |
| `MassText.spoken(grams:)`・`spoken(kilograms:fractionDigits:)` | 250グラム・2.5キログラム | 250 grams · 2.5 kilograms |
| `DateText.yearMonth`・`year`・`monthDay`・`longDate` | 2026年9月・2026年・9月24日・2026年9月24日 | September 2026 · 2026 · Sep 24 · September 24, 2026 |
| `ListText.compact`・`inSentence` | 通常3・金1／英語、数学、理科 | Standard 3 · Gold 1／English, Math, and Science |
| `SentenceText.join` | 文と文の間に何も入れない | 1文字の空白 |
| `CountText.gems(_:)` | 3粒・12,345粒 | 1 gem · 3 gems |

- `PomoGemLocale`と`DurationText`は`Shared/LocalizedDuration.swift`にあり、appとwidget extension
  （ウィジェットとLive Activity）の両方でコンパイルされます。ほかのhelper（`MassText`・`DateText`・`ListText`・
  `SentenceText`・`CountText`、`PomoGemCalendar`）はappだけです。widgetやLive Activityで必要になったら、
  自分で書式を組み立てず、基盤（infra）の変更で`Shared/`へ移します（`project.yml`を編集できるのは基盤と統合だけです）。
  widgetのbundleには`Common`テーブルがないため、`Shared/`のhelperにはcatalogのキーを置きません。
- helperは既定で`PomoGemLocale.current`（文字列を表示している言語＋利用者の地域）で書式を決めます。
  日本語と英語の2言語になると、韓国語のiPhoneでは文字列は日本語（開発地域）なのに`Locale.current`は
  en_KRになります（iOS 26.5 Simulatorで確認）。`Locale.current`で書式を決めると、日本語の画面に
  「Sep 2026」「25 min」が混ざります。日本語だけの今は`Locale.current`と同じ結果です（ja_KR、ja_USなど）。
- 時間と読み上げ用の質量の日本語は、ICUに頼らずコードで組み立てます。単位の前後の空白はiOSの版で
  変わりうるICUデータに依存し、ここでは最新のSimulatorしか試せないためです。英語はFoundationの書式を使います。
- `DurationText.Units`で単位を選びます。タイマーの長さは`.minutesSeconds`（90分）、
  積み上がりの合計は`.hoursMinutes`です。端数は切り捨て、0は最小の単位（「0秒」「0分」）で表します。
  Live Activityの`FocusActivityConstants.durationLabel(seconds: 0)`だけは今「0分」を返すので、置き換えるときに確認してください
  （`Shared/FocusActivityAttributes.swift`はwidget extensionでもコンパイルされ、`DurationText`をそのまま使えます）。
- `CountText`と`MassText.spoken`は桁区切りを入れます（1,234）。1,000未満は今の表示と同じです。
  今1,000以上を区切らずに表示している画面は、置き換えで「1234粒」が「1,234粒」になる点を確認してください。
- 月や年の区切り（`StrataMath.monthLabel`、`FairnessPolicy`）はグレゴリオ暦です。そのラベルは`DateText`で
  `PomoGemCalendar.gregorian`に固定します。和暦に設定したiPhoneでも「令和8年9月」ではなく「2026年9月」になります。
  それ以外の日付は、これまでどおり利用者の暦で`Date.FormatStyle`を使います。
- 書式の結果はテスト（`LocalizationFormattingTests`）で今の手書きの文字列と照合しています。

## 意図的な例外: `// l10n-ignore:`

保存済みデータとの比較や過去の値など、翻訳してはいけない日本語リテラルには理由を付けます。

```swift
// l10n-ignore: 1.0.2が保存したテーマ名と比較する
if subject.name == "英語" { … }
Text("…") // l10n-ignore: 理由
// l10n-ignore-begin: 理由
…
// l10n-ignore-end
```

`#if DEBUG`の中、`#Preview`、`print`や`Logger`の文字列は最初から対象外です。

## ツール（`Scripts/l10n/l10n.py`）

| コマンド | 用途 |
|---|---|
| `status` | catalogごとのキー数と翻訳の状態 |
| `sync --derived-data <DD>` | ビルドで出力された`.stringsdata`を全catalogへ反映（Xcodeの`xcodebuild`は自動では反映しません） |
| `check [--strict] [--derived-data <DD>] [--tables A,B]` | catalog・コード・UIテストの検査 |
| `report [--package ID \| --table T \| --file F]` | まだローカライズしていない日本語リテラルの一覧 |
| `set --table T --from en.json` | 翻訳をまとめて書き込む（JSONかTSV） |
| `carry --table T --from 旧キー --to 新キー` | 日本語を直したとき、英語を新しいキーへ移して`needs_review`にする |
| `format [--check]` | catalogをXcodeと同じJSONの並びに整える |
| `verify-bundle <PomoGem.app>` | appと2つの拡張に、出荷する言語の`.lproj`がちょうどあるか |

catalogの同期は必ず全テーブルまとめて行います（一部だけだと、ほかのテーブルのキーが古いと判定されます）。
同期の後、`git status`で自分のcatalogだけが変わっていることを確認します。

`set`の入力形式:

```json
{
  "集中する": "Focus",
  "%lld粒": {"plural": {"one": "%lld gem", "other": "%lld gems"}}
}
```

### `check`の2つのモード

`--strict`なしの`check`は途中経過の報告です。今の時点で明らかに誤りのものだけで失敗します。

| いつも失敗 | `--strict`（または英語の値がある表）で失敗 |
|---|---|
| catalogの破損・`sourceLanguage`違い、表にないcatalog、`Localizable.xcstrings`、`.lproj`/`.strings` | 未ローカライズの日本語リテラル |
| 出荷言語にない言語の値（例: 有効化前の英語） | 英語の欠落、`needs_review`・`new`・`stale` |
| 英語の中の日本語、引数の不一致、`other`のない複数形、SwiftUIが解釈するMarkdown | テーブルとファイルの対応違い、`Common`への新規キー |
| InfoPlist catalogとInfo.plistの日本語の不一致 | catalogとコードのずれ（`sync`忘れ）、既定テーブルへ行く文字列 |
| `table:`が文字列リテラルでない、識別子の翻訳 | 用語集の必須語、`streak`などの禁止語 |
| 言語を固定せずに起動するUIテスト、ビルド出力がない・別のcheckoutのもの | `-AppleLanguages`の直書き、テーブル未割り当てのファイル |

英語の値が1つでも入ったテーブルは、そのテーブルのファイルが自動的に厳格な検査の対象になります。

## テスト

- unit testとUI testは日本語で実行します。schemeのtest actionは言語`ja`・地域`JP`に固定し、CIでも
  `-testLanguage ja -testRegion JP`を渡します。`LocalizationEnvironmentTests.testHostRunsInJapanese`が、
  固定が外れたときに直し方を示して失敗します。
- UI testのすべての起動は`PomoGemUITestLanguage.configureJapanese(app)`を通します（実機用の2つのsuiteも同じ）。
  `l10n.py check`が、言語を固定しない起動を検出します。
- `LocalizationCatalogTests`はcatalogのsourceを直接読み、構成・InfoPlistの日本語・出荷言語以外の値・翻訳の形を検査します。
- 英語の期待値は`PomoGemTests/Localization/<パッケージ>LocalizationTests.swift`に書きます。各パッケージは自分の
  ファイルだけを編集します。英語は`LocalizationTestSupport.englishBundle()`と`LocalizationTestSupport.english`で
  明示的に解決し、プロセスの言語は変えません。英語の有効化前は自動でskipします。

## CI

- `Scripts/check-oss-readiness.sh`: `Scripts/l10n/test-l10n.py`（ツール自身のテスト）と`l10n.py check`（静的検査）。
- unit testの後: `l10n.py check --derived-data DerivedData-CI-Tests`（コンパイラが抽出したキーとcatalogの照合）。
- Release build: `l10n.py verify-bundle`。今は3つのbundleすべてに`ja.lproj`があり、`en.lproj`がないことを確認します。
  `Scripts/verify-release-archive.sh`も同じ検査をarchiveに行います。

## 英語を有効にする手順（統合ブランチ）

1. 3つのInfoPlist catalogへ英語を入れる: `CFBundleDisplayName`（PomoGem／PomoGem Screen Time）、
   `NSMotionUsageDescription`、`NSPhotoLibraryAddUsageDescription`。Info.plist自体は日本語のままです。
2. `Scripts/l10n/table-map.json`の`shipping_languages`へ`"en"`を加え、`xcodegen generate`で`knownRegions`に`en`が入ることを確認する。
3. 第3の言語（韓国語など）の扱いを決め、Simulatorの`-AppleLanguages (ko-KR) -AppleLocale ko_KR`で確認する。
   開発地域が`ja`のままだと、日本語・英語のどちらも持たない端末には日本語が出ます。英語に倒す場合は、
   3つのtargetのbuild setting `DEVELOPMENT_LANGUAGE`を`en`にします。Info.plistの`CFBundleDevelopmentRegion`を
   直接書き換えても、buildが`$(DEVELOPMENT_LANGUAGE)`の値で上書きします（2026-09-25にprobe appで確認:
   韓国語・中国語の端末は英語の文字列とen_KR／en_CNの書式になる）。catalogの`sourceLanguage`とキーは日本語のままです。
4. 各パッケージが自分のテーブルへ英語を入れる（`sync` → `set` → `check --tables`）。
5. 統合: CIを`check --strict`にし、英語のsmoke UI test（`PomoGemUITestLanguage`に英語の起動を追加）、
   英語のスクリーンショット、App Storeの英語資料、README・サイトの対応言語を更新する。

## 用語と文体

英語の用語・大文字小文字・単位・句読点は`Scripts/l10n/glossary.json`にまとめています。
製品の文体（急かさない、責めない、連続記録を求めない）は`Docs/EngagementArchitecture.md`に従います。

## 基盤の後に残した作業

- `Theme.swift`、`Constants.swift`、`PomoGemLogo.swift`の文言を`Common`へ移す（機能ごとの作業と同時に行う）。
- 共有の時間表示`DurationPresentation`ができたら、`DurationText`の上に載せ替える。
- `AppLinks`に英語版ページ（`?lang=en`）の切り替えを加える。`POMOGEM_PRIVACY_POLICY_URL`は変えません。
- `table-map.json`の規則にまだ入っていないファイル（`l10n.py check`が「unassigned」と表示）のテーブルを決める。

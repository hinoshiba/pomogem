# ポモジェム公式版 — ローカルArchive／App Storeリリース手順

更新日: 2026-09-22

この手順は、許可済みMacのXcode OrganizerからiPhone版をArchive、Validate、Uploadするための
正本です。Mac／Mac Catalyst版は作成しません。

## 既存の自動配布設定を確認（移行時のみ）

以前のXcode Cloudワークフローが存在する場合は、次のリリース前にXcodeまたは
App Store Connectで無効化し、ブランチ・タグの変更によるビルドや自動配布が
開始されないことを確認します。リポジトリ内のフック削除だけでは、サーバー側の
設定は変わりません。既存の実行履歴と成果物は保持し、確認結果を非公開の
リリース記録へ残します。

## 現行候補: 1.1.0 (10)

公開中の1.0.2 (9)とは別に、Screen Timeと起動・オフライン・iCloud再取得の修正を統合した
1.1.0 (10)を準備します。App Store Connectの1.1.0 draft作成はbinaryのupload・審査提出を意味しません。
状態・Archive元・検証結果の正本は[1.1.0 (10) release record](../AppStore/release-record-1.1.0-10.md)、
未完了項目は[submission-checklist](../AppStore/submission-checklist.md)と
[configuration.yml](../AppStore/configuration.yml)です。

署名・配布検証の対象は次の3 bundleです。Widgetだけを確認した過去の配布証拠は流用しません。

| Bundle | 配布用の確認 |
|---|---|
| `com.hinoshiba.pomogem` | CloudKit Production／APNs Production、Family Controls、共有App Group、Time Sensitive Notifications（集中・休憩の終了通知だけ） |
| `com.hinoshiba.pomogem.widgets` | account-neutralなWidget／Live Activity。Family Controls、App Group、CloudKit、APNsなし |
| `com.hinoshiba.pomogem.screentimemonitor` | Device Activity Monitor拡張、Family Controls、本体と同じ共有App Group。CloudKit／APNsなし |

共有先は`group.com.hinoshiba.pomogem`です。本体・MonitorそれぞれについてApple側のFamily Controls
**distribution**権限とprofileを確認し、最終Archive、export IPA、実際のupload payloadの全3 bundleを
`Scripts/verify-release-archive.sh`で検証します。開発用profileの成功を配布承認として扱いません。
現在確認できているローカルdistribution profileにはFamily Controlsがなく、配布準備は未完了です。
秘密鍵や新しい署名identityの生成・exportは、この機能の通常手順に含めません。

Screen Timeは任意の個人認証・10分刻みです。勉強アプリは無料5つ／Pro無制限、黒い石側は無料でも
無制限で学習集計・共有へ混ぜません。iCloud中の再取得は事前読取と端末data削除の明示確認を要し、
端末dataによるiCloud全体の置き換えと復旧再開は引き続き無効です。
2026-09-21の開発署名Releaseでは修正後の到達4件／4件と両レーンの付与を確認した履歴がありますが、
配布署名候補の合格や未試験の境界条件へ拡張しません。現在の作業では実機試験を追加していません。

下記1.0〜1.0.2の提出日時・2 bundleでの検証・初回登録は履歴です。共通の手順を再実行する際も、
version／build／target／公開機能は現在の`project.yml`と上記3 bundleに従い、旧候補の固定値を使いません。

## 過去の候補と識別子（2026-09-13時点）

2026-09-13時点の最新提出候補はPomoGem 1.0.2 (9)でした。build 8までのiCloud修正とProタイマーの分・秒指定に、
視差効果設定に関係なく粒を同じように跳ねさせる修正を加えました。PR #13のmerge commit
`9c256136f7b9d4190da5800723acec0273bd6b27`をcleanな状態でArchiveし、2026-09-13 11:14 JSTに成功しました。
Apple Validateは11:16 JSTに成功し、別途exportしたIPAと実際のupload-staging IPAの厳格な配布検証、
元ArchiveとdSYMのUUID照合も成功しました。Organizerで11:22 JSTの「PomoGem 1.0.2 (9) uploaded」を
確認した後、同じArchive元を指す不変tag `v1.0.2-build9`を作成・pushしました。
Prefs追加2属性は同日11:33 JSTにCloudKit ConsoleのDevelopment/Production両環境で型・indexの
一致を確認しました。Production Historyの同日09:52 JSTの2 field変更・5 index作成により、
確認前に配備されていたことを照合しています。この作業ではschemaを変更・再配備していません。
11:34 JSTにbuild 9の処理完了と提出準備状態を確認し、審査待ちだったbuild 8の提出を取り消して
build 9へ差し替えました。日本語・英語の更新内容、Review Notes、選択ビルドの保存・再読込照合後、
11:39 JSTに審査へ提出しました。提出受付画面でiOS 1.0.2 (9)の「審査待ち」と提出日時を確認しています。
承認後の自動公開と全利用者への即時配信は維持しています。承認や公開完了を示すものではありません。
当時の提出状態は`AppStore/release-record-1.0.2-9.md`を参照してください。2026-09-22にはConnectでReady for Distributionを確認しています。

一つ前のupload済み版はPomoGem 1.0.2 (8)です。Organizerで同日10:01 JSTのupload履歴を確認したため、
今回のbuild numberを9へ増やしました。build 8の同日10:11 JSTの審査提出はbuild 9への差し替えのため
取り消し、「デベロッパにより却下済み」を確認しました。build 8の確認と準備履歴は
`AppStore/release-record-1.0.2-8.md`に保持します。2026-09-13にApp Store Connectで
1.0.1 (7)の「配信準備完了」を確認しました。1.0 (5)と同じApp Store record、Bundle ID、IAP、
CloudKit containerを使用します。Apple IDは`6809139517`、SKUは`pomogem-ios`、
登録名は「ポモジェム：ポモドーロタイマー」です。初回登録・提出結果は
`AppStore/release-record-1.0-5.md`、build 6のupload・取消履歴は
`AppStore/release-record-1.0.1-6.md`、build 7の準備・検証・提出履歴は
`AppStore/release-record-1.0.1-7.md`を参照します。
build 6は実機監査で記録保護の問題を再現したため審査を取り消し、App Store Connectで
「デベロッパにより却下済み」を確認しました。build 7は固定commit
`e4aee83b5e70aa9ae078ff37ad90626bb8becc97`からArchiveし、配布payloadの検証とApple Validateに合格、
Organizerのupload時刻は2026-09-12 11:56 JST、完了表示の確認は11:57 JSTです。upload後に
`v1.0.1-build7`を作成・pushし、上記Archive元を指すことを確認しました。後続の記録更新・merge・機能追加の
commitとArchive元を区別し、このtagを移動しません。
利用者の並列提出指示に従い、処理済みbuild 7を選択し、ja-JP／en-USの更新内容とReview Notesを
保存・再読込で照合して2026-09-12 16:26 JSTに審査へ提出しました。
提出IDは`7f746a75-2605-47c5-83d5-48ee76b40b2c`で、提出時に1.0.1 (7)の「審査待ち」を確認しました。
SettingsのiCloud切り替えと後続のオフライン修正は、このbuild 7には含みません。
公開Privacyの更新はGitHub Actionsの支払い／上限エラーで未配信のままです。
登録済みでも公開前は`app_store_listing_status: not_public`を保持し、Webは「近日公開」のまま
Smart App Bannerを表示しません。実際に公開・ダウンロード可能になってからstatusを`public`へ変更し、
同じ数値IDのSmart App Bannerを追加して検証します。
旧製品のbuild、審査画像、StoreKit商品、CloudKit配布状態は新候補の合格証拠に使いません。
履歴は`Docs/LEGACY_RELEASE_PROVENANCE.md`へ隔離し、未完了項目の正本は
`AppStore/configuration.yml`の`release_blockers`に保持します。

名称変更前の別Bundle ID製品から、保存データや購入権利を自動移行・共有しません。
1.0から1.0.1、1.0.2への更新は同じBundle IDを使用します。
既存のapp record、IAP、CloudKit container、production dataを削除・resetする工程はありません。

## 1. 安全境界

- 公式archiveはmaintainerの許可済みMacとApple Developer teamでのみ作成する
- automatic signingを使い、秘密鍵と証明書はKeychain、profileはXcode管理に置く
- `.p12`、`.p8`、profile、Keychain、certificate fingerprint、password、API key、
  `ExportOptions*.plist`、`.xcarchive`、`.ipa`をリポジトリ、issue、PR、GitHub Releaseへ置かない
- App Store候補はGitの固定commitから作り、upload後に同じcommitへ不変tagを付ける
- version/buildを再利用しない。修正uploadはbuild numberを増やす
- `Docs/LICENSE_AUDIT.md`のrights／provenance確認とcommercial release gateを同じcommitで完了する

Appleは2026年4月28日以降、App Store ConnectへuploadするappをXcode 26以降とiOS 26 SDKで
buildするよう求めています。開始時に[Upcoming Requirements](https://developer.apple.com/news/upcoming-requirements/)
を再確認します。

## 2. App Store Connectを先に整える

初回upload前にApp Store Connectのapp recordが必要です。今回のrecordは`6809139517`として作成済みです。
以下の価格、提供地域、IAP、配布、公開設定は、record作成とは別に確認します。

1. Bundle ID `com.hinoshiba.pomogem`、iCloud/CloudKit、Push Notifications、
   In-App Purchaseのcapabilityが同じteamにある
2. Widget bundle `com.hinoshiba.pomogem.widgets`は登録するが、Version 1.0ではApp Group、iCloud、
   CloudKit、APNs capabilityを付けない。account-neutralな起動導線だけを表示する
3. `com.hinoshiba.pomogem.pro.lifetime`をNon-Consumableで1件だけ作り、米国USD 0.99を基準価格、
   日本JPY 100をcustom price、その他をAppleの現地相当額にする
4. AppとIAPを現行EU 27を除く148／175 Countries or Regionsへ設定し、今後追加されるstorefrontの
   自動追加を有効にする
5. IAPのja-JP名`ポモジェムPro`、en-US名`PomoGem Pro`、各説明、審査用screenshot、税区分、
   availabilityを完成させる
6. 初回のNon-Consumableは新しいapp versionと同じsubmissionへ追加する
7. `pomogem.hinoshiba.com`のDNSをGitHub Pagesの指示どおり設定し、custom domain検証とHTTPS強制を有効化する
8. 単一の製品ページがHTTPS 200で表示され、Privacy、Support、Terms、販売についての各アンカーへ移動できることを確認する。販売セクションはPro案内とアプリの購入前案内からも到達できるようにする
9. App Privacy、年齢区分、輸出コンプライアンス、accessibility回答を実装と照合する
10. 「iPhone/iPad appをApple silicon Macで提供」とVision Proでの提供は、未検証のため無効にする
11. Sign-in requiredはunchecked、Demo accountはnoneとする。Review Notesには、clean installで同格の
    「このiPhoneのみ」を選べばApple Account／networkなしで全基本機能を審査できる手順を記載する

Appleの現行手順は[Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)、
[Submit an In-App Purchase](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/)、
[Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
を参照します。

## 3. CloudKit production gate

App Store版はproduction CloudKit environmentだけを利用します。SwiftData同期元用
`iCloud.com.hinoshiba.pomogem`をdevelopmentで実機検証してから、CloudKit Consoleでversion 1.0に
必要なschemaをproductionへdeployします。

- SwiftData containerには`Subject`、`StudySession`、`AchievementStone`、`Prefs`、
  `ActivityResetMarker`、`SyncedFocusTimer`、`FocusTimerDeviceClaim`の7 model、field、index、
  relationshipがproductionに存在する。保存先切り替え用の追加schemaは下記の記録で区別する
- `AggregatePebble`、`Stratum`、`Bedrock`、`GachaState`は端末内projection storeにあり、CloudKitへ
  uploadされず、同期元recordから再構築できる
- 新規iPhone、既存dataのあるiPhone、offline→再接続の同期
- 2台で異なるoffline UUIDの同時完走が両方残ること、進行中timerの引き継ぎ、後着recordからの
  local projection再構築
- clean installでiCloudとlocal-onlyが同格、どちらも推奨表示なし、各説明の確認後だけ確定すること
- 初回選択画面からcanonical HTTPSのPrivacy Policyを開けること
- local-onlyでApple Account／networkなしに全基本機能が動き、再起動しても同じ専用namespaceを開き、
  iCloudへ自動switch／uploadしないこと。Version 1.0の選択変更不可、app削除時のdata loss、JSONの
  再import／migration不可を画面と公開文面で確認すること
- iCloudはtheme名、成果memo、記録、設定、進行中timerのprivate同期と、選択時・各launch／resumeの
  online account確認を選択確定前に表示すること
- `timerDisplayModeRawValue`と対応するrevision／mutation pairが最終development schemaに存在し、4種類の
  timer表示選択、既定値と未知値の`ringAndTime`へのfallback、offline競合、2台間同期、JSON raw exportを
  検証できること
- iCloud選択後、通信不可／account不明／A→Bではstoreを開かずdataを削除しないこと。Aへ戻ってonline
  確認できた場合だけ同じA namespaceを再び開くこと
- cloud mountではRoot公開前にサーバーのリセット履歴を読み、同じか新しい履歴の端末反映まで待つこと。
  期限切れ・不完全な応答では新規記録を作れず、既存dataも削除しないこと。全記録の同期完了とは区別する
- schema migrationと古いversionからの起動

`RareRewardReleasePolicy.isEnabled`はversion 1.0で`false`に固定します。Release実機でrandom rewardの
選択・設定・結果が表示されず、完走が通常粒として保存され、operations container entitlementと
CloudKit repository生成がないことを確認します。rare rewardを将来有効化する場合は、Apple Account
binding、A→B→A切替、raw data access、2台CASとproduction schemaを別release gateとして扱います。

`CompleteDataDeletionReleasePolicy.isEnabled`はversion 1.0で`false`に固定します。Release実機でSettingsに
direct CloudKit一括削除rowがなく、launch時に削除preflightのnetwork gateへ入らないことを確認します。
offlineで通常のSwiftData storeを開けるのはlocal-only選択時だけで、iCloud選択時は各launch／resumeの
online account確認に失敗すればfail closedにします。version 1.0のproduction gateに削除用zone／record
schemaや削除transaction試験を含めません。

現在の配布候補では、iCloud選択時の「表示中の記録をリセット」も記録保護のため一時停止します。
無効化された操作と理由の表示、呼び出し時にmarker・設定・timer・通知を変更しないことを確認します。
local-onlyの通常resetは維持します。履歴確認のread-only preflightは削除用preflightとは別の機能です。
通常のrelease工程にProduction environmentのresetや既存dataのpurgeを追加してはいけません。

Version 1.0の最終Prefs schemaは`timerDisplayMode`を含む13 group、26個のrevision／mutation stamp fieldです。
production schemaは削除・rename前提で運用せず、後方互換なadditive changeを基本にします。

既存の同期fieldへ、公開中の旧版が知らない値を書くことも後方互換ではありません。fieldの追加が不要なため
CloudKit schemaの配備では検出できず、そのままiCloud経由で旧版端末へ届きます。SwiftDataは未知のenum raw
valueを読んだ時点で停止するため、同じApple Accountの旧版端末が起動のたびに終了します。提出前に次を確認します。

- 公開中のtag（現在は`v1.0.2-build9`）と候補commitの間で、同期modelが保存するenumの値と
  `FocusCloudPayload.currentVersion`を比較し、旧版が読めない値を保存していないこと
- `CloudSchemaCompatibilityTests`が成功すること。`StudySession.source`に保存できる値は
  `SessionSource.legacyPersistableRawValues`（`timer`、`manual`、`timerDemoted`）に固定し、
  `PebbleKind`、`AchievementKind`、`SyncedFocusStatus`、payload versionも1.0.2の値に固定している
- 新しい分類は既存の値と判別できる形で保存し、読み出しで解決する。Screen Timeの記録は`manual`と
  600秒・100gで保存し、`StudySession.effectiveSource`が判別する（[ScreenTimeGems.md](ScreenTimeGems.md)）
- `screenTime`を保存していた修正前の開発版（Release構成はProductionのCloudKitを使う）を入れた端末は、
  2026-11-30までに修正後のbuildへ更新する。更新後の端末が、その期間の記録を1.0.2でも読める値へ直す

2026-09-12 16:40 JSTに、保存先切り替えの復旧用`PomoGemStorageTransferControl`と
`PomoGemStorageTransferChunk`をProductionへ配備しました。Consoleの成功表示、Productionの両型・
全field、Schema Historyを照合済みです。差分は2型、そのindexと2型への権限追加で、既存7種類の
同期元schemaの変更・削除はありません。環境resetや利用者recordの削除は行っていません。
この追加schemaは審査待ちのbuild 7では使いません。開発中の切り替え機能のProduction実通信・
復旧試験の合格とは区別し、検証範囲は[StorageModeTransfer.md](StorageModeTransfer.md)で管理します。

2026-09-13 11:33 JSTに、分・秒指定の追加field `CD_preferredFocusSeconds`（Int(64)、Queryable／Sortable）と
`CD_preferredFocusSecondsMutationID`（String、Queryable／Searchable／Sortable）をDevelopmentとProductionの
`CD_Prefs`（両方70 field）で確認しました。Production Historyには同日09:52 JSTの2 field変更・5 index作成が
記録されており、すでに配備済みでした。今回の作業でschemaを変更・再配備していません。
この照合を実機2台の秒単位送受信の合格とは扱いません。

詳細はAppleの[Deploying an iCloud Container’s Schema](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)
と`Docs/SyncMaintenanceArchitecture.md`を参照します。

## 4. Release candidateを固定する

```sh
./Scripts/check-oss-readiness.sh --release
python3 Scripts/validate-site.py
xcodegen generate
```

その後、生成差分がcommit済みであること、working treeがcleanであることを確認します。

- `MARKETING_VERSION`と`CURRENT_PROJECT_VERSION`がApp Store Connectと一致
- `SUPPORTS_MACCATALYST = NO`
- appとWidgetの`PrivacyInfo.xcprivacy`がarchiveへ含まれ、Widget側のrequired-reason APIは空
- App Iconが1024×1024、alphaなし
- Release buildに`POMOGEM_UI_TEST_*`、`POMOGEM_LOCAL_PREVIEW`、
  `POMOGEM_RUN_40_YEAR_PERSISTENCE`のDebug補助が含まれない
- Pages、Privacy、Support、Terms、OG、font licenseが公開済みで、購入前案内専用の販売者情報URLも直接HTTPS 200
- PomoGem 1.0 (5)からlisting screenshot 5枚とIAP審査画像を再captureし、production UIと架空dataだけを
  使用する。新しいStoreKit商品を確認し、05に無効化したdirect deletion rowがないことと、署名済み
  Release実機とのvisual parityを確認する。旧版の画像や価格取得を新商品の証拠として再利用しない。
  IAP画像未取得中はproductの`review_screenshot_status: pending_live_price_capture`と明示blockerを
  保持する。通常OSS検査だけがこの状態を許容し、`--release`は拒否する。新商品の実価格画像を確認後、
  `captured_live_price`、checksum manifest、asset台帳を同時に更新する
- App Store metadataと実画面に未実装・Mac対応・Web決済の記述がない
- `AppStore/configuration.yml`の`release_blockers`が空。blockerの正本は同fileとし、文書側へ
  個数や要約を重複転記して陳腐化させない

## 5. 署名なしの再現確認

```sh
xcodebuild \
  -project PomoGem.xcodeproj \
  -scheme PomoGem \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData-Release-Verify \
  build CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO
```

unit test、主要UI test、static analyzerを実行します。40年soakはrelease候補の通常起動には含めず、
関連する永続化変更がある場合にDebugの明示gateで別実行します。

## 6. 実機の最終確認

- 無料の25分／45分／60分／90分とProの1〜360分、上限360分の保存・復旧、pause、cancel、完走、
  音、触覚、account-neutralな終了通知
- clean installで同格の保存先二択、両方の確認、local-onlyのoffline基本機能、選択の不変性、app削除前の
  JSON書き出しが再import／移行には使えないという表示
- iCloud選択時のonline確認、各launch／resume、A→B block→A復帰、通信断時fail-closedと保存data非削除
- 既存CloudKit補助directoryを残した再起動、リセット履歴反映前の新規記録拒否と反映後の記録保持、
  iCloud通常resetの一時停止とlocal-only通常resetの継続
- Home／Lock Screen Widgetが利用者dataを表示せずアプリを開くこと
- Live Activityの開始、pause、resume、期限到達、cancel、完了後dismiss、手動dismiss後に再生成しないこと、
  SettingsでOFFにすると即終了すること。全状態でtheme名、memo、質量、account情報を表示しないこと
- 「タイマー中は画面をロックしない」のON/OFF。ONでは集中、集中直後の短い／長い休憩、Homeからの
  単独休憩が前面で残時間のある間だけ点灯を維持し、pause、期限到達、skip／close、backgroundで
  即座に通常の自動ロックへ戻ること
- iPhoneの傾き、瓶のtap位置への局所衝撃、Reduce Motion
- onboardingの任意のためし粒を「次へ」で省略でき、勉強／仕事の利用目的を選ばず最初のテーマ1件で完了すること
- 勉強・仕事共通の一つのテーマ一覧での追加・編集・並べ替え・削除
- Homeのテーマ／集中時間の選択欄から変更でき、開始buttonのtapで集中を開始できること
- 成果の石、10→1／100→1の融合、長期projection、計画modeが実績を書き換えないこと
- 静止画／GIF、写真追加拒否、共有取消、個人用theme・memoが画像へ入らないこと
- StoreKit sandboxの購入、pending、cancel、復元、revocation後の権利更新
- 同じApple Accountの2台と機種変更相当でCloudKitを確認し、theme名、成果memo、記録、設定、進行中timer
  だけがprivate同期対象であることを照合
- VoiceOver、最大Dynamic Type、十分なcontrast、color以外の識別、Reduce Motion

## 7. Xcode OrganizerでArchive／Upload

1. Xcode 26以降で`PomoGem.xcodeproj`を開く
2. Signing & Capabilitiesで公式teamとAutomatically manage signingを選ぶ
3. destinationを`Any iOS Device (arm64)`または接続実機にする
4. Product → Archive
5. Organizerでarchiveのversion、build、bundle ID、entitlementsと上記3 bundleを確認。account-neutral Widget／
   Live Activityに加え、Device Activity Monitor拡張を確認。hostは`NSSupportsLiveActivities = true`、frequent updatesは未宣言、Widget Infoは
   host用の同keyを持たず、Widget binaryがActivityKitを含むことを確認
6. Validate Appを実行し、warningも審査対象として解消・記録
7. Distribute App → TestFlight & App Store → Upload
8. symbolsを含め、signingはXcodeのautomatic selectionを使う

Appleの正本は[Distributing your app for beta testing and releases](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)
です。upload完了はrelease完了ではありません。

## 8. TestFlightから提出まで

1. build processing、export compliance、crash/symbol statusを確認
2. internal TestFlightで上記実機checkをもう一度行う
3. App Store Connectのversionへbuildを選ぶ
4. 初回IAPを同じsubmissionへ追加する
5. screenshot、説明、privacy、age rating、review notes、Support URLを最終照合
6. 手動でSubmit for Reviewする
7. 承認後はautomatic releaseで公開する

公開後はPagesとSupportを監視し、tag、App Store version/build、CloudKit schema deployment日時、
IAP statusをrelease記録へ残します。署名済みbinary自体はGitHub Releaseへ添付しません。

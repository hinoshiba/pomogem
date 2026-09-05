# つみべん公式版 — ローカルArchive／App Storeリリース手順

更新日: 2026-09-06

この手順は、許可済みMacのXcode OrganizerからiPhone版をArchive、Validate、Uploadするための
正本です。Xcode Cloudは現時点で前提にしません。Mac／Mac Catalyst版は作成しません。

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

初回upload前にApp Store Connectのapp recordが必要です。

1. Bundle ID `com.hinoshiba.tumiben`、iCloud/CloudKit、Push Notifications、
   In-App Purchaseのcapabilityが同じteamにある
2. Widget bundle `com.hinoshiba.tumiben.widgets`は登録するが、Version 1.0ではApp Group、iCloud、
   CloudKit、APNs capabilityを付けない。account-neutralな起動導線だけを表示する
3. `com.hinoshiba.tumiben.pro.lifetime`をNon-Consumableで1件だけ作り、米国USD 0.99を基準価格、
   日本JPY 100をcustom price、その他をAppleの現地相当額にする
4. AppとIAPを現行EU 27を除く148／175 Countries or Regionsへ設定し、今後追加されるstorefrontの
   自動追加を有効にする
5. IAPのja-JP名`つみべんPro`、en-US名`Tumiben Pro`、各説明、審査用screenshot、税区分、
   availabilityを完成させる
6. 初回のNon-Consumableは新しいapp versionと同じsubmissionへ追加する
7. `tumiben.hinoshiba.com`のDNSをGitHub Pagesの指示どおり設定し、custom domain検証とHTTPS強制を有効化する
8. Privacy、Support、Termsと購入前案内専用の販売者情報URLを公開し、redirectなしのHTTPS 200を確認する。販売者情報URLはPro案内とアプリの購入前案内からだけリンクし、グローバルheader／footer／sitemapへ掲載せず、`noindex`にする
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
`iCloud.com.hinoshiba.tumiben`をdevelopmentで実機検証してから、CloudKit Consoleでversion 1.0に
必要なschemaをproductionへdeployします。

- SwiftData containerには`Subject`、`StudySession`、`AchievementStone`、`Prefs`、
  `ActivityResetMarker`、`SyncedFocusTimer`、`FocusTimerDeviceClaim`の7 model、field、index、
  relationshipだけがproductionに存在する
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

Version 1.0の最終Prefs schemaは`timerDisplayMode`を含む13 group、26個のrevision／mutation stamp fieldです。
production schemaは削除・rename前提で運用せず、後方互換なadditive changeを基本にします。
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
- Release buildに`TSUMIBEN_UI_TEST_*`、`TSUMIBEN_LOCAL_PREVIEW`、
  `TSUMIBEN_RUN_40_YEAR_PERSISTENCE`のDebug補助が含まれない
- Pages、Privacy、Support、Terms、OG、font licenseが公開済みで、購入前案内専用の販売者情報URLも直接HTTPS 200
- screenshot 5枚はproduction UIをDebug-only fixtureでcapture済みで、UI test 1/1 pass、05に無効化した
  direct deletion rowが写っていない。署名済みRelease実機とのvisual parityを確認し、差があれば再captureする
- App Store metadataと実画面に未実装・Mac対応・Web決済の記述がない
- `AppStore/configuration.yml`の`release_blockers`が空。blockerの正本は同fileとし、文書側へ
  個数や要約を重複転記して陳腐化させない

## 5. 署名なしの再現確認

```sh
xcodebuild \
  -project Tsumiben.xcodeproj \
  -scheme Tsumiben \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData-Release-Verify \
  build CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO
```

unit test、主要UI test、static analyzerを実行します。40年soakはrelease候補の通常起動には含めず、
関連する永続化変更がある場合にDebugの明示gateで別実行します。

## 6. 実機の最終確認

- 25分／45分／60分／90分、pause、cancel、完走、音、触覚、account-neutralな終了通知
- clean installで同格の保存先二択、両方の確認、local-onlyのoffline基本機能、選択の不変性、app削除前の
  JSON書き出しが再import／移行には使えないという表示
- iCloud選択時のonline確認、各launch／resume、A→B block→A復帰、通信断時fail-closedと保存data非削除
- Home／Lock Screen Widgetが利用者dataを表示せずアプリを開くこと
- Live Activityの開始、pause、resume、期限到達、cancel、完了後dismiss、手動dismiss後に再生成しないこと、
  SettingsでOFFにすると即終了すること。全状態でtheme名、memo、質量、account情報を表示しないこと
- 「タイマー中は画面をロックしない」のON/OFF。ONでは集中、集中直後の短い／長い休憩、Homeからの
  単独休憩が前面で残時間のある間だけ点灯を維持し、pause、期限到達、skip／close、backgroundで
  即座に通常の自動ロックへ戻ること
- iPhoneの傾き、瓶のtap位置への局所衝撃、Reduce Motion
- onboardingの任意のためし粒を「次へ」で省略でき、勉強／仕事の利用目的を選ばず最初のテーマ1件で完了すること
- 勉強・仕事共通の一つのテーマ一覧での追加・編集・並べ替え・削除
- Home開始buttonのtapでは集中を開始し、長押しでは開始せず別テーマへ変更できること
- 成果の石、10→1／100→1の融合、長期projection、計画modeが実績を書き換えないこと
- 静止画／GIF、写真追加拒否、共有取消、個人用theme・memoが画像へ入らないこと
- StoreKit sandboxの購入、pending、cancel、復元、revocation後の権利更新
- 同じApple Accountの2台と機種変更相当でCloudKitを確認し、theme名、成果memo、記録、設定、進行中timer
  だけがprivate同期対象であることを照合
- VoiceOver、最大Dynamic Type、十分なcontrast、color以外の識別、Reduce Motion

## 7. Xcode OrganizerでArchive／Upload

1. Xcode 26以降で`Tsumiben.xcodeproj`を開く
2. Signing & Capabilitiesで公式teamとAutomatically manage signingを選ぶ
3. destinationを`Any iOS Device (arm64)`または接続実機にする
4. Product → Archive
5. Organizerでarchiveのversion、build、bundle ID、entitlements、含まれるaccount-neutral Widget／
   Live Activityを確認。hostは`NSSupportsLiveActivities = true`、frequent updatesは未宣言、Widget Infoは
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

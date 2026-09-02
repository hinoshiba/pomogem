# つみべん公式版 — ローカルArchive／App Storeリリース手順

更新日: 2026-09-02

この手順は、許可済みMacのXcode OrganizerからiPhone版をArchive、Validate、Uploadするための
正本です。Xcode Cloudは現時点で前提にしません。Mac／Mac Catalyst版は作成しません。

## 1. 安全境界

- 公式archiveはmaintainerの許可済みMacとApple Developer teamでのみ作成する
- automatic signingを使い、秘密鍵と証明書はKeychain、profileはXcode管理に置く
- `.p12`、`.p8`、profile、Keychain、certificate fingerprint、password、API key、
  `ExportOptions*.plist`、`.xcarchive`、`.ipa`をリポジトリ、issue、PR、GitHub Releaseへ置かない
- App Store候補はGitの固定commitから作り、upload後に同じcommitへ不変tagを付ける
- version/buildを再利用しない。修正uploadはbuild numberを増やす

Appleは2026年4月28日以降、App Store ConnectへuploadするappをXcode 26以降とiOS 26 SDKで
buildするよう求めています。開始時に[Upcoming Requirements](https://developer.apple.com/news/upcoming-requirements/)
を再確認します。

## 2. App Store Connectを先に整える

初回upload前にApp Store Connectのapp recordが必要です。

1. Bundle ID `com.hinoshiba.tsumiben`、App Group、iCloud/CloudKit、Push Notifications、
   In-App Purchaseのcapabilityが同じteamにある
2. Widget bundle `com.hinoshiba.tsumiben.widgets`も同じApp Groupを使う
3. `com.hinoshiba.tsumiben.pro.lifetime`をNon-Consumableで1件だけ作り、日本の価格を100円にする
4. IAPの日本語display name、説明、審査用screenshot、税区分、availabilityを完成させる
5. 初回のNon-Consumableは新しいapp versionと同じsubmissionへ追加する
6. `tumiben.hinoshiba.com`のDNSをGitHub Pagesの指示どおり設定し、custom domain検証とHTTPS強制を有効化する
7. Privacy URLとSupport URLを公開し、redirectなしのHTTPS 200を確認する
8. App Privacy、年齢区分、輸出コンプライアンス、accessibility回答を実装と照合する
9. 「iPhone/iPad appをApple silicon Macで提供」とVision Proでの提供は、未検証のため無効にする

Appleの現行手順は[Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)、
[Submit an In-App Purchase](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/)、
[Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
を参照します。

## 3. CloudKit production gate

App Store版はproduction CloudKit environmentだけを利用します。development containerで次を
実機検証してから、CloudKit Consoleでschemaをproductionへdeployします。

- 全SwiftData model、field、index、relationshipがproductionに存在する
- 新規iPhone、既存dataのあるiPhone、offline→再接続の同期
- 2台で同時完走、進行中timerの引き継ぎ、削除後に遅れて接続する端末
- schema migrationと古いversionからの起動

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
- appとWidgetの`PrivacyInfo.xcprivacy`がarchiveへ含まれる
- App Iconが1024×1024、alphaなし
- Release buildに`TSUMIBEN_UI_TEST_*`、`TSUMIBEN_LOCAL_PREVIEW`、
  `TSUMIBEN_RUN_40_YEAR_PERSISTENCE`のDebug補助が含まれない
- Pages、Privacy、Support、OG、font licenseが公開済み
- App Store metadataと実画面に未実装・Mac対応・Web決済の記述がない
- `AppStore/configuration.yml`の`release_blockers`が空。現時点では、完全offlineの2台でrare抽選台帳をexactly-onceへ収束させるV2が未完了

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

- 25分／60分、pause、cancel、完走、音、触覚、通知、Live Activity
- 画面をロックさせないoptionのON/OFFとbackground移行
- iPhoneの傾き、瓶のtap位置への局所衝撃、Reduce Motion
- テーマの追加・編集・並べ替え・削除、勉強／仕事の切替
- 成果の石、10→1／100→1の融合、長期projection、計画modeが実績を書き換えないこと
- 静止画／GIF、写真追加拒否、共有取消、個人用theme・memoが画像へ入らないこと
- StoreKit sandboxの購入、pending、cancel、復元、revocation後の権利更新
- 同じApple Accountの2台と機種変更相当でCloudKitを確認
- VoiceOver、最大Dynamic Type、十分なcontrast、color以外の識別、Reduce Motion

## 7. Xcode OrganizerでArchive／Upload

1. Xcode 26以降で`Tsumiben.xcodeproj`を開く
2. Signing & Capabilitiesで公式teamとAutomatically manage signingを選ぶ
3. destinationを`Any iOS Device (arm64)`または接続実機にする
4. Product → Archive
5. Organizerでarchiveのversion、build、bundle ID、entitlements、含まれるWidgetを確認
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
7. 承認後はmanual releaseまたは設定したrelease方法で公開する

公開後はPagesとSupportを監視し、tag、App Store version/build、CloudKit schema deployment日時、
IAP statusをrelease記録へ残します。署名済みbinary自体はGitHub Releaseへ添付しません。

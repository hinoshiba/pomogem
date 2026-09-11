# iCloud同期の起動エラー調査と検証

更新日: 2026-09-11

「保存領域を確認できません」は、保存データを開く前の検証が止まったことを示す見出しです。
見出しだけでは、通信、Apple Account、端末内の保存方式設定のどれが原因かは確定できません。
この文書はソースレビューの結果と配布版での確認手順をまとめます。報告端末のログ、Apple Account、
CloudKit Productionの実データは確認していないため、その端末の原因を特定済みとは扱いません。

## 表示と実装の対応

入口は[起動ホスト](../PomoGem/App/PomoGemApp.swift)の保存先選択・起動処理、
見出しは同ファイルの`PersistenceLaunchStatusView.title`にあります。

| 表示 | 実装の状態・経路 | 切り分け |
|---|---|---|
| 保存領域を確認できません | `.blocked`。`PersistenceDeploymentState.validate`が`recoveryRequired`を返した場合 | 保存方式の設定、成功した起動の記録、端末内ファイルの対応を確認できない |
| 保存領域を確認できません | `.blocked`。`AppleAccountBoundaryResolutionError.verification`を受け取った場合 | Apple Account確認、通信、制限、配布設定など。`CloudAccountVerificationFailure`の分類、確認箇所、CloudKitコードを本文に表示 |
| 保存領域を確認できません | `.blocked`。`AppleAccountBoundaryResolutionError.blocked`を受け取った場合 | 保存先と現在のアカウントの不一致、端末内アカウント対応情報の異常、起動中の認証許可の失効など |
| 保存領域を確認できません | `.blocked`。以前のコンテナの解放待ちがtimeoutした場合 | 本文に「保存領域が完全に閉じたことを確認できません」と表示。古いコンテナが残ったまま新しいものを開かない |
| 保存領域を確認できません | `.blocked`。完全削除の試作機能のpreflightが拒否した場合 | Version 1.0では`CompleteDataDeletionReleasePolicy.isEnabled == false`で到達しない |
| 保存領域を準備できませんでした | `.failed`。上記以外の保存設定・`ModelContainer`作成エラー | ローカルファイル、空き容量、モデル構成、移行などを調べる |
| iCloudの状態を確認できません | Settingsの`CloudAccountAvailability.unavailable` | 起動ゲートの見出しとは別の、接続可否表示 |

起動時のアカウント照合は[CloudSyncMonitor.swift](../PomoGem/Core/CloudSyncMonitor.swift)、
保存方式とファイルの整合性検証は[PersistenceStoreTopology.swift](../PomoGem/Core/PersistenceStoreTopology.swift)
が担当します。Settingsの接続可能表示は、全データのアップロード・ダウンロード完了を保証しません。
Core DataのCloudKit同期はシステムによる非同期処理です。
([Apple: Syncing a Core Data Store with CloudKit](https://developer.apple.com/documentation/coredata/syncing-a-core-data-store-with-cloudkit))

## ソースレビューで確認した問題

修正前のアカウント検証には、次の問題がありました。

- `accountStatus`、前後の`userRecordID`、private databaseのzone取得の失敗をすべて
  `identityUnavailable`へ変換していたため、未サインイン、管理制限、通信失敗、配布設定の不備を
  同じ本文で案内していました。復旧に必要な操作と開発者側の修正を切り分けられませんでした。
- zone取得には6秒のrequest timeoutと8秒のresource timeoutがある一方、アカウントとユーザーIDの
  convenience APIにはアプリ側の待機期限がありませんでした。一時的なエラーの再試行もなく、
  正常な通信の遅延で起動を拒否する経路と、確認中のまま長く待つ経路がありました。
- 起動、コンテナ作成直前、作成直後に独立したアカウント検証を行います。検証の安全性は必要ですが、
  短い通信期限と一律エラー処理を3回繰り返す構成は、一時的な接続不良の影響を受けやすくしていました。
- コンテナ作成後の非同期確認中にアプリがinactiveになると、まだ画面へ公開していない候補コンテナを
  解放待ちの対象として追跡できませんでした。公開済みsessionがないことだけで待機を終えると、
  元の候補が生存したまま次の起動で同じ保存先を開く競合が起こりえました。
- inactiveからbackgroundへの連続通知で解放処理を重ねて開始でき、解放対象と待機処理の世代が
  入れ替わる経路がありました。解放中は追加のscene通知で同じ処理を始めない必要があります。
- Settingsで表示開始、foreground復帰、再確認操作が重なると複数の接続確認が並行し、古い失敗が
  新しい成功表示を上書きできました。

修正では失敗理由を分類し、zone取得のrequest／resource timeoutを15秒／30秒、アカウントの状態・
ID・zone取得を含む一度の検証全体の待機期限を45秒にしました。これは一度のresolver呼び出しの上限で、
起動全体にはコンテナ作成前後の独立した検証も含まれます。一時的な通信・サービス失敗の自動再試行は
最大1回とし、サーバーの待機指定が3秒を超える場合は自動再試行を行いません。
候補を含むすべてのコンテナを作成直後から追跡し、解放中の重複したscene処理を抑止します。
Settingsでは前の確認をキャンセルして最新の世代の結果だけを表示します。
別のApple Accountや未検証のアカウントで既存ストアを開く回避策は使いません。
CloudKitはエラーコードと`retryAfterSeconds`を提供し、ネットワーク失敗の再試行にはbackoffを推奨します。
([Apple: CKError](https://developer.apple.com/documentation/cloudkit/ckerror)、
[Apple: networkUnavailable](https://developer.apple.com/documentation/cloudkit/ckerror/networkunavailable))

## 起こりうる外部要因

以下は調査対象となる可能性です。今回の報告端末で発生したと確認した事象ではありません。

| 要因 | 確認する内容 |
|---|---|
| 未サインイン・認証の一時停止 | iPhoneのApple AccountとiCloudの状態、`noAccount`、`notAuthenticated`、`accountTemporarilyUnavailable` |
| アプリのiCloud利用が無効 | iPhoneの設定にあるiCloudのアプリ一覧でポモジェムの利用が有効か |
| 管理・利用制限 | `restricted`、`managedAccountRestricted`。管理されている端末やアカウントのポリシー |
| 通信断・到達不能・応答遅延 | `networkUnavailable`、`networkFailure`。Wi-Fiとモバイル通信の切り替わり、接続先への到達、期限超過 |
| CloudKitの一時障害・混雑 | `serviceUnavailable`、`requestRateLimited`、`zoneBusy`。サーバーが指定した待機時間後の再試行 |
| 保存先と異なるApple Account | iCloud保存を確定したアカウントと現在のアカウントが同じか。元のアカウントへ戻った後に再確認 |
| 署名・コンテナの配布設定 | `missingEntitlement`、`badContainer`、`permissionFailure`。配布されたバイナリとprofileのcapability、container割当 |
| Production schemaの不足 | 起動後の同期やコンテナ設定時のエラー。App Store配布環境に必要なrecord type、field、indexがdeploy済みか |
| 端末の保存ファイル・空き容量 | 保存方式の設定とファイルの不一致、ファイルを読めない状態、保存容量不足。CloudKitのアカウント状態とは分けて調べる |

アカウントの状態とCloudKitエラーの意味はAppleの定義を基準にします。
([Apple: CKAccountStatus](https://developer.apple.com/documentation/cloudkit/ckaccountstatus)、
[Apple: CKError](https://developer.apple.com/documentation/cloudkit/ckerror))
アプリごとのiCloud利用設定はAppleの案内で確認できます。
([Apple: iCloudでデータを同期および保管するアプリを変更する](https://support.apple.com/ja-jp/118225))

`quotaExceeded`はデータの保存時にユーザーのiCloud容量を超えるエラーです。
今回のオンライン確認はzoneの読み取りなので、「保存領域」という見出しを容量不足の証拠にしません。
([Apple: quotaExceeded](https://developer.apple.com/documentation/cloudkit/ckerror/quotaexceeded))

## 配布設定・スキーマのレビュー結果

- `project.yml`、生成済みXcode project、host entitlementsは、同期用container
  `iCloud.com.hinoshiba.pomogem`、CloudKit、APNsを指定しています。
  DebugはDevelopment、ReleaseはProductionで、Info.plistに`remote-notification`があります。
- SwiftData同期元の7 modelをprivate CloudKitへ、再構築可能な4 modelを`.none`の端末内storeへ
  分離しています。同期元のrelationshipは同じconfiguration内にあり、unique constraintは使用していません。
- Version 1.0のWidgetはCloudKitを使わず、operations containerと直接削除の試作機能も出荷経路で
  無効です。このためWidgetへiCloud entitlementを追加する変更は解決策になりません。
- [1.0 (5)のリリース記録](../AppStore/release-record-1.0-5.md)には、2026-09-06時点の配布署名、
  Production環境、7種類・120 scalar attributesのschema照合結果があります。
  同じ記録には実機間同期試験を省略したことも明記されています。過去の確認結果を今回の実機試験の
  合格や現在のCloudKitサービス状態の証拠として扱いません。

ソース上で識別子や環境の明白な不一致は見つかりませんでした。実際にインストールされた署名・profileや
現在のProduction schemaまでソースだけから保証することはできません。App Store版はProductionを
使用するため、developmentでの成功だけでは配布版の確認になりません。
([Apple: Deploying an iCloud Container’s Schema](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema))
SwiftData／Core Dataのモデル制約とschema初期化の要件も配布前に照合します。
([Apple: Creating a Core Data Model for CloudKit](https://developer.apple.com/documentation/coredata/creating-a-core-data-model-for-cloudkit)、
[Apple: Syncing model data across a person’s devices](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices))

## 配布候補の実機検証

Simulatorのunit testは、失敗分類、待機期限、キャンセル、アカウント境界、端末内ファイル整合性を
検証するものです。Simulatorの通常起動はCloudKitを使わないため、実サービスとの同期成功は証明しません。
以下は、検証用アカウントと架空データを使い、同じ配布候補を入れた2台の対応iPhoneで確認します。
結果にはアプリversion／build、iOS version、配布経路、確認日時を残します。

- [ ] [リリース手順](RELEASING.md)に従い、署名済み配布候補のhost／Widgetのentitlementsと
  provisioningを照合する。Productionのcontainerと必要なschemaを確認する。
- [ ] TestFlightで2台とも同じApple Accountを使用し、初回にiCloudを明示選択する。冷起動と
  backgroundからの再開が完了することを確認する。App Store公開後も実際の配布buildで確認する。
- [ ] 一方で架空のテーマ、集中記録、成果、設定を変更し、もう一方で反映を確認する。逆方向でも
  確認し、進行中タイマーと端末内の瓶の再構築を確認する。接続可能の表示だけを合格条件にしない。
- [ ] 起動前にofflineにし、保存領域を開かず本文に接続案内が出ることを確認する。接続を戻して
  再試行し、同じ保存先の既存記録が残ることを確認する。新しい空のstoreへ切り替わらないことも調べる。
- [ ] 起動途中、特にコンテナ作成後の確認中にbackgroundへ移動して通信を切り、再開・再試行する。
  古い確認処理が画面や新しい起動結果を書き換えず、未承認のコンテナが引き継がれないことを確認する。
- [ ] 通信が遅い場合と一時的に失敗する場合に、一定時間で復旧または操作可能なエラー表示へ進むこと、
  再試行が無限に続かず、再試行ボタンの連打で確認処理が増殖しないことを確認する。
- [ ] 検証用端末でApple AccountをAからBへ変更し、Aの保存領域が表示・更新されないことを確認する。
  Aへ戻してオンライン確認すると、同じAの記録を再び利用できることを確認する。background中の変更でも行う。
- [ ] 未サインイン、アプリのiCloud設定が無効、利用制限がある場合に、対応する復旧案内が出ることを
  検証可能な条件で確認する。実施できない条件は未検証と記録する。
- [ ] 別の初回インストールで「このiPhoneのみ」を選び、Apple Accountと通信なしで基本機能と
  再起動後の記録保持を確認する。iCloudへ自動で変更されないことを確認する。

Appleは同期調査で、同じiCloudアカウント、ロック解除済みの2台、良好な通信環境を確認し、
Core Dataのsetup／export／importとCloudKitのログを区別するよう案内しています。
必要なログは許可された検証端末で採取し、利用者の記録、アカウント識別子、認証情報を公開のPRやissueへ
添付しません。今回の修正で自動ログ送信や運営者のデータ収集は追加しません。
([Apple: Syncing a Core Data Store with CloudKit](https://developer.apple.com/documentation/coredata/syncing-a-core-data-store-with-cloudkit))

アプリの削除・再インストールやiCloudデータの削除は、このエラーの通常の復旧手順にしません。
Version 1.0は書き出したJSONを再importできず、削除すると未同期の端末内記録を失う可能性があります。
保存先の安全性を確認できない場合は既存ファイルを残し、原因の切り分けを続けます。

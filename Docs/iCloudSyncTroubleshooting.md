# iCloud同期の起動エラー調査と検証

更新日: 2026-09-12

「保存領域を確認できません」は、保存データを開く前の検証が止まったことを示す見出しです。
見出しだけでは、通信、Apple Account、端末内の保存方式設定のどれが原因かは確定できません。
この文書はソースレビュー、許可された検証用実機での再現結果、配布候補の確認手順をまとめます。
実機で再現した問題と、遅延到着順序をテストで再現した問題を区別します。修正後の実サービスでの
同期・再インストール復元がすべて合格したという記録ではありません。進行中の実機監査は
[実機監査記録](RealDeviceICloudAudit.md)で別に管理します。

## 開発中の保存先切り替えで停止した場合

次候補の保存先切り替えはアップロード済み1.0.1 (7)とは別機能です。通常のDebug／Releaseでは、
複数端末間の競合から記録を保護するため、iCloudを端末データで置き換える操作と、受付済み・別端末の
置き換えの復旧再開を一時的に禁止しています。再起動でこの制限は解除されず、端末データと復旧用コピーを
保持します。置き換え開始前の取消しは可能です。appの削除・再インストールを復旧手順にしません。
account確認、完全なコピー、参照先の対応を検証できない場合は保存先を勝手に確定しません。
不完全なrelationshipや対応が曖昧な記録は、安全に自動復旧できず停止する場合があります。

iCloudの内容を使う有効化と、cloudを端末へコピーしてcloud側を残す解除は維持します。
他端末の終了・更新を、稼働中の同期や遅延した復旧処理を排他する保証にはしません。
通常launchで不正な保存履歴を新しいnamespaceへ逃がす処理とは異なり、
明示したdurable journalまたはcommit済みreceiptで認めた変更だけを扱います。
隔離したDevelopment実機での置き換え・復旧の成功は、通常アプリの利用許可とは別です。
[仕様と試験の範囲](StorageModeTransfer.md)と[複数端末の安全性](MultiDeviceCloudSafety.md)を参照してください。

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
| 保存領域を準備できませんでした | `.failed`。`CloudActivityHistoryPreflight`で履歴取得・端末への反映待ちが失敗した場合 | 本文の履歴確認案内を確認。画面公開と新規記録の作成を止め、既存データは削除しない |
| iCloudの状態を確認できません | Settingsの`CloudAccountAvailability.unavailable` | 起動ゲートの見出しとは別の、接続可否表示 |

起動時のアカウント照合は[CloudSyncMonitor.swift](../PomoGem/Core/CloudSyncMonitor.swift)、
保存方式とファイルの整合性検証は[PersistenceStoreTopology.swift](../PomoGem/Core/PersistenceStoreTopology.swift)
が担当します。Settingsの接続可能表示は、全データのアップロード・ダウンロード完了を保証しません。
Core DataのCloudKit同期はシステムによる非同期処理です。
([Apple: Syncing a Core Data Store with CloudKit](https://developer.apple.com/documentation/coredata/syncing-a-core-data-store-with-cloudkit))

## 実機で再現した保存ファイルの誤判定

検証用実機では、保存先選択と起動済み記録が一致し、端末の主storeとCloudKitサーバーの双方に
テスト用のテーマと設定が存在する状態でも、起動時のファイル検査がCloudKitの補助directoryを
未知の保存履歴として拒否しました。容量不足や別アカウントを示す事例ではありません。

`<stem>`をstoreのファイル名から`.store`を除いた部分とすると、実機で観測した構成には
`<stem>.store`、`<stem>.store-wal`、`<stem>.store-shm`のほか、`<stem>_ckAssets/`と
`.<stem>_SUPPORT/`がありました。実際の保存先、namespace、アカウント識別子は公開しません。

修正では、ファイル検査と削除用の補助処理が同じ有限の命名規則を参照します。追加の認識対象には
`<stem>.store-journal`、`<stem>.store_SUPPORT/`、`<stem>.store.ckAssetFiles/`、
`<stem>.store_ckAssets/`も含みます。未知の名前や不正なnamespaceまで許可する変更ではなく、
ファイル／directoryの種別とsymbolic linkの検証は維持します。

これらの補助directoryを手動で削除して起動させることは、通常の復旧手順ではありません。SQLite本体、
WAL、CloudKit補助データを一組の既存保存領域として保持し、認識側を修正します。削除用補助処理の
修正はアプリ内のCloudKit一括削除機能を有効化するものではありません。修正後の実機再検証結果は
監査記録へ別途残します。

## リセット履歴の到着前に新規記録を作る問題

実機のReleaseホスト上で、本番の保存・世代判定・保守処理に遅延到着順序を与えた回帰テストでは、
以前の高いsequenceのリセット履歴が届く前に作った記録が、後着履歴によって非表示となり、物理削除
されました。新しいリセット操作をしなくても、履歴なしの`nil`世代、部分的に届いた古い世代での手動記録、
進行中タイマーと所有権に同じ問題を再現しました。これは実サービスの自然な配送順序での再現とは区別します。

現在の対策では、iCloud選択時の「表示中の記録をリセット」を一時的に利用不可とし、書き込みや通知の
変更前に拒否します。local-onlyでは引き続き利用できます。既存のリセット履歴を削除したり、時刻から
旧記録の世代を推測して書き換えたりはしません。

さらに[CloudActivityHistoryPreflight](../PomoGem/Core/CloudActivityHistoryPreflight.swift)は、各cloud mountで
`RootView`を公開する前に、private custom zoneの全ページからリセット履歴の必要なfieldだけを読みます。
アカウントを前後で照合し、サーバーで観測したwinnerと同じか新しい履歴が端末へ届くまで待ちます。
順序は`sequence`、`writerDeviceID`、`epochID`、`id`で決め、時刻の丸め差を認可条件にしません。
読み取り専用のfresh `ModelContext`で反映を確認し、通信失敗、不完全な応答、キャンセル、期限切れでは
画面を公開しません。履歴preflight自体の上限は90秒で、その他の起動時アカウント検証とは別の期限です。

全記録のdownload完了を待つ仕組みではありません。query indexへ依存せず全zone変更を読むため、
記憶量はマーカー中心に制限しても、読み取り時間は記録数に応じて増えます。変更tokenの永続cacheは
導入していません。この確認だけで、まだサーバーへ届いていない別端末の変更や、既に誤った世代へ
保存された記録の復元まで保証することはできません。
([Apple: Reading CloudKit Records for Core Data](https://developer.apple.com/documentation/coredata/reading-cloudkit-records-for-core-data)、
[Apple: CKFetchRecordZoneChangesOperation](https://developer.apple.com/documentation/cloudkit/ckfetchrecordzonechangesoperation))

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

## 追加レビューで確認した復旧・通知・タイマー履歴の問題

起動エラーの修正後に、複数の担当による独立レビューと、非同期応答の順序を入れ替える回帰テストを
繰り返しました。次はソースとテストで確認した問題で、報告端末での発生を確認したものではありません。

| 問題 | 修正後の動作 |
|---|---|
| CloudKitの長い待機指定が、再試行ボタンや次のforeground確認で失われる | containerごとの待機期限をプロセス内で共有する。キャンセル後に遅れて届いた制限応答も保持し、期限前のAPI呼び出しを止める |
| 古い保存領域の解放がtimeout後に完了しても、再開時にエラー画面から復旧しない | timeout済みで追跡中のコンテナがすべて解放された場合だけ、foregroundで再検証を始める。進行中の後処理は飛ばさない |
| 通知追加の応答が遅れると、OFF・キャンセル・アカウント切替の後に日次通知が復活する | 最新の操作だけを有効とし、追加処理を直列化する。古い処理の追加済み・追加中の通知と部分失敗を取り消す |
| タイマー通知の一括取消が新しい同一IDの通知を消す、または再登録失敗時に古い通知が残る | 待機後に現在の登録意図を照合する。再登録失敗時は古い終了時刻の通知を削除する |
| 通知許可の遅れた応答が新しいOFF設定を上書きする | 設定ごとの操作識別子を確認し、認可確認後に最新の設定を読み直す |
| 新しい64行より古い進行中タイマーが遅れて同期されると、引き継ぎ候補が更新されない | 読み取り専用の同期保守の完了時にも候補を再確認する。通知・表示の再評価のために同期元行を書き換えない |
| 一時停止・再開を繰り返して同じタイマーの履歴が128行を超えると、引き継ぎ・完了・中止が失敗する | 128行ずつ履歴を読み、判定に必要な行・最大revision・完了の系譜を保持する。同期元履歴は削除せず、各行のpayload検証も継続する |

CloudKitの待機期限には、端末の時計変更の影響を受けない既存の連続稼働時間APIを使います。
保持するのは分類済みエラーと期限だけで、本人確認の成功やApple Account IDはキャッシュしません。
プロセス終了をまたぐ期限の永続化は行いません。
([Apple: CKErrorRetryAfterKey](https://developer.apple.com/documentation/cloudkit/ckerrorretryafterkey))

履歴の分割読み取りは、1つのタイマーについて行数に比例する処理です。アプリが明示的に保持する行は
1ページと少数の判定用行に限定しますが、読み取り時間の一定上限を保証するものではありません。
重複検証では、同じイベントIDに対応する最大128種類の判定用snapshotとpayloadを保持します。
Swiftと保存先の文字列の並び順に依存せず矛盾を検出し、上限を超える場合は更新を
止めます。同一内容の物理コピーの数や、通常の一時停止・再開によるイベント数を制限するものではありません。
アカウント全体の候補探索と所有権読み取りの上限は維持します。途中で行数が変わった場合は、その結果で
新しい更新を作らず再確認を要求します。同じ行数のまま並行して同期元が入れ替わる場合については、
従来の読み取りと同様、厳密なスナップショットの保証はありません。

検証には通知APIの応答を意図的に保留するテスト、65回の一時停止・再開後の引き継ぎ・完了・中止、
ページ境界の重複・不正payload、保存前の重複行、SQLite上の1,000行の履歴を含めます。
設定画面を閉じた場合も、開始済みの通知更新は管理側で完了させます。通知を明示的に無効化した場合、
新しい設定で更新した場合、アカウント境界を閉じた場合は古い更新を無効にします。
実際の通知表示、OSによるCloudKit import、実機間の同期成功は別途実機で確認します。

`PRIVACY.md`、Privacy Manifest、App Storeのprivacy回答案を再照合しました。今回の変更は既存の
CloudKit・端末内通知・連続稼働時間APIの範囲で、SDK、送信先、収集項目、権限、同期modelの追加はありません。

## 再レビューで確認した画面・非同期処理・リセットの問題

| 確認した問題 | 修正 |
|---|---|
| 通知許可ダイアログやControl Centerの一時的な`inactive`でも、公開済みのiCloud保存領域を閉じる | 公開済み領域は一時的な非アクティブ化で維持し、backgroundまたはアカウント変更時に閉じる。準備中の領域は従来どおり非アクティブ化で認可を失う |
| 任意のqueueから届く`CKAccountChanged`でSwiftUIの状態を変更する | 通知をmain run loopへ配送してからアカウント境界を更新する |
| 消えたRoot／設定画面が通知許可やStoreKitの応答待ちで古い`ModelContext`を保持し、解放待ちtimeoutや遅延書き込みを起こす | 画面に属するTaskを終了時に取り消し、システム応答待ちから即座に離脱する。受付済みの通知更新は管理側で直列実行し、次の更新との順序を保持する |
| 上限まで取得した所有権の候補が別の解放履歴によって除外されると、未取得の有効な所有者がいるのに新しいclaimを書き込む | 最初のページが不完全である可能性を最後まで保持し、所有者不在を証明できない場合は更新を拒否する |
| リセット適用済みの記録だけが残り、画面終了やプロセス終了で通知・Live Activityの後処理が抜ける | 端末内の未完了受付を適用済み記録より先に保存し、次回起動で再試行する。正常完了した同じ受付だけを消去する |
| 遅れたリセット後処理が、その間に開始された集中の通知・Live Activityまで消す | 通知の取消境界とActivityの対象を受付時に確定する。再試行時は現在のリセット世代の集中と復元可能な休憩を読み直して保護する |

Appleは`CKAccountChanged`の通知queueを保証せず、一時的な`inactive`とbackgroundを別の状態として
定義しています。保存領域の公開前後の認可検証とbackground時のアカウント再確認は維持します。
([Apple: CKAccountChanged](https://developer.apple.com/documentation/cloudkit/ckaccountchangednotification)、
[Apple: ScenePhase.inactive](https://developer.apple.com/documentation/swiftui/scenephase/inactive))

回帰テストでは、通知callbackを保留したままの画面終了とコンテナ解放、通知更新の順序、上限外の
所有権解放による誤更新、未完了受付の再読込、新旧受付の競合、遅延後処理中の新しいActivityを扱います。
リセット後処理は確定済みの変更に付随するため、画面のキャンセルと独立して実行し、その間は元の保存領域を
保持します。OS処理が停止し続ける場合に、新しい保存領域を安全確認なしで開くことはありません。

未完了受付は既存のランダムな保存先namespace内のUserDefaultsに、リセット世代UUIDと受付UUIDだけを
保存します。完了後に消去し、同期・送信・JSON書き出しには含めません。`PRIVACY.md`、host／Widgetの
Privacy Manifest、`AppStore/app-privacy.md`を再監査し、既存のUserDefaults利用理由`CA92.1`の範囲内で、
新しい権限、SDK、送信先、同期modelがないことを確認しました。

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
- [ ] 実機が作成したCloudKit補助directoryを保持したまま再起動し、認識対象の補助ファイルだけで
  recovery gateへ入らないことを確認する。不正な種別、symbolic link、未知の保存履歴は拒否を維持する。
- [ ] 既存のリセット履歴がある新規・再インストール・再開時に、履歴反映前は新規記録を作れず、
  反映後の手動記録とタイマーが保守処理後も残ることを確認する。失敗・期限切れ時も既存記録は消さない。
- [ ] iCloudの通常リセットが利用不可と理由を表示し、local-onlyのリセットは引き続き機能することを確認する。
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

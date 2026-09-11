# Privacy architecture

この文書は公開ソース上のデータフローの正本です。利用者向けの正式なポリシーは
<https://pomogem.hinoshiba.com/#privacy>です。

## 保存するデータ

最初の保存領域を作る前に、「iCloudで同期」と「このiPhoneのみ」を同格で提示します。どちらも
推奨扱いにせず、それぞれの説明を確認した利用者が一方を選びます。Version 1.0では選択後に保存先を
変更できません。

「このiPhoneのみ」は、Apple Accountやnetwork接続なしで全ての基本機能を利用でき、専用のrandom
namespaceを持つ端末内storeへだけ保存します。iCloudへ自動で切り替えたり、uploadしたりしません。

「iCloudで同期」を選んで確認した場合は、テーマ名、成果メモ、完了セッションと自己申告時間を含む
記録、設定、進行中タイマーを、端末と利用者のApple Accountにあるprivate CloudKit databaseへ保存・
同期します。選択時と各launch／resumeで、`CKContainer.accountStatus`と`userRecordID`を確認し、private
databaseのrecord zoneをread-only取得して同じApple Accountへのonline accessを確認します。通信できない、accountを確認できない、別accountへ切り替わっている場合は、
保存領域を開かないfail-closed状態にしますが、保存済みdataを削除しません。瓶・結晶などの表示用集約は
端末ごとのlocal storeで同期元記録から再構築し、CloudKitへuploadしません。運営者が管理する独自
サーバーへ集中記録を送信しません。

Version 1.0のホーム／ロック画面Widgetは、アプリを開くためのaccount-neutralな案内だけを表示し、
記録、質量、テーマ名、瓶画像を読み取りません。集中を明示的に開始したときのLive Activityも
account-neutralで、アプリ名、選択時間、残り時間、実行状態だけを表示します。ActivityKitへ渡す属性は
ランダムなセッションUUIDと秒数だけで、テーマ名、メモ、質量、Apple Account identifier、CloudKit
dataを含めません。Live Activityは端末内で更新し、独自serverやActivityKit pushへ送信しません。
設定から端末ごとに無効化でき、OS側の許可も尊重します。終了通知も同じ境界に従い、設定にかかわらず
テーマ名を含まない共通文面です。

## 外部処理と権限

- StoreKit: 商品情報、購入、復元、現在の権利をAppleへ確認
- CloudKit: iCloudを選び確認した場合だけ、同じApple Accountの対応iPhone間で同期元データを一つの
  private databaseに保存・同期
- Notifications: タイマー終了を端末上で通知
- ActivityKit: 明示的に開始した集中の残り時間と状態だけを端末のロック画面へ表示。端末内で更新し、
  独自server、push、アカウント由来dataを使用しない。アプリ内設定をオフにすると既存表示も終了
- Photos: 利用者が選んだときだけ生成済み静止画を追加
- Core Motion: 瓶を端末の傾きや軽い振る操作に合わせて動かすため、その場で利用する。iOSが利用許可を
  求める場合は目的を表示し、許可しなくてもtapと他の集中機能を利用できる。値、tap、判定結果を
  保存・送信せず、アプリがinactive／backgroundの間は更新を停止
- UIKit device orientation: 集中・休憩タイマーの上下左右のレイアウトに、端末の向きの通知を利用する。
  瓶用のCore Motionとは別のUIKit APIで、追加の権限を要求しない。端末から届く向きとタイマー中の
  一時的な手動選択は実行中のメモリだけに保持する。設定で選ぶ既定の向き（自動／上／右／下／左）だけを
  このiPhoneのUserDefaultsに保存し、同期・送信・JSON書き出しはしない。通常の記録リセットでは保持し、
  アプリ削除時には消去される。タイマー画面を閉じたときやinactive／backgroundでは向きの更新を停止
- AVFoundation／Core Haptics: 瓶の粒に対する操作を音と触覚で返すため端末内だけで利用する。
  録音、音声取得、操作履歴の保存・送信は行わず、音と触覚は設定から個別に停止可能
- System share sheet / pasteboard: 利用者の明示操作時だけ共有物または定型本文を渡す

GIFの一時ファイルを安全に検証・消去するため、アプリのコンテナ内に作成したファイルの
作成日時と更新日時を参照します。この情報は端末識別や追跡に使わず、端末外へ送りません。

広告、追跡domain、解析SDKはありません。`Analytics.shared`は通信・保存・logを行わない
`NoOpAnalytics`です。

## 製品Webサイト

製品サイトで配信する各ページはGitHub Pagesで配信します。
site source自身はcookie、広告、analytics、行動追跡を実装しません。通常のWeb配信に伴い、GitHubは
IP address、User-Agent、access日時、request URL、security／network診断情報などをservice提供、
安全性、可用性のために処理する場合があります。この処理をアプリの集中記録とは結び付けません。

App Store、GitHub、Appleの購入履歴や規約などへの外部linkは、利用者が選んだ場合だけsystem
browserで開きます。遷移先には通常のWeb通信としてIP address、User-Agent、referrerなどが
送られる場合があり、各事業者の規約とprivacy policyが適用されます。

## 共有時の最小化

共有画像・GIFと定型本文には累計質量と、利用者が選択または入力したハッシュタグを含めます。
保存済みの集中テーマ、成果メモ、顧客名、CloudKit identifier、位置情報を自動では含めません。
任意タグへ入力した文字列は共有されるため、顧客名や案件名などの機微な情報を入力しないで
ください。共有先のアプリが受け取った後の処理は、そのサービスの規約とプライバシーポリシーに
従います。

「データを書き出す」はSNS向け共有とは異なり、利用者が自分のSwiftData保存データを取得する
ための手動操作です。端末で利用可能なテーマ、全記録（リセット以前の旧世代、削除済み成果の
tombstone、旧形式を含む）、
成果メモ、設定、同期用のランダムな端末識別子をversioned JSONへ保存し、system share sheetへ
渡します。アプリが送信先を自動選択したり、運営者へ送信したりすることはありません。
一時ファイルはshare sheetを閉じた後に削除し、OS中断で残った場合も24時間後に削除します。
一時書き出しdirectoryとfileには、端末lock中のaccessを防ぐcomplete data protectionを指定します。
画面のヒント表示済み状態、審査依頼の回数、実行中処理の一時cacheなど、同期対象ではない端末内の
UI／runtime状態は書き出し対象に含めません。

記録リセット後の通知・Live Activityの消去が中断された場合に再試行するため、保存先ごとの端末内
UserDefaultsへリセット世代UUIDと受付UUIDを一時保存します。正常完了後に消去し、同期、送信、
JSON書き出しには含めません。集中テーマ、記録内容、Apple Account identifierは保存しません。

このJSON書き出しは、選択した保存先で端末から利用できる全11種類の出荷対象SwiftData保存データを
対象とします。Version 1.0にはJSONを再importする機能がなく、local-only dataをiCloudへ移行したり、
別端末で記録を継続したりするためには使えません。iCloud側の当該app dataはAppleのiCloudストレージ
管理の対象です。

## サポートへのお問い合わせ

Webのサポートページからメールを送る場合、送信元メールアドレス、メールヘッダー、本文、
任意の添付、および利用者が任意で記載した端末機種、OS・アプリのバージョン、不具合の状況を
受け取ります。これらは
返信、原因調査、購入復元の案内、セキュリティ対応のためだけに使い、広告、追跡、利用者の
集中記録との照合には使いません。メールは送信者側と運営者側のメールサービス事業者により
処理されます。機微な集中テーマ、顧客名、案件名、データ書き出しファイル、認証情報、秘密鍵、
署名資材を送る必要はありません。

お問い合わせ情報は、対応と再発確認に必要な期間に限って保持し、原則として最終応答から
12か月以内に削除します。法令対応または進行中のセキュリティ調査に必要な場合は、その目的に
必要な期間だけ保持することがあります。早期削除を希望する場合は、同じサポート窓口から
対象メールを特定できる情報を添えて依頼できます。

## 保持、リセット、物理的な削除

記録・設定・進行中タイマーなどの同期元データは、local-only選択時はこのiPhoneだけに、iCloud選択時は
端末とprivate CloudKitに保持されます。瓶・結晶などの表示用集約は端末内に保持し、同期元記録から
再構築します。
アプリ内の「表示中の記録をリセット」は同期対象のreset markerを作り、以前の世代を表示と集計から
除外します。この通常のリセットでは、競合防止のため旧世代の物理行が端末とiCloudに残る場合が
あり、データ書き出しにも含まれます。

1.0は独自の利用者accountを作成せず、private CloudKitのzoneをアプリから直接一括削除する機能も
提供しません。端末内の物理データはアプリを削除すると消去されます。local-onlyを選んだ場合、削除・
再install後は保存先を選び直せますが、以前のlocal記録は失われ、書き出したJSONからも復元・移行
できません。iCloud側のアプリデータはAppleが
提供するiCloudストレージ管理から削除できます。別のoffline端末に残るcopyは遠隔消去できないため、
不要なinstallationは各端末で削除してください。Appleが管理する購入履歴はこれらの削除対象外です。
運営者はprivate CloudKitの利用者データを保持せず、利用者に代わって閲覧・削除できません。

写真ライブラリへ追加した画像、Filesなどへ保存した書き出し、共有先へ渡した内容、clipboardへ
コピーした本文、送信済みのsupport mailは、アプリとiCloudの保存領域の外にあります。通常reset、
アプリ削除、AppleのiCloudストレージ管理では消えないため、必要に応じて各保存先・共有先で削除
してください。

## 運営者と変更

運営者・開発者はhinoshibaです。データflow、第三者service、法令または運用を変更した場合は、
公開プライバシーポリシーを更新し、最終更新日を改めます。利用者の判断に重要な変更は、適用開始前
または開始時にアプリ内や製品siteで分かる形で案内します。

## 変更時に再監査する項目

新しいSDK、network endpoint、permission、データ項目、共有項目、Widget、App Group、
required-reason APIを追加するPRは、次を同時に更新します。

1. `PrivacyInfo.xcprivacy`（各対象bundle）
2. このデータフローとWeb Privacy Policy
3. App Store ConnectのApp Privacy回答
4. 権限説明、保持・削除、第三者notice

App Store Connectで「収集」の該当有無を回答するときは、Appleの現行定義と実際のproduction
構成を提出直前に再確認します。この文書だけを根拠に自動で「Data Not Collected」を選びません。

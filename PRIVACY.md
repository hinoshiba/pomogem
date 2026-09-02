# Privacy architecture

この文書は公開ソース上のデータフローの正本です。利用者向けの正式なポリシーは
<https://tumiben.hinoshiba.com/privacy/>です。

## 保存するデータ

集中テーマ、完了セッション、進行中タイマー、自己申告時間、成果の石、瓶・結晶の状態、
設定をSwiftDataへ保存します。iCloudが利用できる実機では、private CloudKit databaseへ
同期します。運営者が管理する独自サーバーへ集中記録を送信しません。

WidgetとLive Activityには、App Group経由で必要最小限の集計値と瓶画像を渡します。
ホーム画面やロック画面に置いた内容は、端末の画面を見ることのできる人の目に触れる場合が
あります。ロック画面・通知にテーマ名を表示する設定は既定でオフです。

## 外部処理と権限

- StoreKit: 商品情報、購入、復元、現在の権利をAppleへ確認
- CloudKit: 同じApple AccountのiPhone間でprivate dataを同期
- Notifications / ActivityKit: タイマー終了を端末上で通知
- Photos: 利用者が選んだときだけ生成済み静止画を追加
- Core Motion: 瓶の重力計算にその場で利用し、値を保存・送信しない
- System share sheet / pasteboard: 利用者の明示操作時だけ共有物または定型本文を渡す

GIFの一時ファイルを安全に検証・消去するため、アプリのコンテナ内に作成したファイルの
作成日時と更新日時を参照します。この情報は端末識別や追跡に使わず、端末外へ送りません。

広告、追跡domain、解析SDKはありません。`Analytics.shared`は通信・保存・logを行わない
`NoOpAnalytics`です。

## 製品Webサイト

製品サイト、プライバシーポリシー、サポート案内はGitHub Pagesをorigin、CloudflareをCDN／
reverse proxyとして配信します。site source自身はcookie、広告、analytics、行動追跡を実装しません。
通常のWeb配信に伴い、GitHubとCloudflareはIP address、User-Agent、access日時、request URL、
security／network診断情報などをservice提供、安全性、可用性のために処理する場合があります。
CloudflareはEmail Address Obfuscationのscriptを配信HTMLへ挿入し、Network Error Loggingの
reportを受け取る場合があります。この処理をアプリの集中記録とは結び付けません。

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
ための手動操作です。端末で利用可能なカテゴリ、全記録（リセット以前の旧世代、削除済み成果の
tombstone、旧形式を含む）、
成果メモ、設定、同期用のランダムな端末識別子をversioned JSONへ保存し、system share sheetへ
渡します。アプリが送信先を自動選択したり、運営者へ送信したりすることはありません。
一時ファイルはshare sheetを閉じた後に削除し、OS中断で残った場合も24時間後に削除します。
一時書き出しdirectoryとfileには、端末lock中のaccessを防ぐcomplete data protectionを指定します。
画面のヒント表示済み状態、審査依頼の回数、実行中処理の一時cacheなど、同期対象ではない端末内の
UI／runtime状態は書き出し対象に含めません。

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

記録と設定は端末と、有効な場合はprivate CloudKitに保持されます。アプリ内の「表示中の記録を
リセット」は同期対象のreset markerを作り、以前の世代を表示と集計から除外して、遅れて届く
旧データを再表示しない設計です。完全オフライン端末へ反映されるのは、その端末が次に同期した
後です。競合防止のため旧世代の物理行は端末とiCloudに残る場合があり、データ書き出しにも含まれ
ます。端末内の物理データはアプリ削除で消去でき、iCloud側の物理データはAppleが提供するiCloud
データ管理から削除できます。運営者はprivate CloudKitの利用者データを保持・代行削除しません。

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

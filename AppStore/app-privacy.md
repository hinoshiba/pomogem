# App Privacy answer draft

1.1.0 (10)候補の実装に合わせた更新です。App Store Connectへの保存・公開結果は別のrelease recordへ記録します。

## 推奨回答

現行Release candidateについては、アプリ本体から運営者へ自動送信する仕組みがないため、
「No, we do not collect data from this app」を第一候補とします。これは実装だけで自動決定できる
回答ではなく、private CloudKit dataを運営者が取得・閲覧・保持しないことと、下記のsupport運用を
提出時にも満たすことが前提です。サポートページから利用者が任意で送るメールは、Appleのoptional
disclosure条件をすべて満たす場合に限って省略可能です。提出担当者が現行の質問文、production binary、
Apple teamの実際のaccess、mail運用を照合して最終回答します。

根拠:

- 独自account、analytics、ads、tracking、developer serverがない
- 初回に「iCloudで同期」と「このiPhoneのみ」を同格で提示し、確認後に一方を確定する。どちらも
  推奨扱いにしない。設定からの切り替えも、残る側と失われる側を示した明示的な確認だけで行う
- 「このiPhoneのみ」は全ての基本機能をApple Account／networkなしで利用でき、専用random namespaceの
  端末storeだけへ保存する。iCloudへ自動切替／uploadしない
- iCloudを選択した場合だけ、テーマ名、成果memo、記録、設定、進行中timerを含む7種類の同期元modelを、
  端末と利用者自身のSwiftData用private CloudKit databaseに保存する
- CloudKit user record IDはaccount境界の照合にだけ使い、container情報とともに端末内でSHA-256
  fingerprintへ変換する。local store名とdefaults keyには別のrandom namespaceを使い、raw identifierを
  埋め込まない。初回取得・同期再開ではaccountと保存先をonline確認し、通常起動のprivate control取得を
  通信確認にも使って前後のidentityを照合する。別accountや未対応の履歴不一致では書き込みを止め、
  保存済みdataを自動削除しない
- 初回は観測した世代以上のリセット履歴が端末へ届くまで期限付きで待機する。以前の確認済み端末dataと
  利用記録が条件を満たせば、同期なしでtimer・記録・設定を使える。変更は端末に保存し、同期待ちと表示する。
  accountのハッシュ、端末保存領域、確認済み世代、改訂ID、オフライン利用・失効状態を端末内に保持する。
  account変更の通知だけでは失効させず、確認できたaccount不一致などを根拠に利用許可を失効させる。オンライン利用後の復帰などではapp終了・再起動が必要になる。
  接続確認は全記録の送受信完了の証明ではない
- iCloud有効化はcloud内容で端末だけのdataを置き換え、結合しない。解除は検証済みコピーを端末へ残し、
  cloud側のdataも保持する。端末dataによるcloud全置き換えと復旧再開は通常Releaseで禁止する。
  進捗・元data・途中コピーを端末に保持し、取消しや後片付けの失敗ではコピーが残る場合がある。
  同じprivate CloudKit内の切り替え・復旧情報を確認し、許可された取消し・終了済み処理の後片付けを行う。
  新しい全置き換え用コピーは通常アプリからuploadしない。運営者向け収集や別containerを追加しない。
  iCloud中の「iCloudから再取得」は、cloud内容の事前読取と未選択の削除同意を経て端末の未送信変更を
  捨てる操作で、cloud側を削除しない。再起動待ちの同意はaccount・namespace・CloudKitコンテナ／環境に
  結び付け、環境が変わったリクエストや旧形式を実行しない
- Proの秒単位の既定時間は既存Prefsにoptional秒数と変更への参照を加え、選んだ保存先へ保持・同期する。
  既存の分単位の意味は維持する。iCloudの通常resetは一時停止し、local-onlyの通常resetは維持する
- `AggregatePebble`、`Stratum`、`Bedrock`、`GachaState`の4種類は端末内だけの表示用projectionで、
  同期元記録から再構築しCloudKitへuploadしない
- 瓶用のCore Motionはその場で処理し、保存・送信しない
- 集中・休憩タイマーはUIKitのdevice orientation通知で上下左右の表示を切り替える。追加の権限要求や
  Core Motion managerの追加はない。端末から届く向きとタイマー中の一時的な手動選択は実行中のメモリだけに
  保持する。設定で選ぶ既定の向き（自動／上／右／下／左）だけをこのiPhoneのUserDefaultsに保存し、
  同期・送信・JSON書き出しはしない。通常の記録リセットでは保持し、アプリ削除時には消去される
- shareは利用者の明示操作でsystem share sheetへ渡すだけ
- 全11種類の出荷対象SwiftData保存データのversioned JSON exportも、利用者の明示操作だけで生成し、
  選択した保存・共有先へ渡す。JSON再importはなく、このファイルによる復元・移行には対応しない。
  設定の保存先切り替えもJSONを読み込む処理ではない
- StoreKit transactionは端末上でApple署名をverifyし、developer serverへ送らない
- Live Activityは明示的に開始した集中のランダムなsession UUID、秒数、終了日時／残り時間、状態だけを
  ActivityKitへ渡して端末内更新する。theme名、memo、質量、Apple Account／CloudKit dataを含めず、
  ActivityKit pushやdeveloper serverを使わないため、この機能自体によるdeveloperのdata collectionはない
- third-party SDKがない
- version 1.0ではrare rewardのUI／writer／runtime repository pathと、二つ目のoperations CloudKit
  containerに接続するentitlement／capabilityを無効化している。将来検討用sourceと公開identifierは
  Release app targetにも残るため、production archiveでnetwork accessが到達不能なことを再確認する
- 1.0は独自accountを作らず、direct CloudKit一括削除UI／launch gateも出荷しない。端末側はapp削除、
  iCloud側はAppleのiCloudストレージ管理を案内し、offline別端末を遠隔消去できないことを公開policyへ明記

公開Support／Privacy／Termsと、購入前案内用の販売者情報URLはGitHub Pagesで配信し、接続情報とnetwork診断情報がGitHubで
処理される場合があります。これはapp binaryへ組み込んだ
SDKやappからの自動送信ではありませんが、公開プライバシーポリシーとsupport mailのoptional
disclosure判断には含めます。

サポートメールがoptional disclosureの条件を満たさないと判断される場合は、少なくとも
Email AddressをApp Functionality（customer support）目的、linked to user、trackingなしとして申告します。
通常のメールは送信元と内容を結び付けられるため、匿名化していない限り「linked to user」として
扱います。問い合わせへJSON export、集中記録、機微なテーマ名を添付させる運用にはしません。

## Publish直前の運用確認

- production archiveの全network endpoint、runtime SDK、privacy manifest、entitlementを再走査する
- CloudKitがprivate databaseだけで、運営者のserver、analytics、crash uploadへ転送されないことを確認する
- 初回保存先の二択が同格で、選択を確定するそれぞれの確認alertに次が表示されることをRelease実機で確認する。
  iCloud側はiCloudへ送る具体的data、online確認とoffline利用の条件、同期を止めるときのコピー先とcloud保持。
  このiPhoneだけ側はapp削除で記録が失われること、あとでiCloud同期へ切り替えるとこのiPhoneの記録が
  iCloudの記録に置き換わること、このiPhoneの記録をiCloudへ移せないこと（JSON書き出しの説明は初回画面に置かない）
- Apple Developer team／CloudKit運用者が利用者dataを日常support、debug、分析、backup目的で取得・閲覧・
  exportしない運用をownerが確認する
- support mailがAppleの現行optional disclosure条件を全て満たすか、実際の受付、保持、12か月以内の
  原則削除、早期削除依頼を含めて確認する
- 一つでも満たせない場合は「Data Not Collected」を選ばず、該当data type、purpose、linked status、
  tracking statusを実態どおり申告する

ただしこれは提出用draftです。Appleはappと組み込んだthird party全体の実態を正確かつ最新に回答
するよう求めています。提出直前にproduction archiveのnetwork、CloudKit access、StoreKit、
dependency、privacy policyを再監査し、App Store Connectの現行質問文に沿ってAccount Holder／
App Managerが最終決定・Publishします。

## Privacy Policy URL

`https://pomogem.hinoshiba.com/#privacy`

## Manifestとの整合

- Tracking: false
- Tracking domains: none
- Collected data types: none（上記のproduction／運用確認を完了した場合の候補。未確定）
- Main app required-reason APIs: File Timestamp `C617.1`、System Boot Time `35F9.1`、standard User Defaults
  `CA92.1`
- Widget required-reason APIs: none。Version 1.0のWidgetとLive Activity extensionは利用者data、CloudKit、
  App Group、UserDefaultsを読まず、account-neutralな起動導線または時間／状態だけを表示
- タイマーのUIKit device orientation利用によるdata type／required-reason API categoryの追加はない。
  端末内だけで処理する向きは[Appleの収集の定義](https://developer.apple.com/app-store/app-privacy-details/)に
  該当せず、使用APIは[required-reason APIの一覧](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)に該当しない
- 既定の向きの端末内保存には、すでに宣言しているstandard User Defaults `CA92.1`を使用する
- 中断されたリセット後処理の再試行用UUIDも、同じ`CA92.1`で保存先ごとの端末内UserDefaultsに保持する。
  正常完了後に消去し、同期・送信・JSON書き出しには含めない

新しいnetwork endpoint、SDK、permission、data retention、Widget accessを追加した時点で、このdraftを
無効として再回答します。

## Screen Time追加時の再監査

1.1.0候補はFamily Controlsの個人認証とDevice Activity Monitorを追加する。利用者が
選択・有効化したアプリの合計利用が10分刻みに達したイベントを処理し、アプリ名・Bundle IDの
取得やDeviceActivityReportからのデータ搬出は行わない。設定・不透明トークン・到達台帳・
黒い石は本体と監視拡張のApp Group内に保持し、バックアップ・CloudKit・共有・ログへ出さない。
監視の登録・停止やコールバックの件数・結果・所要時間、最後の通知時刻などの診断情報は端末内に
保持します。App Groupの件数を本体のApplication Support内へ写した診断ファイルもバックアップ対象外です。
os.Loggerには件数・結果・時間だけを出力し、アプリ名、token、run ID、到達段数、黒いgem数を出しません。
これらのログや診断ファイルを運営者へ自動送信する仕組みはありません。
学習の確定済み10分/100gだけを通常記録へ取り込み、本人がiCloudを選んだ場合はそのprivate
CloudKitへ同期する。運営者のサーバー、解析SDK、追跡処理の追加はない。

WidgetのApp Group非使用は維持する。監視拡張のPrivacy Manifestもtracking=false、
collected data types=[]とする。端末内処理だけではAppleのデータ収集に該当しないが、
配布権限は未確認で、現在のローカルdistribution profileはFamily Controlsを含みません。配布前に
実際のarchive・本体とMonitor拡張それぞれのFamily Controls配布権限・公開ポリシーとApp Store Connectの
最新質問を再確認する。Screen Timeの設定、未取込情報、黒い石は現在のJSON書き出しと
保存先移行に含まれないことをアプリと公開ポリシーで明示する。

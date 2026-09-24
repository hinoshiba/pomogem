# App Review notes draft

対象: 1.1.0 (10) 提出準備。公開中の1.0.2 (9)や過去の実機記録とは区別します。
本体・Monitor拡張のFamily Controls配布権限と最終署名済み候補の実到達試験は未確認です。
Connectへ貼る短縮版は[review-notes-connect.txt](review-notes-connect.txt)を正本とします。

ポモジェムは独自アカウント登録不要のiPhone集中タイマーです。最初の画面で、同格の二つの保存先
「iCloudに保存して同期」と「このiPhoneだけに保存」から明示的に選び、確認して確定します。どちらも
推奨扱いではありません。審査では「このiPhoneだけに保存」→確認alertの「このiPhoneだけで始める」を
選ぶと、Apple Accountへのサインインやnetwork接続なしで基本機能を確認できます。続くonboardingで
任意の「ためしに一粒、落としてみる」（記録には入りません）を実行するか「次へ」で省略し、勉強・
仕事共通の候補から最初のテーマを1つ選ぶとHomeへ進みます。利用目的の選択や勉強／仕事のmode切替はありません。
25分／45分／60分／90分timer、記録、瓶、設定を無料で利用できます。Homeでテーマと時間を選び、
大きな開始buttonをtapするとtimerを開始します。テーマと時間は開始buttonの上にある選択欄で変更できます。
テーマの追加・編集・並べ替え・削除はSettingsの一つの「テーマ」一覧で行います。短時間で完走を確認する場合は、
ポモジェムPro購入後に Homeの時間表示 → 「自由な時間を設定」 で1分を設定してください。無料状態の最短
timerは25分です。hidden demo/debug menuはRelease buildにありません。
Proの設定画面は分・秒の数字入力とホイールに対応し、1分00秒〜360分00秒を指定できます。
入力中にtimerは開始せず、取消では既定時間を変えません。確定して保存できた場合だけ選択時間へ反映します。
秒単位timerの引き継ぎは両端末の更新が必要と画面に表示します。秒数は記録に保持し、瓶の質量は
完了した分ごとに10gです（1分30秒は90秒の記録、10g）。

集中・休憩画面は4方向に対応し、横向きでは時計と操作を左右に配置します。
Settings → 集中 → 「タイマーの既定の向き」で、自動／上／右／下／左を選べます。初期値は自動で、
iPhoneの向きに合わせて切り替わります。既定値はこのiPhoneだけに保存し、新しい集中・休憩timerの
開始時とapp再起動時に適用します。
左上の回転buttonは「上→右→下→左」の順に手動で向きを固定し、「自動」で端末への追従に戻せます。
この一時的な切替は既定値を変更せず、同じtimerの画面再生成をまたいで保持します。次のtimerは既定値で始まります。
iOS 26以降は画面の向きのロックを尊重します。それより前のiOSではlock状態を取得する公開APIがないため、
UIKitが届ける向きの通知に追従します。手動固定はすべての対応OSで利用できます。

## In-App Purchase

- Product ID: `com.hinoshiba.pomogem.pro.lifetime`
- Type: Non-Consumable
- Entry: Homeの時間表示 → 「自由な時間を設定」、またはSettings → ポモジェムPro
- Unlocks: 無料の25分／45分／60分／90分以外の任意の1分00秒〜360分00秒を秒単位で指定、まとまり粒の月刻印、スクリーンタイムの勉強アプリ数無制限（無料5つ）
- Restore: purchase screenの「購入を復元」
- Pricing: United States USD 0.99 base price; Japan JPY 100 custom price; other available storefronts use Apple's automatically generated local equivalent
- Availability: App and IAP are available in 148 of 175 storefronts. Austria, Belgium, Bulgaria, Croatia, Cyprus, Czech Republic, Denmark, Estonia, Finland, France, Germany, Greece, Hungary, Ireland, Italy, Latvia, Lithuania, Luxembourg, Malta, Netherlands, Poland, Portugal, Romania, Slovakia, Slovenia, Spain, and Sweden are excluded. United Kingdom, Norway, and Switzerland remain included; automatic availability for new storefronts is enabled.
- Pre-purchase disclosure: purchase buttonの前に「価格・提供条件・販売者情報を確認」linkを表示
- Subscription、trial、Web決済、外部purchase linkはありません
- Share card: 無料／Proとも、ポモジェムのロゴと`https://pomogem.hinoshiba.com/`を常に表示し、共有本文にも同URLを含めます

25分、45分、60分、90分、記録、どちらかの保存先、瓶の基本体験はpurchase不要です。Version 1.0はランダム報酬を
提供せず、完走時はテーマ色の通常粒を保存します。

## Apple services and permissions

- Screen Time（1.1.0候補）: Settings → スクリーンタイム →「アクセスを許可」でindividual authorizationを
  許可します。勉強アプリと記録先テーマを選び、記録をオンにして「保存」。複数の選択アプリをまたぐ合計
  10分ごとに、復帰後の瓶へ600秒・100gぶんの通常gemを追加します。無料は勉強アプリ5つまで、Proは無制限。
  「黒いgem」側のアプリは無料でも無制限で、別に合計10分ごとに黒い障害物を追加します。黒同士だけで
  結合し、学習時間・共有画像には含めません。二つの集合は重複不可、カテゴリ／Webは選択不可です。
  アプリの選択と黒いgemはApp Groupの端末内台帳だけに保存し、tokenをCloudKitやJSON exportへ渡しません。
  10分未満の端数は日付変更・設定変更・停止でリセットし、timer中は学習側を休止して二重加算を防ぎます。
  OS通知には遅延があり、アクセス拒否や監視失敗は設定へ表示します。実機での確認手順と配布前に必要な
  本体・Monitor拡張のFamily Controls distribution承認は[ScreenTimeGems.md](../Docs/ScreenTimeGems.md)に記載。
  この追記はApp Store Connectへの転記・Apple承認・実機検証の完了を示しません。

- SwiftData private CloudKit: iCloudを選び確認した場合だけ、テーマ名、成果memo、記録、設定、進行中
  timerを含む7種類の同期元modelを一つのprivate containerへ保存し、同じApple Accountの対応iPhone間で
  同期。初回取得と同期再開にはaccount・保存先・リセット履歴をオンラインで確認する。通常起動の
  control取得を通信確認にも使い、取得前後のidentity一致と画面公開前の再検証を行う。
  初回はサーバーで観測したリセット履歴以上の世代が端末へ届くまでwriterを公開しない。
  待機には期限があり、接続確認は全記録の送受信完了を保証しない。独自loginなし
- Offline in iCloud mode: 確認済みの端末dataが利用条件を満たせば、同じ端末storeを同期なしで開き、
  timer・記録・設定を利用できる。「このiPhoneに保存・同期は待機中」と表示する。通信が戻れば
  account・保存先・リセット履歴を確認して同期再開へ進む。account変更や未対応の履歴不一致では停止し、
  記録の自動削除・修復はしない。同期用storeを一度開いたprocessでbackgroundから戻る場合などは、
  安全にoffline用storeへ切り替えられず、app終了・再起動を案内する
- This iPhone only: 全ての基本機能をApple Account／networkなしで利用可能。専用random namespaceの
  local storeだけへ保存し、iCloudへ自動切替／uploadしない
- Local projection: 瓶とまとまり粒に使う`AggregatePebble`、`Stratum`、`Bedrock`、`GachaState`は
  CloudKitへuploadせず、選択した保存先の同期元記録から各端末で再構築。iCloudから後着した記録の
  再検証中は、古いaggregateを生涯の正確値や`+`／`以上`として表示せず「再集計中」と表示し、完了後に更新
- Notifications: timer終了と、任意の「集中に戻るお知らせ」。集中・休憩timer終了の通知だけを
  Time Sensitive（即時通知）として送り、本人が開始したtimerの終了をFocus中にも届ける。毎日の
  リマインダー、今月の積み重ね、集中に戻るお知らせは通常の`.active`。後者はSettings → 集中でオンにして
  通知を許可すると、計測中にアプリを離れて30秒後に一度通知し、復帰・一時停止・中断時に取り消す。
  画面ロックも対象。休憩中と終了間際は予約しない。通知本文は常にaccount-neutralで、テーマ名を含まない。
  timer終了通知の許可は、利用者が初めて明示的に集中を開始したときに一度だけ尋ね、復元・iCloud引き継ぎ
  では尋ねない（毎日のリマインダーとは別）
- Widget: Home／Lock Screenともaccount-neutralな起動導線だけを表示し、記録、質量、テーマ、画像を
  App Groupから読まない
- Live Activity: Homeで任意のtimerを開始してiPhoneをロックすると、ロック画面へアプリ名、選択時間、
  残り時間、実行／一時停止／完了状態だけを表示。テーマ名、メモ、質量、Apple Account、CloudKit dataは
  extensionへ渡さない。更新は端末内のみでActivityKit pushなし。通知権限とは独立し、Settings → 集中 →
  「画面を閉じてもタイマーを表示」で端末ごとに停止可能。Dynamic Islandにも残り時間を表示し、
  展開表示とロック画面に帰還案内を出す。タップするとアプリを開き、既存の集中画面・復元処理へ戻る。
  pause／resume／cancelはアプリの集中画面から確認可能
- Core Motion: Home表示中、端末の傾きで瓶の重力を計算し、軽い往復shakeで粒を動かす。
  `NSMotionUsageDescription`で目的を表示し、許可しなくても瓶のtapと他の集中機能を利用可能。値は
  端末内で即時処理するだけで保存・送信せず、inactive／backgroundでは更新を停止
- UIKit device orientation: 集中・休憩タイマーの回転に使う。瓶用のCore Motionとは別で、追加の権限を
  要求しない。端末から届く向きとtimer中の一時的な手動選択は実行中のメモリだけに保持する。
  設定で選ぶ既定の向きだけをこのiPhoneのUserDefaultsに保存し、同期・送信・JSON書き出しはしない。
  通常の記録resetでは保持し、app削除時には消去される。timer画面を閉じたときやinactive／backgroundでは
  向きの更新を停止
- Photos add-only: 利用者が静止画の保存を選んだ場合だけrequest
- StoreKit 2: productとverified entitlementの確認。独自purchase serverなし

## 保存先切り替えの確認

- 実行中・一時停止中のtimerを終了して、Settings →「iCloudを有効にする」→「iCloudのデータを使う」。
  端末だけのテーマ・記録・設定を削除してiCloudの内容に置き換える。先に両側の件数を読み取り専用で
  表示し、iCloudが空なら警告する。二つの記録を結合せず、最後の削除確認checkは未選択で始まる。戻る・取消・仮選択だけでは開始しない。
- iCloud利用中はSettings →「iCloudと保存先の変更」→「このiPhoneへ引き継ぐ」。確認できたcloud内容を
  端末へコピーし、検証後に同期を解除する。cloud側のdataは残り、解除後の端末変更は同期されない。
- 端末dataでiCloud全体を置き換える選択肢は理由を表示して無効化。受付済み・別端末の置き換えの
  復旧再開も通常のReleaseでは拒否する。既存dataや復旧用コピーを削除して停止を解除しない。
- 切り替えには通信と、案内に従ったapp終了・再起動が必要。app自体を削除しないよう表示する。
  確認中にcloud内容が変わり一致しない場合は保持して停止し、許可された取り込み途中の取消では
  元data・cloud・途中コピーを保持して再起動を案内する。この保持コピーは利用者向けUndoではない。

iCloud利用中は同じ設定画面の「iCloudから再取得」も選べます。先にcloud内容とこの端末の件数を読み、
両方を表示します。cloudに記録と成果が0件なら、この端末で失われる件数を添えた空データ警告を表示します。「最後の確認」の未選択checkで端末の未送信変更を失うことを
確認してから受け付け、再起動後に新しい端末保存領域へ取得します。cloud側のdataは削除せず、
二つの記録は統合しません。転送台帳が無いアカウントも対象ですが、読取失敗では確認画面を開きません。
受付リクエストはaccount、namespace、CloudKitコンテナ／環境と世代に結び付けます。
別環境・旧形式の環境不明リクエストは実行せず、既存の受領記録やデータを変更しません。
管理情報なし・別環境・ローカル受領記録なしを分け、観測していない他端末の置き換えを主張しません。

別端末で完了した保存先の世代と端末が一致しない場合、明示的な再取得には端末の未送信変更を失う
確認が別途必要です。「復旧手順」を読むだけでは削除へ同意した扱いにしません。
app削除はlocal-onlyの記録とcloudへ未送信の変更を消去します。JSONは再importできず、復元・移行には使えません。

direct CloudKit一括削除UIと削除用launch gateは無効です。記録保護のため、iCloud選択時のSettings →
「表示中の記録をリセット」は一時的に利用できず、理由を表示します。「このiPhoneだけに保存」では
引き続き利用でき、以前の世代を表示・集計から除外しますが、物理消去ではありません。端末内dataはapp削除、iCloud側の
app dataはAppleのiCloudストレージ管理から削除するよう案内します。offline別端末は遠隔消去
できません。

SettingsのJSON exportは、選択した保存先で端末から利用できる全11種類の出荷対象SwiftData modelを
対象とします。JSONの再import機能はありません。iCloud側のapp dataはAppleのiCloudストレージ管理から
管理できます。

計画modeは将来の積み上がりを一時的に表示する公開機能です。実記録、抽選、iCloud、Widgetへ
書き込みません。テストアカウントは不要です。

スクリーンタイムの監視登録・停止と到達通知の件数・結果・時間は端末内診断に保持します。
本体とMonitorのApp Group内の件数と、本体Application Supportの診断コピーはバックアップ対象外です。
os.Loggerへtoken、アプリ名、run ID、到達段数、黒いgem数は出さず、自動の外部送信もしません。
学習側の取り込み済み10分記録は計測済みの学習時間・質量・共有に含みます。黒いgemは含めません。

## 起動とオフライン利用

OSのactive待ちが続く場合は期限付きで案内と再試行へ進みます。account状態変更の通知だけでは
既存のoffline利用許可を取り消さず、現在accountの確認や利用条件の検証に進みます。明示的な
account不一致・利用不可を確認した場合は引き続き保護のため停止し、自動で記録を削除しません。

## Jar sound, haptics, and motion test

実機iPhoneで本体の消音モードを解除してください（効果音は`.ambient`として消音設定を尊重します）。

1. すぐ粒を用意するには Home menu → 「時間を手動で積む」→「30分」→「確認して積む」を選びます。
   Homeの瓶で粒付近をtapすると、局所的に跳ね、短いカラン音と触覚が同期します。
2. iPhoneを軽く左右へ往復させると、単発の傾きや机への接触ではなく、反転した2回の加速を検知した
   ときだけ瓶全体が動きます。粒数が多いほど音の密度が増え、大きいまとまり粒ほど低い音と丸く重い
   触覚になります。1操作あたりの音数と触覚数には上限があります。
3. Settings → 音／触覚でそれぞれ独立にOFFにできます。どちらをOFFにしても記録、瓶、tap操作は利用可能です。
4. iOSの「視差効果を減らす」のON／OFFに関係なく、粒は同じ物理挙動で跳ね、落下し、傾きやシェイクにも
   反応します。ONのときはカメラの揺れ、光、粒子などの装飾演出を抑えます。

音はAVFoundationで数学的にPCM生成し、録音・stock sample・生成AI音源・download assetを使いません。
Core Motionの値、tap、生成した音buffer、触覚eventは保存、analytics、network送信に利用しません。

自己申告の上限は、この端末で朝4:00区切りの1日3件です。iCloudを選んだ複数端末が同時に
offlineの場合、各端末がそれぞれ最大3件を保存でき、再接続後のaccount全体件数は3件を超える場合が
あります。これはofflineでも記録を失わないための端末単位制限であり、勤怠・試験等の証明用途を
想定していません。アプリ内表示も「この端末で」と明記します。

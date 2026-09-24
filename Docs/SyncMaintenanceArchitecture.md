# ポモジェム — iCloud同期後の有界メンテナンス設計

更新日: 2026-09-06（新アプリの識別子・初回schema手順）

## 1. 目的

この文書は、SwiftDataとCloudKitから後着するデータを、最初の瓶画面や操作中のUIを止めずに、決定論的かつ再開可能な形で整理するための実装契約を定義します。

この仕組みが守る成果は次のとおりです。

1. 40年・350,640セッション規模でも、Home、瓶、集中開始、設定を操作できる
2. CloudKitの同期元recordの到着順が前後しても、質量、実績、タイマー所有権と、端末内で再構築する集約階層が最終的に収束する
3. アプリ終了、バックグラウンド移行、通信断、途中失敗のあとも同じ修復を安全に再開できる
4. 活動データのreset世代が未知の行を、誤って削除または現在世代へ混入しない
5. 初回オンボーディングと、利用者が削除したテーマの選択を壊さない

ここでいう「メンテナンス」は、表示前に全データを正常化する起動ゲートではありません。表示は安全な会計frontierとreset gateで先に成立させ、深い修復は小さなsliceへ分割して収束させます。

## 2. 非目的

次はこの仕組みの責務に含めません。

- CloudKitの通信を開始、停止、再試行、強制同期すること
- iCloud上の全レコードが端末へ届いたことを証明すること
- `CloudSyncMonitor` のアカウント状態を同期進捗へ読み替えること
- Home、Share、Settingsの画面設計を変更すること
- 初回オンボーディングで利用者が選んでいないテーマを追加すること
- `SeedData.bootstrap` をそのまま本番のバックグラウンド処理として呼ぶこと
- 1回の起動または1回のforeground滞在中に、全修復を必ず完了させること
- 未知のCloudKit到着順に対して、推測で欠損データを補完または削除すること

## 3. 実装状態と残る検証gap

`SyncMaintenanceCoordinator`、durable checkpoint、`SyncMaintenanceSliceWorker`とRootのforeground
drainはproduction pathへ実装済みです。各sliceは最大fetch 256行、総access 1,024行、save 1回に
制限し、failure時の指数backoffはforeground中もcancellable timerで再開します。ここで残るgapは
署名済み2台／production CloudKitでの配信順序・長時間中断試験、最新Release candidateでの全test、
iOS 18+ History token経路の追加最適化です。iOS 17の正しさはrolling verification fallbackで成立させます。
初回の同格な保存先選択、local-only namespace、cloud modeのaccount identity fail-closedとlocal namespace
分離は実装済みですが、両modeとA→B block→A復帰を含む実機検証まではproduction上の分離を実証済みと
しません。rare台帳はversion 1.0で無効です。将来有効にする
場合は、SwiftData側のpending commit／cursorをactive Apple Accountへbindingし、account切替時に
別accountへ送らない境界も改めて設計・実機検証する必要があります。

### 3.1 永続化境界

この節の変更不可・再インストールに関する記述は、保存先切り替えを含まない既存版の制約です。
開発中の次候補は明示した処理とdurable journal、commit済みreceiptを根拠に保存先を変更します。
有効化はcloudか端末のどちらを残すか選び、解除はcloudを端末へコピーしてcloud側を残します。
通常起動の暗黙の切り替えやmergeは許可しません。切り替え中はappを削除せず案内に従い再起動します。
[保存先切り替えの仕様と未完了gate](StorageModeTransfer.md)を参照してください。

version 1.0は最初の`ModelContainer`を作る前に、同格の「iCloudで同期」と「このiPhoneのみ」を提示し、
それぞれの確認後に一方を確定します。どちらも推奨扱いにせず、選択はVersion 1.0では変更できません。
shipping `ModelContainer`は選択に応じて次の分離を使います。

- iCloud選択時の`iCloud.com.hinoshiba.pomogem`: `Subject`、`StudySession`、`AchievementStone`、`Prefs`、
  `ActivityResetMarker`、`SyncedFocusTimer`、`FocusTimerDeviceClaim`の7 modelだけをprivate CloudKitへ同期
- iCloud選択時の`PomoGemLocalProjection`: `AggregatePebble`、`Stratum`、`Bedrock`、`GachaState`の4 modelを
  端末内だけに保存し、上記同期元recordから再構築。CloudKitへuploadしない
- local-only選択時: 同じ7 source modelと4 projection modelを専用random namespaceの別々の端末storeへ
  保存し、両configurationともCloudKit `.none`。Apple Account／networkなしで全基本機能を利用でき、
  iCloudへ自動switch／uploadしない
- rare reward operations container: version 1.0ではentitlement、shipping schema、runtime writerから
  無効化。将来の設計・回帰testだけをsourceに保持

現在世代またはmarker未着世代に属する7 source modelの物理rowは、CloudKitから後着する別copyの証拠です。
background maintenanceはそれらを決定論的なpure resolverで論理表示・会計へまとめますが、duplicateを
canonical rowへ書き戻したり、他copyへfan-outしたり、物理削除したりしません。物理削除を許すsource側の
例外は、supported reset markerで明示的に証明したstale epochと、同じUUIDの有効な`StudySession`がすでに
materializeしているとexact queryで確認した後のclosed focus active tailだけです。4種類のlocal projectionは
CloudKit sourceから再構築できる端末内dataなので、検証済みのmerge／compact／再作成を続けます。
利用者の操作以外で同期元rowの値を書き換えるのは、開発中の1.1.0が`StudySession.source`へ保存した
`screenTime`を、1.0.2も読める`manual`へ直す処理だけです。論理値（`effectiveSource`）は変わらず、
background maintenanceではなくScreen Timeの取り込みと同じ前面の書き込み境界で行います
（[ScreenTimeGems.md](ScreenTimeGems.md)）。

#### 3.1.1 Version 1.0の最終CloudKit source schema

PomoGemは新Bundle ID・新CloudKit containerで始める別アプリです。旧製品のstore、購入権利、CloudKit
recordを移行・共有しません。新containerに次のfieldを含む7-model schemaを初回production schemaとして
固定します。JSONはformat=`jp.hinoshiba.pomogem.user-data`、schemaVersion 3で出力し、再importはありません。

| Model | 最終RCで確認する追加field |
|---|---|
| `Subject` | `syncRecordID`、`contentRevision`、`contentMutationID`、`deletedAt` |
| `StudySession` | `syncRecordID` |
| `AchievementStone` | `syncRecordID`、`deletionRevision`、`deletionMutationID`、`restoredDeletionMutationID`（`revision`、`deletedAt`、`updatedAt`と併用） |
| `Prefs` | `syncRecordID`、`settingsWriterID`、`timerCompletionSoundRawValue`、`timerCompletionHapticRawValue`、`timerDisplayModeRawValue`、下記13 groupのrevision／mutation pair |
| `ActivityResetMarker` | 追加なし。既存の`id`／`epochID`／`sequence`を使用 |
| `SyncedFocusTimer` | 追加なし。既存の`id`／`sessionID`／`revision`を使用 |
| `FocusTimerDeviceClaim` | `syncRecordID` |

`Prefs`の13 groupは`sound`、`haptics`、`timerCompletionSound`、`timerCompletionHaptic`、`rareReward`、
`reminderEnabled`、`reminderTime`、`shareIncludesManual`、`externalTheme`、`keepScreenAwake`、
`preferredFocusMinutes`、`timerDisplayMode`、`usagePurpose`です。`timerCompletionSound`は`timerCompletionSoundRawValue`、
`timerCompletionSoundRevision`、`timerCompletionSoundMutationID`を持ち、`timerCompletionHaptic`は
`timerCompletionHapticRawValue`、`timerCompletionHapticRevision`、`timerCompletionHapticMutationID`を持ちます。
`timerDisplayMode`は`timerDisplayModeRawValue`、`timerDisplayModeRevision`、
`timerDisplayModeMutationID`を持ち、`ringAndTime`、`filledDial`、`timeOnly`、`ringOnly`の4種類を独立して
同期します。既定値と未知raw valueの表示fallbackは`ringAndTime`です。
`usagePurpose`はモデル構造とJSON field構成を維持する履歴groupです。旧containerとの接続や移行を意味しません。出荷UIは
勉強・仕事共通の一つのテーマ一覧を使い、この値で候補、設定画面、onboardingを分岐しません。
各groupは、たとえば`soundRevision`と`soundMutationID`のように、`<group>Revision`と
`<group>MutationID`を一組で持ちます。端末は`settingsWriterID`が自分と一致する1物理rowだけを更新し、
他端末rowをfan-out更新しません。resolverは各field groupを独立に選ぶため、別端末がofflineで別設定を
変更しても片方を失わず、同じ設定のtrue→false／false→trueもrevisionで表現できます。
`AchievementStone`のdurable削除eventは`(deletionRevision, deletionMutationID)`です。削除操作はeventを
作り、同じ物理rowを明示Undoする場合も`deletionRevision`と`deletionMutationID`を消しません。Undoは実際に
観測した削除tokenだけを`restoredDeletionMutationID`へackし、通常編集は削除eventとrestore ackを全て
保持します。pre-release legacy `deletedAt` rowは
`(row.revision, deletionMutationID ?? syncRecordID)`を削除eventとして合成します。activeな高revision rowでも、
未観測の新しい削除tokenをackしていなければ復活根拠にしません。

productionへpromoteする前に、新しい`iCloud.com.hinoshiba.pomogem`のdevelopment environmentを
最終RCでinitializeします。旧containerをclear／resetする工程はありません。新containerのdevelopmentに
試作schemaが残って再初期化が必要な場合も、対象とdata消去の許可を確認し、productionは変更しません。上記field名・型・default（`timerDisplayModeRawValue = ringAndTime`を含む）を
development schemaで照合し、clean install、4種類の表示選択、partial delivery、2台offline競合、exportを
検証した同一schemaだけをproductionへdeployします。
production environmentはclear／resetせず、schemaを再生成した別binaryを先に配布しません。public release
後のfield変更は、この初回initialize手順を再利用せず、released store fixtureとversioned migrationで
別releaseとして扱います。

configuration間のrelationshipは作りません。maintenanceは同期元recordを正本としてlocal projectionを
更新し、projectionの途中状態をCloudKitへ逆流させません。1.0では
`CompleteDataDeletionReleasePolicy.isEnabled == false`とし、direct CloudKit一括削除UIとlaunch gateを
このworkerの契約に含めません。Version 1.0のWidgetはaccount-neutralな起動導線だけを表示し、
SwiftData、CloudKit、App Group、snapshotを一切読みません。Live Activityはアプリ名、選択時間、残り時間、
実行状態だけを表示し、属性をランダムなsession UUIDと秒数に限定します。process終了中のApple Account
切替ではOSの描画cacheを同期失効できないため、system surfaceへ最初からaccount由来dataを置かないことを
境界にします。local-onlyから後でiCloudを始める場合は、必要に応じて
閲覧用JSONを書き出した後にappを削除・再installして選び直します。app削除でlocal記録は失われ、JSONは
再importできず、migrationや別端末での記録継続には使えません。

### 3.2 Apple Account境界

次候補のnamespace変更では、検証済みの明示したjournalまたはcommit済みreceiptだけを限定的な
authorityとして使います。通常launchで既存registryを書き換えず、account、保存元、保存先、
namespaceの他accountとの重複を確認します。commit済みの新cloud領域から旧cacheへ戻るfallbackは
許可しません。これは下記の通常mountのaccount確認を省略する仕組みではありません。

shippingのcloud modeは、利用者へtheme名、成果memo、記録、設定、進行中timerをApple Accountのprivate
iCloudへ保存することとonline確認要件を表示し、利用者がiCloud選択を確認した後、SwiftUIが`RootView`
またはCloudKit-backed `ModelContainer`を作る前に次の境界を確立します。

1. `CKContainer.accountStatus()`がavailableであることを確認する
2. `userRecordID()`を取得する
3. private databaseの全record zoneをread-only fetchし、通信不可またはactive iCloud accountなしなら失敗する
   fresh CloudKit requestを完了する。SwiftData管理containerへraw recordの作成・変更は行わない
4. `userRecordID()`を再取得してfetch前後のIDが一致することを確かめ、container IDとrecord IDを端末内で
   SHA-256 fingerprintへ変換する。途中で変わった場合はどちらもmountせず再試行を求める
5. 初回確定時はfingerprintとrandom UUID namespaceを不変の保存先profileへ保存する
6. 以後の各launch／resumeは、fresh request後のfingerprintと保存済みprofileが完全一致する場合だけ、
   cloud cacheとlocal projectionのSQLite URL、focus復旧／deferred完走、maintenance checkpoint、reset
   適用状態を同じnamespaceへ分離してcontainerをmountする

container作成後、`RootView`とそのwriterを公開する前には`CloudActivityHistoryPreflight`を通します。
private custom zoneの全ページからリセット履歴の必要fieldだけをread-only取得し、サーバーで観測した
winner以上の順序を持つ履歴が端末へ届くまでfresh `ModelContext`で待ちます。順序はsequence／writer／
epoch／idの全tupleで、`resetAt`は含めません。mountの世代・保存先とアカウントをawait前後で再確認し、
不完全な応答、cancel、90秒の履歴確認期限ではRootを公開しません。全同期元データのhydrationや
projection再構築をこのgateの完了条件にはしません。読み取りの前後のidentity確認は独自のzone一覧取得を
行わず（間の読み取りが通信の確認）、account statusと識別を保存先と照合します。直前の確認済み読み取りが残したbinding単位の変更token cache
（`CloudActivityHistoryMarkerCache`）から差分だけを読み、cacheの欠落・破損・key不一致・zone構成の変化・
token失効・zone消失では全zoneを最初から読み直します。

通信不可、account identity不明、保存済みfingerprintと異なるaccountでは旧storeへfallbackせず、記録領域を
開かないfail-closed画面に留まります。Bへ自動switchせず、元のAへ戻ってonline確認できた場合だけ同じA
namespaceを再利用します。fail closedは保存済みdataを削除しません。profile／store履歴の欠落、
破損、部分的なsource／projection pair、sidecarだけの履歴、複数namespace、未知artifactは新規選択で
上書きせずrecovery gateへ送ります。旧versionのregistryが存在する場合は整合性を検査しますが、存在しない
こと自体は正常です。registryは1.0のnamespace authorityではなく、1.0は作成・更新・保存しません。
ただし、選択profileを確定した直後、最初の
store fileを作る前にprocessが終了した境界だけは、fileが0件でも一度限りの正当なmount準備状態として
扱います。

`.CKAccountChanged`を受けたときは、Rootと既知のtimer side effectを
退役させ、旧`ModelContainer`が解放されてからidentityを再解決します。
通常backgroundでもsuspend前にstoreをunmountし、foregroundで再検証するため、processがaccount change通知を
受ける前にsuspendされた場合の旧store再利用を避けます。このboundaryはCloudKit import完了を意味しません。

2026-09-24の所有者承認により、unmountは`.background`の瞬間ではなく約15秒の猶予後に行います
（`CloudBackgroundGraceController`）。猶予中は`UIApplication` background taskを保持するのでprocessは
suspendされず、account change通知も配送されます。猶予はiOSの残りbackground時間から5秒を引いた値で頭打ちに
し、taskを得られない・時間が足りない場合は即座にunmountします。task期限の通知、`CKAccountChanged`、
storage transfer、complete deletionでは猶予を打ち切って即座にunmountし、taskは退役したcontainerの解放を
確認してから終了します（上限10秒、期限通知時は同期的にsessionを外してから終了）。猶予内にsceneが
activeへ戻った場合はRoot・sheet・瓶を維持し、background中に識別を1回再確認します。再確認で
`accountMismatch`・`noAccount`・`restricted`・registryの`blocked`が出た場合だけ`CKAccountChanged`と同じ
quiescenceへ進み、通信・期限の失敗ではsessionを維持します。猶予後の再マウントでは、同じnamespaceの
場合に限り直前のtab（瓶・記録・設定）を復元し、account changeやtransferで記憶を破棄します。

### 3.3 起動時の読み取りは意図的に小さい

`RootView` は最初の画面を守るため、次の上限付きsentinelだけを保持します。

| Model | Rootの上限 |
|---|---:|
| `Prefs` | 16 |
| `StudySession` | 32 |
| `AchievementStone` | 32 |
| `SyncedFocusTimer` | 64 |
| `FocusTimerDeviceClaim` | 96 |
| `AggregatePebble` | 96 |
| `Stratum` | 16 |
| `Bedrock` | 2 |
| `GachaState` | 4 |
| `ActivityResetMarker` | 1 |

これは起動性能として正しい一方、古い日時を持つ後着行や、上限外の既存行の更新をfingerprintだけで完全には検知できません。Rootのfingerprintは「変化が見えたときの早いhint」であり、完全な変更履歴ではありません。

### 3.4 現在のforeground reconciliationが済ませること

`RootView.reconcileIncomingActivityData()` は、UIを守るため次だけを行います。

1. 同時要求をcoalesceする
2. 最新のactivity resetを端末ローカル状態へ適用する
3. `BoundedLaunchPreparation.prepare` を実行する
4. bounded preparationが返した理由を `pendingLaunchMaintenanceReasons` へ追加する
5. boundedな`Prefs`情報からオンボーディング状態と、互換性用`usagePurpose`値を復元する
6. boundedな最新timer情報から、別端末の集中を引き継ぐ提案を作る

`BoundedLaunchPreparation` の各query契約は最大1行です。現行のdeep maintenance理由は次の5種類に限られます。

- `prefsSingletonCreated`
- `prefsSingletonCanonicalized`
- `gachaSingletonCreated`
- `gachaSingletonCanonicalized`
- `localFocusAwaitingResetMarker`

`prefsSingletonCanonicalized`はpre-release checkpoint互換のreason名であり、source `Prefs`を物理的に
canonical rowへ統合する許可ではありません。

### 3.5 軽量foreground reconciliationとworkerの分担

次は `reconcileIncomingActivityData()` 自身では実行せず、durable reasonを受けた
`SyncMaintenanceSliceWorker`が後続sliceで実行します。

- 既知の旧reset世代だけを対象にしたsource rowの物理削除
- `Prefs`を13 field groupごとに、全物理rowを保持したまま論理解決
- 同じlogical UUIDを持つ`StudySession`を、全物理rowを保持したまま論理解決
- 同じsession UUIDを持つfocus完走／active recovery／claimを、全物理rowを保持したまま論理解決
- materialized `StudySession`で閉じたことを証明したfocus active tailだけを別phaseで削除
- `AchievementStone`と`Subject`を、tombstoneを含め全物理rowを保持したまま論理解決
- `GachaState`、`Stratum`、`AggregatePebble`、`Bedrock`という端末内projectionのduplicate統合、
  membership、lineage、10進carry、legacy移行の修復

論理winnerがすでに見えている状態で別source duplicateが後着しても取りこぼさないよう、現行実装は
5つのlaunch理由だけに依存せず、各modelのbounded fingerprint、reset変更、foreground時のrolling
verificationからtyped kindをenqueueします。

### 3.6 `SeedData.bootstrap` は小規模oracleであり本番workerではない

`SeedData.bootstrap` は小さいfixtureに対する決定論的なrepair oracleです。`@MainActor`で複数modelを
全件fetchするため、40年storeの本番interactive pathからは呼びません。本番では同じ不変条件を
有界なModelActor workerへ移植済みです。

さらに、次のsubject seed処理を含みます。

```swift
reconcileSubjects(
    context: context,
    insertMissingPresets: !prefs.hasCompletedInitialSubjectSeed
)
prefs.hasCompletedInitialSubjectSeed = true
```

このseed動作を汎用workerへ移すと、初回オンボーディング前に全presetを作ったり、利用者が削除した
presetを別端末で復活させたりする危険があります。そのため`SeedData.bootstrap`はtest oracleとして
残し、本番workerは欠損presetを作らず、source rowのread-only論理解決とlocal projectionの
actor-safeなrepairだけを行います。

## 4. 必須の不変条件

### 4.1 データ会計

```text
生涯グラム = current loose sessions + current root aggregates
achievement stones = 0g
同じlogical sessionは最大1回だけ数える
```

修復途中でも、既存の安全なfrontierを破壊して二重加算や一時的な質量消失を起こしてはいけません。

### 4.2 reset世代

- supported markerは`sequence` 0...1,000,000だけ。範囲外はcorrupt／unsupportedとして勝者にも
  stale判定根拠にも使わず、対応epochのrowを推測で削除しない
- winnerの主順序はLamport-style `sequence`。同一sequenceは`writerDeviceID`、`epochID`、marker `id`の
  安定順で決め、`resetAt`は表示・監査metadataにしか使わない
- local-onlyの新しいresetは観測済みwinnerの`sequence + 1`。上限到達時はcounterを再利用せず操作を拒否する
- iCloudの利用者によるresetは、未反映の高いsequenceを見落として新世代を作る問題への対策として
  一時停止する。UIと`beginUserInitiatedReset`の両方で変更前に拒否し、既存markerは維持する
- markerが1件もない場合、`nil` epochだけがcurrent
- winning markerのepochがcurrent
- markerが存在する非winning epochと、marker存在後の`nil` epochはstale
- markerがまだ届いていない非nil epochは`awaitingMarker`
- `awaitingMarker`は表示から隔離するが、削除、統合、currentへの書換えをしない

物理削除は容量整理であり、正しさのsource of truthはappend-onlyなreset markerです。

### 4.3 logical groupの非破壊性

現在世代またはmarker未着世代のsource duplicate groupは、完全なbounded setをpure resolverへ渡して
論理winner／field winnerを求めます。groupの半分しか見えていない状態でも、見えているcopyを書換えたり
削除したりせず、次のdeliveryで再解決します。maintenanceによるcanonical書戻し、duplicate削除、全copyへの
fan-out更新は禁止です。利用者の明示操作だけが、Subject／Achievementでは選択した1物理row、`Prefs`では
自端末の`settingsWriterID`に一致する1物理rowへ新しいrevision／mutation IDを書きます。

端末内projectionのduplicate merge／deleteは、完全なgroupまたは証明済みconnected componentを同じsaveで
処理します。page境界でprojection groupの半分だけを保存してはいけません。

### 4.4 aggregateの保守性

missing child、cycle、重複membership、partial deliveryがある場合、証明できないflattened lineageを消しません。破壊的なcompactは、参照される全childが存在し、再帰的に同じ元session集合へ解決できる場合だけ行います。

## 5. 全体構成

```text
Root / foreground / History poll
            |
            v
MainActor MaintenanceCoordinator
  - pending kind + generation
  - durable checkpoint
  - exactly one in-flight slice
            |
            v
short-lived @ModelActor SliceWorker
  - bounded query / mutation / save
  - Sendable result only
            |
            v
MainActor side effects
  - local focus retirement
  - notification cleanup
  - optional passive UI refresh
```

`ModelContainer`はworkerへ渡せますが、`PersistentModel` instanceをactor間で渡してはいけません。workerはUUID、scalar snapshot、cursor、audit、完了理由などの`Sendable`値だけを返します。

## 6. Coordinatorの世代契約

### 6.1 理由の型

本番workerの理由は、bounded launchの5理由とは別に、少なくとも次の粒度を持ちます。

```text
preferences
gacha
sessions
focusFairness
achievements
strata
aggregates
bedrock
subjects
staleEpochCompaction
verificationSweep
```

`localFocusAwaitingResetMarker` はSwiftData graph repairではなく、端末ローカルenvelopeを守るMainActor側の待機理由として扱います。

### 6.2 Setだけではなくper-kind generationを使う

coordinatorは次のような論理状態を持ちます。

```text
pendingGeneration[kind] -> UInt64
cursor[kind]            -> phase-specific cursor
isWorkerInFlight        -> Bool
retryAttempt            -> Int
```

要求を受けるたびに、そのkindがすでにpendingでもgenerationを必ず増やします。

slice開始時には、対象kindとgenerationをsnapshotします。slice終了時にreasonを消してよいのは、現在のgenerationが開始時snapshotと同じ場合だけです。

```text
開始: sessions generation 7
実行中: 新しいsession importでgeneration 8
終了: generationが一致しないためsessionsを消さない
```

これにより、同じkindの変更がworker実行中に届いても失われません。成功時に`removeAll()`したり、開始時Setを無条件でsubtractしたりしてはいけません。

### 6.3 依存理由を展開する

上流reasonは、必要な下流reasonへ展開します。

| 入力reason | 追加する下流reason |
|---|---|
| reset marker | 全current-state phase、stale compaction、local focus再評価 |
| sessions | focus fairness、strata、aggregates、gacha、subjects |
| focus timer | focus fairness、sessions、gacha |
| strata | aggregates |
| subject | sessions・achievementsのsnapshotベース論理表示を再評価（source relationshipは書換えない） |
| preferences | user-state反映、bedrock確認 |

展開したreasonとgenerationは、worker開始前にcheckpointへ保存します。

### 6.4 exactly one in-flight

同じcontainerに対するmaintenance sliceは常に1本です。要求が増えた場合は実行中taskを増やさず、generationを更新して次sliceへ渡します。

sceneがinactiveまたはbackgroundになった場合は新しいsliceを開始しません。すでにatomic saveへ入ったsliceは完了結果を受け取り、それ以外はcancelしてcursorを保持します。

### 6.5 foregroundのidle graceとpacing

初回およびforeground復帰時のrolling verificationは、remote importの見落としがあり得るcloud modeだけが新規に要求し、first frameから60秒のcancellable idle grace後に開始します。local-only、in-memory、Simulatorのlocal storeにはremote blind spotがないため、初回の全範囲verificationを追加しませんが、既存checkpointと明示的なtyped reasonは失いません。drainは選択中tabに依存せず、sceneがactiveである限りSettings／Log／Overview／Shareを含む全画面の背後で継続します。さらにcloud modeのactive sceneは15分ごとにverification ticketを更新し、長時間同じ画面を開いたままでもrolling sweepを再要求します。fingerprintまたは通知が観測したimport reasonはverification markerより高いpriorityを保ちます。drain自体はbackground priorityで、成功したslice間に100msのcancellable pauseを置きます。350,640 sessionを128件pageだけで一巡する最悪ケースでは約2,740 sliceとなり、pauseだけで約274秒を追加しますが、cursorとgenerationが端末内checkpointへ保存されるため、1回のforegroundで完走させることより直接操作の応答性を優先し、終了・background後は同じ安全な境界から再開します。

## 7. `@ModelActor` slice worker契約

概念上の入出力は次のとおりです。

```swift
struct MaintenanceSliceRequest: Sendable {
    let kind: MaintenanceKind
    let generation: UInt64
    let cursor: MaintenanceCursor?
    let limits: MaintenanceSliceLimits
}

struct MaintenanceSliceResult: Sendable {
    let kind: MaintenanceKind
    let generation: UInt64
    let disposition: Disposition // completed / moreWork / retry
    let nextCursor: MaintenanceCursor?
    let audit: MaintenanceFetchAudit
    let mainActorEffects: Set<MaintenanceMainActorEffect>
}
```

workerはsliceごとに短命なinstanceを作ります。`ModelContext`には登録modelを明示的に全解放するpublic APIがないため、長寿命workerが何十万件のmodel faultを保持する設計を避けます。

### 7.1 初期budget

| 項目 | 上限 |
|---|---:|
| 1 queryの`fetchLimit` | 256行 |
| 1 sliceでaccess/materializeするmodel | 合計1,024行 |
| 1 sliceのsave | 1回 |
| 1 sliceの目標wall time | 30〜50ms |
| 同時slice数 | 1 |

wall timeは停止条件の補助です。同期fetchはdeadline到達時に中断できないため、時間だけで有界性を保証してはいけません。すべての個別queryにrow上限が必要です。

`ModelContext.fetch(_:batchSize:)` や `enumerate` の`batchSize`はmemory batchです。返されたcollectionを最後まで走査すれば総時間は無制限になります。`fetchLimit`、実際にaccessした行数、save回数を別々にauditします。

### 7.2 saveの境界

1 sliceで複数phaseを中途半端に保存しません。background workerがsaveできる単位は次のいずれかです。

- 証明が完了したlocal projectionのgroup、aggregate node、または小さいconnected component
- 256件以下の明示的に証明されたstale epoch source row削除
- exactなmaterialized `StudySession`で閉じたことを証明したfocus active tail削除

現在世代／marker未着世代のsource resolverは`saveCount == 0`です。読み取り途中のaccumulatorはcursorへ保存し、
完全な論理解決値が得られるまでsource rowを変更しません。`Prefs`、`StudySession`、`AchievementStone`、
`Subject`、focus timer／claimのduplicateを理由に、canonical書戻しや物理削除を追加してはいけません。

### 7.3 queryとpagination

- 行を削除または並べ替えながら`fetchOffset += pageSize`してはいけない
- stale削除は同じpredicateの先頭256件を繰り返す
- duplicate scanはlogical UUIDのkeyset、またはpage末尾groupのcarryを使う
- 同じUUID groupが256件を超える場合は、scalar accumulatorとcanonical identityをcursorに保持する
- cursorより前へ古い行が後着し得るため、History reasonまたは新generationでscanを再開する
- clean storeにsingleton reasonしかない場合、sessionやaggregateをscanしない

`fetchOffset`は、対象集合を一切変更しないread-only discovery phaseに限って使用できます。それでも新しいimportで集合が変わった場合はgenerationを更新し、cursorを無効化します。

### 7.4 stale削除

stale compactionは、全activity rowを先に読んでepochを分類しません。

1. exact orderingでwinning markerを1件読む
2. reset markerを小さいbatchで列挙する
3. winning epoch以外の「markerが存在するepoch」だけをknown staleとして扱う
4. 各modelを`dataEpochID == knownStaleEpoch`で最大256件ずつ削除する
5. winning markerが存在する場合だけ、legacy `nil` epochを最大256件ずつ削除する

markerが存在しないepochを削除queryの対象にしなければ、unknown generationは自然に保持されます。slice中にwinning markerが変わった場合、そのreset-dependent cursorを破棄してphaseを再開します。

## 8. phaseと依存順

### Phase 0: reset gate snapshot

すべてのsliceの冒頭でwinning markerを再確認します。cursorが記録したwinning epochと異なる場合、下流cursorを無効化します。

### Phase 1: singleton fast repair

- `Prefs`を全物理row保持のまま13 field groupごとに決定論的解決
- `GachaState` singletonのcanonical確認
- `Bedrock`の小さい統合
- `localFocusAwaitingResetMarker`のexact marker再確認

fresh installで端末所有の`Prefs` rowまたはlocal projection singletonが作られただけなら、小さい確認で
完了します。この理由から全履歴scanを開始しません。workerはforeign `Prefs` rowを変更せず、端末所有rowの
作成／設定変更も利用者操作またはbounded launch writerへ委ねます。

local focusが`awaitingMarker`のままなら、reasonを消さず、即時retry loopもしません。marker fingerprint、foreground、History eventのいずれかで再評価します。

### Phase 2: logical activity identityとfocus recovery

1. `StudySession` duplicateをlogical UUIDごとにpure resolverで一度だけ会計し、物理rowは全て保持
2. snapshot、grams、rare kindの論理winnerをstableなpolicyで解決し、legacy `isBaked`は会計根拠にしない
3. 同じsession UUIDのtimer履歴では、materialized `.completed`を不可逆な完走証拠とする
4. `.completed`がない場合、preferred completion-pendingと最早cancellationを集合として解決する。
   cancellationがscheduled endより前ならcancel、同時刻以降ならpendingを論理winnerとするが、両rowを保持
5. terminal rowがなければpreferred active revisionとclaimをlogical group単位で解決し、物理rowは保持
6. 異なるsession UUIDは破壊的にcancelしない。回復UI／通知だけを最古startのactive timerへ直列化し、
   offline端末間で時間が重なった別UUIDの完走は両方をmeasured recordとして保持する
7. exact queryで有効なmaterialized `StudySession`を確認した場合だけ、そのclosed sessionのactive timer tailを
   削除できる。これはduplicate compactionではなく、完走recordへmaterialize済みの一時active tail整理である
8. 影響するlocal projectionを保守的に再検証対象へ送る
9. gachaの最大512候補tailを、session/focus解決後に評価する

同一focus sessionの全pageは最大256行ずつread-onlyで検証し、pure resolverのaccumulatorと境界だけを
checkpointへ保持します。検証後もterminal／active／claimのCloudKit source copyを小さい証拠集合へfoldせず、
一行もcanonicalへ書戻しません。後方pageの破損はそのlogical groupを非破壊でquarantineし、別group／別kindの
maintenanceを継続します。interactiveなexact session queryは128行を上限とし、それを超える履歴を
truncated winnerとして利用せずmaintenance要求としてfail closedします。maintenanceが全pageを読んでも
source row数自体は減らないため、UIのbounded ceilingを超える履歴が自動的に解消すると主張しません。

account-wide interactive recoveryは、最新のactive rowの開始時刻（現在時刻より後なら現在時刻）から
`StudySessionIntegrityPolicy.maximumCompletionWallSpan`（7日）と端末間の時計差1日を引いた時刻以降に
開始したsessionだけを検査します。それより前に始まった集中は有効な`StudySession`になれず、回復・引き継ぎ・
完了のどれにも使えないためです。取り消した集中はrunning rowを残し続けるので、この下限がないと検査の
費用が生涯の取消回数に比例し、257回目の取消で引き継ぎと保存先の切り替えが止まっていました。rowは
削除せず、端末自身の回復は従来どおりlocal envelopeとexactな`completionGate`で判断します。
この範囲で検査するactive logical sessionは最大256件です。invalid groupは表示・
変更せず次の独立sessionへ進みますが、valid timerの前にinvalid active logical sessionが257件以上並ぶと
有界scanを使い切り、maintenance後もfail closedが継続し得ます。checkpoint quarantineは他作業を飢餓
させませんがrow自体をqueryから外さないため、この上限を解消しません。完全解消には、raw payloadを
保持したままinteractive predicateから除外し、再decode成功時に解除するversioned model-level quarantineが
必要です。version 1.0でschemaを増やさない場合は既知limitationとしてrelease ownerとsupportが受け入れます。

ただしこれはnetwork partition中の完走と取消をglobal transactionへ直列化する仕組みではありません。
未materializedのcompletion-pendingへscheduled end前cancelが届いてからcommit判定すればcancelを尊重します。
一方、別端末で`StudySession`がすでにmaterializeした後に同じcancelが後着した場合は、既保存の完走を削除・
demoteせず`.completed`を優先します。したがって「cancelをcommit前に観測したか／StudySessionが先に保存
されたか」により、partition境界の最終履歴が分岐し得ます。version 1.0は履歴を遡及削除する危険より
既保存完走の保護を選ぶ契約であり、強いglobal linearizabilityを主張しません。このCAP trade-offは
署名済み2台のoffline試験とApp Review説明で確認します。

gacha progressは、部分同期で後退させません。

```text
reconciled = max(known synced progress, locally proven progress)
```

### Phase 3: achievements

- 同じUUIDのduplicateをrevision、tombstone、stable physical identityで論理解決し、全物理rowを保持
- 表示時のnote sanitize、未来日時上限、subject name/color snapshot fallbackをwinnerから計算
- 通常編集は`deletedAt`、`deletionRevision`、`deletionMutationID`、`restoredDeletionMutationID`を保持する
- 明示Undoだけが選択した1物理rowへ高いrevisionと、観測済み削除tokenをackする
  `restoredDeletionMutationID`を書いてrestoreする。in-place restore後も元の削除event pairは保持する
- 質量へは加算しない

### Phase 4: legacy strata

- duplicate `Stratum`を統合
- 同じsession membershipを複数stratumへ所属させない
- local projection membershipを権威として会計し、source `StudySession.isBaked`は書換えない
- 対応するstratumが未着の場合、otherwise-unclaimed sessionをlooseとして論理表示する

### Phase 5: aggregate graph

- phase 0でduplicate aggregateをlogical ID単位に統合する
- phase 1で既存leafを一つずつ再検証する。leafのmember UUID一覧と各winnerの固定長SHA-256 digestだけを
  `AggregateLeafValidationState`へ保存し、ownerの一意性と各UUIDのcount/fetch/count exact readを複数sliceで
  行う。全member収集後の昇格sliceではmember 0から全件を再読し、全digestが一致した現物winnerからleafの
  全semantic payloadを再導出する。この一巡をslice budget内で完了できない異常密度は昇格せず、leafと
  ancestorを`projectionValidationVersion == 0`のままfail closedにし、同cursorの100ms busy loopではなく
  durable retryと指数backoffへ移す
- phase 2でHomeに通常のloose pebbleとして残す最新128 `StudySession`の境界を固定し、それより古い
  current sessionをUUID keysetで最大64件ずつ読む。最大10 sessionごとの決定的level-1 leafを、1 slice
  1 saveで不足分だけ作る。既存membershipは日付範囲ではなくexact UUID owner queryで判定する
- phase 3で同levelの検証済みlocal rootを10個単位に選び、決定的parent IDへ1 parent／saveでcarryする。
  既存parentをmax-mergeせず、child集合からgrams／count／source／reward／subject／dateを全て再導出する
- legacy stratumから互換aggregateを作る
- direct sessionとchild aggregateの構成を検証する
- parent/child backlinkを修復する
- 証明できるflattened lineageだけcompactする

aggregateは単純なpage単位で完結しません。Historyから得たdirty aggregate IDを起点に、parentと最大10 childをbounded frontierで辿ります。1回で完了しない場合はfrontierをcursorへ保存します。

empty local projectionからでも512件を超える履歴を再構築できなければ、Homeのbounded 512-row candidate
queryより古いsessionが集計から欠落します。このため620 session fixtureで、空local store、同じ`endAt`
のUUID tie、複数slice、save成功後checkpoint未更新のreplay、全grams／count／source／reward内訳、再generation
実行後のfingerprint不変を検査します。local projectionを正本にせず、cloud-authored `StudySession`を
再構築元とする点は変えません。

sessionから所属aggregateを逆引きするindexed relationshipは現行schemaにありません。session変更時は、aggregateのrolling verificationを独立phaseとして要求します。ただし40年のclean storeでmigration versionが完了済みなら毎起動scanしません。

`projectionValidationVersion`未達のaggregateが一つでも存在する間は、Home／Overview／Share等の全consumerで
aggregate rootを表示会計から除外します。cloud modeでは、起動後または新しいverification generationが
pendingの間も同様に、生涯の正確値、`+`、`以上`を表示しません。代わりに「再集計中」と、その時点で
端末上の同期元から確認できた範囲だけである旨を表示します。local-onlyにはremote blind spotがないため、
localな書込み完了後の値をexactとして扱えます。

### Phase 6: subjectsとrelationship

- presetと同一identityのsubject duplicateをrevision、sticky tombstone、stable physical identityで論理解決し、
  全物理rowを保持する
- version 1.0はsubject restore UIを持たないため、一度観測したsupportedな`deletedAt`は、より高いrevisionの
  offline renameより常に優先する
- tombstoneは削除しないため、全物理rowの件数は削除したテーマの数だけ増え続ける。表示・編集・この
  phaseの上限（256行）は削除されていない行だけに適用し、tombstoneはそれらと同じlogical IDのものだけを
  読む。以前は全行を数えたため、長期利用で257行に達すると全画面のテーマが消え、このphaseは`.retry`を
  繰り返して検証が終わらなかった。削除されていない行が上限を超える悪意ある複製は表示が空になるだけで、
  read-onlyのこのphaseは修復対象がないため完了する
- sessionとachievementはrelationshipをfan-out書換えせず、snapshot subject IDから論理表示を解決する
- missing presetは挿入しない
- `hasCompletedInitialSubjectSeed`をworkerから変更しない

### Phase 7: 許可されたphysical cleanup

supported reset markerでknown staleと証明したsource rowをmodelごとに小さく削除します。また、Phase 2の
materialized `StudySession` proofがあるclosed focus active tailだけを専用phaseで削除できます。このphaseの
未完了を理由にUIを止めません。現在世代／marker未着世代のsource duplicateは対象外です。local projectionの
検証済みcompactionは各projection phaseで行います。

## 9. checkpointとクラッシュ回復

checkpointはCloudKitへ同期せず、この端末だけへ保存し、検証済みApple Accountのrandom namespaceを
keyへ含めます。現行実装は小さいCodable payloadを`UserDefaults`へ保存します。CloudKit modelへ保存すると
別端末がこの端末の未完了作業を消し、global keyへ保存するとaccount切替後に前accountのcursorを適用する
危険があります。identity未検証中はactive namespaceへfallbackしません。

checkpointは少なくとも次を含みます。

```text
formatVersion
maintenanceSchemaVersion
pending generation per kind
phase cursor per kind
winning reset epoch observed by each cursor
retry attempt / last failure category
iOS 18 history token last fully repaired
history upper-bound token currently being repaired
```

### 9.1 書き込み順

1. reasonとgenerationをcheckpointへ保存
2. sliceを開始
3. actor内でatomic repairをsave
4. resultをMainActorへ返す
5. generation一致を確認
6. cursor、reason、history tokenをcheckpointへ反映

SwiftData save後、checkpoint更新前に終了した場合は同じrepairを再実行します。repair policyはidempotentでなければなりません。逆に、repair完了前にhistory tokenだけを進めてはいけません。

### 9.2 migration version

既存installの一回限りscanにはlocalな`maintenanceSchemaVersion`を使います。

- version未達: 全modelをresumable rolling verification
- version完了: 通常起動で40年storeを再scanしない
- repair policyやschemaが変わったときだけversionを上げる
- version完了は全phase cursorが完了してから保存する

singleton作成はmigration未完了の証拠ではありません。

## 10. CloudKit変更検出

### 10.1 iOS 18以降

SwiftData Historyを第一選択にします。

1. localに保存した`DefaultHistoryToken`以後のtransactionを取得
2. insert、update、deleteのmodel typeとpersistent identifierをreasonへ分類
3. 取得時点のupper-bound tokenを記録
4. 対応するrepairを完了
5. upper-bound tokenを「last fully repaired」へ進める

worker自身のsaveがHistoryへ戻って無限loopしないよう、iOS 18以降ではmaintenance用authorを設定し、そのauthorを分類対象から除外します。

`historyTokenExpired` の場合は、古いtokenを捨て、全modelのbounded verification sweepを要求します。新tokenはverification完了後に確定します。

History transactionのsort APIにはOS世代差があります。アプリのdeployment targetはiOS 17なので、iOS 26でしか使えない`sortBy` initializerへ依存しません。

### 10.2 iOS 17

iOS 17にはSwiftData History APIがありません。次をfallbackとします。

- upgrade後の一回限りresumable verification
- first frame後の小さいlaunch verification
- genuine foreground returnごとのbounded rolling verification
- active sceneが継続する間の15分ごとのbounded rolling verification
- `ModelContext.didSave`から、main UIの`StudySession`／`ActivityResetMarker`変更だけを受理し、
  maintenance自己書込みと無関係なentityを除外するtyped hint
- `NSPersistentStoreRemoteChange`のstore URLが、検証済みaccount namespaceのCloudKit source store URLと
  完全一致した場合だけ受理するtyped hint。local projection storeとURLなし／未知URLは除外
- 既存Root sentinel fingerprintからの早いtype hint
- reset markerとlocal focusのexact再確認

iOS 17 fallbackは、Rootのtop-N fingerprintまたは通知だけで「古い後着行を即時かつ完全に検知できる」とは
主張しません。通知は1秒のcoalesce windowで重複を抑えますが、window内の後続通知も即座にtrustを取消し、
durable `.sessions` generationを増やします。高コストなfull verification要求だけをwindow末尾へまとめます。
正しさは初回、真正なforeground復帰、active継続中のrolling verificationで成立させます。

同一process内の通常UI saveは、source sessionまたはreset markerの識別子、もしくは明示的な
invalidated-allだけをtyped reasonへ変換します。iOS 18以降はmaintenance authorを除外し、iOS 17では
other／nil contextのdidSaveをmaintenance由来の可能性があるため除外します。unknown entityを無条件に
全scanへ昇格しません。Core Dataのremote-change optionは外部変更だけでなく当該storeへの全writeを通知し得る
ため、通知名だけで外部性を主張しません。exact source URLのremote通知がworker実行中に届いた場合はtrustを
即時取消し、verification reasonをdurable化します。現在cursorを毎回resetしないようworker quiescenceまで
session generation更新を遅延し、その後に必ず一度再実行します。source-only sentinelは通知payload欠落時の
補助で、projection-only fingerprintはUI refreshだけに使いmaintenance reasonを生成しません。

行数だけの比較では、件数が変わらないupdateを検知できません。`fetchCount`はcheap hintとして使えても、完全な変更検出ではありません。

## 11. `CloudSyncMonitor`との分離

`CloudSyncMonitor` は設定画面で `CKContainer.accountStatus()` を表示するための`@MainActor @Observable`です。次の情報は持ちません。

- CloudKit import開始または完了event
- server change token
- SwiftData transaction token
- 反映済みrecord数
- repair cursorまたは進捗

したがって次の分離を守ります。

- `.available`を「同期完了」と扱わない
- `.available`になったことを理由にpending reasonやHistory tokenをclearしない
- Settings用monitorの一時的なstatusだけを理由に、mount済みの同一account checkpointをclearしない
- monitorをmaintenance coordinatorへ変形しない
- Settingsの「再確認」はaccount statusだけを更新する

これは「account不明でもshipping storeを開く」という意味ではありません。Section 3.2のlaunch boundaryは
別のsecurity gateであり、iCloud選択時は通信不可、identity不明、fingerprint不一致ではcontainer自体を
mountしません。
Simulatorの専用local storeではCloudKit account statusにかかわらずlocal maintenanceを実行できます。
将来、Settingsの再確認後にverificationを要求する場合も、statusは単なる追加hintであり、同期完了の
証拠にはしません。データ修復の正しさはHistoryまたはrolling verificationで成立させます。

## 12. error、cancel、backoff

- error時はactor contextをrollbackし、reasonとcursorを保持する
- retryは指数backoffに上限を持たせる
- 同じfailureをsliceごとにtoast表示しない
- foregroundへ戻ったときにbackoff期限を再評価する
- cancellationは完了済みatomic saveを取り消したと仮定しない
- save結果が不明な場合は同じidempotent groupを再読込して判断する
- UIへ必要な通知・UserDefaults cleanupは`mainActorEffects`として返し、MainActorで実行する

maintenanceの未完了は、現在世代を安全に表示できる限りblocking startup errorにしません。

## 13. test matrix

### 13.1 Coordinator契約

| Test | 期待値 |
|---|---|
| 同じkindがslice中に再到着 | generationが増え、1回目成功後もpending |
| A実行中にB到着 | Aの開始時generationだけ完了判定し、Bを保持 |
| worker failure | reason、generation、cursor、tokenが不変 |
| cancellation | atomic save済み結果だけ反映し、未完了cursorを保持 |
| 同時request連打 | max concurrent workerが1 |
| background中のrequest | 新sliceを始めず、active復帰で再開 |
| awaiting marker継続 | busy loopせず、reasonを保持 |

### 13.2 Apple Account境界

| Test | 期待値 |
|---|---|
| 初回local-only／offline | Apple Account／networkなしで専用namespaceを確定し全基本機能を利用 |
| local-only選択後の再起動 | 同じlocal namespaceを開き、iCloudへ自動switch／uploadしない |
| late cloud verification | 先に確定したlocal-only選択を上書きしない |
| iCloud選択時の初回offline | cloud／local projection storeと旧defaultsを開かずfail closed |
| online A→online B→online A | Bをblockし、Aへ戻りonline確認できると同じA namespaceを再利用 |
| 検証済みAのoffline再起動 | offline reuseせず、store、focus、checkpointを一切開かない |
| profile／store pairの欠落・破損 | fresh choiceへ戻さずrecovery gate。既存artifactを上書き／削除しない |
| account change／background | 旧Rootを外しcontainer解放後にだけ次accountを解決 |
| Widget単独起動 | account状態にかかわらず非個人化した同じ起動導線だけを返す |
| Live Activity | account-neutralな時間／状態だけ。theme、memo、質量、account／CloudKit dataを渡さず、local toggle OFF、account退役、resetで終了 |
| process停止中の旧timer通知 | account-neutralな共通文面だけが届き得る。subject nameをpayloadへ含めない |

pure registry／URL／key／external-surface policyのunit testに加え、通知到着順とprocess suspensionを含む
署名済み実機のA→B block→A復帰試験をrelease gateとします。

### 13.3 Budget契約

すべてのworker testは`MaintenanceFetchAudit`を検査します。

```text
maximumRowsReturnedByAnyFetch <= 256
totalRowsAccessedBySlice <= 1024
saveCount <= 1
```

加えて次をassertします。

- 256件を超えるstale削除は`moreWork`とcursorを返す
- 行を削除しても次sliceでskipしない
- 40年clean fixtureのsingleton verificationはsession/aggregate fetchを0回にする
- 1 logical UUID source groupがpage境界をまたいでも同じ論理値へ収束し、reverse入力、A/B→B/C→late C、
  checkpoint replayの全てでphysical fingerprintと`saveCount == 0`を維持する
- 620件・empty local projectionでも最新128件をlooseに残し、それ以前のsessionを全て一度だけaggregateへ
  表現する。Homeの512件bounded queryとroot summaryで総grams／countが一致する
- aggregate save後に古いcursorをreplayしてもmembership重複がなく、全generation再実行でfingerprint不変
- focus timerが256件を超えても全source rowを保持し、completed、preferred pending、最早cancelから、
  delivery順とslice境界にかかわらず同じ論理winnerへ収束する
- 後方pageにinvalid payload／snapshot conflictがあればread-only validationでgroup全体を非破壊保持し、
  quarantine後も別groupを処理する
- aggregate missing childではflattened payloadを保持する

wall-clockだけのperformance testは端末差で不安定です。構造budgetを必須とし、wall-clockはUI regression testで補完します。

### 13.4 `SeedData.bootstrap`との差分oracle

同じ小fixtureを2つのin-memory containerへ作ります。

- container A: `SeedData.bootstrap`
- container B: bounded workerを`completed`まで反復

次の正規化snapshotを比較します。

- `Prefs`の13 field-group winner、writer ownership、revision／mutation stamp
- logical session数、質量、rare kind、source、`isBaked`、subject snapshot
- achievement数、kind、note、日時、subject snapshot
- stratum membership、grams、count
- aggregate ID、level、parent/children、session IDs、質量、構成、root frontier
- gacha progress
- bedrock値
- subject identityとsnapshotベースの論理linkage（source relationship fingerprintは不変）
- unknown epoch rowの保存状態
- current／awaiting source rowのphysical fingerprint不変とbackground `saveCount == 0`

既存fixtureでは少なくとも次を差分oracleへ含めます。

| 既存テストの論点 | Workerで守る契約 |
|---|---|
| Cloud duplicateと質量維持 | sourceは物理row不変の論理解決、projectionは同じ再構築結果 |
| rare kind duplicate | rare kindの論理解決が到着順に依存しない |
| subjectの後着 | snapshot IDから書換えなしで論理表示を再解決 |
| preset duplicate | sticky tombstone込みの同じlogical subjectを選び、全copyを保持 |
| overlapping bakes | 同じsessionを1回だけ会計 |
| orphan `isBaked` | source bitを書換えず、local membershipがなければlooseとして会計 |
| achievement duplicate | revision／tombstone／snapshotの論理結果が一致し、全copyを保持 |
| legacy stratum migration | aggregateをidempotentに作る |
| decimal carry | childを残し、決定論的parentを作る |
| flattened lineage | 完全なproofだけcompact |
| missing child | 古いpayloadを保持 |
| overlapping offline focus | 異なるsession UUIDは両方measuredとして保持し、同一UUIDの再送は全copyを保持して論理1件として扱う |
| reset marker後着 | unknownをmarker前に削除しない |

worker完了後に同じ全phaseをもう一度実行し、`writeCount == 0`かつsnapshot不変であることも必須です。
さらにsource resolver単独の初回実行も`writeCount == 0`であり、foreign `Prefs` rowや同じlogical IDの
別physical rowを変更しないことを検査します。

`Prefs`は13 groupを個別に検査します。別端末が異なるgroupを同時変更した場合の合成、同じgroupの
false→true／true→false、legacy／stale copyの後着、reverse入力、同じrevisionで異なるmutation IDの
stable tie、同一stampでpayloadが異なる場合のfail-closed、revision上限での新規変更拒否を含めます。
`Subject`はrevision 0 tombstoneを含め削除が高revision offline renameで復活しないこと、
`AchievementStone`は通常編集が`deletedAt`と削除event／restore ackを全て保持し、明示Undoだけが観測済み
tokenを`restoredDeletionMutationID`でackした高revision restoreになることを検査します。in-place restore後も
`(deletionRevision, deletionMutationID)`が残ること、legacy `deletedAt` rowを
`(row.revision, deletionMutationID ?? syncRecordID)`へ合成すること、未観測の新しい削除eventを復活させない
ことも固定します。JSON exportには新しい`syncRecordID`、Subject revision／tombstone、Achievement
`deletionRevision`／`deletionMutationID`／`restoredDeletionMutationID`、`settingsWriterID`、
`timerCompletionSoundRawValue`、`timerCompletionHapticRawValue`、`timerDisplayModeRawValue`、26個のPrefs
stamp fieldを含め、raw evidenceを失わないことを固定します。`timerDisplayMode`は4つの既知raw valueが
保存・復元・端末間同期され、未知raw valueを有効なwinnerとして採用しないことも検査します。

### 13.5 Historyとfallback

#### iOS 18以降

- Root sentinel外の古いsession insertでもHistoryからreasonを生成する
- sentinel外の既存row updateでもreasonを生成する
- repair前にprocessを終了すると古いtokenから再生する
- repair後に終了すると進んだtokenから重複変更なしで再開する
- maintenance authorのtransactionで自己loopしない
- expired tokenでverification sweepへ移る

#### iOS 17

- sentinel外の古いduplicateをrolling scanが最終的に検知する
- 1回のforeground budgetを超えず、次foregroundでcursorから継続する
- migration version完了後のclean launchで全履歴scanを再開しない

### 13.6 resetとオンボーディング

- cloud履歴preflightはnil／古いlocal winnerでwriterを公開せず、同じか新しい全tupleを観測してから許可する
- preflight完了後の手動記録・timer・claimが後続保守で残り、待機中・期限切れ時は活動記録を新規作成しない
- iCloudの利用者resetは変更前に拒否し、local-onlyの利用者resetは既存順序を維持する
- unknown epochはmarker前にdelete、merge、current化されない
- `resetAt`が過去／未来へ大きくずれてもLamport sequenceのwinnerが変わらない
- 同一sequenceのoffline markerが安定tie-breakで収束し、範囲外sequenceをwinner／stale根拠にしない
- maximum sequence到達後は新markerを同じsequenceで作らずresetを拒否する
- marker到着後、winningなら保持、known staleならbounded delete対象になる
- slice中のwinning marker変更でcursorを無効化する
- fresh storeのworker完了後も`Subject`は0件のまま
- workerは`hasCompletedInitialSubjectSeed`を変更しない
- 利用者が削除したpresetをworkerが再作成しない

### 13.7 `CloudSyncMonitor`

全availability caseで次を確認します。

- local maintenance policyをblockしない
- `.available`でpending generationをclearしない
- `.simulator`の専用local storeではlocal repairを実行できる
- launch identity boundaryがblockした場合は、monitor statusと無関係にshipping containerを開かない
- 表示文言は「全記録反映済み」と主張しない

### 13.8 40年UI

既存 `FortyYearPersistentColdLaunchUITests` のbudgetを維持します。

```text
cold launch + Menu interaction < 15秒
Settings表示 < 5秒
設定toggle保存 < 4秒
```

さらに、maintenanceをpendingにした40年fixtureで次を検証します。

- worker実行中もMenu、瓶、集中開始がhittable
- Settingsを開閉し、toggleを往復できる
- Home projection probeがworker前後で完全一致
- singleton理由だけならheavy history queryを行わない
- eventual idleまで全slice auditがbudget内
- relaunchしてもcursorから再開し、理由を失わない

## 14. 段階導入の到達点

Stage 0〜4とStage 6のproduction defaultは実装済みです。Stage 5はiOS 17 rolling verificationを
実装済みで、iOS 18+ History token pathは性能最適化として未実装です。実CloudKit 2台試験が完了する
までは、実装済みという状態をproduction収束の実証と同一視しません。

### Stage 0: 契約と観測

- `MaintenanceKind`、generation、cursor、auditのpure typeを追加
- fake workerでCoordinator testを先に通す
- pure typeとfake workerで契約を固定してからproduction writeを有効化済み

### Stage 1: singletonとlocal focus

- `Prefs`のread-only field-group resolutionと、`GachaState`／`Bedrock`のbounded local verification
- bounded launch理由をdurable checkpointへ変換
- `localFocusAwaitingResetMarker`をbusy loopなしで再評価
- 40年clean storeでheavy fetchが0であることを確認

### Stage 2: reset、session、fairness、gacha

- known stale compaction
- logical session duplicateのread-only resolution
- 同じlogical session UUIDだけを一度会計し、同じUUIDの全physical copyと、時間帯が重なる異なるoffline
  UUIDの両方を保持
- gacha monotone reconciliation
- reset、gacha、failure recovery testを差分oracle化

### Stage 3: achievements、subjects、strata

- achievementのrevision／durable deletion event／restore ackをread-only解決。明示的な編集／削除／Undoだけが
  選択した1 rowを更新し、通常編集とin-place restoreも既存削除eventを消さない
- subjectのrevision／sticky tombstoneをread-only解決。ただしpreset seedとrelationship fan-outは禁止
- local stratum membership修復。source `StudySession.isBaked`は変更せず会計から除外

### Stage 4: aggregate graph

- legacy migration
- bounded connected-component repair
- lineage proof
- decimal carry
- 40年fixtureでUIとprojection不変条件を検証

### Stage 5: History検出

- iOS 17 rolling verificationをproduction fallbackとして実装済み
- iOS 18+ History token pathは性能最適化として延期
- History pathを追加するreleaseでtoken expiry、crash replay、maintenance author testを必須化

### Stage 6: 本番有効化

- feature flagまたはdebug probeでslice auditを確認
- test oracleと40年UIが安定してからproduction defaultを有効化
- `SeedData.bootstrap`は小fixtureのoracleとして保持
- legacy MainActor full sweepは、本番呼出しがないことをtestで固定してから整理する

各Stageは前Stageのbudgetとidempotencyを維持します。local testだけでmaintenance全体がproduction
CloudKit上でも収束すると表示またはlogで主張してはいけません。

## 15. 絶対にしないこと

- `RootView`、foreground callback、first-frame taskから`SeedData.bootstrap`を呼ばない
- MainActorで40年分のmodelをfetchまたはrelationship faultしない
- `fetchLimit`なしでmaintenance queryを追加しない
- `batchSize`またはwall-clockだけを有界性の証拠にしない
- delete/mutateしながら`fetchOffset`を増やさない
- markerが未着のunknown epochをstaleとして削除しない
- current／awaiting source duplicate groupをcanonicalへ書戻し、削除、またはfan-out更新しない
- missing childやcycleがあるaggregate lineageを推測でcompactしない
- workerからpreset subjectを自動追加しない
- workerから`hasCompletedInitialSubjectSeed`をtrueにしない
- `PersistentModel`をMainActorとModelActorの間で受け渡さない
- 新しいreasonが来た可能性を無視してpending Setを一括clearしない
- repair完了前にHistory tokenを進めない
- checkpointをCloudKitへ同期しない
- checkpoint、focus復旧stateをaccount未検証のglobal key／fileへfallbackしない
- cloud modeで通信不可、identity不明またはfingerprint不一致のまま旧`ModelContainer`を開かない
- `resetAt`をreset winnerの主順序または有効期限として使わない
- unsupportedなreset sequenceをwinnerまたはstale削除の証拠にしない
- `CloudSyncMonitor.available`をimport完了と解釈しない
- Settings用`CloudSyncMonitor`だけでaccount boundaryのallow／blockを決めない
- Simulatorの専用local storeを`CloudSyncMonitor`がofflineという理由で止めない
- 同じfocus sessionのsource rowをcompletion／cancellationの小さい集合へ物理compactionしない
- 異なるfocus session UUIDをpartial snapshotだけで破壊的にcancel／deleteしない
- `localFocusAwaitingResetMarker`を短間隔で無限retryしない
- slice失敗ごとに同じtoastを表示しない
- Rootのtop-N fingerprintを完全な変更履歴と扱わない
- cleanな40年storeをsingleton作成だけの理由で全件scanしない

## 16. Apple一次資料

- [ModelActor](https://developer.apple.com/documentation/swiftdata/modelactor)
- [ModelContext](https://developer.apple.com/documentation/swiftdata/modelcontext)
- [ModelContext.fetch(_:batchSize:)](https://developer.apple.com/documentation/swiftdata/modelcontext/fetch(_:batchsize:))
- [ModelContext.fetchIdentifiers(_:batchSize:)](https://developer.apple.com/documentation/swiftdata/modelcontext/fetchidentifiers(_:batchsize:))
- [ModelContext.enumerate(_:batchSize:allowEscapingMutations:block:)](https://developer.apple.com/documentation/swiftdata/modelcontext/enumerate(_:batchsize:allowescapingmutations:block:))
- [FetchDescriptor](https://developer.apple.com/documentation/swiftdata/fetchdescriptor)
- [FetchDescriptor.fetchLimit](https://developer.apple.com/documentation/swiftdata/fetchdescriptor/fetchlimit)
- [Fetching and filtering time-based model changes](https://developer.apple.com/documentation/swiftdata/fetching-and-filtering-time-based-model-changes)
- [HistoryDescriptor](https://developer.apple.com/documentation/swiftdata/historydescriptor)

ローカルのXcode 26.3／iOS 26.2 SDK interfaceでも、`ModelActor`とModelContextのbatch APIはiOS 17
以降、SwiftData HistoryはiOS 18以降、`HistoryDescriptor`の`sortBy` initializerはiOS 26以降であることを
確認しています。このアプリのdeployment targetはiOS 17のため、Historyは将来の追加最適化兼変更検出
とし、実装済みのiOS 17 rolling verification fallbackを正しさの経路として残します。

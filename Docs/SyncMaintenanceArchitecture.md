# つみべん — iCloud同期後の有界メンテナンス設計

更新日: 2026-08-31

## 1. 目的

この文書は、SwiftDataとCloudKitから後着するデータを、最初の瓶画面や操作中のUIを止めずに、決定論的かつ再開可能な形で整理するための実装契約を定義します。

この仕組みが守る成果は次のとおりです。

1. 40年・350,640セッション規模でも、Home、瓶、集中開始、設定を操作できる
2. CloudKitの到着順が前後しても、質量、レア粒、実績、集約階層、タイマー所有権が最終的に収束する
3. アプリ終了、バックグラウンド移行、通信断、途中失敗のあとも同じ修復を安全に再開できる
4. 活動データのreset世代が未知の行を、誤って削除または現在世代へ混入しない
5. 初回オンボーディングと、利用者が削除した教科の選択を壊さない

ここでいう「メンテナンス」は、表示前に全データを正常化する起動ゲートではありません。表示は安全な会計frontierとreset gateで先に成立させ、深い修復は小さなsliceへ分割して収束させます。

## 2. 非目的

次はこの仕組みの責務に含めません。

- CloudKitの通信を開始、停止、再試行、強制同期すること
- iCloud上の全レコードが端末へ届いたことを証明すること
- `CloudSyncMonitor` のアカウント状態を同期進捗へ読み替えること
- Home、Share、Settingsの画面設計を変更すること
- 初回オンボーディングで利用者が選んでいない教科を追加すること
- `SeedData.bootstrap` をそのまま本番のバックグラウンド処理として呼ぶこと
- 1回の起動または1回のforeground滞在中に、全修復を必ず完了させること
- 未知のCloudKit到着順に対して、推測で欠損データを補完または削除すること

## 3. 現状とgap

### 3.1 起動時の読み取りは意図的に小さい

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

### 3.2 現在のforeground reconciliationが済ませること

`RootView.reconcileIncomingActivityData()` は、UIを守るため次だけを行います。

1. 同時要求をcoalesceする
2. 最新のactivity resetを端末ローカル状態へ適用する
3. `BoundedLaunchPreparation.prepare` を実行する
4. bounded preparationが返した理由を `pendingLaunchMaintenanceReasons` へ追加する
5. boundedな`Prefs`情報からオンボーディング状態と利用目的を復元する
6. boundedな最新timer情報から、別端末の集中を引き継ぐ提案を作る

`BoundedLaunchPreparation` の各query契約は最大1行です。現行のdeep maintenance理由は次の5種類に限られます。

- `prefsSingletonCreated`
- `prefsSingletonCanonicalized`
- `gachaSingletonCreated`
- `gachaSingletonCanonicalized`
- `localFocusAwaitingResetMarker`

### 3.3 現在は済ませていないこと

次は `reconcileIncomingActivityData()` では実行されません。

- 既知の旧reset世代の物理削除
- `Prefs`、`GachaState` の全duplicate統合
- 同じlogical UUIDを持つ`StudySession`の統合
- 重複または競合するfocus完走のfairness demotion
- `AchievementStone`の重複統合とsnapshot修復
- `Stratum` membershipの一意化と`isBaked`修復
- legacy `Stratum`から`AggregatePebble`への移行
- aggregate lineage、構成、親子関係、10進carryの修復
- `Bedrock`の統合
- `Subject`重複の統合とsession・achievementの再接続

また、canonicalなsingletonがすでに存在する状態で別duplicateが後着すると、bounded preparationは新しいsingleton理由を返しません。現行5理由だけをworkerの唯一の起動条件にすると取りこぼします。

### 3.4 `SeedData.bootstrap` は正解系だが本番workerではない

`SeedData.bootstrap` は小さいfixtureに対する決定論的なrepair oracleです。しかし現状は`@MainActor`で、複数modelを全件fetchします。40年storeで本番のinteractive pathから呼ぶことはできません。

さらに、次のsubject seed処理を含みます。

```swift
reconcileSubjects(
    context: context,
    insertMissingPresets: !prefs.hasCompletedInitialSubjectSeed
)
prefs.hasCompletedInitialSubjectSeed = true
```

この動作を汎用workerへ移すと、初回オンボーディング前に全presetを作ったり、利用者が削除したpresetを別端末で復活させたりする危険があります。`SeedData.bootstrap` はテストoracleとして残し、本番workerにはactor-safeな小さいrepair policyを段階的に移植します。

## 4. 必須の不変条件

### 4.1 データ会計

```text
生涯グラム = current loose sessions + current root aggregates
achievement stones = 0g
同じlogical sessionは最大1回だけ数える
```

修復途中でも、既存の安全なfrontierを破壊して二重加算や一時的な質量消失を起こしてはいけません。

### 4.2 reset世代

- markerが1件もない場合、`nil` epochだけがcurrent
- winning markerのepochがcurrent
- markerが存在する非winning epochと、marker存在後の`nil` epochはstale
- markerがまだ届いていない非nil epochは`awaitingMarker`
- `awaitingMarker`は表示から隔離するが、削除、統合、currentへの書換えをしない

物理削除は容量整理であり、正しさのsource of truthはappend-onlyなreset markerです。

### 4.3 logical groupのatomicity

同じUUIDを持つduplicate groupは、完全なmerge値の計算、canonical更新、duplicate削除を同じsaveで行います。page境界でgroupの半分だけを保存してはいけません。

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
  - notification / Live Activity cleanup
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
| subject | sessions・achievementsの再接続 |
| preferences | user-state反映、bedrock確認 |

展開したreasonとgenerationは、worker開始前にcheckpointへ保存します。

### 6.4 exactly one in-flight

同じcontainerに対するmaintenance sliceは常に1本です。要求が増えた場合は実行中taskを増やさず、generationを更新して次sliceへ渡します。

sceneがinactiveまたはbackgroundになった場合は新しいsliceを開始しません。すでにatomic saveへ入ったsliceは完了結果を受け取り、それ以外はcancelしてcursorを保持します。

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

1 sliceで複数phaseを中途半端に保存しません。save単位は次のいずれかです。

- 1つ以上の完全に読み切ったlogical UUID group
- 1つ以上の独立したachievement group
- 証明が完了したaggregate nodeまたは小さいconnected component
- 256件以下の既知stale row削除
- singleton accumulatorの走査完了後のcanonical merge

読み取り途中のaccumulatorはcursorへ保存し、完全なmerge値が得られるまで破壊的変更をしません。

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

- `Prefs` deterministic merge
- `GachaState` singletonのcanonical確認
- `Bedrock`の小さい統合
- `localFocusAwaitingResetMarker`のexact marker再確認

fresh installでsingletonが作られただけなら、duplicate不存在を小さく確認して完了します。この理由から全履歴scanを開始しません。

local focusが`awaitingMarker`のままなら、reasonを消さず、即時retry loopもしません。marker fingerprint、foreground、History eventのいずれかで再評価します。

### Phase 2: logical activity identityとfairness

1. `StudySession` duplicateをlogical UUIDごとに統合
2. snapshot、grams、rare kind、`isBaked`をoracle policyで収束
3. overlapping focus完走を検出
4. superseded sessionを`.timerDemoted`、normal、unbakedへ変更
5. 影響するprojectionを保守的に再検証対象へ送る
6. gachaの最大512候補tailを、session/focus修復後に評価する

gacha progressは、部分同期で後退させません。

```text
reconciled = max(known synced progress, locally proven progress)
```

### Phase 3: achievements

- 同じUUIDのduplicateを統合
- noteをsanitize
- 未来日時を上限補正
- subject name/color snapshotを補完
- 質量へは加算しない

### Phase 4: legacy strata

- duplicate `Stratum`を統合
- 同じsession membershipを複数stratumへ所属させない
- membershipを権威として`StudySession.isBaked`を修復
- 対応するstratumが未着の場合、otherwise-unclaimed sessionをlooseとして保持

### Phase 5: aggregate graph

- duplicate aggregateを統合
- legacy stratumから互換aggregateを作る
- direct sessionとchild aggregateの構成を検証する
- parent/child backlinkを修復する
- 証明できるflattened lineageだけcompactする
- rootを10個単位で決定論的にcarryする

aggregateは単純なpage単位で完結しません。Historyから得たdirty aggregate IDを起点に、parentと最大10 childをbounded frontierで辿ります。1回で完了しない場合はfrontierをcursorへ保存します。

sessionから所属aggregateを逆引きするindexed relationshipは現行schemaにありません。session変更時は、aggregateのrolling verificationを独立phaseとして要求します。ただし40年のclean storeでmigration versionが完了済みなら毎起動scanしません。

### Phase 6: subjectsとrelationship

- presetと同一identityのsubject duplicateを統合
- sessionとachievementをcanonical subjectへ付け替える
- snapshot subject IDから未接続sessionを再接続する
- missing presetは挿入しない
- `hasCompletedInitialSubjectSeed`をworkerから変更しない

### Phase 7: physical compaction

known stale rowsをmodelごとに小さく削除します。このphaseの未完了を理由にUIを止めません。現在世代の論理repairと並行して少しずつ進められます。

## 9. checkpointとクラッシュ回復

checkpointはCloudKitへ同期せず、この端末だけへ保存します。候補は小さいCodable payloadを持つ`UserDefaults`またはatomic replaceするApplication Support内JSONです。CloudKit modelへ保存すると、別端末がこの端末の未完了作業を消す危険があります。

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
- 既存Root sentinel fingerprintからの早いtype hint
- reset markerとlocal focusのexact再確認

iOS 17 fallbackは、Rootのtop-N fingerprintだけで「古い後着行を即時かつ完全に検知できる」とは主張しません。複数foregroundにまたがって最終的に全範囲を再確認する設計です。

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
- `.noAccount`、`.temporarilyUnavailable`、`.simulator`でもlocal maintenanceを止めない
- monitorをmaintenance coordinatorへ変形しない
- Settingsの「再確認」はaccount statusだけを更新する

将来、Settingsの再確認後にverificationを要求する場合も、account statusの値に関係なく単なる追加hintとしてenqueueします。正しさはHistoryまたはrolling verificationで成立させます。

## 12. error、cancel、backoff

- error時はactor contextをrollbackし、reasonとcursorを保持する
- retryは指数backoffに上限を持たせる
- 同じfailureをsliceごとにtoast表示しない
- foregroundへ戻ったときにbackoff期限を再評価する
- cancellationは完了済みatomic saveを取り消したと仮定しない
- save結果が不明な場合は同じidempotent groupを再読込して判断する
- UIへ必要な通知・Live Activity・UserDefaults cleanupは`mainActorEffects`として返し、MainActorで実行する

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

### 13.2 Budget契約

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
- 1 logical UUID groupがpage境界をまたいでも1つへ収束する
- aggregate missing childではflattened payloadを保持する

wall-clockだけのperformance testは端末差で不安定です。構造budgetを必須とし、wall-clockはUI regression testで補完します。

### 13.3 `SeedData.bootstrap`との差分oracle

同じ小fixtureを2つのin-memory containerへ作ります。

- container A: `SeedData.bootstrap`
- container B: bounded workerを`completed`まで反復

次の正規化snapshotを比較します。

- `Prefs`の全merge対象scalar
- logical session数、質量、rare kind、source、`isBaked`、subject snapshot
- achievement数、kind、note、日時、subject snapshot
- stratum membership、grams、count
- aggregate ID、level、parent/children、session IDs、質量、構成、root frontier
- gacha progress
- bedrock値
- subject identityとrelationship
- unknown epoch rowの保存状態

既存fixtureでは少なくとも次を差分oracleへ含めます。

| 既存テストの論点 | Workerで守る契約 |
|---|---|
| Cloud duplicateと質量維持 | singleton/session/stratum/bedrockが同じ結果 |
| rare kind duplicate | rare mergeが到着順に依存しない |
| subjectの後着 | snapshot IDからrelationshipを再接続 |
| preset duplicate | relationshipをcanonicalへ付替え |
| overlapping bakes | 同じsessionを1回だけ会計 |
| orphan `isBaked` | membershipがなければlooseへ戻す |
| achievement duplicate | snapshotとsanitize結果が一致 |
| legacy stratum migration | aggregateをidempotentに作る |
| decimal carry | childを残し、決定論的parentを作る |
| flattened lineage | 完全なproofだけcompact |
| missing child | 古いpayloadを保持 |
| overlapping offline focus | 後発をself-reported normalとして保持 |
| reset marker後着 | unknownをmarker前に削除しない |

worker完了後に同じ全phaseをもう一度実行し、`writeCount == 0`かつsnapshot不変であることも必須です。

### 13.4 Historyとfallback

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

### 13.5 resetとオンボーディング

- unknown epochはmarker前にdelete、merge、current化されない
- marker到着後、winningなら保持、known staleならbounded delete対象になる
- slice中のwinning marker変更でcursorを無効化する
- fresh storeのworker完了後も`Subject`は0件のまま
- workerは`hasCompletedInitialSubjectSeed`を変更しない
- 利用者が削除したpresetをworkerが再作成しない

### 13.6 `CloudSyncMonitor`

全availability caseで次を確認します。

- local maintenance policyをblockしない
- `.available`でpending generationをclearしない
- `.simulator`でもlocal repairを実行できる
- 表示文言は「全記録反映済み」と主張しない

### 13.7 40年UI

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

## 14. 段階導入

### Stage 0: 契約と観測

- `MaintenanceKind`、generation、cursor、auditのpure typeを追加
- fake workerでCoordinator testを先に通す
- 本番データへのwriteはまだ行わない

### Stage 1: singletonとlocal focus

- `Prefs`、`GachaState`、`Bedrock`のbounded verification
- bounded launch理由をdurable checkpointへ変換
- `localFocusAwaitingResetMarker`をbusy loopなしで再評価
- 40年clean storeでheavy fetchが0であることを確認

### Stage 2: reset、session、fairness、gacha

- known stale compaction
- logical session duplicate repair
- overlapping focus demotion
- gacha monotone reconciliation
- reset、gacha、failure recovery testを差分oracle化

### Stage 3: achievements、subjects、strata

- achievement repair
- subject dedupe/reconnect。ただしpreset seedは禁止
- stratum membershipと`isBaked`修復

### Stage 4: aggregate graph

- legacy migration
- bounded connected-component repair
- lineage proof
- decimal carry
- 40年fixtureでUIとprojection不変条件を検証

### Stage 5: History検出

- iOS 18+ History token path
- iOS 17 rolling verification
- token expiry、crash replay、maintenance author test

### Stage 6: 本番有効化

- feature flagまたはdebug probeでslice auditを確認
- test oracleと40年UIが安定してからproduction defaultを有効化
- `SeedData.bootstrap`は小fixtureのoracleとして保持
- legacy MainActor full sweepは、本番呼出しがないことをtestで固定してから整理する

各Stageは前Stageのbudgetとidempotencyを維持したまま進めます。aggregateまで未実装の段階で、maintenance全体が完全に収束すると表示またはログで主張してはいけません。

## 15. 絶対にしないこと

- `RootView`、foreground callback、first-frame taskから`SeedData.bootstrap`を呼ばない
- MainActorで40年分のmodelをfetchまたはrelationship faultしない
- `fetchLimit`なしでmaintenance queryを追加しない
- `batchSize`またはwall-clockだけを有界性の証拠にしない
- delete/mutateしながら`fetchOffset`を増やさない
- markerが未着のunknown epochをstaleとして削除しない
- partial duplicate groupを保存しない
- missing childやcycleがあるaggregate lineageを推測でcompactしない
- workerからpreset subjectを自動追加しない
- workerから`hasCompletedInitialSubjectSeed`をtrueにしない
- `PersistentModel`をMainActorとModelActorの間で受け渡さない
- 新しいreasonが来た可能性を無視してpending Setを一括clearしない
- repair完了前にHistory tokenを進めない
- checkpointをCloudKitへ同期しない
- `CloudSyncMonitor.available`をimport完了と解釈しない
- `CloudSyncMonitor`がofflineまたはsimulatorという理由でlocal repairを止めない
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

ローカルのiOS 26.5 SDK interfaceでも、`ModelActor`とModelContextのbatch APIはiOS 17以降、SwiftData HistoryはiOS 18以降、`HistoryDescriptor`の`sortBy` initializerはiOS 26以降であることを確認しています。このアプリのdeployment targetはiOS 17のため、Historyはavailability分岐を持つ追加最適化兼変更検出として実装し、iOS 17 fallbackを必ず残します。

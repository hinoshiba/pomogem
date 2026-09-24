# OSS and App Store release risk audit

更新日: 2026-09-06（新アプリへの移行に伴う証拠範囲の更新）
Target: PomoGem 1.0 (5) / Apple ID `6809139517` / `com.hinoshiba.pomogem`

これは出荷判断のための技術・運用・license監査であり、法律意見ではありません。`Blocker`が1件でも
残る場合はarchiveを配布候補として扱わず、App Storeへuploadしません。

## Executive decision

現時点の判定は **NO-GO** です。PomoGemは新Bundle ID、新App Store record、新IAP、新CloudKit
containerを使う別アプリとして準備中です。2026-09-06にApp Store record `6809139517`、main／Widget
App IDと新CloudKit containerの登録・hostへの割当を確認しました。新IAP、価格、最終commitの署名済み
Archive／distribution、CloudKit production schema、署名済み2台実機、Sandbox、TestFlight、
新ブランドの画像とmetadata、新domainの実配信、法定表示とrights sign-offの完了を確認していません。
未完了項目の正本は`AppStore/configuration.yml`です。

旧製品のbuild 1〜4、署名、Store保存値、Web実測、過去のtest件数は、新アプリの確認済み証拠に
転用しません。来歴は`Docs/LEGACY_RELEASE_PROVENANCE.md`に隔離しています。下表の実装説明は
再検証する契約を示し、過去の成功件数は対象commitが異なる参考情報です。

local candidateは、7種類の同期元modelと
4種類の端末内projectionへ分離しています。初回は同格のiCloud／このiPhoneのみから選択し、
local-onlyならApple Account／networkなしで全基本機能を使えます。cloud modeでは`ModelContainer`を
作る前と各launch／resumeでApple Accountをonline検証し、最初に確認したaccountの不透明なlocal
namespaceへstore、focus復旧状態、maintenance checkpointを分離します。resetの勝者は端末時計ではなく
Lamport sequenceで決め、512件を超える履歴のlocal projectionを有界sliceで再構築します。現在世代／
marker未着世代のCloudKit source duplicateは物理的に統合せず、read-only resolverで論理表示・会計へ
収束させます。例外的なsource削除は、明示的に証明したstale epochと、materialized `StudySession`で
閉じたことをexact確認したfocus active tailだけです。
Apple Account切替で混線し得るrare reward台帳と、安全な直列化を証明できないdirect CloudKit一括削除は
version 1.0のUI、起動、shipping schema、entitlementから除外します。

「リポジトリ全体がOSS」ではありません。ソースコードと通常文書はMIT、同梱fontはOFL-1.1ですが、
名称、logo、app icon、生成背景、Store／Web画像はrights-reservedです。したがって公開時は
**open-source codeを含むmixed-license repository** と表現し、製品全体をOSI認定のopen sourceと
誤認させません。全素材をOSSにする場合は、権利者が別途open licenseを付与するか素材を置換する必要が
あります。

| Severity | Risk | Confirmed evidence | Release condition |
|---|---|---|---|
| 要対応 | Git履歴の公開identity | 過去の個人メールアドレスが履歴に残る。現在の公開連絡先は`support@hinoshiba.com`へ統一 | 履歴の監査結果を非公開で確認し、書き換えの要否を別途判断する |
| Blocker | 新IAP・CloudKit production schema・distribution payloadが未成立 | PomoGemのApp Store record `6809139517`、新host／Widget App IDとCloudKit containerの登録・hostへの割当は2026-09-06に確認した。新IAP、production schema、署名済みdistributionの照合は未完了。旧版のArchive結果は新candidateの証拠に使わない | 新IAPを登録し、配布時のhostだけのCloudKit・Push・IAPとWidgetの追加capabilityなしを照合する。新containerに13 group・26 stamp fieldを含む7-model schemaをinitialize・検証後productionへdeployする。最終commitをArchive／Distributeし、host／widget署名、production CloudKit／APNs、1.0 (5)、extension、Privacy Manifest、Live Activityを再検証する。既存containerとproductionはclearしない |
| Blocker | 実CloudKitでsource同期とmaintenanceが未検証 | bounded worker、kind別durable retry、split store、account namespace、Lamport reset、projection rebuild、source duplicateのread-only resolverはlocal実装／test sourceがある。前身アプリの`timerDisplayMode`追加後候補では2026-09-05にXCTest 598件中597件成功、明示opt-inの40年soak 1件skip、Swift Testing 25件成功、失敗0件。同じ旧候補のRelease Simulatorのbuild／Analyzeもerror／warning／analyzer warning 0件だった。新candidateのRelease Archive、production CloudKitの実配信順序、account切替、分断・再接続、killは未完走 | 一意なbuild番号の最終候補でRelease Archiveを作成する。同じApple Accountの署名済み2台で4種類のtimer表示選択、別groupとのoffline同時変更、同じgroupの競合、異なるoffline session、timer引き継ぎ、A/B→B/C→late Cのpartial duplicate delivery、620件以上のlocal projection再構築、resetを合格する。current／awaiting source fingerprintが不変で、foreign rowへのsave／delete／fan-outがなく、account A→Bはblock、onlineのAへ戻ると元のnamespaceを再mountしてstore／focus／checkpointを混ぜないことも確認 |
| Blocker | 新App Store recordへの提出物保存が未完了 | 原稿は新名称・ID・domainへ更新し、PomoGem 1.0 (5)のlisting 5枚を2026-09-06にDebug fixtureから新規capture・目視確認した。新商品のIAP価格画像とsigned Releaseのvisual parityは未確認。旧recordへの保存履歴は新製品の証拠にならない | PomoGem 1.0 (5)でlisting 5枚と新商品のIAP画像を再captureし、signed Release実機との差を確認する。新recordへcategory、privacy、価格／提供地域、metadata、build、IAPを入力し、reload後も値が一致することを照合する |
| Blocker | 日本向け有料IAPの法定表示と販売主体の判断が未完了 | Pro案内とアプリの購入前linkから到達する販売セクションを単一製品ページへ実装し、固定金額は掲載していない。法定氏名／住所／電話／請求時点の販売価格を遅滞なく開示する送受信、非公開正本、担当者不在時手順は未検証。AppleはApp Storeの購入、決済、領収、返金を扱う代理人だが、Schedule 2はdeveloperをprincipalかつ法令／請求／supportの責任主体とし、消費者庁Q18が求めるApple連絡先の個別代行合意も確認できない。第三者専用page 10件の調査でもAppleを法定開示先とした例は0件 | 特商法の適用と必要表示をowner／専門家が確認。販売事業者情報は`support@hinoshiba.com`でdeveloperが直接回答し、決済／領収／返金だけをAppleへ案内する。購入前導線と実運用を完成し、提出直前にも直接URLがHTTPS 200であることを再確認する。Webとbinaryへ固定金額を埋め込まず、StoreKitの購入時価格だけを表示する。個人情報は適切な管理手段で扱う。代替は1.0を無料・IAPなしで再設計 |
| Blocker | 有料Pro提供地域の販売主体・地域運用判断が未完了 | App本体はFree、Non-Consumable Pro IAPは米国USD 0.99基準、日本JPY 100 custom、他の提供地域はAppleの現地相当額。EU 27 storefrontsは除外し、英国、ノルウェー、スイスを含む148地域を予定。non-trader表示の法的適否、各地域のconsumer／税／制裁／support運用は未判断 | Account Holderが提供148地域の義務とnon-trader statusを決定・検証し、AppとIAPのavailability、新規storefront自動追加、価格、全原稿をreload後に照合する。対応不能地域は提出前に除外 |
| Blocker | 実購入・同期・端末品質を未検証 | production CloudKit、StoreKit Sandbox、2台実機、新candidateのTestFlight完了記録なし | checklist記載の購入／復元／失効、CloudKit、offline、account-neutral Widget／Live Activity、通知、exportを実機で合格 |
| High | Version 1.0の保存先選択が不変で、local-onlyからの自動移行がない | 初回にiCloudとlocal-onlyを同格で提示し確認後に確定する。local-onlyはApple Account／networkなしで全基本機能を使え、iCloudへ自動switch／uploadしない。一方、後からiCloudを開始するにはapp削除・再installが必要でlocal記録を失い、JSONは再import／migration／機種変更時の継続に使えない | 選択前とSettings／listing／Privacy／Supportで制約を明示し、同格表示、確認、選択の不変性、削除後のdata lossを署名済みclean installで検証。Version 1.xでmigrationを追加する場合は既存local store fixture、重複、reset epoch、進行中timerを扱うversioned migrationを別途設計・実機検証 |
| High | rare reward試作をReleaseへ再混入させる回帰 | sourceには将来検討用CAS ledgerとrare modelが残るが、`RareRewardReleasePolicy.isEnabled == false`、shipping schemaは7+4、operations entitlementなし、Root drainerなし、Focusは通常粒を直接保存 | Release archiveでoperations entitlement／container ID、random-reward UI、pending writerがないことをstatic／UI testで確認。将来有効化時はaccount binding、raw data access、2台CAS、age ratingを新規review |
| High | 実験中のdirect CloudKit一括削除はaccount切替と複数workerで安全に直列化できていない | journal／receiptはApple Accountに未binding。複数端末が同じpending fenceを実行すると、commit後の新規zoneを遅いworkerが削除し得る。offline端末は遠隔消去不能 | `CompleteDataDeletionReleasePolicy.isEnabled == false`として1.0のUIとlaunch pathから除外。将来はaccount binding、single-owner lease、全cloud rowのgeneration quarantineを設計・実機検証してから有効化 |
| High | 保存先ごとのcopy／delete説明が利用者期待またはApple reviewと合わない | JSON exportは選択した保存先で端末から利用できる全11 shipping modelを含むが再import不可。app内resetは論理世代切替で物理削除ではない。local-onlyはapp削除で消え、cloud物理削除はAppleのiCloudストレージ管理へ案内 | Review Notes、Privacy、Settings、Supportを同一表現にし、両modeでexport、local app削除、cloud system管理導線を確認。Apple Reviewがapp内deleteを要求した場合は、安全設計を完了するまでupload／submissionを止める |
| High | repositoryの改名後に公開sourceやPagesの導線が切れる | 予定公開先は`hinoshiba/PomoGem`。現repositoryはprivateで、ユーザーが最後に改名する。Pagesは不変のrepository IDでguardし、公開Webはsource linkを掲載しているが、repositoryの公開まではアクセス権が必要。DNS／HTTPSの最終照合は別途必要 | 最終commitのsecret／rights監査後、new URLから匿名でsourceを読めること、Pagesと各policy URLが直接HTTPS 200であることを確認する |
| High | pre-Git source・asset・AI reference inputの権利帰属が技術監査だけでは確定しない | Git履歴は初回OSS commitから。asset台帳はあるがowner sign-offと正式商標調査は別途必要 | 権利者が書面確認し、不明素材を除去／置換。名称は公式商標DBと必要に応じ専門家でclearance |
| High | MIT sourceとrights-reserved brand assetsの境界をforkが誤認する | code／通常文書はMIT、fontはOFL、icon／background／store imageは`ASSET_LICENSES.md`で除外。全体はOSI準拠OSSではない | README、LICENSE、asset台帳、trademark policyをrelease tagで一致させ、「source code is MIT／repository is mixed-license」と明示。全体OSSを望むならassetを再licenseまたは置換 |
| High | App Privacy回答と実運用が乖離するとpolicy違反になる | appはanalytics／ads／developer serverなし。同期元dataは利用者のprivate CloudKit database、瓶projectionは端末内で、Data Not Collectedは「運営者がprivate dataを取得・閲覧・保持しない」運用付きの候補に留める。一方、任意support mailとWeb hosting logは運用側で処理され得る | production binaryのdependency／network／manifest／entitlement、Apple teamの実accessとcontainer運用を再監査し、support mailの利用目的・保持・削除手順をprivacy policyどおり運用。optional disclosure条件を満たさなければEmail Address等を申告 |
| High | CloudKit初回schema／future migrationでデータ損失・起動失敗 | 1.0はpublic buildが存在しないためReleaseは最終split topologyを直接作成し、危険なmonolithic reopen migrationはDEBUGだけ。最終RCでは`syncRecordID`をSubject／StudySession／AchievementStone／Prefs／FocusTimerDeviceClaimへ、Subject revision／tombstone、Achievementの`deletionRevision`／`deletionMutationID`／`restoredDeletionMutationID`、Prefs `settingsWriterID`、`timerCompletionSoundRawValue`／`timerCompletionHapticRawValue`／`timerDisplayModeRawValue`と13組（26 field）のrevision／mutation stampを追加するが、production schemaは未deploy | 新しいPomoGem containerのdevelopment environmentを最終RCからinitializeし、field名・型・default、`timerCompletionSoundRawValue`／`timerCompletionSoundRevision`／`timerCompletionSoundMutationID`、`timerCompletionHapticRawValue`／`timerCompletionHapticRevision`／`timerCompletionHapticMutationID`、`timerDisplayModeRawValue`／`timerDisplayModeRevision`／`timerDisplayModeMutationID`、legacy Achievement event=`(row.revision, deletionMutationID ?? syncRecordID)`、clean install、4種類のtimer表示、2台partial delivery、raw exportを検証後、そのexact 7-model schemaをproductionへpromoteする。旧containerとproduction environmentはresetしない。将来の既存user migrationはreleased store fixtureとversioned migration planなしに追加しない |
| High | AchievementのUndo／通常編集が削除eventを消すと、後着copyを削除済みか復活済みか決定できない | 削除eventを`(deletionRevision, deletionMutationID)`として保持し、in-place restoreもこのpairを消さず、観測tokenだけを`restoredDeletionMutationID`へackする。通常編集は`deletedAt`、event pair、restore ackを全て維持し、legacy `deletedAt` rowは`(row.revision, deletionMutationID ?? syncRecordID)`へ合成する | delete→Undo→ordinary edit、未観測higher deletionの後着、reverse／partial delivery、legacy tombstoneを検査し、explicit Undo以外で復活せず、export後もevent／ackが残ることを最新RCと署名済み2台で確認する |
| High | Apple Account切替時に前accountの端末内状態を表示・更新する | cloud storeを開く前と各launch／resumeでApple Accountをonline確認し、初回fingerprint／random namespaceとの完全一致を要求する。通信不可、identity不明、A→Bはfail closedし、background／account changeではcontainerをunmountする。system surfaceはWidgetをaccount-neutralにし、通知本文からtheme名を除去。Live Activityもランダムなsession UUID、時間、状態だけで、theme、memo、質量、account／CloudKit dataを持たない | 署名済み実機でiCloud選択、各launch／resume、A→B block→A復帰、background／terminated切替、機内modeと通信断復帰を確認。旧store、focus、checkpointを表示せず、WidgetとLive Activityは常に非個人化し、account退役／resetでActivityを終了すること、旧timerの共通通知が一度届き得る残余を記録 |
| High | Live Activityが残留、重複、期限後00:00固定、または設定OFF後に復活する | Attributes／ContentStateを不変な最小payloadとし、同sessionは更新、別sessionは旧Activityを終了、通常復旧は存在するActivityだけを更新して手動dismiss後に再生成しない。期限は`staleDate`で「終了」と表示し、完走時は最終状態後2分でdismiss。local toggle OFFとaccount退役／resetは全Activityを終了。payload key／4KB未満、Widgetの禁止marker、ActivityKit linkageをstatic test／archive verifierで固定 | ActivityKit APIはstaticでmanager lifecycleのdeterministic unit testが未注入。署名済み実機とSimulatorで開始、同session再更新、別session、pause／resume、期限到達、完走後2分、cancel、手動dismiss、force-quit／relaunch、設定OFF／cold launch、OS側許可OFFをsmokeする。pushなしのためsuspend中の期限到達は中立な「終了」で留まり、次回app実行時に確定／終了する残余を受け入れる |
| High | 破損・敵対的な同期timer payloadがsnapshot計算や整数変換をtrapさせる | JSON decodeだけでは巨大な有限Date、remaining、custom duration、statusとengineの不一致を排除できず、以前は完全検証前に`Double`から`Int`へ変換し得た。現候補はDate／duration／phase／completion整合を先に検証し、snapshot remainingを360分、focus cycle countを10,000,000へ飽和させ、invalid cloud rowは変更せずfail closed、invalid local bytesは削除する。旧候補では関連focused test 78/78成功。新しい360分境界は新候補で再検証する | 全suiteとRelease Analyzeを最新candidateで合格。署名済み2台で破損rowが正常timerを誤完了／取消せず、UIが診断可能なfail-closed表示になることを確認 |
| High | 端末時計変更、再起動、別端末引継ぎが未計測完走を通常timerとして確定する | active focusのlocal復旧はwall clockとcontinuous uptimeの連続性を再検証し、reboot／clock不一致／legacy unverifiable anchorでは同一sessionを`timerDemoted`へ不可逆に降格する。別端末のuptimeは比較不能なためcross-device adoptionもactive focusを降格する。break復旧値も許可時間と有限Dateへ制限し、clock／break focused unit testは成功 | 全suiteを合格し、実機でforward／backward clock、再起動、二度目のrelaunch、cross-device adoption後にmeasured-only扱いにならず、session重複も起きないことを確認 |
| High | reset順序を端末時計へ依存すると履歴が復活・誤削除される | `sequence` 0...1,000,000をsupportedなLamport counterとして主順序にし、同値はwriter／epoch／record IDで決定する。`resetAt`は表示・監査metadataだけ。範囲外sequenceは勝者にもstale削除の根拠にもせず、上限到達時は新resetを拒否する | 時計の前進／後退、同一sequenceのoffline同時reset、範囲外marker、A→B block→A復帰とCloudKit後着を実機で確認する |
| High | local projection消失・破損で512件より古い履歴が瓶の集計から欠落する | aggregate maintenanceは`StudySession`を物理変更しないlogical dedupe後、新しい128件をlooseとして残し、それより古いcurrent sessionをUUID keysetで最大64件ずつ決定的なlevel-1 leafへ再構築し、10個単位でrootをroll upする。620件、空local store、同一終了時刻、save後checkpoint未更新replay、正確な質量／件数／reward内訳を検査するtest sourceがある | 最新RCで当該testと全suiteを完走し、署名済み実機でlocal projectionだけを失った状態からUIを止めず全履歴へ収束し、source fingerprintが変わらないことを確認 |
| High | 後着した同一UUIDの`StudySession` winnerが日時、質量、source、reward、subjectを変えても、既存leaf／ancestorが古い値を正確値として表示する | `AggregatePebble.projectionValidationVersion`を導入し、current version未満のaggregateが一つでもある間は全rootを表示会計から除外する。workerは各leafの全memberをexact logical resolverで再読込し、ownerの一意性と固定長SHA-256 digestをdurable cursorへ保持する。昇格sliceでmember 0から全winnerを再読してdigest一致した現物からpayloadを再導出し、ancestorもchildから全fieldを再導出する。最終一巡が1,024-row budgetへ入らない異常密度はv0のままfail closedにする | late winnerでleafと最上位ancestorのgrams／count／source／reward／subject／dateが置換されるtest、2 member各256 physical copyの途中同数差替、count→fetch間変更、途中kill／checkpoint replayを最新RCで合格する。最大10 member各256 copy等、最終一巡がbudgetへ入らない場合は集計を表示せず、support/exportで診断する既知上限をownerが受け入れる。署名済み2台では検証完了まで生涯正確値、`+`、`以上`を表示せず「再集計中」となることも確認 |
| High | iOS 17で古いCloudKit importがtop-N sentinel外に到着するとmaintenanceが始まらず、端末内projectionが無期限に古くなる | cloud modeはmount直後を未検証とする。`ModelContext.didSave`はsource entityだけを分類し、Core Data remote-changeは当該storeの全writeで発火し得るため、検証済みaccountのCloudKit source store URLと一致する通知だけを受理する。projection／未知URLを除外し、worker中のsource通知はtrust取消とverificationを先にdurable化してquiescence後にsessionsを再実行する。1秒windowの後続通知もsessions generationを即時更新し、full sweepだけを末尾へまとめる。さらに初回60秒後、実backgroundからの復帰、active継続15分ごとにもrolling verificationを要求し、pending空、maintenance schema current、ticket generation一致までaggregate rootを正確値として提示しない | iOS 17／18のfocused testに加え、署名済み同一Apple Accountの2台で、appを15分超activeにしたまま相手端末から古い日時の記録を追加・更新し、remote import通知、worker処理中到着、短時間の連続到着、inactive→active、再集計中表示、最終収束を確認する。通知が届かない／分類不能でもrecurring sweepで収束することを実測するまでTestFlight外部配布／提出しない |
| High | 同期／legacyの`StudySession`が巨大な日付範囲やpause期間を正当履歴として拡大する | 中央integrity policyは60〜21,600秒、0〜3,600g、source別の秒／質量完全一致、finite／ordered Dateを必須とする。過去100年は1985〜2024の40年fixtureを保持する互換範囲、未来は評価端末から365日以内、pauseを含む一完走のwall spanは7日以内とし、超過行は表示／集計／maintenanceから隔離しraw exportに保持する | 長期pauseまたは1年を超える端末時刻差による実行はfail closedになる。境界値、境界超過、40年過去fixtureの回帰testを維持し、product／supportで「一完走はpause込み7日以内」を運用する |
| High | 敵対的な不正`StudySession`がHomeの先頭pageを占有し、有効な古い粒を隠す | Homeは1 fetch最大512行、最大16 page／8,192 raw行を走査し、保持・返却は有効logical row最大512件。不正行は削除せずraw exportへ残し、上限到達時は生涯値をlower-bound表示にする。1,024不正行の奥の有効行へ到達するtestと8,192行hard capのtestを追加 | 8,192件を超える連続不正行の奥は1.0の対話表示で到達不能な残余risk。実機latencyとlower-bound表示を確認し、完全解消にはraw保持とquery除外を両立するversioned quarantine indexを設計する |
| High | 不正`StudySession`が起動時onboarding evidenceの先頭候補を占有し、正常な既存履歴を新規端末で未使用と誤判定する | 現在epoch／Date／seconds／gramsの粗いDB predicateで候補を絞り、stable newest-firstで32行ずつ最大16 page／512候補まで走査し、メモリ上の完全integrity検証で有効1件を確定する。不正raw行は削除しない | 512候補を超える連続semantic-invalid行の奥にのみ正常履歴がある場合は、起動時DoS防止を優先してonboardingが再表示され得る。page越え検出、hard cap、raw保持のtestを維持する |
| High | focus履歴の論理解決またはclosed-tail cleanupがcancel／completion境界を失い、完走を誤計上または取消する | 同一sessionではmaterialized `.completed`を不可逆とし、それ以外はpreferred completion-pendingと最早cancelを集合として解決する。cancelがscheduled endより前ならcancel、同時刻以降ならpendingが勝つ。terminal／active／claim duplicateは全pageをread-only検証して物理保持し、異なるsession UUIDも削除しない。唯一のcurrent-source cleanupは、有効なmaterialized `StudySession`をexact確認した同一UUIDのclosed active tail。1000行混在oracle／後方page破損の非破壊test sourceがある | delivery順全順列、reverse入力、partial delivery、source fingerprint、`saveCount == 0`、save／checkpoint境界crash、遅延cancel、StudySession同時保存を最新全suiteで確認する。closed-tail削除はStudySession proofなしで0件、proofありで対象active tailだけになることを署名済み2台でも確認するまで提出しない |
| High | corrupt active focusがinteractive recoveryの有界scanを使い切る | interactive pathは回復可能な期間（最新のactive開始から7日＋1日）に始まった最大256 logical sessionを検査し、各group最大128 rowを超えた場合やinvalid payloadは破壊せずmaintenanceへ送る。maintenance checkpointのquarantineは他kindをstarveさせないが、CloudKit row自体を保持するため、valid timerの前にinvalid active logical sessionが257件以上並ぶとfail closedが継続する | 1.0の既知上限としてowner／supportが受け入れ、実SQLite latencyと復旧表示を実機確認する。完全解消する場合はraw payloadを保持しqueryから除外できる可逆model-level quarantineをversioned schemaとして設計し、後のvalid化／解除まで検証 |
| High | partition中の取消と完走にはglobal linearizabilityがなく、観測順で最終履歴が分岐し得る | scheduled end前cancelをcommit前に観測すれば未materialized pendingを閉じるが、`StudySession`が先にmaterializeした後は遅延cancelより`.completed`を優先する。1.0は既保存完走の遡及削除／demotion回避を選ぶCAP trade-off | product／review説明をこの契約と一致させ、署名済み2台でcancel-before-commitとmaterialize-before-delayed-cancelの両方を確認。より強い単一決定を要するならserver-side authority等を設計する別releaseまで提出を止める |
| High | offline複数端末で自己申告のaccount全体上限を3件にできない | 各device-owned Prefs replicaが朝4:00区切りで最大3件を許可し、再接続時はcounterの最大値を解決する。offline A/Bで各3件なら6件のsessionを失わず保持し、global 3件とは主張しない。UIとReview Notesを「この端末で1日3回」に限定 | これはavailable offline記録とglobal hard capを同時に満たせないCAP trade-off。account全体上限が必要ならserver-side CAS ledgerとoffline時の追加禁止を設計する別releaseまで仕様変更しない |
| Medium | maintenanceの一種類が失敗し他修復を飢餓させる | kind別durable retry/backoffへ変更し、retry中kindをskip。Prefsを含むcurrent source phaseはread-only、Bedrock等のlocal projection writeとstale／closed-tail cleanupは独立phaseに分離 | long-lived failure、再起動、旧checkpoint migration、各phase crashをtest／実機で確認し、batch／budget上限とsource非変更を維持 |
| Low | public identifierを秘密値と誤認し、実際のaccess control検証が弱くなる | bundle／CloudKit／IAP IDはbinaryからも観測可能でcredentialではない。private CloudKitはentitlement、署名、Apple Accountで保護 | identifier公開を前提にApple側権限を検証し、credentialは一切置かず、private disclosure窓口とpatch SLAを運用 |
| Medium | dormant random reward sourceを現行機能と誤認する | version 1.0はrandom rewardを出荷せずAge Ratingはchance-based activities None／loot boxes No。設計文書には将来候補が残る | Product page／Review Notes／siteから現行機能としての訴求を除き、feature gateをcheckerで固定。将来有効化時はage rating、倫理、privacy、IAP非連動を再回答 |
| Medium | 「仕事でも安心」など絶対的に読める訴求が実態より広い | share defaultはtheme／memoを出さないが、利用者入力、OS share先、support mailまでは制御しない | metadataを限定的な表現にし、share previewとprivacy説明を実装どおり維持 |
| Medium | iPhone appが未試験のMac／Vision Proへ自動提供される | 新App Store recordの設定は未確認。sourceはiPhoneのみを対象とする | 両方を無効化し、将来有効化する場合は専用QAを実施 |
| Medium | dependency／CI supply-chainが将来変化する | 現在runtime third-party SDKなし、CI actionはcommit SHA固定 | Renovation時にlicense・maintainer・release provenanceを再監査し、untrusted PRにsecretを渡さない |
| Medium | public repositoryの運用control不足 | branch protection、required checks、private vulnerability reporting、Dependabot／CodeQLの実設定はlocalから未確認 | default branch保護、review／checks必須、secret scanning、Dependabot、CodeQL、private reportを有効化して匿名確認 |
| Medium | support窓口やpolicy pageが止まるとreview／利用者対応が成立しない | 新domainのDNS／HTTPSと実メール送受信、retention手順は未検証 | URL監視、support mailbox送受信、削除／export依頼手順、障害時ownerを確認 |
| Medium | Web security header不足 | 新domainのheaderは未測定。旧domainの過去測定は新配信の証拠に使わない | DNS切替とPages deploy後にHTTP→HTTPS、直接HTTPS 200とresponse headerを測定する。対応hosting/CDNを追加する場合は、実際に使うserviceだけをprivacy policyへ記載する |
| Medium | GitHub Pages custom domainの所有確認が外部から立証できない | 新しい`pomogem.hinoshiba.com`の所有確認は未検証 | Repository／organization SettingsのPagesでOwner verifiedを確認し、未検証ならGitHub指定TXTを追加。CNAME takeover耐性を匿名確認 |
| Medium | 公開support addressのなりすまし耐性が弱い | MXとSPFは存在するが、2026-09-03実測でDMARC TXTなし。送信DKIMは未検証 | 正規送信経路のSPF／DKIM alignmentを確認し、DMARC `p=none`で監視後にquarantine／rejectへ段階移行 |
| Low | source公開によりclone appや偽アプリが出る | MITは商用再利用を許す。brand assets／名称は別条件 | trademark policyを明示し、公式App Store linkと署名済みrelease tagを公開、侵害対応窓口を維持 |

## OSS publication controls

1. `./Scripts/check-oss-readiness.sh`でworking treeと全Git historyを走査する。regex scanは証明ではないため、
   GitHub secret scanningと人手reviewを併用する。
2. `.env`、key、certificate、profile、archive、DerivedData、StoreKit test account、App Store Connect API key、
   Apple contact情報をcommitしない。archiveはcheckout外の一時directoryへ作る。
3. MIT対象外assetは`ASSET_LICENSES.md`のhashと一致させ、OFL fontにはlicense全文を同梱する。
   Pages deployは公式repository ID `1351233156`だけにguardし、改名前後ともforkがbrand asset入りWebを
   誤公開しないようにする。
4. 公開前にcommit diffだけでなく全historyを再確認し、必要な履歴改変がある場合はPublic化前に行う。
5. Public化後はsecurity reportをissueへ誘導せずprivate窓口へ送り、重大事故時のkey rotation、CloudKit
   containment、App Store緊急updateのownerを決める。

## Apple submission controls

1. local、Developer Portal、App Store Connect、archive、exported IPAでhost／widget／iCloud
   identifiersをbyte-for-byte照合し、両bundleにApp Groupがなく、WidgetにiCloud／APNs entitlementが
   ないことも確認する。
2. automatic signingが作るportal stateは、maintainerの許可後だけ変更する。既存certificateを推測で
   revoke／再作成しない。
3. 新しい`iCloud.com.hinoshiba.pomogem`のdevelopment environmentを最終RCからinitializeし、
   7 source modelを照合する。旧containerをclearする工程はない。`syncRecordID`、Subject revision／tombstone、Achievement `deletionRevision`／
   `deletionMutationID`／`restoredDeletionMutationID`、Prefs writer、`timerCompletionSoundRawValue`／
   `timerCompletionHapticRawValue`、`timerDisplayModeRawValue`、13組（26 field）のstampを検査し、検証済みの
   exact schemaを一度だけproductionへdeployする。
   production environmentはclearしない。
4. Release archiveのhostと全`.appex`についてversion、build、architecture、codesign、profile、
   entitlementsを検査する。export時にはdistribution署名を再検査する。
5. screenshotはproduction UIと架空dataだけを使い、個人情報、可視debug UI、誤った課金状態、
   placeholder、status barの不要情報を含めない。Debug-only fixtureを使った場合は明記し、署名済み
   Release実機とのvisual parityを確認する。5枚目にdirect deletion rowがないことも確認する。
6. 初回Non-Consumableはapp versionと同じreviewへ追加し、価格表示はStoreKitのlocalized値だけを使う。
7. uploaderはarchive、commit、version／build、Apple IDを読み上げ確認してから本人が実行する。

## Residual legal and business decisions

- 正式な商標clearance、雇用・委託成果物の帰属、AI reference inputの適法性はowner／専門家判断を要する。
- 現行EU 27を除く148地域で同時配信するため、Account Holderは各地域のcompliance、tax、制裁、
  consumer対応と、日本語UI／supportで提供する範囲を受け入れるか公開前に記録する。
- App Storeだけで配布する公式binaryと、第三者がMIT sourceから作るforkを同一品質・privacyとして
  表示しない。公式署名、公式URL、brand policyで区別する。

## 保存先切り替えの追加レビュー（2026-09-12、開発中）

上の保存先不変・再インストール制約は既存版の記録です。次候補では設定から三つの切り替えを
明示的に選ぶ機能を開発しています。cloud置換は復旧用コピーの受領確認後に管理対象zoneだけを
削除し、解除では検証した端末コピーとcloud側の両方を残します。古い端末の再流入、不完全graphでの
停止、途中終了・account変更後の再開は別のrelease review対象です。一般の一括削除UIや
Production環境のresetを有効にする変更ではありません。

[StorageModeTransfer.md](StorageModeTransfer.md)に実行済みのnamespace/controller/UI試験と
実機manifest読取試験の範囲を記録します。これらを全Runtimeの切り替え、Production追加schema配備、
複数端末、最終配布物の合格とは扱いません。build 7の同期修正の提出とは分離し、Actionsの支払い／
利用上限とPages公開などのblockerは実証なしに解除しません。

## Go / no-go record

Release ownerは次を全て記録してからGOへ変更します。

- Release archiveでrare rewardのUI、writer、operations entitlementが存在しない証拠
- CloudKit maintenance: bounded worker／account-scoped checkpoint、Lamport reset、620件以上のprojection
  rebuild、全current／awaiting source duplicateのread-only論理解決、foreign row不変、closed focus tailの
  StudySession proof gateについての最新unit evidenceと2台の後着／競合試験
- clean installで同格の初回二択、各確認、local-onlyのoffline全基本機能、選択不変性、削除／JSON制約を実機確認
- cloud modeの各launch／resume online確認とA→B block→A復帰を、非破壊fail-closed、store、focus、
  account-neutral通知／Widget／Live Activityまで含めて実機確認。Live Activityの全lifecycle、設定OFF、
  手動dismiss後の非再生成と、どの状態でもaccount由来dataがないことを記録
- 1.0でdirect CloudKit一括削除が無効であるRelease実機確認。将来有効化する場合はaccount binding／single-owner lease／offline再流入対策の別release review
- rights／trademark sign-off
- exact source commit／tag、clean CI、Release build、test、analyze
- Developer Portal identifiers／capabilitiesとsigned archive verification
- App Store Connect metadata／privacy／age rating／pricing／territory／IAP／screenshotsのreload確認
- Sandbox、2-device、TestFlight結果、新containerの最終RC initialize検証記録、exact 7-model
  CloudKit production deploy時刻（productionはclearしていないことを含む）
- GitHub Public化後の匿名accessとrepository security settings
- 有料IAPを含む場合の販売主体／法定表示判断と購入前導線、または無料版へ変更した再監査
- upload担当者、archive path、version／build（upload自体は担当者が実行）

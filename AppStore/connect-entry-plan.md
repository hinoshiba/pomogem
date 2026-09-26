# App Store Connect entry plan

Initial preparation: 2026-09-06 for PomoGem 1.0 (5). The instructions below target 1.1.0 (10). App Store Connect shows 1.0.2 (9) Ready for Distribution as of 2026-09-22. A 1.1.0 draft has been created; its binary is not uploaded. This is not a submission record.
New record created and verified on 2026-09-06: Apple ID `6809139517`.
SKU `pomogem-ios`, primary language Japanese, bundle ID `com.hinoshiba.pomogem`.
The registered Japanese name is ポモジェム：ポモドーロタイマー. Historical submissions and their results are recorded separately in the release records.
[Open the new App Store Connect version](https://appstoreconnect.apple.com/apps/6809139517/distribution/ios/version/inflight).
Creation does not complete its IAP, production schema, distribution signing, pricing, or submission.

この文書はApp Store Connectへ保存する値の正本です。個人の連絡先、credential、certificate、
profileはrepositoryへ記録しません。値を保存した後はpageをreloadし、保持されたことを確認します。

## App Information

| Field | Value |
|---|---|
| Name | `metadata/ja-JP/name.txt`（ポモジェム：ポモドーロタイマー） |
| Subtitle | `metadata/ja-JP/subtitle.txt`（集中した時間が、宝石になる） |
| Primary language | Japanese |
| Bundle ID | `com.hinoshiba.pomogem` |
| SKU | `pomogem-ios` |
| Content Rights | Yes — third-party content is included／shown and the rights are held（OFL fontを含む。ownerの全asset provenance sign-offを前提） |
| Primary Category | Productivity |
| Secondary Category | Education |
| Age rating target | 4+（質問票の全回答を下記どおり確認） |

ポモジェムの中心機能は、特定教科を教える教材ではなく、勉強と仕事の集中時間を整理・計測する道具です。
Appleのカテゴリ定義に合わせ、発見性に強く影響するPrimaryはProductivity、学習用途を補足する
SecondaryはEducationとします。

`AppStore/age-rating.md`のdescriptor別根拠を正本として、現行質問票を次のとおり回答します。

- In-App Controls: Parental Controls、Age AssuranceはNo
- Capabilities: Unrestricted Web Access、User-Generated Content、Social Media、Social Media Disabled
  for Users Under 13、Messaging and Chat、AdvertisingはNo
- Mature Themes: Profanity or Crude Humor、Horror/Fear Themes、Alcohol, Tobacco, or Drug Use or
  ReferencesはNone
- Medical or Wellness: Medical or Treatment Information、Health or Wellness TopicsはNone
- Sexuality or Nudity: Mature or Suggestive Themes、Sexual Content or Nudity、Graphic Sexual Content
  and NudityはNone
- Violence: Cartoon or Fantasy Violence、Realistic Violence、Prolonged Graphic or Sadistic Realistic
  Violence、Guns or Other WeaponsはNone
- Chance-Based Activities: Gambling、Simulated Gambling、ContestsはNone、Loot BoxesはNo

Version 1.0はランダム報酬を出荷せず、完走時は通常粒を決定論的に保存します。上記descriptorへ
影響する機能を追加した時点で4+回答を無効化し、全質問を再判定します。

## Candidate 1.1.0 localizations

| Field | Source |
|---|---|
| Promotional Text | `metadata/ja-JP/promotional_text.txt` |
| Description | `metadata/ja-JP/description.txt` |
| Keywords | `metadata/ja-JP/keywords.txt` |
| Support URL | `metadata/ja-JP/support_url.txt` |
| Marketing URL | `metadata/ja-JP/marketing_url.txt` |
| Privacy Policy URL | `metadata/ja-JP/privacy_url.txt` |
| Copyright | `2026 hinoshiba` |

`en-US`も同じfield構成で`metadata/en-US/`から登録します。英語listingでは、アプリUIとcustomer
supportが現在日本語であることを明示し、英語UIがあると誤認させません。英語専用screenshotを
作らない場合は日本語の画像を継承させます。

- Sign-in required: unchecked
- Demo account: none
- Review notes: `AppStore/review-notes-connect.txt`
- Review path: clean installの最初の画面で同格の「このiPhoneのみ」を選ぶと、Apple Account／networkなしで
  全基本機能を審査可能。iCloud pathは選択確認とonline Apple Account検証が必要。続くonboardingの
  ためし粒は任意で「次へ」から省略でき、勉強／仕事共通の候補から最初のテーマ1件を選ぶ。Homeの
  開始buttonの上にある選択欄でテーマと時間を選び、開始buttonのtapでtimerを開始する
- Release: automatically release after App Review approval
- App Review contact: required。提出担当者はcontact first name、last name、`+`と国番号を含む
  international-format phone number、email addressをApp Store Connect上で入力し、保存後にreloadして
  保持を確認する。これらの個人情報はrepository、review notes、CI logへ転記しない。

## Screenshots

- App Store Connectが2026-09-03にversion 1.0で要求したiPhone 6.5-inch枠へ、
  1242×2688または1284×2778のPNG／JPEGを1〜10枚、alphaなしで登録する。
- 5枚の順序は、Homeの瓶、無料25分timer、完走reward、積み上がりoverview、Settingsの
  iCloud／privacy説明とする。
- 架空dataだけを使い、個人情報、通知、debug UI、placeholder、誤った購入状態を含めない。
- 初回IAPのreview screenshotは、新product IDの実StoreKit価格を表示したpaywallを撮影する。
  対象ファイルは`AppStore/screenshots/iap-review/01-pomogem-pro-live-price.png`。
  `configuration.yml`が`pending_live_price_capture`の間は、この画像を存在するものとして登録しない。
- 掲載画像5枚はPomoGem 1.0 (5)から撮影し、実行結果・目視・checksumを
  `AppStore/screenshots/README.md`へ記録する。旧ビルドの撮影記録は新アプリの証拠にしない。
  署名済みRelease実機とのvisual parityは独立した提出gateとする。

## Pricing and Availability

| Field | Proposed value |
|---|---|
| App price | Free |
| Territory | 148 of 175 Countries or Regions（現行EU 27を除外。新しいstorefrontは自動追加） |
| Distribution | Public |
| Apple School Manager reduced price | enabled（version 1.0の推奨値） |
| iPhone／iPad apps on Apple silicon Mac | disabled |
| Apple Vision Pro availability | disabled |

日本語をprimary localizationとして、現行EU 27を除く148地域へ配信します。除外地域はAustria、
Belgium、Bulgaria、Croatia、Cyprus、Czech Republic、Denmark、Estonia、Finland、France、Germany、
Greece、Hungary、Ireland、Italy、Latvia、Lithuania、Luxembourg、Malta、Netherlands、Poland、Portugal、
Romania、Slovakia、Slovenia、Spain、Swedenです。United Kingdom、Norway、Switzerlandは配信対象に残します。
App UIとサポートの主言語が日本語であることをlistingで誤認させず、地域別の法令・制裁・税務・App Store
statusは公開前と各更新時に再監査します。新しいstorefrontの自動追加は有効のため、配信範囲やEU構成が
変わった場合は再確認します。

## In-App Purchase

| Field | Value |
|---|---|
| Product ID | `com.hinoshiba.pomogem.pro.lifetime` |
| Type | Non-Consumable |
| Reference Name | PomoGem Pro Lifetime |
| ja-JP name | ポモジェムPro |
| ja-JP description | 自由な集中時間・月刻印・勉強アプリ数無制限。買い切りです。 |
| en-US name | PomoGem Pro |
| en-US description | Custom timers, month labels, unlimited learning apps. |
| Base country or region | United States |
| United States target price | USD 0.99（「約1ドル」の利用可能な標準price point） |
| Japan custom price | JPY 100 |
| Other available storefronts | AppleがUSD 0.99を基準に為替・税・各地域の価格慣行から生成する現地相当額 |
| Availability | App本体と同じ148 of 175 Countries or Regions（現行EU 27を除外。新しいstorefrontは自動追加） |
| Family Sharing | Off |
| Review screenshot | `captured_live_price`。2026-09-22に1.1.0 (10)の実StoreKit価格$0.99を撮影・検証し、Connectへ登録・再読込確認済み。storefront国は未確認。正本は `AppStore/screenshots/iap-review/01-pomogem-pro-live-price.png` |
| Review notes | `AppStore/iap-review-notes-connect.txt` |

Unlockは無料preset以外の任意の1分00秒〜360分00秒、まとまり粒の月刻印、スクリーンタイムの勉強アプリ数無制限（無料5つ）です。黒い石用アプリ数は無料でも無制限です。分・秒の数字入力とホイールに対応します。share cardは無料／Proともロゴと公式サイトを常設します。subscription、trial、
external purchase、独自serverはありません。purchase、pending、cancel、restore、revocationと、
entitlement反映後にtransactionをfinishすることをSandboxで検証します。初回IAPのversion 1.0提出は履歴です。1.1.0でも既存商品を維持し、購入済み利用者にも追加機能を提供します。

日本だけをcustom priceとして固定し、EU 27を除くその他の配信地域ではAppleの自動調整を維持します。
「全地域を手動管理」は採用しません。App内では常にStoreKitの`displayPrice`を表示し、固定為替や
税込み表示をコードへ埋め込みません。

## Screen Time and storage review

Settings → スクリーンタイムで個人認証後にアプリ・テーマ・記録を設定します。選択アプリの合計10分ごとに
600秒／100gを取り込みます。OS通知の遅延を明記し、常時・即時計測や他アプリの強制起動を約束しません。
黒い石は黒同士だけで結合し、学習集計・報酬・共有から除外します。tokenと未取込情報・黒い石は端末内、
取り込み済み学習記録は通常の選択保存先という区別を、掲載文・Privacy・Review Notesで統一します。
本体／MonitorのFamily Controls distribution承認・最終profile・実到達は未確認です。

iCloud利用中の設定画面には「iCloudから再取得」を追加します。事前のcloud読取、空なら専用警告、
初期OFFの端末data削除同意を経て、未送信変更を捨てて再取得します。cloud側は残り、結合しません。
受付はaccount・namespace・コンテナ／環境へ結び付け、旧形式・別環境のリクエストは実行しません。
端末dataでiCloud全体を置き換える操作と、その復旧再開は引き続き無効です。

## App Privacy

第一候補は **Data Not Collected** ですが、これはまだPublish回答ではありません。独自account、ads、
analytics、tracking、developer serverはなく、7種類の同期元modelは利用者自身の一つのprivate CloudKit
database、4種類の瓶用projectionは端末内だけに保存します。運営者がprivate CloudKit dataを取得・閲覧・
保持しない設計と実運用が維持されることを前提にします。CloudKitへ送るのは、iCloudを選択して確認した
場合のテーマ名、成果memo、記録、設定、進行中timerです。「このiPhoneのみ」はApple Account／network
なしで全基本機能を使え、iCloudへ自動uploadしません。share／exportは利用者の明示操作です。1.0は
rare reward用operations containerもdirect CloudKit一括削除も提供せず、app削除とAppleのiCloud
ストレージ管理を案内します。現在のJSON exportは全11種類の出荷対象SwiftData modelを対象にします。
スクリーンタイムのtoken・未取込情報・黒い石・診断情報は端末内に限り、JSONには含めません。通常記録へ取り込み済みの学習分は選択した保存先の記録として同期・書き出し対象です。診断は件数・結果・時間に限り、運営者へ送信しません。
JSONを再importする機能はなく、このファイルによる復元・移行には対応しません。明示的な保存先切り替えも、このJSONを読み込む処理ではありません。
ただしsupport mailがAppleのoptional disclosure条件を満たさない運用なら、Email Addressを
App Functionality（customer support）、linked to user、not trackingとして申告します。Publish直前に
`AppStore/app-privacy.md`、production binaryのnetwork／dependency、CloudKit access権限と実際のmail
retentionを再確認します。privacy manifestはhostの`C617.1`、`35F9.1`、`CA92.1`と、
Widgetにrequired-reason API宣言がないことをarchive内で照合します。

## Private iCloud account boundary

最初の保存領域を作る前に「iCloudで同期」と「このiPhoneのみ」を同格で提示します。iCloudへ保存する
テーマ名、成果memo、記録、設定、進行中timerと、初回取得・同期再開のonline確認、offline利用の条件を
説明し、利用者の確認後に確定します。同じ画面からPrivacy Policyを開けます。local-onlyも端末限定、
明示的な切り替え、app削除／JSON制約を確認して選びます。

- local-onlyは専用random namespaceとCloudKit `.none`のstoreを使い、Apple Account／networkなしで
  基本機能を利用できる。iCloudへ自動切替／upload／mergeしない
- SettingsからiCloudを有効にするときは「iCloudのデータを使う」。端末だけのテーマ・記録・設定を
  削除してcloud内容に置き換える。最後の削除確認checkは未選択から始まり、二つの記録を結合しない
- iCloud解除は確認できた内容をこのiPhoneへコピーして検証後に確定。cloud側にもdataを残す。
  解除後の端末変更は同期されない。端末dataでcloud全体を置き換える操作と、その復旧再開は通常Releaseで禁止
- 切り替えには通信と案内どおりのapp終了・再起動が必要。app自体を削除しないよう案内する。
  確認中にcloudが変わった場合は保持して停止し、許可された取消しでは元dataと途中コピーを残す場合がある。
  このコピーは利用者向けUndoではない。別世代を再取得するときも端末未送信dataの削除確認を別途要求する
- 同期用containerを作る前にaccount・保存先・切り替え状態・リセット履歴を確認する。通常起動の
  control読み取りは`accountStatus → identity → 対象control取得 → identity`の順で実行し、通信確認にも
  その応答を使う。namespace照合、controlの2回比較、画面公開直前の再検証を省略しない
- cloud cache、端末内projection、focus復旧／deferred state、maintenance checkpoint、reset適用状態を
  同じnamespaceで分離する。Proの追加optional秒数と変更参照も既存Prefsの選択保存先に保持・同期する
- 初回は観測したリセット世代以上の履歴が端末へ届くまでRootとwriterを公開しない。初回取得の
  非同期確認には30秒、利用済み端末には12秒の期限がある。接続確認を全記録の送受信完了とは表示しない
- 以前に確認できた完全な端末storeと利用記録が条件を満たす場合は、同じstoreを同期なしで開いて
  timer・記録・設定を利用できる。オフラインでの変更を端末へ保存し、「このiPhoneに保存・同期は待機中」と表示する
- account変更はoffline利用を失効させる。未対応の履歴不一致や切り替え処理をoffline許可で迂回しない。
  通信回復時はaccount・保存先・履歴を確認して同期再開へ進む。自動削除や混在修復で起動を続けない
- 同じprocessで一度でも同期用storeを開いた場合、退役後に同じfileを同期なしで開かない。
  online利用後のbackground復帰などではapp終了・再起動が必要になり得る。時間切れでは再試行を案内する
- 同期なしで利用中の画面は通常のbackground移行で保持する。復帰時に利用条件を再確認し、
  account変更の通知・失効では表示とwriterを止める。保存済みdataは自動削除しない
- iCloudの通常resetは一時的に利用不可とし理由を表示。local-only通常resetは維持する
- app削除はlocal-onlyの記録とcloudへ未送信の変更を失わせる。JSON再import・このfileによる復元や移行は未対応
- Widgetはaccount-neutralな起動導線だけを表示し、App Group、iCloud、記録、質量、テーマ名、瓶画像を読まない。
  tapは固定の`pomogem://focus/start`でアプリを開き、Homeの開始buttonと同じ条件で集中を始める
- Live Activityはアプリ名、選択時間、残り時間、実行状態（完走後に選んだ休憩を含む）だけを表示。秒単位の指定時間も分・秒で示し、
  payloadへtheme名、memo、質量、Apple Account、CloudKit dataを含めない。端末内更新で設定とOS許可を尊重する
- OSへ予約済みのlocal notificationはprocess停止中のaccount変更を再検証できないため、
  終了通知へテーマ名を含めない。旧timerの共通文面が一度届く可能性は既知の制約として扱う

これは候補の実装契約です。既存の単体試験、専用host、通常画面の実機試験の結果を分けて記録し、
実施していない二端末・account変更・全データ受領を合格と扱いません。過去のbuildの署名・提出も、
次候補のRelease artifactの検証結果とは分けます。記録は`Docs/OfflineCloudMode.md`、
`Docs/StorageModeTransfer.md`と各release recordを参照してください。

## CloudKit source schema and replica safety gate

これはApp Store Connectのmetadata fieldではなく、build選択前に満たすrelease gateです。iCloud modeの
7 source modelで、現在世代またはmarker未着世代のphysical duplicateをbackground maintenanceが
canonical rowへ書戻し、全copyへfan-out更新、または物理削除することを禁止します。表示・会計・timer
ownershipはboundedなpure resolverで決め、後着copyのたびに再解決します。source削除の例外は、supported
reset markerで明示的に証明したstale epochと、有効なmaterialized `StudySession`をexact確認した同一UUIDの
closed focus active tailだけです。`AggregatePebble`、`Stratum`、`Bedrock`、`GachaState`はCloudKitへ送らない
再構築可能なlocal projectionなので、検証済みのmerge／compactを許可します。

ただしlocal projectionを正本または常に正確なcacheとして扱いません。既存aggregateは
`projectionValidationVersion`と全memberのexact／second-pass検証に合格した場合だけ会計へ使います。
cloud modeの起動直後、remote change検出後、またはmaintenance pending中は旧rootを抑止し、Home／Overview／
Shareで「再集計中」と表示します。初回60秒後、真正なforeground復帰、active継続15分ごとのrolling
verificationを行い、署名済み2台で実CloudKit notificationと古い日時の後着recordを確認するまで
TestFlight外部配布／Review提出のbuildを選びません。

最終RCの7-model schemaでは、次の新規fieldを必ずdevelopment環境で確認します。

| Model | Final source field gate |
|---|---|
| `Subject` | `syncRecordID`、`contentRevision`、`contentMutationID`、`deletedAt` |
| `StudySession` | `syncRecordID` |
| `AchievementStone` | `syncRecordID`、`deletionRevision`、`deletionMutationID`、`restoredDeletionMutationID`（revision／tombstoneと併用） |
| `Prefs` | `syncRecordID`、`settingsWriterID`、`timerCompletionSoundRawValue`、`timerCompletionHapticRawValue`、`timerDisplayModeRawValue`、13組の`<group>Revision`／`<group>MutationID` |
| `ActivityResetMarker` | 追加なし |
| `SyncedFocusTimer` | 追加なし |
| `FocusTimerDeviceClaim` | `syncRecordID` |

Prefsの13 groupは`sound`、`haptics`、`timerCompletionSound`、`timerCompletionHaptic`、`rareReward`、
`reminderEnabled`、`reminderTime`、`shareIncludesManual`、`externalTheme`、`keepScreenAwake`、
`preferredFocusMinutes`、`timerDisplayMode`、`usagePurpose`です。追加するtimer完了設定fieldは
`timerCompletionSoundRawValue`、`timerCompletionSoundRevision`、`timerCompletionSoundMutationID`、
`timerCompletionHapticRawValue`、`timerCompletionHapticRevision`、`timerCompletionHapticMutationID`です。
timer表示設定fieldは`timerDisplayModeRawValue`、`timerDisplayModeRevision`、
`timerDisplayModeMutationID`です。既知raw valueは`ringAndTime`、`filledDial`、`timeOnly`、`ringOnly`で、
既定値と未知値の表示fallbackは`ringAndTime`です。
`usagePurpose`はモデル構造／JSON field構成を維持する履歴fieldであり、旧containerからの移行を意味しません。出荷UIは
勉強・仕事共通の一つのテーマ一覧を使い、この値で表示や候補を分岐しません。
各端末は自分の`settingsWriterID`に一致する1 physical rowだけを更新し、他端末のrowを変更しません。
Subjectの削除tombstoneはVersion 1.0ではstickyで、後着した高revision renameでも復活しません。
Achievementのdurable削除eventは`(deletionRevision, deletionMutationID)`です。通常編集とin-place restoreは
このeventを消さず、画面の明示Undoだけが観測したtokenを`restoredDeletionMutationID`でackして高revision
restoreを書きます。legacy `deletedAt` rowは`(row.revision, deletionMutationID ?? syncRecordID)`をeventとして
合成します。後から届いた未観測の新しい削除eventを、高revision active rowだけで復活させません。

新しい`iCloud.com.hinoshiba.pomogem`のdevelopment environmentを最終RCからinitializeし、
7 modelを照合します。旧containerをclearする工程はありません。上記fieldの名前・型・default、4種類のtimer表示選択、
clean install、2台のoffline変更、A/B→B/C→late Cのpartial delivery、foreign row不変、JSON raw exportを
developmentで検証し、
同じschemaだけをproductionへdeployします。production environmentはclear／resetしません。schemaが異なる
buildを先にTestFlightへ出さず、production deploy時刻と検証したcommit／buildを非公開release recordへ残します。

## EU Digital Services Act

Version 1.0の提供方針は、App本体とIAPを現行EU 27から除外し、いずれも148／175 storefrontで
提供することです。新app recordと新IAPへ設定を保存し、再読み込みで確認するまで地域設定のgateは
完了しません。以前のrecordでの保存履歴は今回の完了根拠にしません。United Kingdom、Norway、
Switzerlandは配信対象に含める計画です。accountの **non-trader** statusも提出時に照合します。
これはtrader該当性についての法律判断ではありません。将来EUでの提供を有効にする場合、またはEU構成・
事業実態・Apple要件が変わる場合は、公開前にAccount Holderがstatus、連絡先検証、product page表示を
再評価します。個人住所・電話・メール・確認書類はrepositoryへ保存しません。

## Export compliance and accessibility

- `ITSAppUsesNonExemptEncryption = NO`。Apple OSのCloudKit／StoreKit通信だけで、独自暗号を同梱しない。
- Accessibility Nutrition Labelsは空欄のまま提出できますが、claimを行う場合はVoiceOver、Voice
  Control、larger text、contrast、differentiate without color、reduced motionを対応端末で再試験します。

## Required Developer Portal state

2026-09-06に下記main／Widget App IDとCloudKit containerの新規登録、およびcontainerのhostへの
割当を確認しました。Production schema、署名済みArchive／distributionの検証は別の未完了gateです。

- main App ID: `com.hinoshiba.pomogem`
- widget App ID: `com.hinoshiba.pomogem.widgets`
- SwiftData iCloud container: `iCloud.com.hinoshiba.pomogem`（CloudKit、hostへ割当）
- main capabilities: iCloud／CloudKit、Push Notifications、In-App Purchase
- widget capabilities: none。App Group、iCloud／CloudKit、Push Notificationsを割り当てない。ローカル更新の
  Live Activityは既存Widget extensionを使い、専用entitlementやActivityKit pushを追加しない
- host Info: `NSSupportsLiveActivities = true`。frequent updatesは宣言しない。Widget Infoにはhost用の
  `NSSupportsLiveActivities` keyを宣言しない

automatic signingによるportal mutationはowner許可後だけ行い、既存certificateを推測でrevoke／再作成
しません。Archiveとexported IPAでhost／widgetのbundle ID、team、profile、entitlement、version／build、
architecture、codesignを再検証します。

新CloudKit development containerの最終RC initialize、field照合、2台検証、productionへのexact schema
deployは未完了です。これはbuild選択・TestFlight配布より前のblockerであり、production schemaをclearして
解消してはいけません。

## Remaining App Store Connect work

- 新version 1.0のja-JP／en-US description、review notes、listing field、copyright、screenshots、
  category、content rightsをsource-of-truthどおり保存し、reload後の完全一致を確認
- App Privacyをproduction binaryと運用に照合して回答・公開
- App Reviewの必須contact first name、last name、国際形式phone、emailを入力
  （個人情報のためrepositoryには置かず、提出画面だけで入力）
- `timerDisplayMode`を含む最終候補を一意なbuild番号でArchive／Distributeし、そのbuildと初回IAPを
  同じsubmissionへ追加して、release methodがautomaticであることを再確認
- 最終CloudKit schema、signed-device／Sandbox QA、export compliance、accessibility回答を完了

2026-09-06にユーザーは新IDでの新規登録とアプリ・HPへの全面反映を明示的に指示しました。
通常の登録・draft保存はこの許可の範囲で進め、実行した結果だけを完了として記録します。

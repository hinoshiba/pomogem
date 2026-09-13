# PomoGem 1.0.2 (9) — 審査提出完了

更新日: 2026-09-13。build 9のArchive、配布payload検証、Apple Validate、uploadは完了しました。
Xcode Organizerで「App upload complete: PomoGem 1.0.2 (9) uploaded」と同日11:22 JSTの
upload履歴を確認しました。App Store Connectで処理済みbuild 9を選択し、同日11:39 JSTに
審査へ提出しました。提出受付画面でiOS 1.0.2 (9)の「審査待ち」と提出日時を確認しました。
これはAppleの承認や公開完了を意味しません。

Xcode Organizerで既存1.0.2 (8)の「Uploaded to Apple」と同日10:01 JSTのupload履歴を
確認したため、修正候補のbuild numberを9へ増やしました。build 8の審査状態やCloudKit schemaの
配布状態を、このupload表示から推測しません。既存のapp record、Bundle ID、IAP、価格、提供地域、
CloudKit containerを維持します。

## 今回の変更

- 「視差効果を減らす」の有効・無効に関係なく、粒のタップ、落下、傾き、シェイクで同じ物理挙動を使う。
- カメラ、光、粒子、結晶形成などの装飾演出には引き続き視差効果設定を適用する。
- 初回のためし粒と完走後の粒にも同じ落下動作を適用し、記録と着地通知の重複を防ぐ。
- build 8のiCloud修正とProタイマーの分・秒指定を含み、日本語・英語の更新内容へ粒の修正を追加する。

粒の修正自体は保存モデル、CloudKit schema、権限、購入商品を変更しません。候補全体には
build 8からのPrefs追加属性`preferredFocusSeconds`と`preferredFocusSecondsMutationID`が含まれます。

## Archive・配布検証・uploadの証拠

[PR #13](https://github.com/hinoshiba/pomogem/pull/13)のmerge commit
`9c256136f7b9d4190da5800723acec0273bd6b27`をcleanな状態で固定し、Xcode 26.6とiOS 26.5 SDKで
Release Archiveを作成しました。2026-09-13 11:14 JSTに成功し、appとWidgetの1.0.2 (9)を照合しました。
OrganizerのApple Validateは11:16 JSTに成功しました。

元のArchiveはApple Development署名とReleaseのCloudKit Production環境の組合せを持つため、
既知の署名class／環境不一致としてdefaultのraw-archive検証に拒否されます。元のArchiveは変更せず保持しました。
Xcodeは既存のcloud-managed Apple Distribution identityを配布時に再利用しました。

別途exportしたIPAと実際のupload-staging IPAの両方について、変更していない配布appと元のdSYMを
一時的なarchive layoutへコピーし、既存の`verify-release-archive.sh --distribution`による厳格な検証に成功しました。
appとWidgetはApple Distribution署名とApp Store配布profileを持ち、`get-task-allow=false`です。
hostの署名済みCloudKit／APNs環境はProduction／productionで、Widgetはaccount-neutralです。
両payloadのapp・Widget実行ファイルのUUIDは元Archiveおよび各dSYMと一致しました。

| 検証済みpayload | SHA-256 |
| --- | --- |
| 別途exportした配布IPA | `f1affe1f4cf1fdd50e34c69f71a53700f1dd0631e53dab2119551ebbd6592896` |
| 実際のupload-staging IPA | `d7f631a07e25fb885b4bd6c1e25e825dcaf5c78fdb0957f30a8bc494e5ee0b1f` |

この2つのpackageは別の成果物です。別途exportのhashをuploadしたファイルのhashとして扱いません。
Organizerのupload成功を確認した後、不変tag `v1.0.2-build9`を作成・pushし、上記の正確なArchive元を
指すことを確認しました。この記録を含む後続commitとArchive元を区別し、tagを移動しません。

## Prefs追加schemaの確認

2026-09-13 11:33 JSTにCloudKit Consoleで`iCloud.com.hinoshiba.pomogem`を開き、
DevelopmentとProductionの両方で`CD_Prefs`が70 fieldを持ち、次の型・indexが一致することを確認しました。

| Field | 型 | Index |
| --- | --- | --- |
| `CD_preferredFocusSeconds` | Int(64) | Queryable、Sortable |
| `CD_preferredFocusSecondsMutationID` | String | Queryable、Searchable、Sortable |

ProductionのSchema Historyには同日09:52 JSTの`CD_Prefs`の2 field変更・5 index作成があり、
今回の確認前に配備されていたことを照合しました。この作業ではschemaの変更・再配備を行っていません。
これは両環境のschemaと配備履歴の確認であり、実機2台の秒単位送受信の成功を意味しません。

## App Store Connectの差し替えと審査提出

2026-09-13 11:34 JSTにTestFlightでbuild 9のupload status「終了」とbuild status
「提出準備完了」を確認しました。既存1.0.2 (8)には同日10:11 JSTの審査提出と「審査待ち」があり、
今回の修正へ差し替えるためその提出を取り消しました。「デベロッパにより却下済み」を確認してから
build 9を選び、保存後に提出準備状態へ戻ることを確認しました。

日本語・英語の「このバージョンの最新情報」を正本から保存し、ページ再読込後に両方の全文が
一致することを確認しました。末尾改行を除き日本語452文字、英語924文字です。
Review Notesは既存の正本3022文字を維持し、再読込後の全文一致を確認しました。
選択ビルドも9であることを再確認しました。

承認後の自動公開と全利用者への即時配信という既存設定を維持しました。screenshots、審査連絡先、
App Privacy、IAP、価格、提供地域は変更していません。
11:39 JSTに提出し、「1項目が提出されました」という成功表示に続いて提出受付画面を開き、
対象がiOS 1.0.2 (9)、状態が「審査待ち」、提出日時が2026-09-13 11:39 JSTであることを照合しました。

## ソース検証と検証範囲

最新mainへ統合した粒の修正commit `410e172`で、iPhoneシミュレータの統合ビルドと試験が成功しました。
単体試験は1,222件中1,216件成功・6件スキップ・失敗0件です。対象UI試験4件もすべて成功し、
「視差効果を減らす」のON／OFFそれぞれでタップ時の跳ね、完了画面を閉じた後の落下、
記録の不変性と落下の再生重複防止を確認しました。試験は2026-09-13 11:04 JSTに完了しました。
raw logとresult bundleはリポジトリ外に保持します。

同commitのcurrent-file readiness、サイト検証、App Store metadata検証も成功しました。
build numberを9へ変更した後のmetadata・サイト検証と差分の書式検査も成功しています。
build 9のprojectを再生成し、Releaseの署名なしSimulatorビルドが成功しました。appとWidgetの
Mach-O、1.0.2 (9)、Release bundle内にDebug／UI試験用hookがないことを照合しました。
Release static analyzerも成功しました。
統合試験はbuild number更新前の同じアプリソースに対する結果です。これらをArchiveや署名済み
実機の合格証拠には転用しません。build 8の試験結果は[既存の記録](release-record-1.0.2-8.md)に保持します。

GitHub Actionsはaccountの支払い・利用上限の理由でjob自体を開始できませんでした。上記は
ローカル検証の結果で、hosted CIが成功したことを示しません。

`AppStore/configuration.yml`の既知のrelease blockerは未解決のまま保持します。current-file readinessは
full-historyの合格を意味せず、過去のGit identity metadataに対する既知の監査失敗も解決済みとは扱いません。
実機2台の秒単位送受信、StoreKitの実購入・復元、全アクセシビリティ項目をこの候補で検証済みとはしません。
公開Privacyの配信状態も別途確認が必要です。

Archive、IPA、署名情報、profile、端末・account識別子、raw logと審査連絡先はリポジトリ外に保持します。

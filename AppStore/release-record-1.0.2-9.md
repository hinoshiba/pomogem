# PomoGem 1.0.2 (9) — upload完了・審査提出待ち

更新日: 2026-09-13。build 9のArchive、配布payload検証、Apple Validate、uploadは完了しました。
Xcode Organizerで「App upload complete: PomoGem 1.0.2 (9) uploaded」と同日11:22 JSTの
upload履歴を確認しました。App Store Connectでの処理完了と選択ビルドは未確認で、
build 9の審査提出はまだ行っていません。

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

## ソース検証と残作業

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

ブラウザの自動操作が拡張機能UIで停止しているため、App Store ConnectとCloudKit Consoleの
以下の確認・操作は完了していません。upload成功を審査への提出やschema配布完了として扱いません。

- Prefs追加2属性のCloudKit Development/Production状態を確認する。現在は未確認であり、
  以前のschema証拠やbuild 8・9のupload成功を配布完了の証拠として転用しない。
- Apple側のbuild処理完了、App Store Connectの選択ビルド、更新内容とReview Notesを保存・再読込で照合し、審査へ提出する。

`AppStore/configuration.yml`の既知のrelease blockerは未解決のまま保持します。current-file readinessは
full-historyの合格を意味せず、過去のGit identity metadataに対する既知の監査失敗も解決済みとは扱いません。
実機2台の秒単位送受信、StoreKitの実購入・復元、全アクセシビリティ項目をこの候補で検証済みとはしません。
公開Privacyの配信状態も別途確認が必要です。

Archive、IPA、署名情報、profile、端末・account識別子、raw logと審査連絡先はリポジトリ外に保持します。

# PomoGem 1.0.2 (9) — 提出準備

更新日: 2026-09-13。build 9はまだArchive・upload・審査提出を完了していません。

Xcode Organizerで既存1.0.2 (8)の「Uploaded to Apple」と同日10:01 JSTのupload履歴を
確認したため、修正候補のbuild numberを9へ増やします。build 8の審査状態やCloudKit schemaの
配布状態を、このupload表示から推測しません。既存のapp record、Bundle ID、IAP、価格、提供地域、
CloudKit containerを維持します。

## 今回の変更

- 「視差効果を減らす」の有効・無効に関係なく、粒のタップ、落下、傾き、シェイクで同じ物理挙動を使う。
- カメラ、光、粒子、結晶形成などの装飾演出には引き続き視差効果設定を適用する。
- 初回のためし粒と完走後の粒にも同じ落下動作を適用し、記録と着地通知の重複を防ぐ。
- build 8のiCloud修正とProタイマーの分・秒指定を含み、日本語・英語の更新内容へ粒の修正を追加する。

粒の修正自体は保存モデル、CloudKit schema、権限、購入商品を変更しません。候補全体には
build 8からのPrefs追加属性`preferredFocusSeconds`と`preferredFocusSecondsMutationID`が含まれます。

## 検証と残作業

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

提出前には次を確認し、実際に得た結果だけを追記します。

- PRのmerge後にcleanな固定commitからArchiveし、appとWidgetの1.0.2 (9)を照合する。
- 実際の配布payloadの署名、権限、バージョン、実行ファイルとdSYMの対応を検証し、Apple Validateを完了する。
- Prefs追加2属性のCloudKit Development/Production状態を確認する。現在は未確認であり、
  以前のschema証拠やbuild 8のupload成功を配布完了の証拠として転用しない。
- Apple側のbuild処理完了、App Store Connectの選択ビルド、更新内容とReview Notesを保存・再読込で照合し、審査へ提出する。
- upload成功後に、実際のArchive元を指す新しい不変tagを作成する。既存のrelease tagを移動しない。

`AppStore/configuration.yml`の既知のrelease blockerは未解決のまま保持します。current-file readinessは
full-historyの合格を意味せず、過去のGit identity metadataに対する既知の監査失敗も解決済みとは扱いません。
実機2台の秒単位送受信、StoreKitの実購入・復元、全アクセシビリティ項目をこの候補で検証済みとはしません。
公開Privacyの配信状態も別途確認が必要です。

Archive、IPA、署名情報、profile、端末・account識別子、raw logと審査連絡先はリポジトリ外に保持します。

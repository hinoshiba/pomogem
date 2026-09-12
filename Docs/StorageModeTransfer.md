# 保存先の切り替え — 開発中の仕様と検証範囲

更新日: 2026-09-12

この文書は、Settingsに追加中の保存先切り替えを説明します。1.0.1 (7)には含まれません。
同期修正のbuild 7は2026-09-12 16:26 JSTに提出し、`WAITING_FOR_REVIEW`を確認しました。
保存先切り替えの追加CloudKit schemaは同日のCloudKit ConsoleでProductionへの配備完了表示を
確認しています。これは新機能のProduction runtime試験の合格を意味しません。
保存先切り替えを含む次候補のbuild番号、最終実機検証、公開は未完了です。掲載文・審査メモ・Webの
build 7向け説明を、この開発中機能の説明で上書きしません。提出の詳細は既存のrelease recordで管理し、
この文書を新機能のConnect保存やPages公開の証拠にはしません。

## 利用者が選ぶ動作

初回は引き続きiCloudと「このiPhoneのみ」を同格で提示します。local-onlyを自動で
iCloudへ切り替えたり、二つの保存先の記録を自動で結合したりしません。

| 設定で確認する選択 | 残すデータと変更範囲 |
| --- | --- |
| iCloudを有効にする → iCloudのデータを使う | iCloudの内容を検証して新しい端末保存領域へ取り込み、現在の端末だけのテーマ・記録・設定を置き換える |
| iCloudを有効にする → このiPhoneのデータで置き換える | 現在の端末データを残し、iCloudのPomoGemデータを置き換える。同じApple Accountの他の端末にも影響する |
| iCloudを解除する → このiPhoneへ引き継ぐ | iCloudの内容を端末へコピーし、検証できた後に同期を解除する。iCloud側のデータは残り、解除後の端末での変更は同期されない |

有効化の二択はどちらも失われる側を表示し、最後の確認で初期状態が未選択のチェックを
求めます。「キャンセル」「戻る」や仮の選択だけでは処理を開始しません。受け付けた処理の
二重起動を防ぎ、タイマー実行・一時停止、書き出し、削除などと重なる開始を抑止します。

画面の案内に従ってアプリを終了し、開き直す手順があります。**アプリ自体を削除しないでください。**
通信断や中断後は復旧画面から再試行します。JSON書き出しには再インポート機能がなく、この
切り替えでJSONを読み込むわけではありません。local-onlyのままアプリを削除すると端末の記録は失われます。

iCloudを端末の内容で置き換える前に、他の端末のPomoGemを終了し、最新版へ更新してください。
古い版やオフライン端末は新しい処理の境界を守れず、後から古いデータを再送する可能性があります。
他端末を遠隔消去する機能ではなく、古いクライアントを含む原子的な置き換えを保証しません。

## 保存と復旧の境界

- 処理は同じApple Accountと確認済みの保存元・保存先へ結び付けます。通常起動で古いnamespaceを
  任意の新しいnamespaceへ差し替えることは許可しません。明示した処理のdurable journalと
  commit済みreceiptだけが、限定した保存先変更の根拠になります。
- 閉じた元storeの検証済みコピーを保持し、新しい保存先を準備します。7種類の同期元modelの
  全fieldとrelationshipを比較し、件数や一部の表示が一致しただけでは完了にしません。
  端末内だけの4種類のprojectionを通常のCloudKit同期元recordとして送ることはありません。
- iCloudを置き換える場合、端末データの復旧用コピーを同じApple Accountのprivate CloudKitへ
  保存し、受領・内容を確認した後だけ管理対象zoneの削除へ進みます。このコピーには端末だけの
  過去の記録や内部保存データも含まれます。復旧用control/chunkは同じcontainer内の専用zoneを使い、
  別のoperations containerや運営者のserverを使いません。通常の同期modelへ直接CloudKit recordを
  書き込む設計ではありません。
- 処理完了後は復旧用コピーの削除を試み、失敗時は再試行待ちとして残ります。復旧用コピーを
  利用者向けの任意復元・Undo機能とは扱いません。
- 全ページ取得、account照合、schema、復旧コピー、recordの対応関係を検証できなければ停止します。
  途中の取り込みで参照先が欠ける、同じ候補が複数あり一意に対応できない、といった不完全な
  relationship graphも自動的に破棄・修復して続行しません。再試行しても解消しない場合はサポートへ
  連絡し、アプリやiCloudデータを自己判断で削除しないでください。
- 別端末で更新されたdatasetに端末cacheが追いつかない場合も通常のwriterを開きません。
  明示的に新しいcloud保存領域へ取り直し、検証できてから以前のcacheを退役させる経路を開発中です。
- 別端末の未完了の置換を引き継ぐremote復旧は、引き継ぐ端末に既存cloud cacheや以前の保存先切り替えの
  receiptがある場合、現在の実装では停止します。既存の保存領域を黙って消すことはありません。
  完了済みdatasetを新しい領域へ取り直す前項の経路とは異なり、既存cacheがある端末も含めた
  2台間の復旧が成立するとは主張しません。停止を解除するためにappを削除する案内もしません。

通常起動の`CloudActivityHistoryPreflight`はリセット履歴の世代を待つ確認であり、全利用者データの
取り込み完了を保証しません。保存先切り替えの全field比較とは別です。一般のCloudKit一括削除UIは
引き続き無効で、iCloudの「表示中の記録をリセット」も一時停止中です。local-onlyの通常resetは維持します。

## 確認できたことと残る試験

2026-09-12の確認結果です。実データ、account識別子、端末識別子、署名情報は記載しません。
最新のSimulator単体テスト全体は1,152件中1,146件成功・明示的な実機専用6件をskip・失敗0件です。
Release構成のSimulator arm64／x86_64解析も成功しました。端末やProduction環境の試験を
Simulatorの結果で置き換えるものではありません。

| 証拠 | 確認できた範囲 | その証拠だけでは未確認の範囲 |
| --- | --- | --- |
| Simulatorのnamespace authority 14件、controller 5件成功 | 明示処理だけのnamespace変更、別account・不正authority拒否、commit後再開、二重開始と失敗再試行 | 実CloudKit通信と全Runtimeの切り替え |
| 実際のSettings部品を使うDebug専用UI fixtureの保存先切り替え8ケース成功、修正後のオフライン4ケースも成功 | 二択、未選択の削除確認、戻る・取消、1回だけの開始、解除時のcloud保持、busy表示、AX5の操作・改行。オフライン案内の占有面積、全文のスクロール、44pt以上の操作、二重再試行の防止 | 8ケースと修正後4ケースは別run。通常Settingsから永続化サービスまでの全工程、実機VoiceOverの総合評価は別途必要 |
| 実機のProduction private databaseを読むmanifest試験とprivate `.none` storeへの取り込み成功 | 実データの全field decoderとrelationship比較、fresh context再読、7種類のschema descriptor | `AchievementStone`は実レコード0件のためその実配送、保存先切り替えによる削除・置換・中断復旧の全工程 |
| 実機Developmentで非空iCloudの置き換え・端末へのコピー・コピー開始の取消が成功 | 端末とiCloudに異なるテストデータを用意。復旧コピー受領後の管理対象zone削除、要求されたプロセス再起動、完了後の端末11種類・サーバー7種類の全データ一致。コピーと取消ではiCloud内容不変 | 通常画面を起動しない専用ホストでのRuntime試験。実際の通信断、アプリ削除からの復旧、通常画面操作、複数端末を含む試験ではない |
| 実機Developmentで切り替え途中のアプリ削除・再インストールからの復旧が成功 | 受領済みの復旧コピーがあり、置換中の状態で実際にアプリを削除。再インストール後に通常同期を拒否し、サーバーの復旧コピーだけから新しい端末保存領域へ復旧。端末11種類15件、サーバー7種類11件の全データ・関連付け・識別子・epochが一致し、確定済み世代と未完了処理の解消も確認。再インストール後のデータ投入やMacからのファイル復元は行っていない | 復旧コピーを受領した特定の置換中チェックポイントと明示的なプロセス再起動での試験。任意の処理中の強制終了、通常利用中の再インストール、通信断、通常画面、Production環境を含む証拠ではない |
| CloudKit Consoleの追加schema配備完了表示を確認 | ConsoleがProductionへのschema配備を完了したこと | 新機能のProduction runtimeでの保存・削除・復旧、全切り替えの実機試験 |

UI fixtureの処理先は記録用の代替closureであり、CloudKitや利用者storeを変更しません。
実機manifest試験自体はread-onlyですが、hostアプリの通常起動による設定・同期metadata更新は許可した
試験です。「プロセス全体がcloudへ書き込んでいない」という証拠にはしません。

次候補の出荷には、全Runtimeの三つの切り替え、途中終了・再起動、account変更、古い端末・複数端末、
大きなデータ、不完全graph、復旧用コピーの保持・削除を含む実機検証が必要です。
追加control/chunk schemaはProductionへ配備済みですが、新機能のProduction実通信検証、最終Release
artifactの署名・試験用hook除外、掲載文と実画面の照合は別途必要です。build 7のArchive・Upload・
審査待ち状態や、schemaの配備だけをこれらの合格証拠へ流用しません。

GitHub Actionsの支払い／利用上限による未実行、PagesのDNS・HTTPS・公開確認など既存の運用blockerは
この文書で解除しません。Connectのログインやbuild 7の提出状況も個別の実行結果で更新します。現在の正本は
[RELEASING.md](RELEASING.md)、[提出チェックリスト](../AppStore/submission-checklist.md)と
[configuration.yml](../AppStore/configuration.yml)です。通常のリリース手順にProduction環境の
reset・一括消去を追加しません。

## 次候補の文面とvalidatorの更新対象

build 7の掲載文を保持するため、現時点ではREADME・設計・トラブルシュートに開発中の補足を加えています。
次候補を提出する際は、`AppStore/metadata/*/description.txt`、両Review Notes、`app-privacy.md`、
`connect-entry-plan.md`と`http_dists/index.html`の静的日本語・翻訳辞書の両方で、旧版の変更不可・
再インストール誘導を三つの切り替えと復旧用コピーの説明へ更新します。現在のbuild 7の原稿を、
次候補が出荷済みのように書き換えません。

`Scripts/validate-store-metadata.py`は文字数と既存の導線labelを確認しますが、残す側／失われる側、
解除後のcloud保持、復旧コピー、再起動・app削除禁止の一致までは確認しません。
`Scripts/validate-site.py`も翻訳の構造とリンクを検証しますが、これらの意味の一致は対象外です。
次候補では文言更新に合わせた照合を追加し、build/version固定値はその候補が決まってから変更します。
`Scripts/verify-release-archive.sh`の既存`POMOGEM_UI_TEST_`除外は新しいSettings fixtureにも適用します。
この文書更新ではvalidator、build固定値、公開状態、source/testを変更・実行していません。

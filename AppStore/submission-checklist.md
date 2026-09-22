# App Store submission checklist

PomoGemの現行候補と、初回1.0 (5)以降の履歴を区別したチェックリストです。実装済みの項目と、
Apple上の登録・実機検証は分けて確認します。以前のアプリに対するupload／価格／schema／登録済みの証拠は新アプリへ転用しません。
過去の結果は`Docs/LEGACY_RELEASE_PROVENANCE.md`に分離しています。

## 2026-09-13 スクリーンタイム候補の配布前確認

次は新機能の出荷条件です。sourceのmerge、Simulatorでの成功、以前のApp Store提出結果を
Apple承認や実機確認の代わりにしません。[仕様・手順](../Docs/ScreenTimeGems.md)を参照します。

2026-09-20〜21にApple Development署名のRelease実機（iPhone 12 mini／iOS 26.3.1）で確認を実施しました。
範囲と合格・不合格・保留の内訳は[実機スクリーンタイム監査](../Docs/RealDeviceScreenTimeAudit.md)に記録します。
**この実施で新たにチェックできた項目はありません。** 10分到達そのものは#10の修正後に実機で成立しましたが、
同じ項目が束ねている20分到達・端数・日付またぎ・時刻／タイムゾーン変更・端末再起動・タイマー中の休止表示は
いずれも未確認のため、項目としては閉じられません。取消・再許可も人手が必要なまま残っています。
各項目の下に、実機で確認できたこととできていないことを書き分けます。

09-21夕方の1回目の再試験は、**アプリが起動できなくなり中断しました**（オフライン継続の受領書が
アカウント変化で取り消され、起動画面から非破壊の出口が消える不具合。
[監査記録](../Docs/RealDeviceScreenTimeAudit.md)の#9）。これは誤検知と判明し、別ブランチで修正して
実機で確認済みです（**この候補のブランチには未取り込み**）。

同日深夜、その修正を入れたbuildで2回目の再試験が成立し、**10分到達が不合格である理由が初めて
実機の数字で特定できました**。iOSは両方の利用窓で閾値到達を**実際に配送しており**（到達2件、
いずれも利用窓の中の時刻）、監視拡張がその2件とも「認可が不明」として**黙って捨てています**
（記録0件・拒否0件）。故障はOSの配送でも登録でもなく、**拡張内の認可判定**です
（[監査記録](../Docs/RealDeviceScreenTimeAudit.md)の#10）。#10はその後このブランチで修正し、
**同日夕方に同じ端末で修正後のbuildを回して直っていることを確認しました**——12分の利用窓を4本回して
**閾値到達4件が4件とも記録**され（捨てた到達0件）、黒いgemは`0個ぶん／累計0分`→`3個ぶん／累計30分`、
Homeの合計は`11粒／3.20 kg`→`14粒／3.50 kg`になりました。監視エラーも重複取り込みの表示も出ていません。
1本目の窓だけ各レーンで+2になりますが、カウンタ上は到達1件・記録1件で、差分が2だったのは同じ区間に
修正前buildの取りこぼし（OSが測った20分ぶん）が残っていたためです。2本目の窓は両レーンとも+1でした。
端末の「アプリとWebサイトのアクティビティ」はOFFでしたが、閾値はそれでも届いたため**原因ではありません**。
端末ログは最後まで読めておらず、件数は計測の写しから読み出しました。
**チェック済みへ移せた項目は1つもありません**（下の各項目が束ねている未確認の条件が残るためです）。

- [ ] アプリ本体とDevice Activity Monitor拡張それぞれのFamily Controls **distribution**承認を確認。
  App Groupを含むApp ID・provisioning profileと、最終Archive／IPAの署名が一致することを検証
  - 実機確認済み: 開発署名のRelease buildで、本体と拡張の双方が`com.apple.developer.family-controls`と
    `group.com.hinoshiba.pomogem`を持ち、同一Teamで署名されていること。未確認: **distribution承認そのもの**、
    App ID・profileの内容、最終Archive／IPAとの署名一致。[監査記録](../Docs/RealDeviceScreenTimeAudit.md)
- [ ] 署名済みiPhoneでindividual authorizationの許可・拒否・取消・再許可と、監視エラーからの再試行を確認
  - 実機確認済み: 許可済み状態での表示整合（「アクセス許可済み」のとき「アクセスを許可」が出ない）。
    未確認: **許可プロンプト本体・拒否・拒否後の再試行・取消の表示・再許可**。既に許可済みのためプロンプトを
    再表示できず、iOS側のアクセス切り替えは1度しか動かず自前でONへ戻ったため、取消の確認は人手が必要です。
    2026-09-21に判明した点: 同じ時刻に**アプリ側は「アクセス許可済み」、監視拡張側は「不明」**を読んでおり、
    認可の見え方がプロセスごとに食い違います。この食い違いが10分到達の不合格の直接の原因でした（#10）。
    **食い違い自体は修正後も残っています**（修正後の4件の到達すべてで拡張は認可を読めていません）。
    変えたのは、拡張がその読み取りを付与の可否の判断に使わなくなったことだけです。
    [監査記録](../Docs/RealDeviceScreenTimeAudit.md)
- [ ] 勉強側の無料5つ・6つ目拒否、Pro購入／復元で無制限、Pro取消時の超過監視停止を確認。
  黒いgem側は無料6つ以上も利用でき、カテゴリ／Web選択と両側への同一アプリ登録を拒否
  - 実機確認済み: **勉強側6つ目の拒否**、**カテゴリ／Web選択の拒否**、**両側への同一アプリ登録の拒否**
    （いずれも「反映」が無効化され、所定の文言が出る）。未確認: 5つ以下へ戻したときの再有効化、
    Pro購入／復元後の無制限、Pro取消時の超過監視停止、黒いgem側の無料6つ以上。
    [監査記録](../Docs/RealDeviceScreenTimeAudit.md)
- [ ] 各側で複数アプリにまたがる合計10分・20分の実到達を確認し、復帰時に差分だけが瓶へ落ちる。
  タイマー中は学習側を休止し、黒いgem側は記録を継続。端数・日付・時刻変更・再起動も確認
  - 実機で**いったん不合格、原因を特定し修正、修正後のbuildで10分到達の付与は合格**: 保存済み・自動記録中・監視エラーなしの状態で、
    勉強側（2アプリ合計12分）は閾値超過から64分待っても1粒も増えず、黒いgem側（12分）も26分待って
    0個ぶんのままでした。2026-09-21深夜の再試験（両側とも12分）でも同じで、勉強側15回・黒いgem側20回の
    読み取りがすべて同値です。今回は計測が理由を示しました——**iOSは両方の利用窓で閾値到達を配送しており**
    （到達0→1→2、時刻はいずれも利用窓の中）、監視拡張が2件とも「認可が不明」として捨て、
    記録0件・拒否0件でした。レーン用の区間開始も16件あるので、登録は成立しています。
    したがって原因は端末・OS側の条件ではなく**この製品側の欠陥**です
    （[監査記録](../Docs/RealDeviceScreenTimeAudit.md)の#10）。
    端末の「アプリとWebサイトのアクティビティ」はOFFでしたが、閾値はそれでも届いたので原因ではありません
    （ONにするのはiOS設定の変更で、利用者本人以外は行えません）。
    **#10の修正はこのブランチに入り、同日夕方に同じ端末で確認しました**: 12分の利用窓を4本
    （黒いgem側・勉強側を交互に2巡）回したところ、閾値到達**4件が4件とも記録**され（捨てた到達0件、
    拒否・台帳が拒んだ・名前が合わないもすべて0件）、黒いgemは`0個ぶん／累計0分`→`3個ぶん／累計30分`、
    Homeの合計は`11粒／3.20 kg`→`14粒／3.50 kg`になりました。閾値到達からUIへの反映は212〜439秒、
    前面復帰からは71〜87秒です。1本目の窓は各レーンで+2でしたが、カウンタ上は到達1件・記録1件で、
    差分が2だったのは同じ区間に修正前buildの取りこぼし（OSが測った20分ぶん）が残っていたためです。
    2本目の窓は両レーンとも**きっちり+1**で、付与後5分間の二重加算もありません。
    **それでもこの項目は閉じません。** 項目が束ねている**20分の一括到達・端数・日付またぎ・
    時刻／タイムゾーン変更・端末再起動・タイマー中の休止表示**がいずれも未確認だからです。
  - 実機確認済み: **タイマー終了後に学習側が「自動記録中」へ再登録されること**（監視エラーなし）。
    未確認: 20分到達、差分だけの落下、端数、**タイマー中の休止表示**（集中画面から設定画面へ戻る導線がなく
    自動操作では観測できません）、**日付またぎ**（端末ログが取れず、0時の再登録が起きたかどうかも
    観測できていません）、時刻・タイムゾーン変更、**端末の再起動**（確認できたのは
    アプリのプロセス再起動2回だけ）。[監査記録](../Docs/RealDeviceScreenTimeAudit.md)
- [ ] 通知重複・順序逆転・保存失敗・途中終了・再試行で二重加算せず、保存先／アカウント／resetの
  境界で古い台帳や遅延通知を新しい領域へ取り込まないことを実機で確認
  - 実機確認済み: 保存の二重押しで保存が**1回だけ**走ること、プロセス再起動2回で取り込みが重複せず
    合計も変わらないこと、アプリ内resetが**スクリーンタイムの状態だけ**を消し保存済みの勉強記録を残すこと。
    #10の修正後に追加で確認できたこと: 付与のあと5分間読み続けても値が動かないこと（2本の窓）。
    未確認: **到達通知の重複・順序逆転・保存失敗・途中終了からの再試行**（意図的に重複・逆転させた確認は
    行っていません）、保存先／アカウント切り替え境界。
    [監査記録](../Docs/RealDeviceScreenTimeAudit.md)
- [ ] 保存直後に`screen-time.updating`の「反映中」行が出ること、その間も戻る操作ができ、保存の
  二重実行が防がれることを実機で確認し、登録完了までの実測時間を記録。Simulatorでは許可が下りず
  登録処理が走らないため、この項目はunit test／UI testでは代替できない
  - 実機確認済み: 保存直後も**戻る操作ができる**こと、登録内容が変わる保存では「保存」が即座に無効化される
    こと、**二重押しでも保存は1回だけ**走ること（45秒の観測窓で保存完了の表示は1回）、保存後に
    「自動記録中」へ落ち着き監視エラーが出ないこと、「反映中」行が保存の**3.089秒後**に出た回があること。
    未確認: **登録完了までの実測時間**。「反映中」行が消えるまでの時間は一度も測れておらず、
    出現も1回しか観測できていません。2026-09-21の再試験では6秒読み続けても行を捕まえられず
    （この端末では登録が読み取り周期より速く終わります）、該当の試験は測れなかった値を根拠にしないため
    意図的に`XCTSkip`で終わっています。実測には端末ログが要り、その経路は依然ありません。
    [監査記録](../Docs/RealDeviceScreenTimeAudit.md)
- [ ] 黒いgemは黒同士だけで結合し、学習時間・勉強質量・レア抽選・共有画像／内訳へ混ざらないことを確認
  - 実機確認済み（部分）: #10の修正後、黒いgemが実際に3個ぶん（累計30分）付き、**その窓のあいだHomeの
    勉強側（粒・勉強質量）は動きませんでした**。未確認: **黒同士の結合**、レア抽選、共有画像・内訳からの除外。
    黒いgemを結合が起きる個数まで貯めていません。[監査記録](../Docs/RealDeviceScreenTimeAudit.md)
- [ ] VoiceOver・最大文字サイズ・視差効果を減らす設定で、アプリ選択・テーマ・保存・停止と瓶の識別を確認
  - 未確認: 端末のアクセシビリティ設定は今回の監査の対象外とし、変更していません。
    [監査記録](../Docs/RealDeviceScreenTimeAudit.md)
- [ ] 起動画面でオフライン継続の受領書が取り消された場合に、利用者へ非破壊の出口を残すことを実機で確認
  - 実機で**不合格を再現し、修正を別ブランチで実機確認済み。この候補のブランチには未取り込み**:
    受領書がアカウント変化で取り消されると「端末のデータでオフライン利用」が描画されなくなり、
    成功しない「もう一度試す」とデータを捨てる「iCloudから再取得」しか残りませんでした
    （後者はアプリが提示すらしませんでした）。調査の結果この取消は**誤検知**で、識別に使う値は
    取消の前後でバイト単位に同一でした。修正（照合が別アカウントだと示したときだけ永続的に取り消す／
    照合が済むまではそのプロセスの中でオフラインの経路を断る）を入れたbuildでは、2026-09-21に
    起動画面が再び「端末のデータでオフライン利用」を描画し、約1秒でHomeへ到達しています。
    **未確認**: アプリを起動していない間にアカウントが変わる場合（通知が届かないため、この保留は働きません）。
    この項目を閉じるには修正の取り込みが必要です。[監査記録](../Docs/RealDeviceScreenTimeAudit.md)の#9
- [ ] Pro掲載文・新しい審査画像・Privacy・Review Notesを最終候補へ合わせ、必要な公開先へ転記後に再確認。
  端末内だけの選択／黒いgemと、通常の保存先へ入る勉強記録を区別して説明

## 2026-09-12 の1.0.1 (7) 審査提出

build 6は実機監査でreset履歴の問題を再現したため審査取消操作を行い、version itemはReady for Reviewへ
戻りました。以下はbuild 7だけの記録です。利用者の並列提出指示に従い、build 7を2026-09-12
16:26 JSTに提出し、「審査待ち」を確認しました。SettingsのiCloud切り替えは開発・検証中で、
このbuildには含みません。次の機能版のbuild番号は未確定です。
後続の2026-09-06欄と過去のチェック済み項目は、
build 7の合格・upload・提出の証拠には使いません。現行状態は
[release-record-1.0.1-7.md](release-record-1.0.1-7.md)、実機監査の範囲と残件は
[RealDeviceICloudAudit.md](../Docs/RealDeviceICloudAudit.md)に記録します。

- [x] build 6の「デベロッパにより却下済み」を確認してからbuild 7を選択
- [x] Archive元`e4aee83b5e70aa9ae078ff37ad90626bb8becc97`のbuild 7で生成project・Release Archiveを検証し、
  別途exportしたIPAと実際のupload-staging IPAの双方でstrict distribution検証に合格。app／Widgetの実行fileとdSYMのUUIDも一致
- [x] ローカルのDebug全815件（811成功・明示opt-in 4skip・失敗0）、current-file readiness、Release静的解析を確認
- [ ] Archive元のGitHub CIを実行完了。run `34668002596`は支払い／Actions上限によりrunner起動前に失敗し、未実行
- [x] Apple Development署名のRelease実機でiCloud保存領域の再起動、履歴反映前の記録保護、
  cloud reset一時停止、local-only reset継続、実通信断からの非破壊復旧を確認。App Store配布版の実機試験とは区別
- [x] Apple Validate（2026-09-12 11:43 JST）とOrganizerのbuild 7 uploadを確認（記録時刻11:56 JST、完了表示確認11:57 JST）
- [x] upload後に`v1.0.1-build7`を作成・pushし、上記Archive元のcommitを指すことを確認
- [x] 改訂したja-JP／en-US更新内容とReview NotesをConnectへ保存・再読込して正本との一致を確認
- [ ] 公開Privacy文面を一致させる。Pages run `34669415266` attempt 2も支払い／上限によりrunner起動前に失敗
- [ ] 既存screenshotを署名済みReleaseと比較し、差がある画像だけを更新。旧captureのversion・hashを新規撮影扱いにしない
- [x] 処理済みbuild 7を選択し、1.0.1 (7)の1項目を審査へ提出。提出ID `7f746a75-2605-47c5-83d5-48ee76b40b2c`、2026-09-12 16:26 JSTに審査待ち
- [ ] Appleの承認と公開を確認。既存の承認後自動公開設定は維持

`AppStore/configuration.yml`の既知blockerは、実行または判断の証拠なしに解除しません。
今回の1台の試験を、2台同期・account切替・StoreKit・accessibility全項目の合格とは扱いません。
上記提出の完了は、開発中の保存先切り替え機能の合格・追加schema公開・提出を意味しません。
後続の記録更新／merge commitはArchive元とは別に扱い、source tagは上記の固定commitを指します。

## 2026-09-06 の再登録・提出作業

新IDの署名・アップロード・CloudKit schema・IAPについて確認済みの結果は
[release-record-1.0-5.md](release-record-1.0-5.md)を参照します。
iCloudの端末間同期と関連するアカウント境界の実機再検証は、ユーザーの明示指定で今回は省略。
以下の未チェック項目を合格とみなすことはありません。OSS公開、追加実機QA、運用確認の項目も含まれ、
リポジトリは引き続き非公開、改名はユーザーが後で行います。
HTTPS証明書の是正もユーザーが担当し、その完了を待たず提出する明示指示に従い、同日19:07 JSTに審査送信しました。

## 検証項目と未実施の追加確認

- [x] 2026-09-06改訂のja-JP／en-US掲載文・subtitle・promotional text・keywordsとHomeのテーマ／時間選択導線を
  最終候補へ照合し、App Store Connectへ保存後に再読み込みで一致を確認。過去の転記済みcheckは今回改訂の保存を意味しない
- [x] Homeのテーマ／時間選択が写る最終候補で正式screenshotを再撮影し、5枚・hash・画面内versionを更新。
  旧候補の画像と開発中のArtifacts画像を今回の提出証拠として扱わない
- [ ] `release-experience-review.md`の共通タスクを署名済み実機でVoiceOver／200%以上の文字サイズ／
  視差効果を減らす／色以外の識別／コントラストの観点から実行。Accessibility Nutrition Labelsは
  検証を完了した対応項目だけを申告し、自動UI auditだけを対応根拠にしない
- [x] 新App Store Connect app record（Apple ID `6809139517`、SKU `pomogem-ios`、`com.hinoshiba.pomogem`、日本語名「ポモジェム：ポモドーロタイマー」）の作成を確認（2026-09-06）。同日19:07 JSTに1.0 (5)＋初回IAPを提出、審査待ち・未公開
- [x] Free／Paid Apps Agreement、tax、bankingがactiveであることを確認（2026-09-03）
- [x] App Store Connect上のDSA statusがnon-trader表示であることを確認（2026-09-04）
- [ ] 単一の製品ページがHTTPS 200で表示され、日本語・Englishの切り替えとPrivacy、Support、Terms、販売セクションの各アンカーが動く。Pro案内とアプリの購入前リンクから販売セクションへ到達できる
- [x] `pomogem.hinoshiba.com`のCNAMEが`hinoshiba.github.io`へ向くことを確認（2026-09-06）
- [ ] GitHub Pagesのcustom domain所有確認と「Enforce HTTPS」を有効化し、新domainの実配信を検証
- [ ] 公開SupportメールアドレスとGitHub profileの掲載をmaintainerが明示承認
- [x] 新規`iCloud.com.hinoshiba.pomogem`のdevelopment schemaを、最終RCから
  replica identity／Subject tombstone／Achievement deletion revision・token・restore ack／
  `timerDisplayModeRawValue`と13組・26 fieldのPrefs stampを含む7種類の同期元modelでinitialize・検証して、
  同一schemaをproductionへdeployする。production environmentはclearしない
- [x] 初回に「iCloudで同期」と「このiPhoneのみ」を同格で提示し、どちらも推奨扱いにせず、確認後に
  一方を確定するVersion 1.0仕様へ実装／listing／Privacy／Review Notesを統一。iCloudの選択説明から
  Privacy Policyを開ける
- [x] 「このiPhoneのみ」はApple Account／networkなしで全基本機能を利用でき、専用random namespaceの
  local storeだけへ保存し、iCloudへ自動切替／uploadしない。Version 1.0の選択は変更不可で、app削除・
  再installはlocal dataを消去し、JSONは再import／iCloud移行／機種変更時の継続に使えないことを明記
- [x] cloud modeで`ModelContainer`作成前にApple Accountをfail closedで解決し、cloud cache／local
  projection／focus state／maintenance checkpointをrandom namespaceへ分離する実装と
  pure unit testを追加
- [ ] 不変profileの欠落・破損、存在する旧registryの破損またはprofileとの不整合、source／projectionの片側だけ、sidecarだけ、複数namespace、symlink、
  matching unknown artifactがあるclean-installでない状態はfresh choiceへ戻さずrecovery gateになり、
  既存artifactを削除／上書きしないことをRelease candidateで確認。選択profile
  確定済みでstore fileが0件の一度限りのcommit／mount crash境界だけは正しく再開する。旧registryが
  存在しないこと自体は正常とし、Version 1.0はregistryを新規作成・更新・保存しない
- [x] account-neutral Widgetが利用者dataを共有しないため、host／Widget双方からApp Group entitlement、
  production suite defaults／container access、privacy reason `1C8F.1`を除去
- [ ] 署名済みclean install実機で、二つの初回選択が同格で各確認後だけ確定し、local-onlyは
  Apple Account／networkなしで全基本機能が動き、再起動後もlocal-onlyのままで自動uploadしないことを確認
- [ ] 署名済み実機でiCloud選択時のprivate database全zone read-only fetch、各launch／resume、A→B block→A復帰、background中account切替、
  通信断を試す。別account／通信不可では保存領域を開かずdataを削除しないこと、Aへ戻ると元のnamespaceを
  開くことを確認。Widgetは常にaccount-neutral、Live Activityは時間／状態以外を表示せず、旧timerの
  共通通知が一度届き得ることも記録する
- [ ] 署名済み実機でLive Activityの開始、pause、resume、期限到達、cancel、完了後のdismiss、手動dismiss後に
  勝手に再生成しないこと、SettingsでOFFにすると即終了し再起動後もOFFであることを確認。theme名、memo、
  質量、Apple Account／CloudKit情報がロック画面へ出ないことをA→B block中も確認
- [ ] 署名済み実機で「タイマー中は画面をロックしない」をONにし、集中、集中直後の短い／長い休憩、
  Homeからの単独休憩が前面かつ残時間ありの間だけ点灯を維持することを確認。pause、期限到達、
  skip／close、backgroundでは即座に通常の自動ロックへ戻り、設定OFFでは全timerで抑止しない
- [x] Apple Account切替時の混線リスクが残るrare reward台帳、pending outbox、operations containerを1.0のRelease経路・shipping schema・entitlementから無効化
- [x] bounded／checkpointed maintenance workerを実装し、page境界duplicate、世代変更、local projection失敗後の再開をunit testで検証
- [x] Achievementの削除event `(deletionRevision, deletionMutationID)`を通常編集／in-place restore後も保持し、
  explicit Undoだけが観測tokenを`restoredDeletionMutationID`でackする。legacy `deletedAt` rowは
  `(row.revision, deletionMutationID ?? syncRecordID)`へ合成し、未観測の後着削除を復活させない
- [x] reset winnerをLamport sequence 0...1,000,000で決め、`resetAt`をmetadataだけにし、範囲外sequenceと
  counter上限をfail closedで扱う実装／test sourceを追加
- [x] 620 session／empty local projection fixtureで、Homeの512件windowより古い履歴を有界sliceで
  level-1 leaf化し10進rollupする再構築test sourceを追加
- [ ] `projectionValidationVersion`未達のaggregateが一つでもある間は全rootを会計から除外し、leafの
  全memberの固定長digestをdurable cursorで収集し、昇格sliceでmember 0からexact再読した後だけ昇格する。
  最終一巡が1,024-row budgetへ入らない異常密度はv0のまま抑止する。late winner、2×256 dense member、
  count→fetch間変更、kill／checkpoint replay、ancestor全field再導出の回帰testを最新RCで合格する
- [ ] cloud modeは起動直後を未検証とし、source／reset save、remote-store change、初回60秒、真正な
  foreground復帰、active継続15分ごとにsessions verificationを要求する。pending中は生涯正確値、`+`、
  `以上`を表示せず「再集計中」「この端末で確認済み」とするfocused testを合格する
- [x] 同一focus sessionのterminal／active／claim duplicateを全物理row保持のままread-onlyで論理解決し、
  異なるsession UUIDを破壊的にcancelしない実装を追加。materialized `StudySession`で閉じたことをexact確認した
  active tailだけを別cleanupとして削除可能
- [x] hostile／破損timer payloadをsnapshot前に検証し、remaining／cycle countを飽和。invalid cloud rowは
  非破壊fail closed、invalid local recovery bytesは削除する回帰testを追加
- [x] clock変更／reboot／cross-device adoptionを`timerDemoted`へfail closedにし、break recoveryの
  minutes／Date／整数変換を有界化するunit testを追加
- [ ] invalid active logical sessionが先頭から257件以上ある場合、interactive recoveryは256件で
  fail closedする既知上限をownerが受け入れる。解消する場合はraw payloadを保持する可逆quarantineを
  versioned CloudKit schemaとして設計・実機検証する
- [ ] `timerDisplayMode`追加後候補でaccount境界、Lamport reset、620件projection rebuild、256件超focusの
  read-only resolution、partial delivery、foreign row不変、duplicate maintenanceのsource write／delete 0を含む
  全unit testを再実行。2026-09-05にXCTest 598件中597件成功、明示opt-inの40年soak 1件skip、
  Swift Testing 25件成功、失敗0件。Release Simulatorのbuild／Analyzeもerror／warning／analyzer warning 0件。
  残る最終ゲートとして、一意なbuild番号のRelease Archiveで同じ3種類のissueが0件であることを確認する
- [x] 最新Release candidateで、onboardingの任意のためし粒を「次へ」で省略し、勉強／仕事を分けない
  共通候補から最初のテーマ1件だけで完了できることを確認。Settingsも一つのテーマ一覧だけを表示し、
  Home開始buttonはtapで集中開始し、種類と時間はHomeの専用選択欄で変更する。既存の履歴と互換性用`usagePurpose`値は保持する。
  2026-09-05のfocused unit 9件とUI 4件で失敗0件
- [ ] `timerDisplayMode`の4つのraw value、既定値と未知値の`ringAndTime`へのfallback、別groupとのoffline同時変更、
  同一groupの競合解決、JSON raw export、2台間同期を最終development schemaと署名済み実機で確認する
- [ ] partition中は、commit前に見えたscheduled-end前cancelを尊重する一方、先にmaterializeした
  `StudySession`は遅延cancelで削除／demoteしないCAP trade-offをownerが承認し、署名済み2台で両順序を確認
- [ ] direct CloudKit一括削除の無効化を維持し、現在の候補ではiCloud通常resetも変更前に拒否して理由を表示する。
  local-only通常resetは維持し、物理削除との違いを審査メモ・Privacy・画面で一致させる
- [ ] 既存CloudKit補助directoryを消さずに起動できることと、不正な保存履歴の拒否を確認する。
  cloud履歴preflightはRoot公開前に必要な世代の反映を待ち、期限切れ・取消・不完全応答では新規記録を作らない
- [ ] 署名済み実機2台でmaintenance、foreground復帰、15分以上のactive継続中に相手端末から追加・更新した
  古い日時のsession、remote import通知、再集計中表示、timer引き継ぎと同期を検証し、Release buildに
  rare reward UI／operations entitlement／direct CloudKit一括削除UI／削除用launch preflight gateがないことを確認
- [x] `com.hinoshiba.pomogem`と`com.hinoshiba.pomogem.widgets`、
  `iCloud.com.hinoshiba.pomogem`を新規登録し、containerのhostへの割当を確認（2026-09-06）
- [x] 配布前にhostのiCloud／CloudKit、Push Notifications、IAPとWidgetの追加capabilityなしを照合し、
  新しい配布copyで両targetの明示bundle ID、Apple Distribution profile、`get-task-allow = false`、
  hostのCloudKit Production／APNs Productionを実物で確認する
- [x] 新Non-Consumable `com.hinoshiba.pomogem.pro.lifetime`を作成し、米国USD 0.99を基準価格、日本をJPY 100のcustom price、その他の配信地域をAppleの現地相当額に設定
- [ ] 日本向け有料IAPについて販売主体と特商法上の表示要否を確認し、必要な事業者情報・価格・支払／提供時期・返品等を購入前に表示。氏名／住所／電話／Webで省略する販売価格は、請求時に購入判断前の十分な余裕をもって遅滞なく提供できる実運用を確認（現行の既知blocker）
- [ ] `Docs/COMMERCIAL_DISCLOSURE_OPERATIONS.md`に従い、非公開の法定情報正本、販売価格を含む開示請求メール、担当者不在時の代替手順を実地確認
- [ ] 新IAPのja-JP（`ポモジェムPro`）／en-US（`PomoGem Pro`）を「任意時間・月刻印・勉強アプリ数無制限」の
  2機能で登録し、新product IDのreview notes・価格・配信地域・Family Sharingを保存後に再確認する。
  同じ新アプリのversion 1.0と初回IAPを同一のreview submissionへ追加する
- [x] IAP review screenshotを「任意時間・月刻印」の2機能とStoreKitの実価格だけを示す現行paywallへ差し替え、reload確認
- [x] App本体をFree、Public、148／175 Countries or Regionsへ設定。現行EU 27を除外し、United Kingdom、Norway、Switzerlandは含め、今後追加されるstorefrontの自動追加を有効化
- [x] IAPをApp本体と同じ148／175 Countries or Regionsへ設定。現行EU 27を除外し、United Kingdom、Norway、Switzerlandは含め、今後追加されるstorefrontの自動追加を有効化
- [x] App本体とIAPのEU 27での提供を外し、Version 1.0のEU DSA release blockerを配信範囲で解消。これはtrader該当性についての法律判断ではなく、将来EU提供を有効にする場合はAccount Holderが再評価
- [x] `ja-JP`と`en-US`のlistingを入力し、英語listingでApp UI／supportが日本語であることを明示
- [x] 新version 1.0のja-JP／en-US descriptionとApp Review notesを正本どおり保存し、reload後の完全一致を確認
- [x] App Review contactのfirst name、last name、国際形式電話番号、emailをApp Store Connectだけに入力し、保存後にreloadして確認
- [ ] Sandboxでpurchase、pending、cancel、restore、revocationを確認
- [ ] App Privacy draftをproduction archive、private CloudKit access権限、support mailの実運用と照合。
  運営者がiCloud dataを取得・閲覧・保持せずoptional disclosure条件も満たす場合だけData Not Collectedを
  Publishし、満たさなければEmail Address等を実態どおり申告
- [ ] privacy manifestでhostのFile Timestamp `C617.1`、System Boot Time `35F9.1`、standard defaults
  `CA92.1`と、Widgetのrequired-reason API宣言が空であることをRelease archiveに照合
- [ ] `AppStore/age-rating.md`の全descriptorを新レコードの2026年版age rating質問へ入力し、生成結果4+を保存後にreloadして確認
- [ ] Export complianceを現行質問で確認
- [x] 新1.0 (5)のiPhone screenshot 5枚をproduction UIのDebug-only fixtureから撮影し、
  実行結果と1284×2778 RGB／alphaなし、個人情報・placeholder・誤訴求なしを
  `screenshots/README.md`に記録する。新IAPのlive-price画像は別gateとして確認する
- [ ] 上記5枚を署名済みRelease実機と比較し、visual parityがない画像は再capture
- [x] metadataのname、subtitle、description、keywords、URLs、review notesを入力
- [ ] Accessibility Nutrition Labelsを実機評価に基づき回答
- [x] Apple silicon MacとVision ProでのiOS app提供を無効化
- [x] Apple School Manager reduced priceをenabledとして保存
- [ ] OSS公開方式をownerが選択: source／通常文書MIT、font OFL、名称／logo／icon／生成背景／Store・Web
  画像rights-reservedのmixed-licenseとして公開するか、除外assetを再license／置換して全体OSS化する
- [ ] 選択したlicense境界を`LICENSE`、`ASSET_LICENSES.md`、`TRADEMARKS.md`、README、release tagで一致させ、
  rights／商標／AI reference inputのowner sign-offを記録
- [ ] Public化前に全Git historyのsecret／個人情報／署名資材を再監査し、Public化後に匿名access、branch
  protection、required checks、secret scanning、private vulnerability reportingを確認。2026-09-06に
  owner指定の公開メールへ全履歴を統一。履歴・公開メールの検証記録は`Docs/OSS_PUBLISHING.md`を参照
- [ ] `./Scripts/check-oss-readiness.sh --release`、site validation、build、test、analyzeが成功
- [ ] 全11出荷対象モデルのversioned JSON exportを40年相当の保存データで実行し、件数・内容・Files保存・一時ファイル削除を確認
- [ ] local-only実機でofflineの基本機能、削除前のJSON書き出しと再import不可を確認し、iCloud実機2台で
  online account確認、リセット履歴反映後の記録作成、同期、timer引き継ぎ、通常resetの利用不可、
  通信断時fail-closedと非破壊性を確認。local-only通常resetの継続も確認する
- 過去の別アプリ1.0 (1)／1.0 (3)のアップロード・実機installは、今回の新アプリの証拠にはしない。
  日時と旧IDを含む履歴は`Docs/LEGACY_RELEASE_PROVENANCE.md`を参照。
- [x] `timerDisplayMode`を含む最終候補を一意なbuild番号でArchive／Distributeし、distribution署名／
  production CloudKit・APNsを再検証して、App Store Connectでそのbuildを提出対象へ選択
- [ ] 変更後の最終候補をDistribute後、internal TestFlightまたは同一署名候補相当の実機QAを完了
- [x] 初回IAPとapp versionを同じsubmissionへ追加し、2026-09-06 19:07 JSTに提出。双方の審査待ちを確認
- [ ] version/build/commit/tag/CloudKit deploy日時をrelease記録へ保存

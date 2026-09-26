# ポモジェム — 持続的学習と報酬設計

設計初版: 2026-09-01
名称・識別子更新: 2026-09-06

過去の日付の実測・test件数は前身アプリの実施履歴であり、PomoGem 1.0 (5)の合格結果ではありません。
新候補の検証と外部サービス登録は`AppStore/configuration.yml`のrelease gateで追跡します。

> Release status（2026-09-03）: Version 1.0は`RareRewardReleasePolicy.isEnabled == false`です。
> Apple Account切替時の台帳分離と実機2台検証が未完了のため、以下のrare reward設計は将来候補・
> 回帰test用sourceとしてのみ保持し、1.0のUI、完走処理、shipping schema、CloudKit entitlementには
> 含めません。1.0の完走はテーマ色の通常粒を決定論的に保存します。将来有効化する場合も、
> `StudySession`のCloudKit duplicate全copyへのreceipt fan-outは禁止します。有効化前に端末-owned
> writer identityを設計し、その単一rowへのmutationとread-time logical resolverを実機の
> partial-delivery試験で再検証します。

## 1. 目標

ポモジェムが最適化するのは、アプリを何度も開かせることではなく、利用者が自分で選んだ学習や仕事へ戻りやすくなることです。

成功の定義は次の順です。

1. 完走した集中時間が増える
2. 中断後にも責められず再開できる
3. 自分の成長を正確に理解できる
4. 睡眠、不安、課金、通知への悪影響を増やさない
5. その結果として継続率と推薦意向が上がる

病理的な依存、無限スクロール、損失恐怖、near-miss、課金抽選、ランキング圧力は成功指標にしません。

倫理方針の中心は依存形成ではなく、本人が設定や行動を選べる自律性、事実に基づく積み上げから得る能力感、完走後に休める余白、学習や仕事へ長期的に戻れることです。短期的な起動回数や滞在時間が増えても、この四点を損なう設計は採用しません。

### 1.1 スクリーンタイムの任意記録（2026-09-13候補）

本人が選んだ勉強アプリの合計利用時間を10分単位で粒（勉強アプリの粒）にします。無料は個別アプリ5つまで、
Proは無制限です。本人が別に選んだ控えたいアプリは無料でも無制限で、合計10分ごとに黒い石を
瓶へ追加します。黒い石は黒同士だけで結合する障害物で、既存の学習時間や粒を減らさず、
学習集計・レア抽選・共有画像へ含めません。二つの選択集合は重複不可、カテゴリ／Web指定も不可です。

設定と許可は任意で、停止にProは不要です。細かい利用履歴を復元したり、本人の意志や能力を推測したり
しません。10分未満の端数、OS通知の遅延、タイマー中の学習側休止、端末内の選択・黒い石の保存を説明します。
黒い石は、アプリの選択や記録を残したまま本人がいつでも片付けられます（増える一方にせず、区切り直しを
本人が選べるようにするため）。取り込んだ粒と黒い石はHomeで一度だけ「スクリーンタイム：…」と中立に
知らせ、黒い石には音・報酬演出・評価の言葉を付けません。
Apple配布権限と署名済み実機の確認は実装とは別の出荷条件です。[仕様・検証範囲](ScreenTimeGems.md)を正本とします。

## 2. エビデンスから設計への変換

| 研究知見 | ポモジェムでの判断 |
|---|---|
| 自己決定理論では、自律性・有能感・関係性を満たす動機づけが持続に重要 | テーマ、時間、通知、共有は本人が選ぶ。勉強／仕事の用途選択で入口を分けず、完走後は能力の証拠を返し、自動で次のタイマーを始めない |
| 習慣は同じ文脈での反復から形成され、形成速度の個人差は大きい。一度の欠落が習慣形成を壊すとは限らない | 連続日数ではなく「今週戻ってきた回数」を表示。一日休んでも何も失わない。将来の再訪cueは本人が選ぶ `if-then` 形式にする |
| 進捗の可視化は次の行動を促し得るが、時間の可視化だけで理解度や技能向上を証明することはできない | 一回の完走で粒と決定論的な10-slotを必ず進め、長期の瓶にも同じ記録を残す。成果の星は時間とは分ける |
| 不確実なインセンティブは条件によって反復を増やし得るが、学習成果や健康を長期的に改善する根拠にはならない | レア粒は視覚のみ、価値ゼロ、再抽選なし、確率開示、Proで確率不変。通常粒と決定論的進捗を全完走に保証し、ランダムを継続の主エンジンにしない |
| intactなstreakは行動を増やす場合がある一方、壊れたstreakの強調は達成感と再開を損ね得る | 公開する連続日数、失効、穴埋め課金を作らず、週内の回数と消えない生涯記録を併置する |
| 失敗後の自己慈悲は、少なくとも実験条件では次の改善行動を支える場合がある | 空白期間を失敗画面にせず、過去の瓶を先に見せ、「記録はそのまま」から一回の再開へ導く |
| バッジ、順位、競争、ポイントは条件次第で動機や成績を悪化させる | 公開ランキング、強制比較、streak救済課金を入れない。共有は自分の瓶と質量の表現に限定 |
| 選んだ相手への目標共有は支援を得やすくする可能性があるが、広いSNS公開やGIF共有そのものが学習を改善するとは限らない | 共有は任意・編集可能・自動投稿なしとし、共有回数を学習成果の代理にしない |
| 通知は注意を中断し、頻度や制御不能感がストレスになり得る | 通知は既定オフ、時刻を本人が選び、テーマ名は端末外の通知へ出さない。毎日のリマインダーは、その日に集中を始めたか時間を手動で積んだ日は鳴らさず（スクリーンタイムの粒や、前日の集中を翌朝に保存したことでは止めない）、最後にアプリを開いてから7日で休む（開けば静かに再開）。先月の瓶のお知らせは前の月に記録がなければ送らない。時刻は現地時刻に従う。端末の通知許可で同期設定を書き換えない |

主要資料:

- [Self-Determination Theory](https://selfdeterminationtheory.org/the-theory/)
- [Ryan & Deci: intrinsic and extrinsic motivation](https://selfdeterminationtheory.org/wp-content/uploads/2020/06/2020_RyanDeci_IntrinsicandExtrinsic.pdf)
- [Deci, Koestner & Ryan: expected tangible rewards and intrinsic motivation](https://doi.org/10.1037/0033-2909.125.6.627)
- [Vansteenkiste et al.: autonomy-supportive learning, performance and persistence](https://pubmed.ncbi.nlm.nih.gov/15301630/)
- [Sailer & Homner: gamification of learning meta-analysis](https://doi.org/10.1007/s10648-019-09498-w)
- [Mekler et al.: points, levels and leaderboards do not by themselves improve intrinsic motivation](https://doi.org/10.1016/j.chb.2015.08.048)
- [Gamification and intrinsic motivation meta-analysis](https://link.springer.com/article/10.1007/s11423-023-10337-7)
- [Lally et al.: habit formation in the real world](https://onlinelibrary.wiley.com/doi/abs/10.1002/ejsp.674)
- [Planning promotes studying: a 42-day micro-randomized trial](https://www.sciencedirect.com/science/article/pii/S0361476X25000876)
- [Broken streaks and goal re-engagement](https://academic.oup.com/jcr/article/49/6/1095/6623414)
- [Streaks to Success?: randomized messages to 60,000 students](https://www.nber.org/papers/w34173)
- [Reward uncertainty can intensify pursuit](https://academic.oup.com/jcr/article-pdf/41/5/1301/9976234/41-5-1301.pdf)
- [Uncertain incentives can reinforce repetition](https://academic.oup.com/jcr/article-abstract/46/1/69/5050467)
- [Self-compassion after failure and self-improvement motivation](https://pubmed.ncbi.nlm.nih.gov/22645164/)
- [Progress monitoring and goal attainment meta-analysis](https://www.apa.org/pubs/journals/releases/bul-bul0000025.pdf)
- [Endowed Progress Effect](https://msbfile03.usc.edu/digitalmeasures/jnunes/intellcont/endowed%20progress%20effect-1.pdf)
- [Loot box systematic review](https://pmc.ncbi.nlm.nih.gov/articles/PMC8264989/)
- [WHO: gaming disorder](https://www.who.int/standards/classifications/frequently-asked-questions/gaming-disorder)
- [Negative effects of gamification in education](https://www.sciencedirect.com/science/article/pii/S0950584922002518)
- [Social support versus competition RCT](https://pmc.ncbi.nlm.nih.gov/articles/PMC5008041/)
- [Goals Out Loud: goal disclosure, support and goal pursuit](https://doi.org/10.1177/01461672251382271)
- [Gollwitzer et al.: public intention can reduce subsequent action](https://doi.org/10.1111/j.1467-9280.2009.02336.x)
- [Notification stress intervention](https://pmc.ncbi.nlm.nih.gov/articles/PMC5207732/)
- [Stothart et al.: notification receipt disrupts attention](https://doi.org/10.1037/xhp0000100)
- [Fitz et al.: predictable notification batching field experiment](https://doi.org/10.1016/j.chb.2019.07.016)
- [OECD: dark commercial patterns](https://www.oecd.org/en/publications/dark-commercial-patterns_44f5e846-en.html)
- [UNICEF RITEC design toolbox](https://www.unicef.org/childrightsandbusiness/workstreams/responsible-technology/online-gaming/ritec-design-toolbox)
- [Apple HIG: Motion](https://developer.apple.com/design/human-interface-guidelines/motion)
- [Apple HIG: Playing haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics)
- [Apple HIG: Managing notifications](https://developer.apple.com/design/human-interface-guidelines/managing-notifications)
- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

## 3. 報酬アーキテクチャ

### 3.1 完走直後

順序を固定します。

1. 音・触覚で終了を伝える
2. 完走した一粒を落とす
3. `25分 / 250g` など事実を表示する
4. 「時間の核」を実測質量ぶんだけ連続的に進める
5. 「今週の結晶」の一面と、物理整理を示す10-slotを補助的に一つ進める
6. 休憩を提案する
7. 共有は遅れて任意に表示する

1の終了の知らせは、本人がその場にいるかどうかで変えます。アプリを開いている間にタイマーが
終わったときだけ、目覚まし時計のように本人が止めるまで音と触覚を繰り返します。画面をつけたまま
席を外している可能性があるためです。ロック中や別アプリの利用中に終わった場合、通知が届いていれば
アプリへ戻っても鳴らさず、通知が届いていなくても終了直後（60秒以内）の復帰で一度だけ鳴らし、
それより後は鳴らしません。アプリを前面へ戻すのは本人だけなので、戻った時点で本人は画面を見ています。
繰り返し中に画面ロックや別アプリへ移ったときは、離れた時点で止める操作と同じ扱いにし、戻っても
（iCloudの保存領域を開き直した後も）鳴らしません。アプリを開いたままApple Accountの確認などで画面が
作り直されたときだけは、席を外している可能性があるため、止めるボタンとともに繰り返しを再開します。
再起動後に繰り返しを再開することはありません。いずれの場合も記録の保存を待って、そのまま瓶と
完走カードへ進みます。

通常報酬は必ず得られます。レア判定が通常報酬を置き換えてはいけません。

時間の核が価値の主表示です。1分を10g、25分／250gを1標準単位とし、端数を完走境界で
丸めません。したがって10分は0.4、25分は1.0、60分は2.4標準単位です。同じ総時間を
短く分割しても長くまとめても、時間の核、質量節目、星図の大きさは同一になります。

Reward Bridgeは新しい通貨でも抽選目標でもなく、物理的な粒の整理を理解する補助表示です。保存済みの累計粒数から、
直近の一粒が参加する最も近い10→1変換を主表示として導出し、常に10個のslotで示します。
11〜19粒では×10の1/10〜9/10を一粒ずつ進め、×100など長期tierの進みは小さい補助行に
分離します。10粒目では次tierへ即座に表示を飛ばさず`×10完成 10/10`、100粒目では
`×100完成 10/10`を保持します。99粒目のように次の一粒で複数階層が融合する場合も、
その事実だけを表示し、near-miss演出にはしません。partial projectionの下限値からは
10進の余りを推測しません。下限10・真値11のような到着順では`10/10`から`1/10`へ
戻って見えるため、この状態では確実な`今回 +1粒`と`結晶進捗を同期中`だけを表示し、
iCloud到着後に正確なslot位置へ切り替えます。

完走直後の表示はpersisted Reward Receiptで保護します。StudySessionを集中記録のsource of
truthとしたまま、session ID、時刻、休憩分数、質量、テーマ表示名、色、週内回数、確定した
粒種、着地時点の累計粒数、partial projectionかどうかという表示用full payloadを
UserDefaultsへ最大4件保存します。一回限りの着地markerを消費するより先にreceipt保存を
確認するため、その後にプロセスが終了してもセッションを再保存・再抽選せず復元できます。
復元時は着地音や物理衝撃を再生せず、本人が「閉じる」「休憩」「共有」のいずれかを明示して
acknowledgeしたときだけ一度削除します。複数receiptは時刻順の小さなFIFOとして扱い、
後の完走で表示中の完走を上書きしません。receiptの表示・待機中は新しい集中開始と大きな
融合sheetを保留し、`完走カード → 明示ack → 融合説明`の順序を固定します。activity resetでは
receiptも同時に削除します。

### 3.2 三つの距離

#### いまの瓶

- 最近の12〜40粒を物理的に動かす
- 瓶のタップ座標をSpriteKitの瓶内座標へ変換し、その位置を中心に局所衝撃を与える。瓶全体を一律に揺らす操作へ置き換えない
- iPhoneの傾きで粒が動く
- 一回の集中の手触りを担当する
- 可動粒の背面に、累計質量だけを入力とする非物理の「積み上がりの光」を置く。可動体数、十進桁、レア種、融合タイミングを入力にせず、45体が1個へ融合しても光量を減らさない
- 瓶内の明るい層は2.50kg（集中250分相当）を一巡として下から上へ進み、毎巡必ず100%まで満ちる。満杯回数を保持し、短い到達beatのあと次の巡の余りへ進む。物理床ではないため前景粒を固めない
- 2.50kg、25.0kg、250kg、2.50t…の長期質量段階は巡回層と分離し、一度きりの強いbeatと到達痕を最大6個残す。履歴を開き直しただけでは過去のbeatを再生しない
- 積み上がりの光は対数的に育てて上限を持たせる。前景は常に動ける余白を保ち、長期達成感は質量・節目・星図で失わない
- 整理前の実測粒は半径でなく面積を質量比例にする。10分100g、25分250g、60分600gの粒は大きさが異なり、loose粒だけを比べれば同じ総時間の合計面積は同じになる。極端な1〜360分は物理安定性のため半径を有界化する
- 10→1後の物理半径と可動体数は瓶を塞がないため圧縮され、元セッション回数にも依存する。融合後の見かけ面積を時間価値の証拠として使わず、累計時間・質量、巡回層、時間の核、星図を価値の正本にする
- 1〜9粒では、動く実物粒を主役にし、HUDの小さな10-slot railだけを必ず一つ進める。瓶の中央に同じ一粒を別のgemとして複製しない
- 10粒が実際に融合した時点で初めて、同じ生涯カウントから導出した非物理の「時間の核」を物理層の奥に誕生させる。以後の10-slotはレア抽選とは無関係に進む
- 1〜9粒のReward BridgeとOverviewは、完成済みgemに見える中央素材を描かず、透過した「結晶の器」だけを示す。10粒で初めて色面・ハイライト・発光を持つ実体核へ変化し、未達と達成を見た目で正確に分ける
- 核の色は選択中のテーマではなく、会計frontierの質量加重色から導出する。部分同期時は推測した10進位置を描かず、「以上／同期中」に切り替える

#### 育つ結晶

- 10粒 → ×10、10個の×10 → ×100という十進階層
- 元のセッション、質量、テーマ構成、実測／手動、レア内包数を保持する
- 高階層ほど発光、面、輪郭を強くする
- 物理半径は上限を持たせ、長期利用で瓶を塞がない
- 数字ラベルは物理回転を打ち消し、常に読める

#### 時間星図と年月の星庫

- 生涯のroot結晶を最大8個の代表星と中央の「時間の核」で俯瞰する
- 星の色は表示ページの多数色ではなく、生涯質量の正確な加重合成にする
- 月の瓶を棚に残し、週、月、年へズームして眺められる
- 空白期間を失敗として赤くしない
- 満点・資格合格・仕事の達成は質量ゼロの「成果の星」として独立表示する

#### 適応的な初期距離

Overviewの初期レンズは、追跡型の推薦や機械学習ではなく、保存済みデータだけを使う
決定論的で説明可能な規則です。利用者は表示後も「いま／結晶／年月」を自由に切り替えられます。

- 特定の結晶から開いた場合は「結晶」を選び、その結晶の内訳を開く
- 今週の実測完走または現在のloose粒がある場合は「いま」を選ぶ
- 最近の粒がなくても、root結晶または10粒以上の生涯記録があれば「結晶」を選ぶ
- 本当に空の記録では「いま」を選び、最初の一粒への手がかりを残す

これにより、長く積んだ人が空白期間のあと戻ったとき、最初に「今週0回」だけを見せて
過去を失ったように感じさせません。これは再開を改善するという検証済み効果を意味せず、
視覚的な損失表現を避けるための設計仮説です。

質量の不変条件:

```text
生涯グラム = loose sessions + root aggregates
achievement stones = 0g
時間価値 = 生涯グラム / 250g
同じ総分数なら、完走への分割にかかわらず時間価値は同じ
```

子集約と元セッションは探索用に残りますが、同じ画面で親と重複加算しません。

部分同期中も同じ不変条件を守るため、表示と集計は「会計frontier」を一度だけ
構成します。

- 同じsession membershipは最大1回だけ数える
- 親がchild IDを宣言していれば、子側backlinkが未着でも親子関係として扱う
- 親の構成要素が不足していれば、利用可能で検証できる子へ安全にfallbackする
- ancestor／descendantや複数rootが重なる場合は同時加算しない
- 元sessionが端末へ到着済みなら、その実測値から正確な総量を復元する
- membership情報を持たない旧compatibility rowは従来の表示互換性を保つ

これによりCloudKitの到着順が前後しても、親結晶とその子・元粒を重ねて質量を
膨らませません。

### 3.3 今週の結晶

今週表示はstreakではなく文脈の手がかりです。

- 完走カードでは今週の実測質量を第一表示し、戻った回数は「時間価値とは別の頻度」として第二表示する
- 「今週」はどの画面でも暦の週一つだけ（端末の週の始まりから7日、`WeeklyProgressPolicy.week`）。記録の「今週／今月」も直近7日ではなく同じ暦の週・月を使い、範囲の日付を表示する
- 週の実測表示は実測（タイマーとScreen Time）だけを数える。自己申告だけの週を「まだ透明」とは呼ばず、自己申告の質量が瓶とこれまでの記録に入っていることを示し、実測がある週も「このほか自己申告」を添える。記録の合計は入力方法を問わず数え、「このうち自己申告」を併記して実測と照合できるようにする
- 戻った回数・完走ポモ・タイマー完走はタイマーの完走だけを数える（`SessionSource.isTimerCompletion`）。Screen Timeの10分単位は実測時間として質量に入るが、回数には入れない
- 完走ごとに一面を点灯
- 休んだ日に減らさない
- 週をまたいでも以前の瓶は保持
- 既定のノルマを押し付けない
- 将来目標を追加する場合も、利用者が自分で設定・変更・無効化できる

休憩提案も回数ではなく実測質量を使います。従来の4×25分に相当する1,000g／100分ごとに
長い休憩を提案し、10分×10、25分×4、60分をまたぐ経路で同じ境界になります。加えて、途中で
休めなかった1回60分以上の連続した集中の後も長い休憩を提案し、休憩の周期をそこから数え直します。
分割した集中には間に休憩の機会があった一方、長い一続きの集中にはなかったためです。分割しても
長い休憩が早まることはなく、報酬（質量・抽選・結晶）は従来どおり同じ総時間で同じです。同じ完走IDを
クラッシュ復帰で再処理しても二重加算せず、休憩を受けるかどうかは常に本人が選べます。

### 3.4 レア粒の倫理ガードレール

維持する制約:

- 1〜360分の実測完走で積んだ対象質量のみ抽選へ加算し、250gごとに一回抽選する
- 250g未満の端数質量は次の対象完走へ繰り越す
- 通常粒は必ず付与
- 金・虹は見た目以外の価値を持たない
- 確率と保証条件を表示
- 課金で確率を変えない
- 再抽選、期間限定rate-up、near-miss、コンプ報酬を作らない
- 保証までの残り回数をHome、通知、完走CTAへ出し、次の抽選を追わせない
- レアの有無で質量、十進階層、共有可否、成果の星、機能解放を変えない
- `standard / quiet / off` を本人がいつでも変更できるようにし、Reduce Motionや全体の音・触覚設定とは独立させる

三つの設定は次の意味に固定します。

- `standard（標準）`: 対象質量が累計250gへ達するごとに一回抽選し、種類の色・光、レア専用の落下前予告、常時きらめき、着地時の専用音・専用触覚を使う
- `quiet（控えめ）`: `standard`と同じ250g境界・確率で抽選し、金の保証カウントも同じように進める。粒種と履歴は保持する一方、レア専用の落下前予告、常時きらめき、専用音・専用触覚は使わない。タイマー終了通知と通常の着地フィードバックは、本人が選んだ全体の音・触覚設定に従う
- `off（抽選しない）`: 実測完走でもRNGを呼ばず、テーマ色の通常粒を保存する。抽選用の端数質量と金の保証カウントは増加もリセットもせず現在位置で停止し、`standard`または`quiet`へ戻したとき同じ位置から再開する。`off`中の質量をあとから抽選用に貯めない

設定変更で過去の`StudySession`の粒種や結晶内の金・虹の実数は書き換えません。既存の履歴、質量、十進融合、共有範囲と共有内訳はすべて保持します。`off`中の完走には隠れた抽選結果そのものが存在しないため、再び抽選を有効にしてもあとからレア結果を開示しません。どの設定も無料で、機能、成果、質量、融合速度、共有可否に差をつけません。

`standard`と`quiet`では、抽選回数と金の保証を完走回数ではなく実測質量で進めます。同じ600gは、
10分×6、25分×2 + 10分、60分×1のどの経路でも抽選2回 + 100g繰り越しです。金が出ない抽選が
20回続いた場合は次の250g抽選を金にし、虹はこの回数をリセットしません。このため時間の分割で
抽選効率や保証までの時間を稼げません。`off（抽選しない）`は他の二設定と同じ強さで提示し、
レアを時間価値の証拠として扱いません。

### 3.5 成果の星

満点、資格合格、仕事の成果はランダム粒より明確に目立たせます。

- 通常粒より一回り大きい
- 専用色、縁、発光、記号を持つ
- 記号は濃紺の不透明面と白文字で分離し、鮮明な種類色の縁を残す。背景色だけに意味を依存しない
- 質量に混ぜない
- 集約で飲み込まない
- 最新12個を瓶で動かし、全件を記録と星庫に保持

## 4. 満杯時の導線

「物理的に詰まる満杯」「繰り返し見届ける満杯」「生涯の長期段階」を分離します。
物理的な詰まりは操作不能やオーバーフローを招くため恒常状態にしません。背面の非物理層は
固定2.50kgごとに必ず下から上まで満ち、満杯回数を一つ増やし、超過分を失わず次の巡へ繰り越します。40年後も
一巡の長さは変えません。長期段階は2.50kgから10倍ずつ伸び、強い光と消えない到達痕を
別に残します。巡回層が次へ移っても、累計質量、満杯回数、到達済み長期段階は減りません。

2.50kgは集中250分に相当します。短期の満杯周期と、生涯の履歴である10倍段階を同じ
「次の目標」として扱いません。10倍段階は進みが数年単位で小さくなるため、Homeで残量を
煽らず、Overviewと積み上がり計画で到達履歴として見せます。

| 習慣 | 1年の質量 | 2.50kg満杯周期 | 40年の質量 | 40年の満杯回数 |
|---|---:|---:|---:|---:|
| 25分／日 | 91.3125kg | 10日に1回 | 3.6525t | 1,461回・端数なし |
| 1時間／日 | 219.15kg | 4日4時間に1回 | 8.766t | 3,506回 + 次の40% |
| 10時間／日 | 2.1915t | 4時間10分に1回 | 87.66t | 35,064回・端数なし |

| 長期到達痕 | 25分／日 | 1時間／日 | 10時間／日 |
|---|---:|---:|---:|
| 2.5kg | 10日 | 4.17日 | 4時間10分 |
| 25kg | 100日 | 41.7日 | 4.17日 |
| 250kg | 2.74年 | 1.14年 | 41.7日 |
| 2.5t | 27.38年 | 11.41年 | 1.14年 |
| 25t | 273.8年 | 114.1年 | 11.41年 |

10時間／日では満杯演出が一日2.4回となるため、同じ大演出の反復は馴化する可能性が高い、
という製品仮説を持ちます。将来は「その日最初の満杯だけ大きく祝う／以後は静かにする」を
実利用データで比較します。個人別に2.50kg自体を変えると満杯回数の共通意味が失われるため、
短期周期は固定し、本人が選ぶ週間目標を別レイヤーに置きます。

満杯はエラーでもリセットでもありません。また、結晶化を満杯まで
待たせません。安定位置や容量に依存せず、同じ階層の10個が揃うたび、
作成日時とUUID順で同じ10個を決定論的に選びます。

```text
10個目の対象が揃う（または容量接近）
  → 対象10個が中央へ集まる
  → 保存可能性を確保
  → 一つの結晶が誕生
  → 元記録・質量が保持されたことを説明
  → 中の粒を見る / カードにする / 次へ
```

必須の障害設計:

- StudySession保存をsource of truthとし、別storeを単一transactionと偽らず、Reward Receiptで表示へのdurable hand-offを作る
- 完走結果のfull payloadを最大4件のReward Receiptとして着地marker消費前に永続化し、復旧時にもセッション再保存・再抽選をしない
- receiptは表示しただけでは消さず、閉じる／休憩／共有という明示ackで一度だけ削除し、activity resetでも残さない
- 途中遷移でも要求を失わない
- 保存失敗時は元粒へ完全復帰
- 同じ失敗を毎フレーム再試行しない
- 明示的な再試行を提供
- hard limitでも「まとめています」のまま停止しない

## 5. SNS共有

共有の目的は比較ではなく、自己表現と努力の意味づけです。

含めるもの:

- 瓶または結晶のGIF
- 累計または選択期間のグラム数と、それに相当する集中時間。グラムを主に大きく示し、その下に
  `4時間10分の集中`のように時間を添える（集中1分＝10gなので、見る人がグラムから時間を逆算しなくて
  よい）。共有本文も`…を 2,500g（4時間10分）積みました`と両方を書く。時間表記は全画面で
  `DurationPresentation`の`N分 / H時間 / H時間M分`に揃え、`1.5h`や`30m`は使わない。表示する時間は
  質量になった時間（完走ごとの分単位、Proの40分30秒なら40分・400g）で、記録（期間の合計と月ごとの瓶）・
  年月（月・日・テーマ別の時間と割合）・Wrapped（合計とテーマ別）・カードとも質量から求める。秒を
  合計すると、同じ記録で記録とWrappedが`1時間21分`、カードが`1時間20分`と食い違う
- 累計カードの期間表示は`これまで`。当日の日付だけを付けて、その日の成果のように見せない
- 利用者が確認・編集できるハッシュタグ。既定は`#ポモジェム #ポモドーロ`で、`#勉強記録 #勉強垢`は
  未選択の候補として並べ、利用者が選んだときだけ共有する
- 保存済みテーマ名や成果メモは自動で外へ出さず、利用者が確認・編集した追加タグだけを明示的に共有する
- 金／虹のレア粒内訳と、100点／試験合格／仕事の節目という記念石種別

カード内の瓶は、密度を上げて判別不能にするのではなく代表表示にします。

- フィードは loose 32粒、まとまり8個、記念石6個まで
- ストーリーは loose 64粒、まとまり12個、記念石8個まで
- 上限を超えた場合は画像内に `代表表示 +N`、共有本文とVoiceOverに非表示の集中粒・まとまり・記念石をそれぞれ開示
- まとまりに含まれる元セッションは非表示loose粒として二重計上しない
- 質量、総数、金／虹内包数は代表表示によって減らさない
- タグ選択はプレビュー時点で固定した同一snapshotを、カード画像、GIF全frame、共有本文へ渡す。選択解除や任意タグが表示だけに留まり、実共有で固定タグへ戻る状態を許さない
- カードの内容（粒・まとまり・記念石・質量・自己申告の有無）は記録の読み込み時と`自己申告を含める`の
  切替時にだけ一度解決し、プレビュー、共有本文、写真保存、書き出しが同じ値を読む。タグ入力や形式の
  切替のたびに全記録を解き直さない
- 累計カードの瓶は実際の瓶の画像を使う。ただし黒い石や含めない自己申告の粒を隠すと、その上に
  載っていた宝石が穴の上に浮く場合は、共有する記録だけで描いた瓶に切り替える。記念石は重さを
  持たず、カードに常に載る（`記念石は自己申告`と開示）ので瓶でも隠さない
- 描いた瓶の記念石は、真下にある宝石・結晶・先に置いた記念石の上に、何もなければ瓶の底に置く。
  いちばん高い宝石の段に合わせた棚には置かない（宝石が少ないと空のガラスの上に浮くため）
- カードのハッシュタグは1行に縮めず折り返す。4つの候補と30文字の追加タグを選んでも、画像から
  欠けて本文にだけ残ることはない。調整のタグ候補も横スクロールにせず折り返して全部見せる
- GIFは720px幅（フィード720×900、ストーリー720×1280）で書き出し、15MBを超える場合だけ
  段階的に小さくする。`動くGIF`を選んで写真に保存した場合は、2サイズともGIFのまま保存する。
  写真への追加の許可は描画の前に確認し（拒否されたら描画しない）、生成中は`写真用のGIFを作って
  います…`と表示する。生成時間は端末で大きく変わるため、画面に秒数は書かない

含めないもの:

- 順位
- 他人より上／下という文言
- 連続日数を失う脅し
- 自動投稿
- 連絡先への自動招待

## 6. 敵対的導線監査

| 導線 | 攻撃的な問い | リリース条件 |
|---|---|---|
| 初回起動 | 物理接触イベントが来ないと先へ進めないか。勉強／仕事という不要な分類を強制していないか | ためしの一粒は任意で「次へ」から省略可能。共通候補から最初のテーマ1件だけを選ぶ |
| タイマー開始 | 誤ったテーマ・時間で始めやすいか。テーマや時間の選択で意図せず集中まで始まらないか | 開始前にテーマと時間が読め、Homeの選択欄で変更できる。選択だけでは開始せず、開始buttonのtapでタイマーが始まり、中断も可能 |
| 25分／45分／60分／90分 | demoだけ通り、本番の無料時間が開始・停止・再開できない状態を見逃さないか | 四つすべてを実UIで開始・一時停止・再開・「今日はここまで」まで操作し、中断では粒と質量を増やさない |
| テーマ管理 | 追加・改名・非表示・復帰・削除の途中でHomeが選択不能にならないか | 勉強・仕事共通の一一覧で全lifecycleを実UIで通し、選択中テーマの削除後も別テーマへ安全にfallback。過去記録はsnapshot名で保持 |
| テーマ削除 | OSがキャンセルactionを視覚・AX上から抑制し、背景タップだけが回避策にならないか | 履歴保持と不可逆性を本文に示し、削除と明示キャンセルを同時にAX操作可能なalertで表示 |
| バックグラウンド | OS終了、時計変更、機種変更で二重完了するか | 同一session IDで冪等 |
| 2端末 | オフライン競合で正常完走が消えないか | 両完走を説明付きで保持 |
| 完了保存 | 所有権拒否を成功と誤認しないか | 結果型を分離し、未確認ならリカバリ保持 |
| 中断 | terminal保存失敗後にクラウドで復活しないか | cancel tombstoneを永続保存してからローカル状態を消去。失敗時はタイマーと復元情報を保持して継続 |
| 手動追加 | 上限超過、誤タップ、2端末合算が説明通りか | 残回数、Undo、同期後方針を表示 |
| 成果追加 | 誤った合格記録を直せるか。削除前に見えていなかった旧duplicateが後着して復活しないか | 個別編集・削除・Undo、単調revision、tombstone込みcanonical winnerを表示前に解決 |
| 完走報酬表示 | 粒の保存後、Reward Bridge表示前に終了したら演出が消えるか、再抽選されるか | 実装済みのpersisted Reward Receiptを着地markerより先に保存。再起動では同じsession IDのfull payloadを復元し、明示ackで一度だけ削除 |
| 結晶化 | 0/100/400/520msで遷移しても壊れないか。1〜9粒で完成済み核を見せていないか | 正確に一度保存または完全rollback。BridgeとOverviewの実体核は10粒以上だけ |
| 満杯 | 永続障害で無限アニメーションしないか | 試行上限、安定表示、手動再試行 |
| 概要 | 40年分を全件同期ロードして固まらないか。空白後の長期利用者へ「今週0回」を最初に突きつけないか | ページング、集計Query、有界メモリ。決定論的な適応初期レンズで消えない結晶を先に表示 |
| 再訪 | 休んだ人へ罪悪感や失効を示し、一般通知で繰り返し追わないか | 任意・編集可能・無効化可能な本人作成if-then cueと「記録はそのまま」の再開文言 |
| レア演出 | Reduce Motionだけで不確実報酬を拒否できたことにしていないか。未選択を標準扱いしていないか | 初回に同格の`抽選しない / 控えめ / 標準`から明示選択。未選択と抽選しない設定ではRNGと保証進行を止めても、履歴・質量・融合・共有・成果に不利益を与えない |
| シェア | キャンセル・容量超過・生成失敗から戻れるか | データを失わず再試行可能、CTAが見える |
| 課金 | 複数プランに見せる、偽の期限、価格の不一致、復元困難がないか | 無料download＋買い切り1商品だけとし、日本JPY 100、米国USD 0.99基準、その他はAppleの現地相当額をStoreKitの`displayPrice`で提示。復元、条件、法的リンク、閉じるを常時提供 |
| iCloud | Apple Account可否を同期成功と誤表示しないか | 保存済み／待機／最終同期／エラーを分離 |
| unsigned simulator | CloudKit entitlementのないビルドでcontainer生成時に例外終了しないか | `CKContainer`構築前にsimulator判定し、ローカル専用状態へ分岐 |
| アクセシビリティ | AX5、VoiceOver、Reduce Motionで詰まらないか | 全主要E2Eを通す |

### 6.1 10粒→100粒・共有・完走後CTAの再監査

10粒から100粒までは、90回分が無反応なのではありません。20、30、…、90粒でも実際の
10→1融合が起き、可動する`×10`結晶が一個ずつ増えます。問題はHomeの説明が長期の
`×100へ 1/10`〜`9/10`を主に見せ、次の10粒単位の到達点を動く粒から推測させていた点です。
そこで、HomeとOverviewは次の二つを同時に示します。

- 耐久的な全体進捗: `×100へ 1/10`など
- 直近の到達点: `次の結晶まであと9粒`など。99粒では`あと1粒で2段融合`

これは90個の中間バッジを追加する設計ではありません。小目標を序盤の進行感に使いながら、
全体目標を失わないhybrid表示です。partial iCloud projectionでは数を推測せず、同期中とだけ
表示します。瓶内の固定サイズHUDに加え、Accessibility Dynamic Typeではスクロール可能な
system fontの補助カードを出し、VoiceOverの完走通知にも長期・直近の両方を含めます。

共有Composerは、既定状態で`GIF / 静止画`、`4:5 / 9:16`、共有範囲、タグ、ブランド表示、写真保存
という六つの情報と判断を同時に提示していました。通常の意図は「今の瓶を共有する」なので、既定値を
一行で開示し、任意変更を一つの`調整`へ段階開示します。通常はComposerからsystem share
sheetまで一回のタップです。自己申告だけの期間は「記録なし」と誤表示せず、`自己申告を含めて
カードにする`を直接提示します。記念石だけでカードが0gになる場合は、除外した自己申告を
`自己申告の30分は、カードに含めていません。`のように量で示す枠と`自己申告を含める`ボタンを
カードの下に出します。実測分がすでにカードにある場合は、`既定は実測のみ`を選んだ本人に毎回
促さないよう、同じ文を一行の注記にして横に小さな`含める`を置きます。どちらも保存済みの既定は、
本人がこの操作をしたときだけ変わり、VoiceOverには含めた後のカードの質量と時間を読み上げます。
設定の一行表示は集中の範囲と記念石を分けて`実測のみ（自己申告は除外）・記念石は自己申告`のように示します。月の瓶（Wrapped）の
時間と粒は自己申告を含むため、その場合は画面にそう明記します。ポモジェムのロゴと公式サイトは無料／Proともカードへ常設し、公式
URLを共有本文にも含めます。共有先アプリの選択はOSのactivity viewに委ね、自前でSNS別の選択画面を重ねません。

完走後の旧`閉じる`は見た目が約34×14ptで、隣の共有・休憩CTAより著しく小さく、端を狙う
操作で失敗しました。文字付きcapsuleへ変更し、通常時88×44pt前後、Accessibility最大文字では
横幅いっぱい×44ptを確保します。最大文字では安全な三つの操作を詳細進捗より先に置き、初期
viewport内、相互非重複、端部タップ、hit region、text clipping、説明、traitを検証します。

判断根拠:

- [Apple Human Interface Guidelines — Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)
- [Apple Human Interface Guidelines — Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
- [Apple Human Interface Guidelines — Activity views](https://developer.apple.com/design/human-interface-guidelines/activity-views)
- [Scheibehenne et al. — Can There Ever Be Too Many Options?](https://scheibehenne.de/ScheibehenneGreifenederTodd2010.pdf)
- [Huang et al. — Step by Step: Sub-goals as a Source of Motivation](https://zhang.gsm.pku.edu.cn/__local/7/D4/0B/7FC03382DEF52A06FCE2BD03C67_3CB8772C_E7FC0.pdf)

## 7. 40年耐久の不変条件

表示用シミュレーションだけでは合格にしません。二段階で検証します。

### 算術・物理テスト

- 350,640セッション
- 87,660,000g（87,660kg）
- 146,100時間
- 38,958個の集約（×10: 35,064、×100: 3,506、×1,000: 350、×10,000: 35、×100,000: 3）
- 生涯root結晶18個、未集約0個
- Debugの可視物理体はroot 18個 + 成果12個 = 30個
- 通常画面の可視物理体は常に128以下
- 元ID、質量、テーマ構成、成果12個を保持
- うるう年、DST、timezone変更を含む
- 同じ8,766,000分を、10分×876,600回、25分×350,640回、60分×146,100回へ分けても、すべて87,660,000g・350,640標準単位になる
- 上記三経路は物理粒数と融合回数だけが異なり、時間の核、質量節目、星図の価値表示は一致する

### 実ストア・実画面テスト

- 実SwiftDataへ履歴と集約を投入
- cold Homeを1.5秒以内に操作可能
- 全履歴を物理待機列へ入れない
- 古い同期分は即時に有界表現へまとめる
- 最新の一粒だけ着地演出を再生
- Overviewは集計・fetch limit・ページングで構成
- iCloud重複到着順を逆転しても質量不変

2026-08-31のiOS Simulator実測soak:

| 指標 | 実測値 |
|---|---:|
| StudySession投入 | 350,640件 |
| AggregatePebble投入 | 38,958件 |
| store容量 | 104,681,472 B |
| insert所要時間 | 53.822秒、peak 71,174,568 B |
| 全件fetch | 14.730秒、peak 754,519,520 B |
| cold bounded projection | 0.165秒、peak 73,420,256 B |
| projection結果 | descriptor 30個（root 18個 + 成果12個）、loose 0個、物理待機queue 0個 |

全件fetchは比較用の負荷測定であり、通常導線では実行しません。cold projectionは
root集計と有界データだけを読み、全350,640セッションを画面モデルや物理待機列へ
展開しません。このsoakではクラッシュとOOMのどちらも発生せず、質量・root数・
未集約数は算術モデルと一致しました。

同日の高速UI fixtureと回帰検証:

- 本番の十進階層計算から、×100,000を3個、×10,000を5個、×100を6個、×10を4個の計18 rootとして構成
- 350,640セッション、87,660,000g、root 18個 + 成果12個 = 物理体30個をOverviewへ正確に表示
- `87.66t`、`350,640`、各階層の個数をiPhone Simulatorの上下viewportで目視確認
- XCTest 254件（253合格 + 重量級soak 1件を明示的opt-inとしてskip）+ Swift Testing 22件 = 276 checks、failure 0
- 実時間12秒のタイマーを10回完走するE2Eで、×10結晶、2.5kg、共有範囲の正確な総量を確認
- 上記E2Eで発見した「選択した結晶と、その元sessionを共有時に重複加算する」不具合を修正し、再発テストを通過

Reward Bridge／Receiptの追加targeted回帰:

- 時間公平性、固定2.50kg巡回、積み上がり光、粒半径、完走後表示、部分同期、整数上限のtargeted回帰75/75に合格。同じ総質量の分割耐性、10／25／60分の比例、節目100%の一度きり保持、超過質量の繰越、融合前後で光が不変、40年で有界かつ単調、旧receiptの後方互換を検証
- 積み上がり計画の純粋projection回帰7/7に合格。40年境界、月スライダー、入力上限、決定性、物理体上限に加え、10／25／60分の同一週分が0〜480か月の全点で同じ総分・質量になることを有理数算術で検証
- 積み上がり計画の実UI回帰1/1に合格。Release相当のメニューから開き、常時「予測・保存なし」を表示し、60分へ変更後も閉じて開き直すと初期値へ戻ることを検証。preview sceneが共有音・触覚サービスを変更してアプリ全体を無音化していた副作用を除去した

- `ProgressPresentationTests` 32/32合格。直近10-slot、10／100境界の完成10/10、11／19／20／99粒での「長期tier + 次の結晶」の二重表示、1〜9の透過destination、10以上の実体core、lower-boundのcore保持とslot同期中表示、receiptのfull payload round-trip・重複排除・明示削除を検証
- 共有のunit回帰20/20、実UI回帰4/4に合格。通常時は一つの共有CTAと折りたたんだ`調整`、自己申告のみでは正直な直接CTAを示し、4:5／9:16のプレビュー・静止画・GIFが同じ正規化canvasを共有して、バッジ・タグ・常設ブランド表示をカード外へ押し出さないことを検証
- 完走後CTAの敵対的UI回帰7/7に合格。`閉じる`は通常約88×44pt、Accessibility最大文字では338×44ptを確保し、共有・休憩との非重複、初期viewport、端部タップ、hit region、文字切れ、説明、button traitを検証
- 専用persistent UI relaunch test 1/1合格。完走後にプロセス終了しても同じBridgeが復元され、保存済み粒が1件のまま増減せず、ack後の再起動では再提示しないことを検証
- 完走保存fault UI test 1/1合格。実transactionを保存直前に一度失敗させ、保護時0行、Home再試行後`sessionRows=1 / uniqueSessionIDs=1 / 250g`、faultを再armした別processの再起動後も同じ1行であることを検証
- 結晶化保存fault UI test 1/1合格。10個目の実完走後、集約transactionの保存直前だけを一度失敗させ、完全rollback後は同一UUIDのloose 10個・各250g・合計2,500g・aggregate 0件を保持。明示再試行後は元UUID集合を全て保持する別UUIDのaggregate 1件となり、再起動後も同じ1件・2,500gであることを検証
- GIF share lifecycle UI test 1/1合格。実12-frame GIFをImageIOで検証し、実`UIActivityViewController`へ渡し、system cancel後に同じ所有一時URLが削除済みであることを検証
- GIF共有のVoiceOver操作 UI test 1/1合格。説明文コピーを共有カード全体から独立したCTAとして到達可能にし、system pasteboardへの実コピー、独立した成功メッセージ／閉じるCTA、composer復帰までを検証
- ×10実時間E2E再検証 1/1合格。10個目でも`×10完成 10/10`のReward Bridgeを先に固定し、明示ack後にだけ結晶化sheetへ進み、2.5kgの範囲共有カードと可逆な内訳表示まで順序を維持することを検証
- 9→10実時間visual E2E 1/1合格。9/10の中央は中空の器、10/10で初めて実体核になり、融合sheetはsystem grabber一本・large初期表示でタイトルと保持説明をクリップしないことを原寸screenshotで検証
- `RuntimeFlowAuditUITests` 5/5、`CriticalFlowAdversarialUITests` 4/4、独立した実時間×10 E2E 1/1の計10/10に合格。連続完走中に旧Reward BridgeのAX要素を次回分と誤認したテスト競合は、旧Bridge消失、launcherのhittable、Focus画面成立、新Bridge出現、各回の実粒数増分を同期条件にして排除し、製品側の8→9→10保存・融合が正常であることを再確認
- 瓶の局所バウンド、レア抽選の初回選択／無抽選、完走保存失敗、融合保存失敗を同一serial bundleで5/5合格。各UI testの開始前／終了後にアプリprocessを明示終了し、残留Reward Receiptをdrainしてシナリオを隔離。負荷時の12秒timerは結果条件を弱めず待機上限だけ60秒にし、粒ID、grams、融合元、再起動後の永続化assertを維持
- 主要導線の敵対的UI再検証 2/2合格。手動追加、資格合格、Overview、記録、GIF共有、設定、Pro説明を往復してHomeへ復帰し、画面維持設定も変更後に元の値へ戻せることを検証
- 無料の25分・45分・60分・90分の実タイマーは、同じ開始→一時停止→再開→中断を4/4で再検証する。既存の25分・60分は2/2で通過し、中断後も粒・質量を増やさないことを確認済み。英語`PAUSED`を「一時停止」へ統一し、同義の中断操作を下部「今日はここまで」1件に統合
- テーマ削除の明示cancelは、修正前AXで`exists=false / frame=absent`を検出。system `confirmationDialog`へ背景タップだけで戻らせず、削除／キャンセルを同時表示するalertへ変更した。修正後は`exists=true / hittable=true / 288×48pt`、cancel後の存続と再確認後の削除を1/1で実操作
- 旧Reduce Motion方針のtargeted回帰は73/73合格し、粒を安全位置へ静置することを検証した。現在の瓶は下記のとおり、Reduce Motionに関係なく同じ物理挙動を使う
- 固定AX5敵対的監査 1/1合格。Home、Menu、Overviewの「いま／結晶／年月」の5画面に対して、コントラスト・タップ領域・説明・文字切れ・traitsの25監査を通し、Overviewを閉じてHomeへ戻るところまで検証
- system Dynamic Type監査 1/1合格。テスト専用サイズ固定を使わず、XCTestが文字サイズを実際に変更しながらHome→Menu→Overviewの主要導線を検証
- 瓶の局所タップ実UI test 1/1合格。SpriteKitの実着地座標へタップし、1.2秒以内に8pt以上の上昇と反応sequence更新を確認。前後で1粒・250g・元record ID/gramsが完全一致し、表示だけの操作が実績を変更しないことを検証
- 背景カードを装飾子要素から単一のVoiceOver targetへ統合した後も`.isButton`を明示し、「オーロラ、光に包まれる」等を名称・選択状態・操作roleの揃ったボタンとして到達可能にした
- 公開前の最終gateではstatic analyzeをwarning 0で終え、generic iOS Releaseを生成する。QA Simulatorへ既存コンテナを消さずに最新版を上書きし、250g・1粒・1/10の実績保持、2回連続のterminate／cold relaunch、直近15分のcrash report 0件・fatal log 0件を確認する

これは追加対象の結果であり、上記の全体check数を最終回帰前に推測して更新するものではありません。

## 8. 実験計画

比較する候補:

- A: 通常粒のみ
- B: 三段階表示 + 適応的な初期レンズ + 決定論的Reward Bridge、ランダムなし
- C: B + 本人が選ぶ週目標／実行意図の手がかり
- D: C + 上限付きの視覚的レア粒

A/Bは構成要素を理解する探索比較とし、レア粒の採否を決める主要比較は最低28日の
C/Dとします。割付は利用者単位で固定し、同じ人の完走ごとに条件を入れ替えません。
CとDの差は視覚的レアだけに限定し、Dでも本人はいつでも`quiet / off`へ変更できます。
変更者を除外せず、割付時点を基準に評価します。

この比較から言えるのは、対象期間と対象利用者における因果差までです。レア粒が次回開始を
増やしても、28日の学習指標を改善しない、または防御指標を悪化させる場合は採用しません。
「脳の報酬系を刺激する」「依存性がある」といった神経学的・臨床的な断定にも使いません。

主要指標:

- 7日・28日あたりの実測完走分数
- 3〜14日の空白または中断後、7日以内の再開率
- タイマー開始から完走までの率
- Overviewを見た後の次回完走率
- 本人が作成したif-then cueの予定完走率
- 任意で記録された問題数、章、成果物、試験結果など、時間以外の成果

防御指標:

- 本人が設定した睡眠時間帯の利用増加
- 25分／45分／60分／90分の選択比率がレア条件だけで変化していないか
- 通知無効化率
- 休憩スキップの連続回数
- 連続3本・4本以上の完走率と、タイマー外のアプリ滞在時間
- `quiet / off`への変更率
- 課金後悔・返金
- 「追われる」「休むと損」「やめたいのに続けた」、不安、義務感、睡眠への自己申告悪化
- クラッシュ、保存失敗、同期競合、二重記録

単なる起動回数、画面滞在時間、共有回数だけで勝者を決めません。学習指標が改善し、防御指標を悪化させない案だけを採用します。

現時点の`Analytics.shared`は永続化・通信・loggingを行わない`NoOpAnalytics`です。
したがって、上記は実験計画であって、現行Reward Bridgeやレア粒の継続効果を示す実績では
ありません。実験前に、テーマ名、成果メモ、顧客名を収集しない最小イベント設計、同意、
撤回、保存期間、分析除外条件、安全性の非劣性基準を事前に固定します。

## 9. 現在の実装状況

実装済み:

- Homeは瓶と開始を中心に、開始前のテーマ・時間を直接選べるボタンを併置。設定変更だけでは開始せず、詳細操作はメニューにまとめる。メニューは記録・積み上がり・シェア・設定を先頭に置き（半分の高さでも記録と設定が見える）、手動・成果の追加、積み上がり計画、背景（集中する空間）の順に続ける。背景は最後にあるので、選ぶころにはメニューが全画面に広がっていることが多い。背景を選ぶとメニューを半分の高さに戻し、選んだ背景をシートの後ろで確かめられるようにする
- Focusは中断操作を下部「今日はこまで」1件に限定し、一時停止表記を日本語に統一。突然閉じる左上×は置かない
- タップ位置への局所衝撃、傾き、Reduce Motion
- 無料の25分・45分・60分・90分、Proのそれ以外の任意時間（1〜360分）。Homeの時間メニューはこの端末で最近使ったProの時間を最大3件並べ、プリセットへ切り替えた後も一度で戻せる
- 終了音・触覚、画面維持
- 通常／金／虹、確率開示、Pro非連動
- `標準 / 控えめ / 抽選しない`のレア粒設定。初回は三択を同じ寸法・強調で未選択から提示し、選ばずにタイマーを開始できない。旧利用者も明示選択の記録がなければ次回集中前に一度確認する。標準と控えめは実測質量250gごとに同じ抽選・保証を進め、端数を次回へ繰り越すため、同じ600gは分割方法によらず抽選2回 + 100g繰り越しになる。控えめは履歴を保ったままレア専用の予告・常時きらめき・専用音触覚を停止し、抽選しない設定はRNGを呼ばず通常粒を保存して抽選用端数と保証をその位置で停止・再開する。既存履歴、質量、十進融合、共有は変更しない
- 成果の星。Logの詳細から種類・テーマ・日付・メモを訂正でき、削除確認後も同一画面でUndoできる。設定で削除したテーマの記念石は、編集してもほかのテーマを選ばない限りそのテーマ（リンクと名前・色）のまま残し、先頭のテーマへ付け替えない。削除は質量へ影響せず、revision付きtombstoneを正本判定に含めるため、古いiCloud複製が後着しても表示へ復活させない
- Logは時間チャートやランダム統計より先に「成果の星」を配置し、本人が記録した満点・合格・仕事成果を偶然のレア表現より上位に扱う
- 成果markerの濃紺面・白記号・鮮明な種類色rimによる高コントラスト表示
- 十進階層の可動結晶と元データ保持
- 10個ごとの決定論的な即時結晶化（容量・物理座標から独立）
- 「いま／結晶／年月」のOverview
- 「年月」はcurrent epochの最古／最新1件だけから年範囲を作り、選択した年・月だけを256件batchでUUID重複排除しながら正確に集計する。40年分を一度にViewへ展開せず、月瓶は最新96粒の代表表示と正確な全件数・質量を分離し、iCloud入着中のローカル範囲であることを常時開示する。年と月は保存済みの月ラベル（`StrataMath.monthLabel`）と同じ西暦で区切って表示し（`PomoGemCalendar.gregorian`、端末の時間帯・週の始まりはそのまま）、和暦の端末でも「8年」にしない
- 年月の月シートは、同じ正確集計からテーマ別の時間と割合、日ごとの記録（時間・粒数・テーマ色）を追加の読み込みなしで示し、日を選ぶとその日の全記録を1日の有界区間として読む日シートを開く。「この月を振り返る」で12か月より古い月もWrappedとカードにできる（年月はシート上にあるため、カードはWrappedの上に開き、Wrappedの戻るボタンは「月の記録へ戻る」）。記録・年月・Wrapped・月のカードの「月」はすべて西暦の月（`PomoGemCalendar.gregorian`）で、イスラム暦などの端末でも行のラベルと開く範囲が一致する。記録からは「過去の記録を月・日ごとに見る」と「月ごとの瓶」の「もっと前の月を見る」、グラフの棒（VoiceOverではカスタムアクション）から同じ日シートへたどれる。記録の最新30件は延長せず、生涯一覧のページングも行わない。同期中に変わり続けるCloudKit複製の集合を安全にページングする仕組み（SyncMaintenanceArchitecture §7.3、roadmap 3）が整うまでは、日と月の有界区間で答える。活動した日数は数えず、連続日数のような表示にしない
- Overviewを開く目的と保存済み実績から、最近の実績があれば「いま」、空白後も結晶が残る長期利用者または指定結晶からの遷移では「結晶」、本当に空なら「いま」を選ぶ決定論的な適応初期レンズ
- 最大8代表星 + 生涯質量色の時間星図
- 1分10gを唯一の時間価値とする時間の核。10分=100g／0.4標準単位、25分=250g／1.0、60分=600g／2.4として、同じ総時間の分割で進捗を稼げない
- 可動粒の背面に累計質量だけで育つ有界な積み上がり光を配置。10→1融合では後退せず、2.50kgごとに必ず満ちる巡回層と満杯回数、2.50kgから10倍ごとの長期到達beatと消えない到達痕を分離して持つ
- 10／25／60分の整理前の実測粒は質量の平方根で半径を決め、同じ総時間ならloose前景の合計面積も一致する。融合後は物理容量のため圧縮する。VoiceOverも時間・質量を先に読み、10→1の回数由来表示は「瓶の整理」として二次表示する
- Homeでは1〜9粒を実物の可動粒 + 小さな10-slot railだけで示し、同じ一粒に見える中央gemは描かない。×10成立時に初めて、全保存粒が必ず進める決定論的な「時間の核」を物理瓶の背面へ誕生させる。40年fixtureでも約96ptを上限とし、実際に動く粒を覆わない
- 最初の1〜3粒を、物理半径や質量を変えず光輪で可視化
- 完走カードの今週結晶
- 完走カードとOverviewの今週表示は実測質量を第一指標、戻った回数を頻度の補助指標にする。長い休憩は完走回数ではなく累計1,000g／100分ごと、または1回60分以上の連続集中の後に提案し、分割方法で早められない
- 完走後カードで、直近の一粒が参加するimmediate 10→1変換を、中央の次tier結晶と周囲10個のsource shardからなる有限の軌道図、`N/10`、残り粒数で示す決定論的Reward Bridge。10／100境界は完成10/10を保持し、保存済みテーマ色・実levelで一度だけ収束／発光して静止する。長期tierは補助行、partial projectionではslotを推測せず`今回 +1粒／結晶進捗を同期中`だけを表示する
- 融合sheetは`10 → 1 / 記録100%保持`を可視化し、「次の一粒」ではなく中立な「ここで休む」で閉じられる。完走直後に次の抽選や次の集中を急かさない
- 完走表示のfull payloadをUserDefaultsへ最大4件保存するpersisted Reward Receipt。着地marker消費より先に保存を確認し、再起動では着地FXやセッション保存を繰り返さず復元、閉じる／休憩／共有の明示ackで一度だけ削除し、activity resetでも削除する。複数件はFIFOでdrainし、後の完走による上書きを防ぐ
- Reward Receiptの表示または待機中は次の集中開始と融合sheetを保留し、完走カードのack後に融合説明を一度だけ提示する
- `iCloud.com.hinoshiba.pomogem`には`Subject`、`StudySession`、`AchievementStone`、`Prefs`、`ActivityResetMarker`、`SyncedFocusTimer`、`FocusTimerDeviceClaim`の7種類の同期元modelだけを保存
- `AggregatePebble`、`Stratum`、`Bedrock`、`GachaState`は端末内projection storeへ分離し、同期元recordから再構築してCloudKitへuploadしない
- version 1.0はoperations containerをentitlementへ含めず、offline完走も`StudySession`の通常粒として直接保存する
- `CompleteDataDeletionReleasePolicy.isEnabled == false`として、version 1.0のdirect CloudKit一括削除UIとlaunch gateを無効化。Settingsは表示中の記録の通常reset、端末dataはapp削除、cloud dataはAppleのiCloudストレージ管理を案内し、offline別端末を遠隔消去できるとは表示しない
- 中断時はcancel tombstoneを共有履歴へ保存してからタイマー・通知・復元情報を消去し、保存失敗時は終了を装わずタイマーを継続するfail-safe
- 初回フレーム表示直後にもCloudKit入着データを照合し、監視開始前に`@Query`へ届いた変更を取りこぼさない
- iCloud/foreground時の全履歴MainActor走査を廃止し、有界singleton確認へ分離
- unsigned simulatorは`CKContainer`構築前にローカル専用へ分岐し、CloudKit entitlement例外によるSettingsクラッシュを防止
- Log／Share／Wrappedの履歴読み込みをepoch predicate・fetch limit付きの有界表示へ移行
- 記録の「月ごとの瓶」（直近12か月）は、年月と同じ`AccumulationTimelineRepository`で12か月を1回の有界区間として正確に集計し、月ごとの12ページを読まない。`@ModelActor`は専用スレッドを持たず、SwiftDataの既定executorは待っている側のスレッドで処理を実行する（iOS 26.5で計測。SwiftUIの`.task`から直接awaitするとメインスレッドで走る）。そのためViewは必ず`AccumulationTimelineLoader`（detached taskから呼び、キャンセルを転送する）経由で読む。記録の月一覧、年月の範囲・年・月、日シートが対象で、`AccumulationTimelineRepositoryTests`がメインスレッド外で走ることと、View側がRepositoryを直接生成しないことを検査する
- 記録の読み込みは依存するものごとに3つに分ける。今週／今月のページ（切り替えで読むのはこれだけ）、期間に依存しない最新30件・記念石・まとまり粒、月一覧。Control Center・通知センターの開閉（inactive）ではどれも再読込せず、バックグラウンドからの復帰で読み直す。最初の読み込みが終わるまでは「この期間の粒は、まだありません。」「一粒積むと、ここに記録が残ります。」などの空の文言を出さず読み込み中を示す（WrappedViewも同じ再読込規則）
- 共有カードの代表表示上限、非表示内訳開示、金／虹・記念石種別のcaption/VoiceOver表現
- 実12-frame GIFの生成、system share sheetへの受け渡し、cancel復帰、所有一時ファイル削除をDEBUG実UIで検証。ハッシュタグは既定候補を個別に外せ、任意タグを追加できる。同じ確定snapshotをプレビュー、静止画、全GIF frame、共有本文へ渡し、共有時だけ既定タグへ戻さない
- GIF説明文のコピー、成功通知、閉じるをVoiceOverでそれぞれ独立操作にし、system pasteboardまで実UIで検証
- 部分同期用の会計frontierにより、欠落backlink、不完全な親、重複root、ancestor／descendantを保守的に解決し、既知membershipを最大1回だけ集計
- Home／Share／Overview／Logで、直接membership・親子backlink・子aggregate集合が証明する重複rootを除外し、互換性上membership不明な旧summaryは保守的に保持
- 生涯Shareは検証済みrootだけを採用し、部分同期で一時的に未集約へ戻ったsessionは最新summary終了後の分だけを追加して親子二重計上を防止
- 結晶化永続化は10個のsource、epoch、階層、再計算結果、決定論的ID、既存親を全件preflightしてから変更し、欠落・既集約・競合親では兄弟を一切変更しない。完全一致する再送だけを冪等に修復
- 実時間タイマー10回の×10結晶E2Eで、2.5kgと共有総量の一致を確認し、範囲共有の親子二重計上を修正
- 40年履歴をSettingsで常駐Queryしないreset-generation方式
- 350,640セッション・38,958集約・120成果の実SwiftData soakで、30 descriptor（18 roots + 成果12）・0 loose/queue・cold projection 0.165秒・クラッシュ/OOMなしを確認
- 40年の高速Overview fixtureで、350,640セッション・87,660,000g・18 roots・成果12個・物理体30個と全階層ラベルを実画面検証
- Releaseにも表示する「積み上がり計画」。1〜40年、週1〜21回、10／25／60分と経過月を変更し、時間・質量・節目・瓶・星図を予測する。永続化やCloudKitへ依存せず、実績、レア抽選、成果石、休憩、共有、音・触覚、ウィジェットへ書き込まない。閉じると入力を破棄し、常時「予測・保存なし」と表示する。開発者向けの検証画面はアプリ内に置かない
- 本人が選んだ休憩は、集中と同じ時間・状態だけのLive Activityでロック画面とDynamic Islandに残り時間を示し、終わると「休憩終了」とだけ表示する。次の集中を促す文言は置かない
- 回帰件数と成否はrelease candidateごとのXCTest／Swift Testing result bundleを正本とし、この文書へ固定件数を置かない。直近のopt-in 40年soakでは350,640 session・38,958 aggregate・120 achievement（計389,723行）を実SQLiteへ保存し、cold projectionは30 descriptor・queue 0・0.165秒、peak 73,420,256 Bだった。最終候補ではsplit store、rare release gate、direct deletion無効化を含む全suiteとRelease Simulator buildを再実行する
- 完走保存障害時、復元情報を保持してHomeへ退避し、常設カードから再試行。DEBUG限定の実save faultでrollback、raw 0→1行、再起動非重複を検証
- 結晶化保存障害時、source 10件の変更とaggregate挿入を同一transactionで完全rollbackし、常設カードから明示再試行。DEBUG限定の実save faultでloose 10件→aggregate 1件→再起動後も同一1件、2,500g、元source UUID集合の不変を検証
- 旧`SeedData.bootstrap`は本番呼び出しを持たない状態を維持。部分同期下で競合親を作り得る一括migrationは再有効化せず、既存配布storeを移行する場合だけ有界batch workerとして別途実装する
- Reduce Motionの有効・無効に関係なく、瓶の粒は同じ物理挙動で跳ね、落下し、傾きやシェイクにも反応する。Reduce Motionはカメラ、光、粒子、結晶形成などの装飾演出に適用し、質量・保存・Reward Receipt・結晶化の意味は変えない
- 最大文字サイズではOverviewのレンズをsegmented controlからmenu pickerへ切り替え、棚・要約・週KPIを1列化。Home／Menu／Overviewの主要画面はAX5の25監査とsystem Dynamic Type変更監査を通過

リリース前の最優先課題:

1. rare reward V2の試作と回帰testはsourceに保持するが、Apple Account binding、署名済み2台の
   分断・再接続、process kill、raw data access、production schema試験が未完了である。Version 1.0は
   `RareRewardReleasePolicy.isEnabled == false`に固定し、operations container、pending writer、設定UI、
   結果表示を出荷しない。以下は将来releaseで再検討する場合の設計記録である。

   最小反例は、旧状態が`端数200g / 金なし20回`の2台をオフラインにし、両方で50gずつ完走する場合である。各端末は同じ250g ordinalを消費して保証の金粒を一つずつ保存するが、正しい直列化は`合計300g / 金1回 / 次の端数50g`である。scalarの最大値は250g・端数0gとなって50gを失い、新規行の和100gは共有済み200gを失う。二つの保存済み金から、どちらを先のordinalとして残し、もう一方をどの自然抽選へ戻すかも事後には決定できない。`GachaHistoryReconciliationTests`にこの質量・保証双方の反例を固定し、現在のmergeをexactly-onceと誤認する変更を禁止する。

   V2の実装契約と残る実機受入条件は次の通りとする。

   - `iCloud.com.hinoshiba.pomogem.operations`のprivate database専用custom zoneに、reset epochごとに一つのepoch recordと、`epoch + StudySession UUID`を一意キーにした完走receiptを置く
   - epoch recordはmigration fingerprint、credit総質量、端数、次ordinal、金なし回数、抽選seed、revisionを保持する。receiptは参加有無、受理質量、割り当てordinal範囲、全結果、適用前後revisionを保持し、同じsession IDの再送を同じreceiptとして返す
   - epochのchange tagを取得してから、更新epochと新規receiptを同じzoneの一回のatomic saveへ入れ、`ifServerRecordUnchanged`で保存する。競合時は暫定値を捨ててserver recordを再取得し、同じsession IDのreceipt有無を確認してから再計算する。CloudKit custom zoneは同一zoneの複数recordを原子的に変更でき、change tag不一致を`serverRecordChanged`として拒否できる（[CKRecordZone](https://developer.apple.com/documentation/cloudkit/ckrecordzone)、[isAtomic](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/isatomic)、[ifServerRecordUnchanged](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/recordsavepolicy/ifserverrecordunchanged)）
   - 完全オフライン中はStudySessionとpending receiptだけを同一ローカルtransactionで保存し、未取得のserver ordinalをレア確定結果として表示・共有・集約しない。再接続後のatomic commitだけがレア結果のsource of truthになる
   - `off`も参加なしreceiptを残し、後日の設定変更で過去質量を抽選へ入れない。課金状態はepoch、receipt、seed、確率、保証の入力に含めない
   - active timerの通知・復元調停と、完走済みStudySessionの会計を分離する。異なるsession UUIDのoffline同時完走は両方をmeasured recordとして保持し、後着claimで遡及的に`timerDemoted`へ変更しない。同一session UUIDの再送だけを同じreceiptとして返すため、確定済みordinal・端数・pityを後から再編しない
   - 1.0は初回releaseのため、既に付与済みのStudySession上のrare表示を保持しつつ、merge不能な旧scalar端数／pityは全端末共通のzero baselineからV2を開始する。端末固有の旧値をfingerprintへ入れて永久不一致にしない。不正な非canonical fingerprintは最大値mergeせずfail closedにする
   - signed-in実機2台で、50g+50g、100g+150g、250g+250g、600g+600g、pity直前、同一session再送、順序反転、process kill、通信断、reset、異なるUUIDの重複時間帯を試し、両端末のreceipt集合、ordinal、端数、金なし回数、StudySession投影が一致するまで出荷blockerを解除しない
   - local outbox／cursorをactive Apple Accountへbindingし、account変更通知でwriterを停止・storeを隔離する。Aでpendingを残したままBへ切替えてBへ送られず、Aへ戻したときだけ再開する実機試験に合格するまで1.0でrare台帳を有効化しない
   - 将来のoperations raw epoch／receiptを現行11-model shipping exportへ含める方法を設計する。利用者copy取得方法または適用法令・Apple要件上の扱いを確定できなければrare台帳を有効化しない

2. 10→1の物理整理animationも回数由来なので、時間価値が同一でも短時間分割の方が多く見られる。主CTAや共有では質量を優先し、短い完走を反復させる文言を置かず、28日試験で時間帯・総時間を統制して分割率を監査する
3. Overviewのon-demand正確集計と同じepoch／UUID規則をLog／Share／Wrappedへ広げ、永続化summary + ページングへ発展させる（記録の月別合計はメインスレッド外の区間集計へ移行済み。今週／今月のページと最新30件は有界のままメインスレッドで読み、最新30件は今週／今月の切り替えでは読み直さない）
4. 実装済みの有界ModelActor maintenanceを、署名済み2台、長時間offline、process kill、production CloudKitでsmall-store oracleと同値検証する
5. 現在の年月ブラウザは選択期間を全件batch集計するため正確だが、毎回の再走査を避ける月・年summaryを保存し、CloudKit後着行で差分更新する
6. 中断tombstoneのオフラインoutboxと設定revision。現状は保存失敗時にタイマーを安全に継続し、outboxはオフラインでも終了意図を即時受理するためのUX改善とする
5. 同期の最終成功・待機・エラーをAccount可否と分けて表示
6. 手動追加Undo／2端末上限。保存直後の同一端末Undoも、同期済み`StudySession`行の物理削除では作らない。削除すると、その行を保持して表示中の画面（別端末、未更新の1.0.2を含む）でSwiftDataのmodelが無効になり、参照した時点で停止し得る。保存した端末でも、Homeが保持する行を先に外さないと同じ停止が起きることを2026-09-24にsimulatorで確認した。revision付きtombstone（schema追加）か、確認後の保存を数秒遅らせて取り消せる方式を選んでから実装する。成果の個別訂正・削除・同一端末Undoは実装済みのため、実CloudKit 2端末で同時編集、削除、旧複製の後着、Undo競合を検証する
7. 実CloudKit 2端末、実機VoiceOver、StoreKitを含む全主要E2E。AX5の25監査、system Dynamic Type、GIF生成・system cancel・コピー・一時ファイル削除はsimulator実UIで検証済み
8. 既存/TestFlight storeを対象にする場合は、停止中の旧`SeedData.bootstrap`を戻さず、競合親と欠落同期を扱える有界legacy migrationを追加
9. 本人が「いつ／どこで／何の後に、何を何分するか」を一件ずつ選択・編集・無効化できるif-then cue。空白後は失効表示をせず、「記録はそのまま」から再開する
10. 集約履歴のレア表現を、主要画面での単なる`containsRare`や一律glowから、保存済みの金／虹の実数と素材の脈へ発展させる。数が多いほど過剰に煽らず、内訳と可逆性を豊かにする
11. P0 fault injection。receipt保存失敗、破損UserDefaults、5件目の上限処理、着地marker前後のprocess kill、ackとactivity resetの競合、partial projection中の再起動で、重複保存・再抽選・誤削除がないことを検証する
12. 個人情報を含めない同意制の最小計測と、事前に指標・安全停止条件を固定した最低28日のC/D実験。現行`NoOpAnalytics`のまま効果を主張しない

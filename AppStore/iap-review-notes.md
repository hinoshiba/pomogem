# In-App Purchase review notes

Product: `com.hinoshiba.pomogem.pro.lifetime`

Candidate: 1.1.0 (10). The existing non-consumable gains unlimited learning-app selection.

Review image to refresh: `AppStore/screenshots/iap-review/01-pomogem-pro-live-price.png`
Historical image: `AppStore/screenshots/history/iap-review-20260906.png`
（1.0 build 5、実際のStoreKit商品価格を表示、購入未実行。候補の新しいPro機能の証拠にはしません。）
Type: Non-Consumable

## English (for App Review)

PomoGem Pro is a one-time, non-consumable purchase. It unlocks every other focus timer from
1 to 360 minutes beyond the free 25-, 45-, 60-, and 90-minute presets, plus month labels on
grouped pebbles, and an unlimited number of learning apps for Screen Time recording (five apps
on the free plan). Apps selected for black distraction gems are unlimited on both plans.
Share cards retain PomoGem branding for every user. There is no subscription,
free trial, external payment, account login, or custom purchase server.

Review steps:

1. On first launch, tap “iCloudに保存して同期”, then confirm with “確認して続ける”.
   (Choosing “このiPhoneだけに保存” also reaches the same app and purchase screen.)
2. On the optional trial-pebble page, tap “次へ” to skip it (or drop the pebble), then
   select one initial theme from the single combined study/work list. There is no purpose selector.
3. On Home, tap the top-right menu, then Settings.
4. In Settings, tap the entire “ポモジェムPro” row (the row has a chevron).
5. The paywall displays the storefront price returned by StoreKit. The link labeled
   “価格・提供条件・販売者情報を確認” opens the pre-purchase terms and seller information.
6. “購入を復元” (Restore Purchases) is at the bottom of the same screen.
7. On an authorized iPhone, Settings → “スクリーンタイム” → “勉強のgem” accepts up to five
   learning apps for free. After purchase or restore, more than five can be selected and saved.
   Category and website selections are not accepted. “黒いgem” app selection is unlimited without purchase.

Use the paywall showing the live `Product.displayPrice` as the IAP review screenshot.
The existing non-consumable was originally submitted with version 1.0; this candidate adds a benefit to the same product.
The Screen Time addition is part of the 1.1.0 candidate. It requires Family Controls distribution
approval for the host and monitor extension, plus signed-device verification before submission.
The historical review image above must be refreshed to include the added Pro feature.

## 日本語

ポモジェムProは1回限りの買い切りです。無料の25分・45分・60分・90分以外の任意の1〜360分タイマー、まとまり粒の月刻印、スクリーンタイムの勉強アプリ数無制限（無料5つ）を解放します。
黒いgem用のアプリ数は無料でも無制限です。
シェアカードのポモジェムロゴと公式サイトは、無料／Proとも常に表示します。subscription、trial、
外部決済、独自purchase serverはありません。

確認手順:

1. 初回起動時に「iCloudに保存して同期」→確認画面の「確認して続ける」を選びます。
   （「このiPhoneだけに保存」を選んでも、同じアプリ内購入画面へ進めます。）
2. 任意のためしの一粒は「次へ」で省略（または一粒を積む）し、勉強・仕事共通の一覧から最初の
   テーマを1つ選んでHomeを表示します。利用目的の選択はありません。
3. 右上の「メニュー」→「設定」を開きます。
4. 設定内の「ポモジェムPro」の行全体（右端に山形がある行）を選びます。
5. PaywallはStoreKitから取得したlocal priceを表示し、「価格・提供条件・販売者情報を確認」から
   購入前の販売条件を開けます。
6. 「購入を復元」は同じ画面の下部にあります。
7. 許可済みiPhoneで設定 →「スクリーンタイム」→「勉強のgem」を開き、無料では5アプリまで、
   購入・復元後は6アプリ以上を選択・保存できることを確認します。「黒いgem」は購入不要で無制限です。

スクリーンタイム追加は1.1.0候補です。提出前に本体・Monitor拡張のFamily Controls配布権限承認と
署名済み実機検証を行い、冒頭の過去の審査画像も新しいPro機能を含む画像へ更新します。

独自loginやreview用accountは不要です。初回提出はversion 1.0の履歴です。今回は既存商品を維持し、購入済み利用者にも追加機能を提供します。
Sandboxで購入、承認待ち、cancel、復元、revocationを確認し、審査用screenshotは上記paywallで
`Product.displayPrice`が表示された状態を使用します。

# In-App Purchase review notes

Product: `com.hinoshiba.tumiben.pro.lifetime`

Review image: `AppStore/screenshots/iap-review/01-tumiben-pro-live-price.png`
（1.0 build 4、実際のStoreKit商品価格を表示、購入未実行。出所は`screenshots/README.md`）
Type: Non-Consumable

## English (for App Review)

Tumiben Pro is a one-time, non-consumable purchase. It unlocks every other focus timer from
1 to 360 minutes beyond the free 25-, 45-, 60-, and 90-minute presets, plus month labels on
grouped pebbles. Share cards retain Tumiben branding for every user. There is no subscription,
free trial, external payment, account login, or custom purchase server.

Review steps:

1. On first launch, tap “iCloudに保存して同期”, then confirm with “確認して続ける”.
   (Choosing “このiPhoneだけに保存” also reaches the same app and purchase screen.)
2. On the optional trial-pebble page, tap “次へ” to skip it (or drop the pebble), then
   select one initial theme from the single combined study/work list. There is no purpose selector.
3. On Home, tap the top-right menu, then Settings.
4. In Settings, tap the entire “つみべんPro” row (the row has a chevron).
5. The paywall displays the storefront price returned by StoreKit. The link labeled
   “価格・提供条件・販売者情報を確認” opens the pre-purchase terms and seller information.
6. “購入を復元” (Restore Purchases) is at the bottom of the same screen.

Use the paywall showing the live `Product.displayPrice` as the IAP review screenshot.
The first non-consumable is submitted together with app version 1.0.

## 日本語

つみべんProは1回限りの買い切りです。無料の25分・45分・60分・90分以外の任意の1〜360分タイマーと、まとまり粒の月刻印を解放します。
シェアカードのつみべんロゴと公式サイトは、無料／Proとも常に表示します。subscription、trial、
外部決済、独自purchase serverはありません。

確認手順:

1. 初回起動時に「iCloudに保存して同期」→確認画面の「確認して続ける」を選びます。
   （「このiPhoneだけに保存」を選んでも、同じアプリ内購入画面へ進めます。）
2. 任意のためしの一粒は「次へ」で省略（または一粒を積む）し、勉強・仕事共通の一覧から最初の
   テーマを1つ選んでHomeを表示します。利用目的の選択はありません。
3. 右上の「メニュー」→「設定」を開きます。
4. 設定内の「つみべんPro」の行全体（右端に山形がある行）を選びます。
5. PaywallはStoreKitから取得したlocal priceを表示し、「価格・提供条件・販売者情報を確認」から
   購入前の販売条件を開けます。
6. 「購入を復元」は同じ画面の下部にあります。

独自loginやreview用accountは不要です。初回Non-Consumableなのでversion 1.0と同じsubmissionへ追加します。
Sandboxで購入、承認待ち、cancel、復元、revocationを確認し、審査用screenshotは上記paywallで
`Product.displayPrice`が表示された状態を使用します。

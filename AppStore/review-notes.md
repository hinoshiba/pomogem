# App Review notes draft

つみべんはアカウント登録不要のiPhone集中タイマーです。初回起動後、利用目的とテーマを選ぶと
Homeの大きなbuttonから25分または60分を開始できます。実時間を待たずに審査する必要がある場合、
審査側の標準的な時間操作を想定せず、実際のtimer flowを確認してください。hidden demo/debug menuは
Release buildにありません。

## In-App Purchase

- Product ID: `com.hinoshiba.tsumiben.pro.lifetime`
- Type: Non-Consumable
- Entry: Home menu → 時間を選ぶ → 任意時間、またはSettings → つみべんPro
- Unlocks: 1〜180分、まとまり粒の月刻印、share card右下の小さな透かし非表示
- Restore: purchase screenの「購入を復元」
- Subscription、trial、Web決済、外部purchase linkはありません

25分、60分、記録、iCloud同期、rare粒を含む瓶の基本体験はpurchase不要です。

## Rare visual rewards

実測した対象質量250gごとに、通常粒へgold 8%、prism 0.8%のvisual variant抽選があります。
goldは20回不発後の次回保証です。確率と保証はSettings内に表示します。利用者は標準、控えめ、
抽選しないをいつでも無料で選べます。購入で確率、保証、質量、機能価値は変わりません。rare粒は
購入、換金、交換、譲渡できず、機能的価値を持ちません。

## Apple services and permissions

- private CloudKit: 同じApple AccountのiPhone間で記録を同期。独自loginなし
- Notifications / Live Activity: timer終了。テーマ名は既定で非表示
- Motion: 端末の傾きで瓶の重力を計算。保存・送信なし
- Photos add-only: 利用者が静止画の保存を選んだ場合だけrequest
- StoreKit 2: productとverified entitlementの確認。独自purchase serverなし

計画modeは将来の積み上がりを一時的に表示する公開機能です。実記録、抽選、iCloud、Widgetへ
書き込みません。テストアカウントは不要です。

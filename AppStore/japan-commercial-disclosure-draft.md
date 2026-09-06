# Japan commercial disclosure decision — draft

Status: paid IAP selected by owner; disclosure page implemented locally. Operational verification remains required before release.
Scope: Non-Consumable `com.hinoshiba.pomogem.pro.lifetime`

この文書に個人の氏名、住所、電話番号は記録しません。公開pageは請求時開示方式を採用し、
`https://pomogem.hinoshiba.com/commercial-transactions/` と購入button前のApp内linkを実装済みです。
公開前に、ownerが実際の法定情報を安全に保持し、請求へ遅滞なく回答できる運用を確認します。
実運用のrelease gateは`Docs/COMMERCIAL_DISCLOSURE_OPERATIONS.md`を正本とします。

## Appleを介する範囲

日本のApp StoreではiTunes K.K.がdeveloperの代理人として購入の受付、決済、配信等を行いますが、
Apple Developer Program License Agreement Schedule 2 §1.1、§1.3、§4、§5によれば、これは
developer本人に代わる販売者情報開示窓口の指定ではありません。Appleの利用者向け規約も、Appleは
アプリプロバイダの代理人である一方、Appleと利用者が第三者アプリの売買／利用契約の当事者になる
わけではなく、現地法上の請求とサポートはアプリプロバイダの責任としています。

したがって、窓口は次のように分けます。

- App Storeでの購入手続、決済、購入履歴、請求書／領収書、返金申請: Apple
- Appの内容、動作、購入復元、販売事業者情報の開示: `support@hinoshiba.com`

消費者庁Q18がプラットフォームの住所／電話番号の表示を認めるのは、それらが当該販売者の取引上の
連絡先として機能するという当事者間の合意、platformによる本人情報の把握、確実な連絡体制等がある場合です。
Appleの標準契約と公開supportにはこの個別の連絡先代行合意を確認できないため、Appleへ開示請求を
転送しません。将来、Appleとの契約に明示的な変更があった場合だけ再評価します。

Webで常時公開する連絡先は`support@hinoshiba.com`だけとし、法定氏名／名称、住所、電話番号は
同メールへの購入前請求に対してdeveloperが遅滞なく個別開示します。ただし個人Developer Programの
App Store上のdeveloper nameは法的氏名となるApple仕様であり、製品page公開後は氏名自体がApp Storeで
表示されます。製品pageへのlinkは公開後に補足として追加できますが、請求時開示運用の代替にはしません。

## 公開事例の確認

2026-09-05に、個人／法人の第三者App 11件と簡略例1件を公開Webで確認しました。専用pageを確認できた
10件はすべて、価格、決済、解約または返金をApple／各storeへ案内する一方、販売者情報の連絡はdeveloperの
メールまたはformで受けていました。Appleを氏名／住所／電話番号の開示請求先として代用する例は0件でした。
個人運営で住所／電話番号を請求時開示にした例には
[Nomicho](https://nomicho.jp/tokusho)、[Virtu-ally](https://virtu-ally.app/ja/legal/tokushoho)、
[iruyo](https://iru-yo.com/tokushoho/)があります。これらは市場運用の観察であり、適法性の根拠にはしません。

## Why this is a release gate

Apple Developer Program License AgreementのIn-App Purchase条項3.2は、Appleがsystem UIを出す
部分を除き、購入UIと販売前に法律上必要な開示を提供する責任をdeveloperへ置いています。日本の
消費者庁「通信販売広告Q&A」は、有償serviceが通信販売規制の対象になり得ること、広告・申込段階で
必要事項を表示すること、個人事業者の屋号だけでは氏名／名称の表示にならないことを説明しています。

氏名、住所、電話番号、販売価格は、請求を受けたとき申込み判断前の十分な余裕をもって遅滞なく提供できる
実措置があり、その旨を広告へ表示する場合に省略可能とされています。文言を置くだけで、実際に
提供できない運用は採用しません。

## Decision A — paid IAP in 1.0

採用済みです。日本はJPY 100、米国はUSD 0.99を基準とし、その他の配信地域はAppleが生成する
現地相当額で提供します。App本体とIAPはいずれも148／175 storefrontで、現行EU 27（Austria、Belgium、
Bulgaria、Croatia、Cyprus、Czech Republic、Denmark、Estonia、Finland、France、Germany、Greece、Hungary、
Ireland、Italy、Latvia、Lithuania、Luxembourg、Malta、Netherlands、Poland、Portugal、Romania、Slovakia、
Slovenia、Spain、Sweden）を除外します。United Kingdom、Norway、Switzerlandは提供対象で、新しい
storefrontの自動追加は有効です。EU DSA release blockerはこの配信範囲によって解消していますが、
trader該当性についての法律判断ではありません。以下は公開前にも継続して確認する契約です。

owner／専門家が必要範囲を確定し、少なくとも次を利用者が購入前に到達できるpageへ明瞭に掲載します。

- 販売業者／役務提供事業者の法定氏名または名称
- 代表者または通信販売責任者（該当する場合）
- 現に活動する住所と確実に連絡できる電話番号、または適法な請求時開示の表示・手続
- 問い合わせ先と対応時間
- 販売価格（StoreKitとApp Storeの購入画面に購入時点で表示される価格）
- 価格以外に必要な費用（通信料等）
- 支払方法と支払時期（Apple Account／App Storeによる決済）
- 提供時期（決済完了後に直ちにentitlement反映、障害時の扱い）
- 申込み撤回、返品、返金、契約不適合時の扱いとAppleの返金窓口
- 1回限りのNon-Consumableで、自動更新／subscriptionではないこと
- 動作環境と提供機能

完成pageは`noindex`とし、Web footer／sitemap／READMEには掲載しません。一方、Proを案内する製品サイトの
該当箇所とpaywallの購入buttonより前には、内容が分かる見やすいlinkを置きます。App Storeのsystem
confirmationだけに依存せず、表示と実装を実機確認します。

## Decision B — free 1.0 without IAP

IAPを1.0から外し、Pro機能を無料開放または初版対象外としてproduct contract、StoreKit code／config、
metadata、Web、terms、screenshot、review notes、privacy、testを再監査します。単にApp Store Connectで
IAPを作らないまま課金buttonを残すことはしません。

## Primary references

- [Apple Developer Program License Agreement](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/), Schedule 2 §1.1、§1.3、§4、§5、In-App Purchase Attachment 2 §3.2
- [Appleメディアサービス利用規約](https://www.apple.com/jp/legal/internet-services/itunes/jp/terms.html)、App Storeの追加条項
- [Appleの返金手続](https://support.apple.com/ja-jp/118223)
- [Apple Developer nameの仕様](https://developer.apple.com/help/app-store-connect/create-an-app-record/set-your-developer-name/)
- [消費者庁 特定商取引法ガイド「通信販売広告Q&A」](https://www.no-trouble.caa.go.jp/qa/advertising.html) Q1、Q3〜Q18

このdraftは法律意見ではありません。

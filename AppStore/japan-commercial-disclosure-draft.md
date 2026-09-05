# Japan commercial disclosure decision — draft

Status: paid IAP selected by owner; disclosure page implemented locally. Operational verification remains required before release.
Scope: Non-Consumable `com.hinoshiba.tumiben.pro.lifetime`

この文書に個人の氏名、住所、電話番号は記録しません。公開pageは請求時開示方式を採用し、
`https://tumiben.hinoshiba.com/commercial-transactions/` と購入button前のApp内linkを実装済みです。
公開前に、ownerが実際の法定情報を安全に保持し、請求へ遅滞なく回答できる運用を確認します。
実運用のrelease gateは`Docs/COMMERCIAL_DISCLOSURE_OPERATIONS.md`を正本とします。

## Why this is a release gate

Apple Developer Program License AgreementのIn-App Purchase条項3.2は、Appleがsystem UIを出す
部分を除き、購入UIと販売前に法律上必要な開示を提供する責任をdeveloperへ置いています。日本の
消費者庁「通信販売広告Q&A」は、有償serviceが通信販売規制の対象になり得ること、広告・申込段階で
必要事項を表示すること、個人事業者の屋号だけでは氏名／名称の表示にならないことを説明しています。

氏名、住所、電話番号は、請求を受けたとき申込み判断前の十分な余裕をもって遅滞なく提供できる
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
- 販売価格（App Storeの購入画面に表示される税込価格）
- 価格以外に必要な費用（通信料等）
- 支払方法と支払時期（Apple Account／App Storeによる決済）
- 提供時期（決済完了後に直ちにentitlement反映、障害時の扱い）
- 申込み撤回、返品、返金、契約不適合時の扱いとAppleの返金窓口
- 1回限りのNon-Consumableで、自動更新／subscriptionではないこと
- 動作環境と提供機能

完成pageのURLをWeb footer、App Store descriptionまたはsupport、そしてpaywallの購入buttonより前の
見やすいlinkへ追加します。App Storeのsystem confirmationだけに依存せず、表示と実装を実機確認します。

## Decision B — free 1.0 without IAP

IAPを1.0から外し、Pro機能を無料開放または初版対象外としてproduct contract、StoreKit code／config、
metadata、Web、terms、screenshot、review notes、privacy、testを再監査します。単にApp Store Connectで
IAPを作らないまま課金buttonを残すことはしません。

## Primary references

- Apple Developer Program License Agreement, In-App Purchase Attachment 2 §3.2
- 消費者庁 特定商取引法ガイド「通信販売広告Q&A」Q1、Q3〜Q18

このdraftは法律意見ではありません。

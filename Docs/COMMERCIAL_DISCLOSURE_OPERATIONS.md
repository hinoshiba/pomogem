# 有料IAPの販売者情報開示運用

更新日: 2026-09-05

この文書は公開repositoryへ個人情報を置かず、`ポモジェムPro`の購入前に請求された販売者情報を
実際に開示できるようにし、配信対象地域の価格・提供地域を誤表示しないための運用契約です。法律意見
ではありません。対象法令・事業形態に応じ、必要なら専門家へ確認します。

## 非公開で保持する正本

Account Holderは次をアクセス制御された非公開の保管先へ保持し、変更時に更新します。

- 法定氏名または名称
- 現に活動する住所
- 確実に連絡できる電話番号
- 代表者または通信販売責任者（該当する場合）
- App Store上の販売主体と一致することを確認した記録

これらをsource、Issue、Actions log、App Store review notesへ転記しません。

## 開示請求の処理

1. `support@hinoshiba.com`で、件名「販売事業者情報の開示請求」を受信できることを毎release前に試験する。
2. 自動応答または一次返信で受領を通知し、購入は開示情報の受領・確認後に行えることを案内する。
3. 法定氏名、住所、電話番号、請求時点の販売価格その他必要事項を、購入判断に間に合うよう遅滞なく返信する。
4. 本人確認を過剰に要求せず、開示請求へ集中記録やデータ書き出しの添付を求めない。
5. 請求メールはプライバシーポリシーのサポートメール保持期間に従って削除し、広告・分析へ利用しない。

Appleへ転送するのではなく、販売主体であるdeveloperが上記メールから直接回答します。Appleの住所、
電話番号またはsupportを販売者の連絡先として表示するのは、Appleとの間にその連絡先が本Appの取引上の
連絡先として機能する旨の明示的な合意を確認できた場合だけです。通常のPaid Applications Agreement上の
「代理人」という文言だけでは、その合意があるものと扱いません。

## 問い合わせの振り分け

- 販売事業者情報の開示、Appの内容／動作、購入復元: `support@hinoshiba.com`で直接対応
- App Store決済、購入履歴、請求書／領収書: Appleの購入履歴／請求supportへ案内
- 返金申請: Appleの[返金手続](https://support.apple.com/ja-jp/118223)へ案内

分類に迷う問い合わせはまず受領し、Appleへ案内する場合も、販売事業者情報の開示請求やApp側の問題を
未回答のまま転送しません。

## Release gate

次のすべてを確認するまで日本で有料IAPを販売しません。

- 販売者情報URLがHTTPSで表示でき、Pro案内とアプリの購入前案内からだけリンクされ、グローバルheader／footer／sitemapには掲載されず`noindex`である
- Paywallの購入buttonより前に販売条件linkがあり、VoiceOverでも到達できる
- 日本でApp Store Connectに設定した価格が、App内のStoreKit `displayPrice`およびApp Store購入確認画面と一致し、公開Webに固定金額がない
- 上記の非公開正本が揃っている
- 開示請求の送受信試験と、担当者不在時の代替手順が完了している
- 返金案内がAppleの現行窓口へ到達する

App Store公開後は実際の製品pageを開き、developer name、価格表示、Support URLを確認します。製品pageの
linkをWebへ補足追加する場合は、公開済みHTTPS URLであることを確認してから行い、販売事業者情報の
請求時開示手続の代替とは表示しません。個人accountではdeveloper nameに法的氏名が表示されるため、
その公開範囲をAccount Holderが公開前に認識していることも確認します。

## 配信対象地域の価格・提供地域gate

次もApp Store Connect保存後にstorefrontを切り替えて確認します。

- App本体は無料、IAPはNon-Consumable 1商品だけで、AppとIAPのavailabilityが現行EU 27を除く
  148／175 Countries or Regions
- 米国はUSD 0.99の利用可能なprice pointを基準、日本だけJPY 100のcustom price
- その他の国・地域はUSD 0.99を基準にAppleが生成する現地相当額で、固定の「1ドル」や為替換算額を
  metadata、Web、binaryへ埋め込まない
- Paywallと購入buttonは常にStoreKitの`Product.displayPrice`を表示し、App Storeの確認画面と一致
- Account HolderがEU DSA trader statusを自己評価し、traderなら必要な連絡先をApp Store Connectで
  検証・公開。non-traderなら判断根拠とproduct page表示を非公開release recordへ残す
- 日本語UI／supportのまま配信対象地域へ提供すること、地域ごとのconsumer対応、税、制裁、返金問い合わせを
  運営者が受け入れ、対応不能地域があれば公開前にavailabilityを限定する

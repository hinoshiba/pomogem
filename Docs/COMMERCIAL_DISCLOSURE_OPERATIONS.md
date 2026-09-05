# 有料IAPの販売者情報開示運用

更新日: 2026-09-04

この文書は公開repositoryへ個人情報を置かず、`つみべんPro`の購入前に請求された販売者情報を
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
3. 法定氏名、住所、電話番号その他必要事項を、購入判断に間に合うよう遅滞なく返信する。
4. 本人確認を過剰に要求せず、開示請求へ集中記録やデータ書き出しの添付を求めない。
5. 請求メールはプライバシーポリシーのサポートメール保持期間に従って削除し、広告・分析へ利用しない。

## Release gate

次のすべてを確認するまで日本で有料IAPを販売しません。

- 公開された販売条件URLがHTTPSで表示できる
- Paywallの購入buttonより前に販売条件linkがあり、VoiceOverでも到達できる
- 日本の表示価格がJPY 100で、App内はStoreKitの`displayPrice`と一致する
- 上記の非公開正本が揃っている
- 開示請求の送受信試験と、担当者不在時の代替手順が完了している
- 返金案内がAppleの現行窓口へ到達する

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

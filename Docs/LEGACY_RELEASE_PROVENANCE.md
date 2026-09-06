# 旧製品の来歴（現行リリースの合格証拠には使わない）

更新日: 2026-09-06

この文書に限り、旧名称・旧識別子・実在する過去artifact名を履歴として記録します。
現行製品の名前はPomoGem／ポモジェムです。名称変更に伴い新しいアプリを作る判断をしたため、
旧recordの保存済みmetadataや署名済みbuildを、新製品の準備完了とは扱いません。

## 旧製品の識別子

| 対象 | 旧製品の履歴 |
|---|---|
| 名称・表記 | Tumiben／Tsumiben／つみべん |
| App Store numeric ID | `6806758060` |
| IAP review record numeric ID | `6808533188` |
| App bundle ID | `com.hinoshiba.tumiben` |
| Widget bundle ID | `com.hinoshiba.tumiben.widgets` |
| CloudKit container | `iCloud.com.hinoshiba.tumiben` |
| IAP product ID | `com.hinoshiba.tumiben.pro.lifetime` |
| Website | `tumiben.hinoshiba.com` |
| GitHub repository | `hinoshiba/Tumiben` |

旧app record、IAP、containerの削除・resetは改名工程に含めません。新アプリは別sandbox・別購入権利・
別CloudKit containerを使い、自動移行や共有を実装していません。旧identifierが存在することを、
新appのentitlement、schema、StoreKit商品、購入復元の検証に代用しません。

## 過去の作業と証拠範囲

- 初回OSS公開前、約4.1 GBのDerivedDataとArtifactsをrepository外の
  `Tsumiben-local-artifacts-20260902`へ退避しました。この名前は実在した退避先の来歴です。
  build log、個人用path、Simulator診断、署名済みbinaryを公開sourceへ戻しません。
- 初回OSS公開時は監査済みtreeからrepositoryを初期化しました。今回のPomoGemへのrepository改名は
  既存Git履歴を保持し、再初期化しません。2026-09-06のowner指定メールへの履歴正規化は
  `OSS_PUBLISHING.md`に記録しています。
- 旧appにはbuild 1のupload履歴があります。旧build 3の配布操作についてownerから申告があり、
  旧build 4の開発署名Archiveとraw検証を実施しました。これらはPomoGemのbuildではありません。
- 旧candidate commit `172678e`のversion 1.0 (4)は、2026-09-06に署名なしRelease Archiveを作成して
  製品構造を確認しました。新Bundle IDへ変更したversion 1.0 (5)は、別の固定commitで再build・
  署名・配布検証する必要があります。
- 旧appで取得したlisting 5枚とIAPの実商品価格画像、および旧App Store Connect recordへの
  metadata保存は新製品の審査画像や新商品の価格取得を証明しません。画像台帳は新captureの実体と
  hashが確定してから更新します。
- 2026-09-03〜05の旧domainのHTTPS、header、DNS測定は新domainの配信証拠ではありません。
  `pomogem.hinoshiba.com`をdeployした後に直接HTTPS 200、各policy URLと画像、所有確認を再測定します。
- 2026-09-05以前のunit／UI／soakの成功件数は前身のsourceに対する結果です。改名後のmodule、
  notification、Widget、StoreKit、CloudKit、URL schemeを新candidateで再検証します。

## 素材と名称の権利

文字を含まないFocus Cycle v5 iconは2026-09-05に本プロジェクトの前身向けに制作し、PomoGemでも
継続使用します。改名時に新規生成したとは記録しません。詳細は`Brand/APP_ICON.md`と
`ASSET_LICENSES.md`を参照します。

上記の旧名称、旧logo、旧Store／Web素材にも、`TRADEMARKS.md`と`ASSET_LICENSES.md`と同じ
rights-reservedの方針を適用します。履歴を公開することは、第三者に旧製品の名称・素材を使った
公式版を装う権利を与えません。

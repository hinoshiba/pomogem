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

改名工程中は旧app record、IAP、containerを保持しました。後続の明示依頼による旧登録の整理結果は下記を参照してください。新アプリは別sandbox・別購入権利・
別CloudKit containerを使い、自動移行や共有を実装していません。旧identifierが存在することを、
新appのentitlement、schema、StoreKit商品、購入復元の検証に代用しません。

## 後続依頼による旧登録の整理（2026-09-06）

PomoGemの審査提出後、ユーザーから旧TumibenのIDとアプリ登録の削除を明示依頼されました。

- 旧IAPの未提出審査下書きを解除し、旧アプリ本体と旧IAPを全地域で配信停止。
- App Store Connectの旧アプリ `6806758060` は削除済み。旧登録画面が編集不可となり、
  「アプリを復元」が表示されることを確認しました（Appleの削除済みアプリへ移動）。
- 旧Widget App ID `com.hinoshiba.tumiben.widgets` は削除し、DeveloperのID一覧からの消失を確認。
- 旧本体App ID `com.hinoshiba.tumiben` はAppleが削除を拒否。旧アプリ登録の削除後も
  App Storeで使用中との応答が続きました。アップロード済みの明示App IDは削除できないという
  [Appleの制約](https://developer.apple.com/help/account/identifiers/delete-an-app-id/)に該当します。
  削除成功として扱わず、IDは残っています。
- 旧CloudKit containerと保存済みデータには削除・resetを行っていません。
- PomoGemの本体／Widget IDは存在し、アプリ1.0 (5)とProの審査待ちも維持されています。

参照: [Appleのアプリ登録削除手順](https://developer.apple.com/help/app-store-connect/create-an-app-record/remove-an-app/)。

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

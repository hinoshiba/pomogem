# App Store source of truth

このfolderはApp Store Connectへ入力する内容と提出判断のsource of truthです。App Store Connect
APIのcredentialやdownloadしたprofileは置きません。

- `configuration.yml`: product identifierと提供範囲
- `connect-entry-plan.md`: App Store Connectへ保存するfield値と未完了項目
- `metadata/ja-JP/`: 日本語listing原稿
- `metadata/en-US/`: 全世界配信用の英語listing原稿（App UI／supportが日本語である旨を明記）
- `screenshots/`: production UIをDebug-only deterministic fixtureでcaptureした提出予定画像と再現手順
- `review-notes-connect.txt`: App Store Connectへ貼り付ける4,000文字以内のApp Review notes正本
- `review-notes.md`: App Review確認と実機検証の詳細版
- `iap-review-notes-connect.txt`: App Store Connectへ貼り付けるIAP Review notes正本
- `iap-review-notes.md`: Non-Consumable審査とSandbox検証の詳細版
- `app-privacy.md`: App Privacy回答の根拠
- `age-rating.md`: 年齢区分回答の根拠
- `export-compliance.md`: 暗号化回答の根拠
- `japan-commercial-disclosure-draft.md`: 日本向け有料IAPの法定表示判断と公開前gate
- `submission-checklist.md`: versionごとの提出gate
- `release-experience-review.md`: 掲載文・導線・アクセシビリティのリリース前評価と実機確認項目

2026-09-06に新ブランド・新IDのPomoGem 1.0 (5)へ更新しました。掲載文の正本は
`metadata/`です。旧アプリのApp Store Connect登録、アップロード、課金価格、CloudKit schemaは
新アプリの完了証拠には使いません。2026-09-06に新App Store record（Apple ID `6809139517`、
SKU `pomogem-ios`、bundle ID `com.hinoshiba.pomogem`、日本語名「ポモジェム：ポモドーロタイマー」）を
作成・確認し、実値を`configuration.yml`へ記録しました。2026-09-13に日本・米国の公開listingで
1.0.1の配信を確認しました。[App Store](https://apps.apple.com/app/id6809139517)へのリンクと
Smart App BannerをWebに表示し、`app_store_listing_status: public`とします。
これは当時の確認記録です。2026-09-22にApp Store Connectで1.0.2 (9)のReady for Distributionを
確認しました。現在の掲載文は次の1.1.0 (10)候補用で、1.1.0のdraftは作成済みですがbinaryは未uploadです。
Family Controlsの配布権限と最終署名済み候補での実到達は未確認で、旧版の提出結果を流用しません。

現在の掲載画像5枚とIAP審査画像は2026-09-22に1.1.0 (10)から撮り直しました。実行結果とhashは
`screenshots/README.md`に記録しています。実StoreKit表示価格は$0.99（storefront国は未確認）で、
`review_screenshot_status: captured_live_price`です。購入・復元の成功や署名済み実機との表示一致は未確認です。
旧IAP画像はupload対象外の`history/`に保存しています。現在の準備状態は
`release-record-1.1.0-10.md`を参照してください。
過去のDeveloper Portal確認ではmain／Widget App IDとCloudKit containerの登録・hostへの割当を確認しました。
この登録はProduction schemaのdeployや配布署名の完了を意味しません。新IDの署名・実機表示・Sandbox・
CloudKit Production・Connectの残りの提出内容の保存と再読み込みは別途必須です。
過去のアーカイブ等の来歴は`Docs/LEGACY_RELEASE_PROVENANCE.md`に分離しています。

App Store Connectのcopyright欄は`configuration.yml`の`2026 hinoshiba`を正本とし、アプリ内の
表示、Info.plist、Web footer、repository licenseと一致させます。

## Screenshot

掲載用screenshotはproduction UIを架空dataのDebug-only deterministic fixtureでcaptureし、
今回のConnect draftで使用している6.5-inch枠へ1284×2778で書き出しています。
これはsigned Release binaryの同一表示を証明しないため、提出前に署名済みRelease実機と全画面を比較し、
差があれば再captureします。status bar、通知、顧客名、個人情報も確認します。画面内にPro機能がある
場合は追加購入であることをmetadataでも明確にします。

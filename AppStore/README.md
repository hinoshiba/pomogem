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

既存のApp Store Connect record（Apple ID `6806758060`、bundle ID
`com.hinoshiba.tumiben`）を公式recordとして使用します。WebにはこのIDのSmart App Banner metadataを
掲載しますが、App Store上で公開されるまではdownload buttonを有効化しません。

App Store Connectのcopyright欄は`configuration.yml`の`2026 hinoshiba`を正本とし、アプリ内の
表示、Info.plist、Web footer、repository licenseと一致させます。

## Screenshot

初回提出用screenshotはproduction UIを架空dataのDebug-only deterministic fixtureでcaptureし、
App Store Connectがversion 1.0で要求する6.5-inch枠（1242×2688または1284×2778）へ書き出します。
これはsigned Release binaryの同一表示を証明しないため、提出前に署名済みRelease実機と全画面を比較し、
差があれば再captureします。status bar、通知、顧客名、個人情報も確認します。画面内にPro機能がある
場合は追加購入であることをmetadataでも明確にします。

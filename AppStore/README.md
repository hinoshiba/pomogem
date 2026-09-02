# App Store source of truth

このfolderはApp Store Connectへ入力する内容と提出判断のsource of truthです。App Store Connect
APIのcredentialやdownloadしたprofileは置きません。

- `configuration.yml`: product identifierと提供範囲
- `metadata/ja-JP/`: 日本語listing原稿
- `review-notes.md`: App Review向けの操作説明
- `app-privacy.md`: App Privacy回答の根拠
- `age-rating.md`: 年齢区分回答の根拠
- `export-compliance.md`: 暗号化回答の根拠
- `submission-checklist.md`: versionごとの提出gate

App Store IDはrecord作成後にこの文書へ追加します。ID未確定の間はSmart App BannerやApp Store
download linkをWebへ掲載しません。

App Store Connectのcopyright欄は`configuration.yml`の`2026 hinoshiba`を正本とし、アプリ内の
表示、Info.plist、Web footer、repository licenseと一致させます。

## Screenshot

初回提出用screenshotはまだ未配置です。実際のRelease candidateをiPhone 15以降のSimulatorまたは
実機でcaptureし、App Store Connectがその時点で受け付ける寸法へ書き出します。fixtureは架空の
テーマ・成果だけを使い、status bar、通知、顧客名、個人情報を確認します。画面内にPro機能がある
場合は追加購入であることをmetadataでも明確にします。

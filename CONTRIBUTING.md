# Contributing

ポモジェムを改善していただき、ありがとうございます。

1. 同じ内容のissueがないか確認してください。
2. 大きな機能、課金、確率、同期model、permission、network、dependency、ブランド変更は、実装前にissueで相談してください。
3. 1つのPRは1つの目的に絞ってください。
4. `project.yml`を正本とし、`xcodegen generate`後のproject差分も含めてください。
5. UI変更はiPhone 15以降のsize、Dynamic Type、VoiceOver、Reduce Motion、暗色のcontrastを確認してください。
6. 時間・質量・レア抽選・融合を変更する場合は、不変条件と公平性のtest、`Docs/EngagementArchitecture.md`を更新してください。
7. CloudKit、StoreKit、通知、写真、モーション、共有を変更する場合は`PRIVACY.md`、Privacy Manifest、App Store資料を再監査してください。
8. dependencyやassetには再配布・商用利用できる根拠を付け、`THIRD_PARTY_NOTICES.md`または`ASSET_LICENSES.md`を更新してください。
9. 画面の文言を追加・変更する場合は`Docs/Localization.md`に従い、ファイルごとに決まったテーブルを
   `String(localized:table:comment:)`または`Text(_:tableName:)`で指定してください。日本語が原文です。
   保存・同期するデータやアクセシビリティ識別子は翻訳しません。UI testの起動は
   `PomoGemUITestLanguage.configureJapanese(app)`を通してください。

提出前に次を実行します。

```sh
./Scripts/check-oss-readiness.sh --current
python3 Scripts/validate-site.py
python3 Scripts/l10n/l10n.py check
xcodegen generate
```

署名なしSimulator buildとunit testも実行してください。重い40年soakは関連変更時だけ明示的に
有効化します。実際の集中テーマ、顧客名、案件名、スクリーンショット、CloudKit dataをpublic
issueやPRへ貼らないでください。

証明書、秘密鍵、provisioning profile、App Store Connect key、Keychain、`.xcarchive`、`.ipa`、
署名済みappは絶対に追加・送付しないでください。公式archiveはmaintainerの許可済みMacと
Keychainでのみ作成します。

Contributionを提出する人は、その内容を提出する権利があり、ソース部分を本リポジトリの
MIT Licenseで提供することに同意するものとします。名称・brand assetは`TRADEMARKS.md`に
従います。

開発とリリースにはローカルのXcodeを使用します。PRのCIは署名なしのビルドと検証を行い、
maintainerのApple Accountやcredentialを必要としません。変更後は関連する検証を実行し、
差分を確認してgit commitとgit pushを行い、共通PRテンプレートで提出してください。
プロジェクトの公開連絡先は`support@hinoshiba.com`です。maintainerのcommit／annotated tagには
公開承認済みの`kai.openclaw01@gmail.com`を使用できます。連絡先とcommit identityは別に扱います。
外部contributorは公開用のメールまたはGitHubのnoreplyメールを使用してください。未承認の個人用
メールproviderのアドレスは検査で止まるため、その場合はGitHubのnoreplyメールを使用します。
履歴を含む公開監査は`./Scripts/check-oss-readiness.sh`で別途実行します。

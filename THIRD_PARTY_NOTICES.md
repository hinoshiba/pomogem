# Third-party notices

## アプリに同梱する第三者素材

### Zen Maru Gothic

- Copyright 2021 The Zen Maru Gothic Project Authors
- License: SIL Open Font License 1.1
- Files: `PomoGem/Resources/Fonts/ZenMaruGothic-Black.ttf`、Web用コピー
- License text: `LICENSE-fonts.txt`

第三者の解析、広告、SNS、ネットワーク、課金SDKは同梱していません。CloudKit、StoreKit、
SwiftData、SpriteKit、WidgetKit、ActivityKit、Photos、Core Motion、AVFoundation、Core Haptics、UserNotificationsなどは
AppleのSDK／OS機能としてAppleの契約に従い、Appleプラットフォーム上だけで利用します。
システムフォントとSF SymbolsもAppleの提供機能として表示し、フォントやSymbol画像を抽出して
同梱、再配布、アプリアイコンや商標へ利用しません。これらをMITとして再許諾しません。

製品サイトはGitHub Pagesで配信します。将来CDN、リバースプロキシ、解析など別の配信事業者を
追加する場合は、運用開始前にこの台帳、`PRIVACY.md`、公開プライバシーポリシーを更新します。

## 開発時だけ使うツール

| Tool | 固定版 | License | 用途 |
|---|---:|---|---|
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | 2.45.4 | MIT | `project.yml`からXcode projectを生成 |
| [ripgrep](https://github.com/BurntSushi/ripgrep) | 15.2.0 | Unlicense / MIT | 公開候補の内容・履歴scan |
| [actionlint](https://github.com/rhysd/actionlint) | 1.7.12 | MIT | GitHub Actions workflowのlint |
| [actions/checkout](https://github.com/actions/checkout) | v7.0.1のcommit固定 | MIT | CI／Pagesでsourceを取得 |
| [actions/configure-pages](https://github.com/actions/configure-pages) | v6.0.0のcommit固定 | MIT | Pages設定 |
| [actions/upload-pages-artifact](https://github.com/actions/upload-pages-artifact) | v5.0.0のcommit固定 | MIT | `http_dists`だけをPages artifact化 |
| [actions/deploy-pages](https://github.com/actions/deploy-pages) | v5.0.0のcommit固定 | MIT | Pagesへdeploy |

開発ツールは配布アプリへ同梱しません。依存、フォント、画像、音、データセット、SDKを
追加した場合は、この台帳、Privacy Manifest、App Privacy、asset licenseを同時に更新します。

設計文書で参照する研究や公的資料は、事実と知見を独自に要約して出典へlinkしています。
論文本文、図表、データセット、団体logoをアプリやrepositoryへ転載・同梱していません。

# Third-party notices

## アプリに同梱する第三者素材

### Zen Maru Gothic

- Copyright 2021 The Zen Maru Gothic Project Authors
- License: SIL Open Font License 1.1
- Files: `Tsumiben/Resources/Fonts/ZenMaruGothic-Black.ttf`、Web用コピー
- License text: `LICENSE-fonts.txt`

第三者の解析、広告、SNS、ネットワーク、課金SDKは同梱していません。CloudKit、StoreKit、
SwiftData、SpriteKit、WidgetKit、ActivityKit、Photos、Core Motion、UserNotificationsなどは
AppleのOS/frameworkとして利用します。

## 開発時だけ使うツール

| Tool | 固定版 | License | 用途 |
|---|---:|---|---|
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | 2.45.4 | MIT | `project.yml`からXcode projectを生成 |

開発ツールは配布アプリへ同梱しません。依存、フォント、画像、音、データセット、SDKを
追加した場合は、この台帳、Privacy Manifest、App Privacy、asset licenseを同時に更新します。

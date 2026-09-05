# Asset license register

この台帳は、ソースコードのMIT Licenseとは別に扱う画像・フォントを記録します。
ハッシュは公開直前に`Scripts/check-oss-readiness.sh`で再確認します。

## 適用範囲

- ソースコードと通常文書には`LICENSE`のMIT Licenseが適用されます。
- Zen Maru GothicにはSIL Open Font License 1.1が適用されます。全文は
  `LICENSE-fonts.txt`を参照してください。
- 下表で「All rights reserved」とした「つみべん」「Tumiben」「Tsumiben」固有の視覚素材は
  MIT Licenseの対象外です。著作権とブランド上の権利はhinoshibaが留保します。

この台帳の第三者向け限定許諾は、権利者であるhinoshiba自身による公式アプリ、公式Web、
App Store素材の制作、公開、販売を制限するものではありません。

## 未改変素材の開発用限定許諾

権利者は、下表で「All rights reserved」とした素材について、次の目的に限り、素材を
未改変のままsource checkout／forkの一部として保持・複製し、公開source forkの一部として
公衆送信し、または一時的な非公開build／test生成物へ組み込む、世界的・非独占的・無償の
限定許諾を付与します。

- このリポジトリを取得またはforkすること
- ローカルでbuild・testすること
- CI、code review、issue／pull requestの検証、contributionを行うこと

公開するsource forkに素材を残す場合は、この台帳と`TRADEMARKS.md`を保持し、forkが
非公式であることを明確にしてください。この許諾は、素材の改変・抽出再利用、素材を含む
アプリ／Webサイト／配布package／公開build artifactの公開・販売、マーケティング利用、
または公式版・公認・提携と誤認させる表示を許可しません。CIの生成物は一時的な検証用、
または公開されないreview用に限ります。

改変版アプリを第三者へ配布する場合は、配布前に対象のブランド素材を自作物へ置き換えるか、
権利者から別途書面による許可を得てください。この限定許諾は、名称やロゴを商標として使う
権利を付与しません。

| 素材 | 場所 | 出所 | 配布条件 | SHA-256 |
|---|---|---|---|---|
| つみべん App Icon（Focus Cycle v5、active） | `Tsumiben/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-FocusCycle-v5.png` | Tumiben独自のv4 iconとpaletteを基に、本プロジェクト向けにCodex built-in ImageGenで再設計し、人が選定・調整 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `1c8c4ac81b99a2201fdaa3a723ca2e76ee08350970f3243053d0d8b4d37ae15e` |
| App Icon高解像度source（Focus Cycle v5、active） | `Brand/AppIcon-FocusCycle-v5-source.png` | 上記の生成source | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `9b83d0ac419add475e4e3cf4ff42dabb7bb7340a4a59eddfe6dcdeb2dd5859cc` |
| Web App Icon（Focus Cycle v5、active） | `http_dists/public/app-icon-focus-v5.png` | active App Iconの256px Web用派生画像 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `a0ee59d504570ad0ce53c2710b2c2114a2518d7ee10e098d1e5787943d19add7` |
| Apple Touch Icon（Focus Cycle v5、active） | `http_dists/public/apple-touch-icon.png` | active App Iconの180px Web用派生画像 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `50dda39716f125b546d72f379192318530df845f4205fbdb240f55d5564a453a` |
| Web OG画像（focus v6、active） | `http_dists/og-focus-v6.png` | hinoshiba保有の旧OG v5へactive App IconをSharpで決定論的に合成し、sRGB／RGB／opaqueへ正規化 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `ce639d897fe02d352118d09de83f66f334509e46dcea0ea451a0d873be6e4f7f` |
| 旧App Icon高解像度source（Focus Vessel v4） | `Brand/AppIcon-FocusVessel-v4-source.png` | 本プロジェクト向けにAI支援で生成し、人が選定・調整 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `b60d2fe464f4460702be923976c5865dfca487b189072ac249638eac1e1ec1ca` |
| 旧Web App Icon（focus v4） | `http_dists/public/app-icon-focus-v4.png` | 旧App IconのWeb用派生画像 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `05ac0bbdc58cfa85d23d5b01cf2a3d38dc0d89016ee33fa1a940cef1e1a7c469` |
| 旧Web OG画像（focus v5） | `http_dists/og-focus-v5.png` | 旧ブランド素材と実アプリ画面から作成 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `09e0544c3af28dec0b24b95b34503727357f7bf53e28d4d8697a2e876aa7896f` |
| 旧App Icon比較素材 | `Brand/AppIcon-Aurora-v3-legacy.png` | 本プロジェクト向けにAI支援で生成 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `30d8c4b856a46dc87a00c5c09861df6a008ffce8092a0a3f72bea4b074e3a4f8` |
| Aurora背景 | `Tsumiben/Resources/Assets.xcassets/focus.aurora.imageset/focus-aurora.png` | 本プロジェクト向けにAI支援で生成し、人が選定・調整 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `b6a9e5e324e13978eeb0806ce051ca51304571d4fb22544916c55cc8350a8e66` |
| Webアプリ画面 | `http_dists/public/app-home-current.webp` | 実アプリ画面から作成 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `28a3a322c560fabbff571a3fb399346fbf8298120891f50f93f6a61f5df2df66` |
| App Store画面 01 | `AppStore/screenshots/ja-JP/01-home-with-first-pebble.png` | production UIをDebug-only deterministic fixtureでcapture | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `384b21cd2b8ff67b3d78f79f4bb46b7a3b00d29dbbbbb7bf3f25aa5681cb6628` |
| App Store画面 02 | `AppStore/screenshots/ja-JP/02-25-minute-focus.png` | production UIをDebug-only deterministic fixtureでcapture | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `c87133a22d632ab4a2d65b1d55bd8ca448346689fb131efc7ca0d3836d999948` |
| App Store画面 03 | `AppStore/screenshots/ja-JP/03-completion-reward.png` | production UIをDebug-only deterministic fixtureでcapture | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `8bebfb530daf4d46c41bdca9365159888ccaa0edb9545523fa883b0c2182b466` |
| App Store画面 04 | `AppStore/screenshots/ja-JP/04-accumulation-overview.png` | production UIをDebug-only deterministic fixtureでcapture | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `89f57ad1ec230413a8cdde94117554b2a9b5410bd624efde29baca31685ef886` |
| App Store画面 05 | `AppStore/screenshots/ja-JP/05-iCloud-and-privacy.png` | production UIをDebug-only deterministic fixtureでcapture | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `39ab5a8b4ae79e267ec1110635cf29916370b6c9ab7df3193530264ed5bd7a9a` |
| Zen Maru Gothic Black | `Tsumiben/Resources/Fonts/ZenMaruGothic-Black.ttf`、`http_dists/public/ZenMaruGothic-Black.ttf` | Copyright 2021 The Zen Maru Gothic Project Authors | SIL Open Font License 1.1。`LICENSE-fonts.txt`参照 | `6bd74fe76cd39ee0ec18775c3661d845343fb3f6f8fa09a3076638417baf741f` |

生成経緯とpromptの要約は`Tsumiben/Resources/GENERATED-ASSETS.md`に記録しています。
SF Symbolsは`Image(systemName:)`で参照し、書き出したSymbol画像を同梱していません。

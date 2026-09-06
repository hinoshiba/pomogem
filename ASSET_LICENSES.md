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
| Web OG画像（focus v7、active） | `http_dists/og-focus-v7.png` | active App IconとOFLのZen Maru GothicをSharpで決定論的に合成し、ポモドーロタイマー×集中記録の訴求へ更新 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `db51b5fed769d18eb99cae48ef437f6485311c17e0c191e33cb183d9a3653ad4` |
| Webホーム画面（v2、active） | `http_dists/public/app-home-v2.webp` | App Store画面01をcwebpで603×1305へ縮小 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `f819951afc8a9f60abd18c4540ea18d796fbebf3244aaa1ee013850e33b60f33` |
| Webタイマー画面（v1、active） | `http_dists/public/app-timer-v1.webp` | App Store画面02をcwebpで603×1305へ縮小 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `7d66a2be14844d67cb2c0c51639fe6d7205c6ff90a678dda45422bf7c810750a` |
| 旧App Icon高解像度source（Focus Vessel v4） | `Brand/AppIcon-FocusVessel-v4-source.png` | 本プロジェクト向けにAI支援で生成し、人が選定・調整 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `b60d2fe464f4460702be923976c5865dfca487b189072ac249638eac1e1ec1ca` |
| 旧Web App Icon（focus v4） | `http_dists/public/app-icon-focus-v4.png` | 旧App IconのWeb用派生画像 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `05ac0bbdc58cfa85d23d5b01cf2a3d38dc0d89016ee33fa1a940cef1e1a7c469` |
| 旧Web OG画像（focus v6） | `http_dists/og-focus-v6.png` | 旧OG v5へactive App IconをSharpで決定論的に合成した旧訴求画像 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `ce639d897fe02d352118d09de83f66f334509e46dcea0ea451a0d873be6e4f7f` |
| 旧Web OG画像（focus v5） | `http_dists/og-focus-v5.png` | 旧ブランド素材と実アプリ画面から作成 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `09e0544c3af28dec0b24b95b34503727357f7bf53e28d4d8697a2e876aa7896f` |
| 旧App Icon比較素材 | `Brand/AppIcon-Aurora-v3-legacy.png` | 本プロジェクト向けにAI支援で生成 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `30d8c4b856a46dc87a00c5c09861df6a008ffce8092a0a3f72bea4b074e3a4f8` |
| Aurora背景 | `Tsumiben/Resources/Assets.xcassets/focus.aurora.imageset/focus-aurora.png` | 本プロジェクト向けにAI支援で生成し、人が選定・調整 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `b6a9e5e324e13978eeb0806ce051ca51304571d4fb22544916c55cc8350a8e66` |
| 旧Webホーム画面 | `http_dists/public/app-home-current.webp` | 実アプリ画面から作成。Web上の参照はv2へ移行済み | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `28a3a322c560fabbff571a3fb399346fbf8298120891f50f93f6a61f5df2df66` |
| App Store画面 01 | `AppStore/screenshots/ja-JP/01-home-with-first-pebble.png` | version 1.0 (4)のproduction UIをDebug-only deterministic fixtureでcapture | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `5c7a093ae749a354512fe4a82f21861f60b3f33ffdf9a031625b1acb8dbcb629` |
| App Store画面 02 | `AppStore/screenshots/ja-JP/02-25-minute-focus.png` | version 1.0 (4)のproduction UIをDebug-only deterministic fixtureでcapture | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `962c5fb13046560d265bc6c4eca354481b6ead5cc489b0a3c8e8cc8aca6bb657` |
| App Store画面 03 | `AppStore/screenshots/ja-JP/03-completion-reward.png` | version 1.0 (4)のproduction UIをDebug-only deterministic fixtureでcapture | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `8cbdd99b4a7218c4ff05df7313abf48e9ca80d690e3578e70835c2ed5cef67c1` |
| App Store画面 04 | `AppStore/screenshots/ja-JP/04-accumulation-overview.png` | version 1.0 (4)のproduction UIをDebug-only deterministic fixtureでcapture | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `77a59f13e47a27e92c21505fc91255a6a99c3a9ae772f231e59badba9ea02eed` |
| App Store画面 05 | `AppStore/screenshots/ja-JP/05-iCloud-and-privacy.png` | version 1.0 (4)のproduction UIをDebug-only deterministic fixtureでcapture | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `8c5afaba9317c5e03e30c6609d4642e5718c62da5dac54442fd64dabba915c4f` |
| IAP審査画面 | `AppStore/screenshots/iap-review/01-tumiben-pro-live-price.png` | version 1.0 (4)のproduction UIでStoreKitの実商品価格を表示してcapture。購入未実行、価格加工なし | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `9a6107604fc9228f5e5ac257f424277758459c1d055e126f311ee91b83661bc6` |
| Zen Maru Gothic Black | `Tsumiben/Resources/Fonts/ZenMaruGothic-Black.ttf`、`http_dists/public/ZenMaruGothic-Black.ttf` | Copyright 2021 The Zen Maru Gothic Project Authors | SIL Open Font License 1.1。`LICENSE-fonts.txt`参照 | `6bd74fe76cd39ee0ec18775c3661d845343fb3f6f8fa09a3076638417baf741f` |

生成経緯とpromptの要約は`Tsumiben/Resources/GENERATED-ASSETS.md`に記録しています。
SF Symbolsは`Image(systemName:)`で参照し、書き出したSymbol画像を同梱していません。

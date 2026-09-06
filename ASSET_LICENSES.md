# Asset license register

この台帳は、ソースコードのMIT Licenseとは別に扱う画像・フォントを記録します。
ハッシュは公開直前に`Scripts/check-oss-readiness.sh`で再確認します。

## 適用範囲

- ソースコードと通常文書には`LICENSE`のMIT Licenseが適用されます。
- Zen Maru GothicにはSIL Open Font License 1.1が適用されます。全文は
  `LICENSE-fonts.txt`を参照してください。
- 下表で「All rights reserved」とした「ポモジェム」「PomoGem」固有の視覚素材は
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

PomoGemへの改名時点では、文字を含まない既存iconとAurora背景を継続使用します。
listing 5枚はPomoGem 1.0 (5)から新規captureし、XCTestのRGB PNG添付を無加工でコピーしています。
署名済みRelease実機とのparityは別のrelease gateで確認します。
IAP審査画像は、2026-09-06にPomoGem 1.0 (5)の新商品を実際のProduct.productsで取得し、
StoreKit設定ファイルなしでUS storefrontの実価格$0.99を表示して撮影しました。日本語UIの
1284×2778 RGB PNGを無加工でコピーし、目視とhashを確認しています。購入自体は実行していません。
旧商品の画像や仮価格の画像は使わず、購入・復元・署名済み実機・提出の検証は別に行います。

| 素材 | 場所 | 出所 | 配布条件 | SHA-256 |
|---|---|---|---|---|
| ポモジェム App Icon（Focus Cycle v5、active） | `PomoGem/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-FocusCycle-v5.png` | 本プロジェクトの前身で制作したv4 iconとpaletteを基に、本プロジェクト向けにCodex built-in ImageGenで再設計し、人が選定・調整 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `1c8c4ac81b99a2201fdaa3a723ca2e76ee08350970f3243053d0d8b4d37ae15e` |
| App Icon高解像度source（Focus Cycle v5、active） | `Brand/AppIcon-FocusCycle-v5-source.png` | 上記の生成source | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `9b83d0ac419add475e4e3cf4ff42dabb7bb7340a4a59eddfe6dcdeb2dd5859cc` |
| Web App Icon（Focus Cycle v5、active） | `http_dists/public/app-icon-focus-v5.png` | active App Iconの256px Web用派生画像 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `a0ee59d504570ad0ce53c2710b2c2114a2518d7ee10e098d1e5787943d19add7` |
| Apple Touch Icon（Focus Cycle v5、active） | `http_dists/public/apple-touch-icon.png` | active App Iconの180px Web用派生画像 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `50dda39716f125b546d72f379192318530df845f4205fbdb240f55d5564a453a` |
| Web OG画像（PomoGem v1、active） | `http_dists/og-pomogem-v1.png` | 本プロジェクトのHTML/CSS原稿 Brand/og-pomogem.html と既存icon・OFL fontをブラウザーで1200×630に描画・capture後、sipsでJPEGからPNGへ形式のみ変換。2026-09-06に新名称・domain・訴求を目視確認。新規ImageGen素材ではない | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `a434e1526f860cc2765ec4a02fae07e151edf3d239b8be053e66a7eaf27fee99` |
| Webホーム画面（v3、active） | `http_dists/public/app-home-v3.webp` | PomoGem 1.0 (5)の新App Store画面01から cwebp -q 85 -m 6 -resize 603 0 で603×1305へ縮小 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `e36fad494ed4223b21f518d68b5aad1649dc893a94b402442d2dc8a3bddc896a` |
| Webタイマー画面（v2、active） | `http_dists/public/app-timer-v2.webp` | PomoGem 1.0 (5)の新App Store画面02から cwebp -q 85 -m 6 -resize 603 0 で603×1305へ縮小 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `24a79a83b7fb5cbc58aad0dc304d8b02c920ca611d7953bca511d2e42173ee77` |
| 旧App Icon高解像度source（Focus Vessel v4） | `Brand/AppIcon-FocusVessel-v4-source.png` | 本プロジェクト向けにAI支援で生成し、人が選定・調整 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `b60d2fe464f4460702be923976c5865dfca487b189072ac249638eac1e1ec1ca` |
| 旧App Icon比較素材 | `Brand/AppIcon-Aurora-v3-legacy.png` | 本プロジェクト向けにAI支援で生成 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `30d8c4b856a46dc87a00c5c09861df6a008ffce8092a0a3f72bea4b074e3a4f8` |
| Aurora背景 | `PomoGem/Resources/Assets.xcassets/focus.aurora.imageset/focus-aurora.png` | 本プロジェクト向けにAI支援で生成し、人が選定・調整 | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `b6a9e5e324e13978eeb0806ce051ca51304571d4fb22544916c55cc8350a8e66` |
| App Store画面 01 | `AppStore/screenshots/ja-JP/01-home-with-first-pebble.png` | PomoGem 1.0 (5)のproduction UIをDebug-only deterministic fixtureで2026-09-06に新規capture。XCTest添付PNGを無加工でコピー。詳細は AppStore/screenshots/README.md | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `c4d5200526bcd629561c7be909ae7563d753071446de111772b59f6bdef06e50` |
| App Store画面 02 | `AppStore/screenshots/ja-JP/02-25-minute-focus.png` | PomoGem 1.0 (5)のproduction UIをDebug-only deterministic fixtureで2026-09-06に新規capture。XCTest添付PNGを無加工でコピー。詳細は AppStore/screenshots/README.md | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `a226fbe8844c33d044b281f4ef3ee557a17cea398db4d104607de6d985d96b60` |
| App Store画面 03 | `AppStore/screenshots/ja-JP/03-completion-reward.png` | PomoGem 1.0 (5)のproduction UIをDebug-only deterministic fixtureで2026-09-06に新規capture。XCTest添付PNGを無加工でコピー。詳細は AppStore/screenshots/README.md | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `8cbdd99b4a7218c4ff05df7313abf48e9ca80d690e3578e70835c2ed5cef67c1` |
| App Store画面 04 | `AppStore/screenshots/ja-JP/04-accumulation-overview.png` | PomoGem 1.0 (5)のproduction UIをDebug-only deterministic fixtureで2026-09-06に新規capture。XCTest添付PNGを無加工でコピー。詳細は AppStore/screenshots/README.md | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `77a59f13e47a27e92c21505fc91255a6a99c3a9ae772f231e59badba9ea02eed` |
| App Store画面 05 | `AppStore/screenshots/ja-JP/05-iCloud-and-privacy.png` | PomoGem 1.0 (5)のproduction UIをDebug-only deterministic fixtureで2026-09-06に新規capture。XCTest添付PNGを無加工でコピー。詳細は AppStore/screenshots/README.md | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `0aaaf14b32c8b5834cbf9bd2eadbe1fff37f59409cdf818bb0471f87356cf97d` |
| IAP審査画面 | `AppStore/screenshots/iap-review/01-pomogem-pro-live-price.png` | PomoGem 1.0 (5)のproduction UIで新商品の実StoreKit価格を2026-09-06にcapture。Product.products、StoreKit設定なし、JA UI／US storefront $0.99。購入未実行、1284×2778 RGB PNGを無加工でコピー。詳細は AppStore/screenshots/README.md | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `d1cba699d99ef7f34cebe0e1261f7fd6616003138a4c01aa9e0ded2555aa52c0` |
| Zen Maru Gothic Black | `PomoGem/Resources/Fonts/ZenMaruGothic-Black.ttf`、`http_dists/public/ZenMaruGothic-Black.ttf` | Copyright 2021 The Zen Maru Gothic Project Authors | SIL Open Font License 1.1。`LICENSE-fonts.txt`参照 | `6bd74fe76cd39ee0ec18775c3661d845343fb3f6f8fa09a3076638417baf741f` |

生成経緯とpromptの要約は`PomoGem/Resources/GENERATED-ASSETS.md`に記録しています。
SF Symbolsは`Image(systemName:)`で参照し、書き出したSymbol画像を同梱していません。

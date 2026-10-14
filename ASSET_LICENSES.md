# Asset license register

この台帳は、画像・フォントごとの出所とライセンスを記録します。
ハッシュは公開直前に`Scripts/check-oss-readiness.sh`で再確認します。

## 適用範囲

- ソースコードと通常文書には`LICENSE`のMIT Licenseが適用されます。
- 下表で「MIT License」としたタイマー方向の説明用画面画像9枚について、本プロジェクトが
  保有する権利を`LICENSE`のMIT Licenseで許諾します。ブランド素材向けの開発用限定許諾は
  この9枚には適用しません。フォントやAppleの素材自体を再許諾するものではありません。
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
現在の日英listing各5枚は2026-09-30にPomoGem 1.1.0 (10)からcaptureし、XCTestのRGB PNG添付を無加工でコピーしています。
署名済みRelease実機とのparityは別のrelease gateで確認します。
現在のIAP審査画像は2026-10-01に1.1.0 (10)の現行Pro画面を実際のProduct.productsで取得し、
StoreKit設定ファイルなしで実表示価格$0.99を撮影しました。storefront国は未確認です。日本語UIの
1284×2778 RGB PNGを無加工でコピーし、目視とhashを確認しています。購入・復元は実行していません。
2026-09-06の1.0 (5)の画像はhistory内に来歴として保持し、今回のuploadには使いません。
購入・復元・署名済み実機・提出の検証は別に行います。

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
| App Store画面 01 | `AppStore/screenshots/ja-JP/01-home-with-first-pebble.png` | PomoGem 1.1.1 (13)のja-JP production UIをDebug-only deterministic fixtureで2026-10-12にcapture。XCTest添付PNGを無加工でコピー。詳細は AppStore/screenshots/README.md | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `1b34c8ffb88da0610cffd5ab4b5008ac077385b10656bb3927e68f48ecb2910b` |
| App Store画面 02 | `AppStore/screenshots/ja-JP/02-25-minute-focus.png` | PomoGem 1.1.1 (13)のja-JP production UIをDebug-only deterministic fixtureで2026-10-12にcapture。XCTest添付PNGを無加工でコピー。詳細は AppStore/screenshots/README.md | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `643b2673445b2d0ff3e46b127e2470df1cbeaf79a40e4880e0b99427e4574a4e` |
| App Store画面 03 | `AppStore/screenshots/ja-JP/03-completion-reward.png` | PomoGem 1.1.1 (13)のja-JP production UIをDebug-only deterministic fixtureで2026-10-12にcapture。XCTest添付PNGを無加工でコピー。詳細は AppStore/screenshots/README.md | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `83471bca8ee1360cda3fb9ef4ea1c67b61741aa3689233a690d49978e0a62724` |
| App Store画面 04 | `AppStore/screenshots/ja-JP/04-accumulation-overview.png` | PomoGem 1.1.1 (13)のja-JP production UIをDebug-only deterministic fixtureで2026-10-12にcapture。XCTest添付PNGを無加工でコピー。詳細は AppStore/screenshots/README.md | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `8fbce542464a070854577e98d7d894f753913048111280de397f25cac4b41197` |
| App Store画面 05 | `AppStore/screenshots/ja-JP/05-timer-display.png` | PomoGem 1.1.1 (13)のja-JP production UIをDebug-only deterministic fixtureで2026-10-12にcapture。XCTest添付PNGを無加工でコピー。詳細は AppStore/screenshots/README.md | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `143fd8714761d9b81c03dec00f6d2af936436c299e394b9a8ff01715ffe809ac` |
| App Store画面 EN 01 | `AppStore/screenshots/en-US/01-home-with-first-pebble.png` | PomoGem 1.1.1 (13)のen-US production UIをDebug-only deterministic fixtureで2026-10-12にcapture。XCTest添付PNGを無加工でコピー。詳細は AppStore/screenshots/README.md | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `1b87a9221c132a6a554e036fa415a4df253c544800e2c0f128bcb932376c3788` |
| App Store画面 EN 02 | `AppStore/screenshots/en-US/02-25-minute-focus.png` | PomoGem 1.1.1 (13)のen-US production UIをDebug-only deterministic fixtureで2026-10-12にcapture。XCTest添付PNGを無加工でコピー。詳細は AppStore/screenshots/README.md | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `56f0f50dba32af4a784f15c8f092747089d207305b97e59a74b9e4fb0b7f08e9` |
| App Store画面 EN 03 | `AppStore/screenshots/en-US/03-completion-reward.png` | PomoGem 1.1.1 (13)のen-US production UIをDebug-only deterministic fixtureで2026-10-12にcapture。XCTest添付PNGを無加工でコピー。詳細は AppStore/screenshots/README.md | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `8d420c06177b32ffa39f934075e0bf899cd8c8286d24515f12caf8e0a6b43e37` |
| App Store画面 EN 04 | `AppStore/screenshots/en-US/04-accumulation-overview.png` | PomoGem 1.1.1 (13)のen-US production UIをDebug-only deterministic fixtureで2026-10-12にcapture。XCTest添付PNGを無加工でコピー。詳細は AppStore/screenshots/README.md | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `24c605cae61ae243ac68354327afda8cb542fc8abff586f39871b39da4be6207` |
| App Store画面 EN 05 | `AppStore/screenshots/en-US/05-timer-display.png` | PomoGem 1.1.1 (13)のen-US production UIをDebug-only deterministic fixtureで2026-10-12にcapture。XCTest添付PNGを無加工でコピー。詳細は AppStore/screenshots/README.md | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `832a87d0e702ca9d975d1674a48fad3c3525d5357e46723e8cbea37671a0cbed` |
| IAP審査画面 | `AppStore/screenshots/iap-review/01-pomogem-pro-live-price.png` | PomoGem 1.1.1 (13)のja-JP production paywallを2026-10-12にcapture。実StoreKit価格$0.99（storefront国未確認）、月刻印なしの2機能、購入・復元なし。XCTest添付PNGを無加工でコピー。詳細は AppStore/screenshots/README.md | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `0c7ef153e90c8022a946dc4e5c69212e8073ac33bd6e62b03410175e4892ec1d` |
| 過去のIAP審査画面 | `AppStore/screenshots/history/iap-review-20260906.png` | PomoGem 1.0 (5)のproduction UIで新商品の実StoreKit価格を2026-09-06にcapture。Product.products、StoreKit設定なし、JA UI／US storefront $0.99。購入未実行、1284×2778 RGB PNGを無加工でコピー。詳細は AppStore/screenshots/README.md | Copyright 2026 hinoshiba. All rights reserved. MIT対象外 | `d1cba699d99ef7f34cebe0e1261f7fd6616003138a4c01aa9e0ded2555aa52c0` |
| Zen Maru Gothic Black | `PomoGem/Resources/Fonts/ZenMaruGothic-Black.ttf`、`http_dists/public/ZenMaruGothic-Black.ttf` | Copyright 2021 The Zen Maru Gothic Project Authors | SIL Open Font License 1.1。`LICENSE-fonts.txt`参照 | `6bd74fe76cd39ee0ec18775c3661d845343fb3f6f8fa09a3076638417baf741f` |
| タイマー既定方向の設定画面 | `Docs/images/timer-orientation/default-orientation-settings.png` | 2026-09-09、iPhone 17 Pro / iOS 26.5 Simulatorの実UIをXCTestでcapture。テスト専用の空の保存領域を使用、加工・合成なし。詳細は Docs/TimerOrientation.md | Copyright 2026 hinoshiba. MIT License（本プロジェクトが保有する権利） | `c40006bc617c4f1d44accc932a02ec92089146655d963cc7a172e825dd41ba78` |
| 集中タイマー・上 | `Docs/images/timer-orientation/timer-up.png` | 2026-09-09、iPhone 17 Pro / iOS 26.5 Simulatorの実UIをXCTestでcapture。テスト専用の空の保存領域と初期テーマ「英語」を使用、加工・合成なし。詳細は Docs/TimerOrientation.md | Copyright 2026 hinoshiba. MIT License（本プロジェクトが保有する権利） | `964d36dd4a65cf12e94c9066bdf41c4dd7a7051f0713d663919ecacd9bffea99` |
| 集中タイマー・右 | `Docs/images/timer-orientation/timer-right.png` | 2026-09-09、iPhone 17 Pro / iOS 26.5 Simulatorの実UIをXCTestでcapture。テスト専用の空の保存領域と初期テーマ「英語」を使用、加工・合成なし。詳細は Docs/TimerOrientation.md | Copyright 2026 hinoshiba. MIT License（本プロジェクトが保有する権利） | `bd8ecfc38f16bd4dbc58eba7be33cc079f349d93e599c6b794e149ea5d2bb50d` |
| 集中タイマー・下 | `Docs/images/timer-orientation/timer-down.png` | 2026-09-09、iPhone 17 Pro / iOS 26.5 Simulatorの実UIをXCTestでcapture。テスト専用の空の保存領域と初期テーマ「英語」を使用、加工・合成なし。詳細は Docs/TimerOrientation.md | Copyright 2026 hinoshiba. MIT License（本プロジェクトが保有する権利） | `f6569b315513ac91fdf8304b4768c7892418a23b498a976c995b9a61ce8e83de` |
| 集中タイマー・左 | `Docs/images/timer-orientation/timer-left.png` | 2026-09-09、iPhone 17 Pro / iOS 26.5 Simulatorの実UIをXCTestでcapture。テスト専用の空の保存領域と初期テーマ「英語」を使用、加工・合成なし。詳細は Docs/TimerOrientation.md | Copyright 2026 hinoshiba. MIT License（本プロジェクトが保有する権利） | `444ff92eaa283f2ab8c7c6fb7a3c8bbed14e2adc373310360273155f82b96818` |
| 休憩タイマー・上 | `Docs/images/timer-orientation/break-up.png` | 2026-09-09、iPhone 17 Pro / iOS 26.5 Simulatorの実UIをXCTestでcapture。テスト専用の空の保存領域と初期テーマ「英語」を使用、加工・合成なし。詳細は Docs/TimerOrientation.md | Copyright 2026 hinoshiba. MIT License（本プロジェクトが保有する権利） | `34457201d06351eb8364545edcce124d3a085f87f594bd137f723820d21e030c` |
| 休憩タイマー・右 | `Docs/images/timer-orientation/break-right.png` | 2026-09-09、iPhone 17 Pro / iOS 26.5 Simulatorの実UIをXCTestでcapture。テスト専用の空の保存領域と初期テーマ「英語」を使用、加工・合成なし。詳細は Docs/TimerOrientation.md | Copyright 2026 hinoshiba. MIT License（本プロジェクトが保有する権利） | `6b7bfbef91884aed505ebb937d84214fc75435e644af4a1304cf623293bed245` |
| 休憩タイマー・下 | `Docs/images/timer-orientation/break-down.png` | 2026-09-09、iPhone 17 Pro / iOS 26.5 Simulatorの実UIをXCTestでcapture。テスト専用の空の保存領域と初期テーマ「英語」を使用、加工・合成なし。詳細は Docs/TimerOrientation.md | Copyright 2026 hinoshiba. MIT License（本プロジェクトが保有する権利） | `f7973db86f9ccb3278b1a61c2c8b95649d42cb3273b0849546be51c2b258ce3e` |
| 休憩タイマー・左 | `Docs/images/timer-orientation/break-left.png` | 2026-09-09、iPhone 17 Pro / iOS 26.5 Simulatorの実UIをXCTestでcapture。テスト専用の空の保存領域と初期テーマ「英語」を使用、加工・合成なし。詳細は Docs/TimerOrientation.md | Copyright 2026 hinoshiba. MIT License（本プロジェクトが保有する権利） | `482cc6fb71c22e66886db4f38a4641648ad5c2154c2420dce658bb448f3f805e` |

## 音

アプリが鳴らす音（瓶の効果音、タイマー終了の音、終了アラーム8種）は、すべてsource code内の
数式から実行時に合成します。録音、第三者のsample、AHAP、生成AI音源、音声ファイルは同梱せず、
`Scripts/check-oss-readiness.sh`がtreeとGit履歴の音声ファイルを拒否します。音はsourceと同じ
MIT Licenseの対象で、商用利用できます。

- 終了アラームの「ベル」「デジタル」「マリンバ」「学校のチャイム」「目覚まし時計」は
  `PomoGem/Core/Alarm/AlarmSoundSynthesis.swift`のFM・modal・加算合成です。既存の3種は
  `PomoGem/Juice/SoundSynth.swift`の音を音量だけ上げて使います。
- 「学校のチャイム」の旋律はWestminster Quarters（1793年）で、著作権の保護期間を過ぎた
  public domainの旋律です。音名から独自に実装し、録音、楽譜の版、編曲物は参照していません。
- 通知とAlarmKitが鳴らすCAFは、端末上で`Library/Sounds`へ書き出す生成物です。repositoryにも
  app bundleにも含めず、backupの対象外にしています。

AI生成素材の生成経緯とpromptの要約は`PomoGem/Resources/GENERATED-ASSETS.md`に記録しています。
SF Symbolsは`Image(systemName:)`で参照し、書き出したSymbol画像を同梱していません。

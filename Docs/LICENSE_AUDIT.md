# License and commercial distribution audit

更新日: 2026-09-06（名称・識別子変更に伴うrelease gateの更新。過去の監査証拠は再取得していません）

## Conclusion

現行構成は、MITでのsource公開と、hinoshibaによるApp Store公式binaryの商用配布に対応します。
有料利用を禁止するruntime license、第三者SDK、binary frameworkは検出していません。ただし、これは
技術・license台帳の監査記録であり、法律意見ではありません。権利帰属、商標、Apple account、
App Store提出状態に関する未確認事項は、下記release gateを完了するまで配布可否を確定しません。

現行の製品契約は「無料download＋1回限りのNon-Consumable IAP」です。有料download型へ変更する
場合は、価格、metadata、Web、StoreKit、審査資料を別の製品判断として再監査します。
AppとIAPは現行EU 27を除く148／175 Countries or Regionsへ提供し、IAPは米国USD 0.99を基準、
日本JPY 100をcustom price、その他をAppleの現地相当額とする方針です。実際の購入表示は
StoreKitの`displayPrice`を正本とします。

| Component | Version / source | App binaryへ同梱 | License / status | Decision |
|---|---|---:|---|---|
| PomoGem Swift sourceと通常文書 | repository | yes | MIT, Copyright 2026 hinoshiba | 商用利用・OSS公開可 |
| Runtime第三者package／SDK | none | no | n/a | 検出なし |
| Zen Maru Gothic Black | upstream font、SHA-256を台帳固定 | yes | SIL Open Font License 1.1 | 有償appへのbundle可。license全文を同梱 |
| Apple SDK frameworks | Xcode 26 SDK | platform-linked | Apple agreements | Apple platform app内だけで利用 |
| SF Symbols／system fonts | OS／SDK | system描画 | Apple terms | UIだけ。logo／iconへ未使用 |
| 瓶・タイマーの効果音／触覚 | app sourceによる実行時生成 | binaryにsource logicのみ | Swift sourceはMIT、Apple framework | AVFoundationで数学的にPCM生成。ロック中の通知音も同じPCMを端末内`Library/Sounds`へCAF化し、Core Hapticsはsource内patternを使用。第三者sample、録音、AHAP、生成AI音源なし |
| App icon、Aurora背景、Web／Store画像 | `ASSET_LICENSES.md` | yes／Web配信 | hinoshiba rights reserved、MIT対象外 | hinoshiba公式版は配布可。第三者forkは置換または許可が必要 |
| StoreKit Non-Consumable | `com.hinoshiba.pomogem.pro.lifetime` | service連携 | Apple StoreKit | digital機能unlockとしてIAPを使用 |
| GitHub Pages | 製品Web配信 | no | service terms | app binary外。privacy policyへ処理を開示 |
| XcodeGen、ripgrep、actionlint、GitHub Actions | `THIRD_PARTY_NOTICES.md` | no | 各OSS license | build／CI時だけ利用 |
| 研究・公的資料 | 設計文書のlink | no | 原資料ごとの条件 | 独自要約。本文、図表、dataset、logoを同梱しない |

## Rights and provenance

- `LICENSE`のMIT grantはsourceと通常文書に適用し、fontと固有brand assetは明示的に除外します。
- `ASSET_LICENSES.md`は全ての同梱・公開画像をorigin、条件、SHA-256で固定します。
- AI支援生成画像の生成経緯と人による選定・調整は`PomoGem/Resources/GENERATED-ASSETS.md`へ記録します。
  生成serviceの規約だけで第三者権利の不存在や排他的著作権を保証できないため、maintainerは全ての
  reference inputを所有または適法に利用できることをreleaseごとに確認します。
- 現在のGit履歴はhinoshibaだけですが、初回commit以前のsource、文書、assetについて、雇用主、
  顧客、共同制作者、過去projectの秘密情報・codeを含まないことを権利者が別途確認します。
- `ポモジェム`／`PomoGem`と類似称呼の名称台帳・正式な商標調査は、
  copyright/license監査とは別に行います。

## Policy for new dependencies and assets

原則許容候補はMIT、Apache-2.0、BSD-2/3-Clause、ISC、Zlib、CC0、fontのOFL-1.1です。
GPL、AGPL、LGPL、MPL、CC BY-SA、ODbL、proprietary SDK、custom license、AI生成素材、
copied textはmaintainerの明示review対象です。No License、研究・教育・個人利用限定、CC BY-NC、
CC BY-ND、SSPL、BUSL、Commons Clause、出所不明・scraped assetは配布候補へ追加しません。

## Commercial release gate

各releaseで次を実施します。

1. SPM、CocoaPods、binary framework、font、image、sound、model、dataset、copied text、Web serviceを棚卸しする。
2. exact version、official origin、license、binary inclusion、商用配布条件を記録する。
3. OFL全文のapp bundle同梱、アプリ内表示、全固有asset hashを検証する。
4. 追加source／assetとAI reference inputの権利をmaintainerが確認する。
5. Paid Apps Agreement、税務・銀行情報、実IAP、App Store ID、screenshot、privacy回答を完了する。
6. `AppStore/configuration.yml`の`release_blockers`を実装とtestで空にする。
7. StoreKit Sandboxで購入、pending、cancel、復元、revocation、権利反映後のtransaction finishを確認する。
8. `./Scripts/check-oss-readiness.sh --release`、Release build、unit／UI test、archive validationを通す。
9. 公開Privacy／Support／Termsと購入前案内専用の販売者情報URL、GitHub Pages公開状態、HTTPS redirectを実配信で照合する。
10. App Storeへ送ったsource commitを固定tagにし、この監査を同じtagへ残す。

## Current no-go items

- 新App Store recordはApple ID `6809139517`として2026-09-06に作成・確認し、host／Widget App IDと
  CloudKit containerの登録・hostへの割当も確認した。新IAP、価格、配布署名、提出は未完了。
  旧版の署名・upload・metadata保存結果は新appの証拠に使わず、`Docs/LEGACY_RELEASE_PROVENANCE.md`
  に区別する。最終7-model schemaのproduction deployと、署名済み2台の同期品質確認も未完了。
- rare reward V2の試作はsourceに保持するが、local outbox／cursorのApple Account bindingとA→B→A
  切替隔離が未解決のため、version 1.0ではrelease policy、shipping schema、entitlement、UI、runtime
  repository経路から無効化済み。将来有効化する場合は別releaseとして再監査する。
- direct CloudKit一括削除の試作にはApple Account bindingと複数worker直列化の未解決riskがあるため、
  `CompleteDataDeletionReleasePolicy.isEnabled == false`として1.0のUI／launch pathから除外済み。1.0は
  通常reset、app削除、AppleのiCloudストレージ管理を案内する。
- PomoGem 1.0 (5)のlisting 5枚は2026-09-06に新規captureし、画像台帳へhashを固定した。新商品の
  IAP実価格画像は未取得。Debug fixtureでのcaptureは署名済みRelease実機のvisual parityを証明せず、
  Sandbox／TestFlight試験も別途必要。
- 日本向け有料IAPの販売主体と特商法上の表示要否・購入前開示について、owner／専門家の判断と
  実運用が未完了。
- Apple側の契約・税務・銀行情報はaccount単位で照合する。新recordの年齢区分、価格、提供148地域、
  IAP localization／review screenshot／tax、App Privacy、category、listing／review metadata、buildを
  保存し、reload後の値を確認する。旧recordへの保存履歴を完了根拠にしない。
- EU DSAのVersion 1.0方針は現行EU 27をApp／IAPの提供対象外にする。新recordへ同じ設定を反映した
  ことを確認するまで地域設定のgateを完了しない。残る148地域のconsumer、tax、制裁、support運用は
  Account Holderが公開前に確認する。
- 全pre-Git code／asset、AI inputのowner sign-offと正式な名称・商標調査が未完了。

Materialな不確実性が残る場合は、qualified counselまたは各権利者の確認が終わるまでreleaseを止めます。

## Primary references

- [MIT License — Open Source Initiative](https://opensource.org/license/mit)
- [Zen Maru Gothic OFL text — upstream repository](https://github.com/googlefonts/zen-marugothic/blob/main/OFL.txt)
- [SIL Open Font License FAQ](https://openfontlicense.org/ofl-faq/)
- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Apple Standard EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/)
- [Apple App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)
- [Apple Developer Program License Agreement](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/)
- [OpenAI Terms of Use](https://openai.com/policies/terms-of-use/)

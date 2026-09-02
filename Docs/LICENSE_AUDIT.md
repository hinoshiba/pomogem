# License and commercial distribution audit

Audit date: 2026-09-02

## Conclusion

現行構成は、MITでのsource公開と、hinoshibaによるApp Store公式binaryの商用配布に対応します。
有料利用を禁止するruntime license、第三者SDK、binary frameworkは検出していません。ただし、これは
技術・license台帳の監査記録であり、法律意見ではありません。権利帰属、商標、Apple account、
App Store提出状態に関する未確認事項は、下記release gateを完了するまで配布可否を確定しません。

現行の製品契約は「無料download＋1回限りのNon-Consumable IAP」です。有料download型へ変更する
場合は、価格、metadata、Web、StoreKit、審査資料を別の製品判断として再監査します。

| Component | Version / source | App binaryへ同梱 | License / status | Decision |
|---|---|---:|---|---|
| Tsumiben Swift sourceと通常文書 | repository | yes | MIT, Copyright 2026 hinoshiba | 商用利用・OSS公開可 |
| Runtime第三者package／SDK | none | no | n/a | 検出なし |
| Zen Maru Gothic Black | upstream font、SHA-256を台帳固定 | yes | SIL Open Font License 1.1 | 有償appへのbundle可。license全文を同梱 |
| Apple SDK frameworks | Xcode 26 SDK | platform-linked | Apple agreements | Apple platform app内だけで利用 |
| SF Symbols／system fonts | OS／SDK | system描画 | Apple terms | UIだけ。logo／iconへ未使用 |
| App icon、Aurora背景、Web／Store画像 | `ASSET_LICENSES.md` | yes／Web配信 | hinoshiba rights reserved、MIT対象外 | hinoshiba公式版は配布可。第三者forkは置換または許可が必要 |
| StoreKit Non-Consumable | `com.hinoshiba.tsumiben.pro.lifetime` | service連携 | Apple StoreKit | digital機能unlockとしてIAPを使用 |
| GitHub Pages／Cloudflare | 製品Web配信 | no | service terms | app binary外。privacy policyへ処理を開示 |
| XcodeGen、ripgrep、actionlint、GitHub Actions | `THIRD_PARTY_NOTICES.md` | no | 各OSS license | build／CI時だけ利用 |
| 研究・公的資料 | 設計文書のlink | no | 原資料ごとの条件 | 独自要約。本文、図表、dataset、logoを同梱しない |

## Rights and provenance

- `LICENSE`のMIT grantはsourceと通常文書に適用し、fontと固有brand assetは明示的に除外します。
- `ASSET_LICENSES.md`は全ての同梱・公開画像をorigin、条件、SHA-256で固定します。
- AI支援生成画像の生成経緯と人による選定・調整は`Tsumiben/Resources/GENERATED-ASSETS.md`へ記録します。
  生成serviceの規約だけで第三者権利の不存在や排他的著作権を保証できないため、maintainerは全ての
  reference inputを所有または適法に利用できることをreleaseごとに確認します。
- 現在のGit履歴はhinoshibaだけですが、初回commit以前のsource、文書、assetについて、雇用主、
  顧客、共同制作者、過去projectの秘密情報・codeを含まないことを権利者が別途確認します。
- `つみべん`／`Tsumiben`の名称台帳と正式な商標調査は、copyright/license監査とは別に行います。

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
9. 公開Privacy／Support／Terms、Cloudflare設定、HTTPS redirectを実配信で照合する。
10. App Storeへ送ったsource commitを固定tagにし、この監査を同じtagへ残す。

## Current no-go items

- `AppStore/configuration.yml`のApp Store IDが未設定。
- 完全offlineの2台でrare抽選台帳をexactly-onceへ収束させるV2が未完了。
- 初回App Store screenshot、実IAP、CloudKit production、Sandbox／TestFlight試験が未完了。
- Apple側のPaid Apps Agreement、税務・銀行情報、App Privacy公開状態はrepositoryから確認できない。
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

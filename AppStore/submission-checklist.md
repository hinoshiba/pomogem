# App Store submission checklist

## 未完了なら提出しない項目

- [ ] App Store Connect app recordとApp Store IDを作成
- [ ] Agreements、tax、banking、EU trader statusなど対象地域のcomplianceを完了
- [ ] Pages、Privacy、Supportが公開され、全URLがredirectなしHTTPS 200
- [ ] `tsumiben.hinoshiba.com`のDNS CNAMEを検証し、GitHub Pagesの「Enforce HTTPS」を有効化
- [ ] 公開SupportメールアドレスとGitHub profileの掲載をmaintainerが明示承認
- [ ] CloudKit development schemaを検証しproductionへdeploy
- [ ] 完全offlineの2台で同時完走してもrare抽選ordinal・端数・gold保証がexactly-onceへ収束するV2台帳を実装し、分断・再接続testに合格（現行の既知blocker）
- [ ] App Group、iCloud、Push Notifications、IAPのdistribution provisioningが有効
- [ ] Non-Consumable `com.hinoshiba.tsumiben.pro.lifetime`を作成し、日本の価格を100円に設定
- [ ] IAP localization、review screenshot、tax、availabilityを完成
- [ ] Sandboxでpurchase、pending、cancel、restore、revocationを確認
- [ ] App Privacy draftをproduction実装と照合しPublish
- [ ] 2026年版age rating質問へ回答
- [ ] Export complianceを現行質問で確認
- [ ] iPhone screenshotを実Release candidateから作成し、個人情報・placeholder・誤訴求なし
- [ ] metadataのname、subtitle、description、keywords、URLs、review notesを入力
- [ ] Accessibility Nutrition Labelsを実機評価に基づき回答
- [ ] Apple silicon MacとVision ProでのiOS app提供を無効化
- [ ] `./Scripts/check-oss-readiness.sh --release`、site validation、build、test、analyzeが成功
- [ ] 全11モデルのversioned JSON exportを40年相当の保存データで実行し、件数・内容・Files保存・一時ファイル削除を確認
- [ ] 2台の実機でiCloud、offline、timer引き継ぎ、resetを確認
- [ ] Archive → Validate App → Upload → internal TestFlight QAを完了
- [ ] 初回IAPとapp versionを同じsubmissionへ追加
- [ ] version/build/commit/tag/CloudKit deploy日時をrelease記録へ保存

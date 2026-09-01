## 概要

<!-- 何を、なぜ変更したか -->

## 検証

- [ ] `./Scripts/check-oss-readiness.sh`
- [ ] `python3 Scripts/validate-site.py`
- [ ] `xcodegen generate`後に意図しない差分なし
- [ ] 署名なしiOS Simulator buildと関連test
- [ ] 関連flowをiPhone実機で確認
- [ ] UI変更時にDynamic Type、VoiceOver、contrast、Reduce Motionを確認

## プライバシー・公平性・ライセンス

- [ ] 新しい収集、通信、SDK、permission、required-reason APIはない
- [ ] またはPrivacy Manifest、`PRIVACY.md`、Web policy、App Store draftを更新した
- [ ] 同じ総時間の価値、rare抽選、融合、manual/measuredの不変条件を壊さない
- [ ] dependency/assetの権利を確認し、noticeとasset台帳を更新した
- [ ] 実際のテーマ、顧客名、案件名、個人情報を含まない
- [ ] 秘密鍵、証明書bundle、profile、API key、Keychain、archive、signed binaryを含まない
- [ ] 公式署名・配布に関する変更は`Docs/RELEASING.md`の安全境界に従う

# App Privacy answer draft

## 推奨回答

現行Release candidateについては、アプリ本体から運営者へ自動送信する仕組みがないため、
「No, we do not collect data from this app」を第一候補とします。ただし、サポートページから
利用者が任意で送るメールは、Appleのoptional disclosure条件をすべて満たす場合に限って
省略可能です。提出担当者が現行の質問文と実運用を照合して最終回答します。

根拠:

- 独自account、analytics、ads、tracking、developer serverがない
- 学習・仕事dataは端末と利用者自身のprivate CloudKit databaseに保存
- motionはその場で処理し、保存・送信しない
- shareは利用者の明示操作でsystem share sheetへ渡すだけ
- 全11種類のSwiftData保存データのversioned JSON exportも、利用者の明示操作だけで生成し、
  選択した保存・共有先へ渡す
- StoreKit transactionは端末上でApple署名をverifyし、developer serverへ送らない
- third-party SDKがない

サポートメールがoptional disclosureの条件を満たさないと判断される場合は、少なくとも
Email AddressとCustomer Supportを、目的App Functionality、trackingなしとして申告します。
通常のメールは送信元と内容を結び付けられるため、匿名化していない限り「linked to user」
として扱います。

ただしこれは提出用draftです。Appleはappと組み込んだthird party全体の実態を正確かつ最新に回答
するよう求めています。提出直前にproduction archiveのnetwork、CloudKit access、StoreKit、
dependency、privacy policyを再監査し、App Store Connectの現行質問文に沿ってAccount Holder／
App Managerが最終決定・Publishします。

## Privacy Policy URL

`https://tumiben.hinoshiba.com/privacy/`

## Manifestとの整合

- Tracking: false
- Tracking domains: none
- Collected data types: none
- Main app required-reason APIs: File Timestamp `C617.1`、System Boot Time `35F9.1`、User Defaults `CA92.1`
- Widget required-reason APIs: none

新しいnetwork endpoint、SDK、permission、data retention、Widget accessを追加した時点で、このdraftを
無効として再回答します。

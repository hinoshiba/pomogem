# Age rating answer draft

## 推奨

現行機能だけなら4+相当を想定します。App Store Connectの2026年版質問票で最終確定します。

## 現行質問票の回答

| Category | Descriptor | Answer | Version 1.0の根拠 |
|---|---|---|---|
| In-App Controls | Parental Controls | No | App独自の子ども向け監視、content filter、利用制限を提供しない。Apple Account側のAsk to BuyはApp独自機能ではない。 |
| In-App Controls | Age Assurance | No | Declared Age Range API、年齢推定、公的身分証等による年齢確認を行わない。 |
| Capabilities | Unrestricted Web Access | No | 固定されたPrivacy、Support、Terms、販売条件、Apple／GitHub URLをsystem browserで開くだけで、任意URLの閲覧機能はない。 |
| Capabilities | User-Generated Content | No | theme名、成果memo、任意tagは利用者本人の端末／private iCloud用で、App内で不特定多数へ配信しない。明示操作のsystem share sheetはApp内UGC配信機能ではない。 |
| Capabilities | Social Media | No | feed、follow、like、comment、発見・拡散機能を提供しない。 |
| Capabilities | Social Media Disabled for Users Under 13 | No | Social Media自体を提供しないため、この年齢別制限も設けない。 |
| Capabilities | Messaging and Chat | No | 利用者間のDM、group chat、public postを提供しない。 |
| Capabilities | Advertising | No | 広告SDK、banner、動画広告、native adを含まない。 |
| Mature Themes | Profanity or Crude Humor | None | 該当する文言、音声、画像、storyを含まない。 |
| Mature Themes | Horror/Fear Themes | None | 恐怖、超常、死、心理的恐怖を扱わない。 |
| Mature Themes | Alcohol, Tobacco, or Drug Use or References | None | 酒類、煙草、薬物の使用・描写・言及を含まない。 |
| Medical or Wellness | Medical or Treatment Information | None | 診断、治療、投薬、緊急医療の情報または助言を提供しない。 |
| Medical or Wellness | Health or Wellness Topics | None | 勉強・仕事用の集中／休憩timerであり、健康、fitness、diet、運動、治療、self-careの助言として表示しない。休憩は任意のtimer cadenceで、健康上の効果をclaimしない。 |
| Sexuality or Nudity | Mature or Suggestive Themes | None | 性的・成人向けの暗示や主題を含まない。 |
| Sexuality or Nudity | Sexual Content or Nudity | None | 性的行為または裸体を含まない。 |
| Sexuality or Nudity | Graphic Sexual Content and Nudity | None | 露骨な性的表現または裸体を含まない。 |
| Violence | Cartoon or Fantasy Violence | None | cartoon／fantasy上の攻撃・危害を含まない。瓶の粒の物理演算は暴力表現ではない。 |
| Violence | Realistic Violence | None | 現実的な攻撃・負傷描写を含まない。 |
| Violence | Prolonged Graphic or Sadistic Realistic Violence | None | graphic／sadisticな暴力表現を含まない。 |
| Violence | Guns or Other Weapons | None | 銃、刀剣その他の武器の描写・言及を含まない。 |
| Chance-Based Activities | Gambling | None | 現金または換金可能な価値を賭ける機能を提供しない。 |
| Chance-Based Activities | Simulated Gambling | None | 換金性の有無を問わず賭けを模した機能を提供しない。 |
| Chance-Based Activities | Contests | None | 利用者間の順位、競争、賞品付きeventを提供しない。個人の記録・計画はcontestではない。 |
| Chance-Based Activities | Loot Boxes | No | 購入によりランダムitemを得るcontainerを提供しない。 |

Version 1.0はランダム報酬、確率要素、loot boxを提供しません。完走時はテーマ色の通常粒を
決定論的に保存します。したがってchance-based activitiesもNone、loot boxesはNoと回答します。

全descriptorが上記のNone／NoであることをRelease binaryと公開Webで再確認したうえで、生成された
ratingが4+であることをApp Store Connect上で保存・reloadして確認します。IAPが存在すること自体は
年齢区分を引き上げる回答にせず、購入制限はApple Account／Ask to Buyへ委ねます。

参照: [Age ratings values and definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions)

ランダム要素、health／wellness上の助言、UGC配信、social／chat、広告、任意Web閲覧、IAP内容、
share導線、外部link、画像・音声を変更した場合は必ず全質問を再判定します。

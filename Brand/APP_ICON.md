# つみべん App Icon — Focus Cycle v5

## Brand idea

「集中した時間が、一粒ずつ器に着地して積み上がる」という固有のproduct loopを、
フォーカス時間のリング、落下中の一粒、底に積もった三粒で表現する。

- 不透明な深いネイビーの正方形背景は、アプリ本体の静かな集中体験と共通する。
- 太いコーラルからブルーへの未完のリングは、特定の数字に固定しないフォーカス時間を示す。
- 落下中のマットなコーラルの一粒と、器の中のコーラル／ブルー／バイオレットの三粒が、一回の集中と積み重ねを示す。
- 半透明の器は、「時間を質量に変えて残す」場所であり、宝箱や抽選演出として描かない。
- 文字、数字、トマト、木、チェックマーク、SF Symbolsを使わない。
- コイン、ガチャ、スパーク、巨大な虹色のgem、casinoの連想を生む要素、画像内の角丸は使わない。

## Provenance

- Redesigned: 2026-09-05
- Tool: Codex built-in ImageGen
- Basis: Tumiben自身のFocus Vessel v4と、アプリで使っているネイビー／コーラル／ブルー／バイオレットのpaletteから再設計

Prompt summary: an opaque dark-navy square; a thick, incomplete coral-to-blue focus-time ring;
one matte coral unit falling; a simplified translucent receiving vessel containing three calm coral,
blue, and violet units; no text, numbers, tomato, tree, check mark, SF Symbols, coins, gacha,
sparks, giant rainbow gem, casino cues, or baked rounded corners.

## Production files

- Source render: `AppIcon-FocusCycle-v5-source.png` (1254×1254, sRGB, opaque)
- Shipping iOS asset: `../Tsumiben/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-FocusCycle-v5.png` (1024×1024, sRGB, opaque)
- Website icon: `../http_dists/public/app-icon-focus-v5.png` (256×256)
- Website touch icon: `../http_dists/public/apple-touch-icon.png`
- Open Graph image: `../http_dists/og-focus-v7.png` (1200×630)

The shipping icon is a flattened 1024×1024 sRGB image for compatibility with the app's iOS 17 minimum deployment target. The composition is intentionally separable into background, focus-time ring, vessel, falling unit, and accumulated units for a future Icon Composer source.

## Category and confusion review

Reviewed: 2026-09-05. Apple defines Productivity around organizing or making work and processes
more efficient, while Education is oriented toward teaching a particular subject or skill. Tumiben's
primary App Store category is therefore Productivity and its secondary category is Education.

The market review rejected tomato, tree, check-mark, standalone clock, and a pure ring-with-stacked-
stones mark. The first four are crowded focus-app conventions; the last already resembles existing
focus and wellness identities and also loses Tumiben's falling-and-receiving product loop. Focus Cycle
v5 keeps the time cue dominant while making the one-unit-to-accumulation sequence the distinctive cue.

This is a dated design-confusion screen, not a legal trademark clearance or registrability opinion.
Obtain a qualified trademark search before relying on exclusivity in a new market.

References:

- Apple Human Interface Guidelines — App icons: <https://developer.apple.com/design/human-interface-guidelines/app-icons/>
- Apple Developer — Choosing a category: <https://developer.apple.com/app-store/categories/>
- Apple Human Interface Guidelines — SF Symbols usage: <https://developer.apple.com/design/human-interface-guidelines/sf-symbols>

## Small-size acceptance

- At 64 px: the incomplete focus-time ring, falling coral unit, vessel, and accumulated units must remain distinct.
- At 29 px: the thick time ring, falling unit, and accumulated units remain identifiable as one sequence. This is the acceptance size because it preserves the original product loop while using fewer game-like cues than the former faceted, rainbow-gem composition.
- The system supplies the rounded mask; never bake rounded corners into the source.

## Legacy files

The previous Focus Vessel v4 source, 256px Web derivative, and focus-v5/v6 Open Graph images remain in the repository for provenance and comparison. They are not the active identity. The obsolete v4 PNG is not retained inside the active AppIcon asset set, which keeps the catalog free of an unassigned child:

- `AppIcon-FocusVessel-v4-source.png`
- `../http_dists/public/app-icon-focus-v4.png`
- `../http_dists/og-focus-v5.png`
- `../http_dists/og-focus-v6.png`

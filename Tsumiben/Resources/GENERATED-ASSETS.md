# Generated visual assets

## Licensing

この生成経緯を記録する文書自体は通常文書としてMIT Licenseの対象ですが、ここで説明する
画像素材はMIT Licenseの対象外です。画像ごとの権利表示とSHA-256は
`../../ASSET_LICENSES.md`、名称・公式表示の扱いは`../../TRADEMARKS.md`を参照してください。
未改変素材をfork、build、test、CI、review、contributionに使える限定許諾も同台帳に
記載していますが、配布アプリやWebサイトへの再利用許諾ではありません。

## `focus.aurora`

- Generated: 2026-08-30
- Tool: Codex built-in ImageGen
- App usage: optional, static Home atmosphere behind the live SpriteKit jar
- Source asset: `Assets.xcassets/focus.aurora.imageset/focus-aurora.png`

Prompt summary: a premium 9:16 midnight-navy study-timer background with restrained coral, cobalt, and violet aurora ribbons; quiet negative space through the center for a transparent glass jar; a dim lower area for the primary action; no bottle, people, furniture, UI, text, logo, or watermark.

The asset is intentionally kept separate from live metrics and controls. All text, accessibility information, bottle physics, and interaction remain code-native.

## `AppIcon-FocusCycle-v5`

- Generated: 2026-09-05
- Tool: Codex built-in ImageGen (`imagegen` skill, referenced-image redesign)
- App usage: active flattened 1024px iOS App Icon
- Shipping asset: `Assets.xcassets/AppIcon.appiconset/AppIcon-FocusCycle-v5.png`
- High-resolution source: `../../Brand/AppIcon-FocusCycle-v5-source.png`
- Web derivatives: `../../http_dists/public/app-icon-focus-v5.png` and `../../http_dists/public/apple-touch-icon.png`
- Brand rationale: `../../Brand/APP_ICON.md`

Prompt summary: redesign Tumiben's own Focus Vessel v4 and palette into an opaque dark-navy square with a thick, incomplete coral-to-blue focus-time ring, one matte coral unit falling, and a simplified translucent receiving vessel containing three calm coral, blue, and violet units. Use no text, numbers, tomato, tree, check mark, SF Symbols, coins, gacha, sparks, giant rainbow gem, casino cues, or baked rounded corners.

At 29px, the reduced composition retains the time ring, falling unit, and accumulated units as one readable product loop. It distinguishes the icon from generic timer marks while removing the former faceted rainbow-gem emphasis and reducing game-like or gambling-adjacent cues.

The PNG remains flattened for the iOS 17 minimum deployment target. Its background, ring, vessel, falling unit, and accumulated units remain compositionally separable for a future multilayer Icon Composer source.

## `AppIcon-FocusVessel-v4` (legacy)

- Generated: 2026-09-01
- Tool: Codex built-in ImageGen (`imagegen` skill, referenced-image redesign)
- App usage: previous flattened 1024px iOS App Icon; high-resolution source retained for provenance and comparison
- High-resolution source: `../../Brand/AppIcon-FocusVessel-v4-source.png`
- Retained Web derivative: `../../http_dists/public/app-icon-focus-v4.png`
- Brand rationale: `../../Brand/APP_ICON.md`

Prompt summary: use the Home and share-card visuals as the authoritative language; center a simplified tall, open optical-glass vessel on the restrained coral/cobalt Aurora; show one large normal coral focus pebble falling toward one large fused multicolor cluster; remove the former gold hero gem, loose gem collection, tiny sparks, floor reflection, fantasy ornament, text, border, and baked corner mask. The falling pebble and cluster are deliberately oversized for recognition at 29px.

The former shipping PNG was flattened for the iOS 17 minimum deployment target. It was removed from the active AppIcon asset set after replacement so the catalog contains no unassigned legacy child. The retained source keeps its background, vessel, falling pebble, and fused cluster composition available for provenance.

## `AppIcon-Aurora-v3` (legacy)

- Generated: 2026-08-30
- Tool: Codex built-in ImageGen
- App usage: previous 1024px iOS App Icon source, retained for comparison
- Source asset: `../../Brand/AppIcon-Aurora-v3-legacy.png`
- Previous icon candidates retained in the ignored, local-only QA archive:
  - `legacy-assets/app-icons/AppIcon-1024.png`
  - `legacy-assets/app-icons/AppIcon-Aurora-v2.png`

The QA archive is intentionally stored outside the public repository.

Prompt summary: a simplified, front-facing open thick-glass vessel with one falling warm focus gem and three accumulated gems; the same coral upper-left and cobalt/violet right-side Aurora lighting as Home; strong small-size silhouette; no lid, natural rock grain, text, baked rounded mask, border, or watermark. A second targeted pass corrected only the environmental light direction to match the Home background.

The icon is intentionally flattened for the current asset catalog. Its perceptual background, vessel, accumulated gems, and falling gem are separated clearly enough to recreate as three or four Icon Composer layers later without changing the mark.

## `aurora-unified-direction-v2`

- Generated: 2026-08-30
- Tool: Codex built-in ImageGen
- Usage: non-runtime implementation reference
- Artifact: `aurora-unified-direction-v2.png` in the local-only QA archive

Prompt summary: preserve the live Home layout and Japanese UI, while changing only the vessel, gem, and local material response toward an open thick optical-glass vessel and a softly faceted translucent focus crystal. The runtime remains code-native so SpriteKit physics, live records, Dynamic Type, and accessibility stay authoritative.

## `og-aurora-v2`

- Generated: 2026-08-30
- Tool: Codex built-in ImageGen
- Web usage: retired Open Graph and X/Twitter preview
- Archive: moved to the ignored, local-only QA archive during OSS preparation

Prompt summary: preserve the exact Japanese title and wide social-card hierarchy while replacing the former natural-rock vessel with the same open Aurora glass vessel, one falling gem, and three accumulated gems used by the app identity. No lid, natural stones, extra copy, or watermark.

## `og-focus-v6`

- Composed: 2026-09-05
- Tool: Sharp deterministic composite; the active Focus Cycle v5 icon itself was created with Codex built-in ImageGen
- Web usage: active Open Graph and X/Twitter preview
- Shipping asset: `../../http_dists/og-focus-v6.png`

Composition specification: preserve the exact text and 1200×630 layout of the hinoshiba-owned
`og-focus-v5.png`; replace only its legacy icon card with the active Focus Cycle v5 icon, using the
existing 420px rounded card geometry; then normalize the result to opaque RGB sRGB. No third-party
asset is introduced by this derivative.

## `og-focus-v5` (legacy)

- Generated: 2026-09-02
- Tool: Codex built-in ImageGen; normalized to the 1200×630 Open Graph canvas
- Web usage: previous Open Graph and X/Twitter preview, retained for provenance and comparison
- Shipping asset: `../../http_dists/og-focus-v5.png`

Prompt summary: match the current Aurora Home rather than an older rock illustration; use the same deep navy, coral, cobalt and violet atmosphere, the current optical-glass vessel, vivid live gems and fused crystal; keep the exact Japanese product hierarchy readable; state iPhone and 基本無料 without an exact IAP price; no Mac claim, people, unrelated ornament or watermark.

## `og-focus-v4` (legacy)

- Generated: 2026-09-01
- Tool: ImageMagick composition using the shipping brand assets
- Web usage: retired Open Graph and X/Twitter preview
- Archive: moved to the ignored, local-only QA archive during OSS preparation

The previous social preview used the Focus Vessel mark, midnight palette and coral action color. It was replaced because its rendered gem language no longer matched the current app closely enough.

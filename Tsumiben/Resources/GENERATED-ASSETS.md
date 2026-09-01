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

## `AppIcon-FocusVessel-v4`

- Generated: 2026-09-01
- Tool: Codex built-in ImageGen (`imagegen` skill, referenced-image redesign)
- App usage: active flattened 1024px iOS App Icon
- Shipping asset: `Assets.xcassets/AppIcon.appiconset/AppIcon-FocusVessel-v4.png`
- High-resolution source: `../../Brand/AppIcon-FocusVessel-v4-source.png`
- Brand rationale: `../../Brand/APP_ICON.md`

Prompt summary: use the Home and share-card visuals as the authoritative language; center a simplified tall, open optical-glass vessel on the restrained coral/cobalt Aurora; show one large normal coral focus pebble falling toward one large fused multicolor cluster; remove the former gold hero gem, loose gem collection, tiny sparks, floor reflection, fantasy ornament, text, border, and baked corner mask. The falling pebble and cluster are deliberately oversized for recognition at 29px.

The PNG remains flattened for the iOS 17 minimum deployment target. Its background, vessel, falling pebble, and fused cluster are compositionally separable for a future multilayer Icon Composer source.

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

## `og-focus-v5`

- Generated: 2026-09-02
- Tool: Codex built-in ImageGen; normalized to the 1200×630 Open Graph canvas
- Web usage: active Open Graph and X/Twitter preview
- Shipping asset: `../../http_dists/og-focus-v5.png`

Prompt summary: match the current Aurora Home rather than an older rock illustration; use the same deep navy, coral, cobalt and violet atmosphere, the current optical-glass vessel, vivid live gems and fused crystal; keep the exact Japanese product hierarchy readable; state iPhone and 基本無料 without an exact IAP price; no Mac claim, people, unrelated ornament or watermark.

## `og-focus-v4` (legacy)

- Generated: 2026-09-01
- Tool: ImageMagick composition using the shipping brand assets
- Web usage: retired Open Graph and X/Twitter preview
- Archive: moved to the ignored, local-only QA archive during OSS preparation

The previous social preview used the Focus Vessel mark, midnight palette and coral action color. It was replaced because its rendered gem language no longer matched the current app closely enough.

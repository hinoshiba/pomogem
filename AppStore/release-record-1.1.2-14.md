# PomoGem 1.1.2 (14) — release preparation

Updated: 2026-10-14. This candidate is being prepared. Archive, validation,
upload, processing, and App Review submission are not yet complete.
Apple's public Japan storefront lookup reports version 1.1.1, released on
2026-10-13 at 07:52:40 UTC. This does not identify its build number.
The prior submission receipt remains in [build 13's record](release-record-1.1.1-13.md).

## Changes

- Gem colors reflect the credited activity breakdown across the jar,
  completion, hierarchy, and share artwork. Tap moves a Gem; long-press opens
  its details. Queued completion notices wait while details or sharing are open.
- Menus keep their horizontal position. Themes are called Activities.
- Activities can specify a default focus duration, music, and autoplay.
  Built-in music, personal playlists, search, and shared links are supported.
  Music preferences remain on this iPhone. Autoplay respects other playing audio.
- Landscape timers return to the portrait Home consistently. Large-text
  layouts and repetitive explanations were reviewed and corrected.
- Already-submitted build 13 metadata, screenshots, and historical receipts
  are retained as the release baseline; the former Pro month-stamp promise
  is not restored. No new artwork, recording, or signing identity is required.

## Verification and release requirements

The eight-round UX review and its precise scope are recorded in
[RELEASING.md](../Docs/RELEASING.md#2026-10-14-リリース前uxレビュー).
After integration with current main, static OSS, privacy, metadata, website,
and localization checks passed, including compiler-extracted localization.
Full unit tests, focused UI regression tests, and the Release build are in progress.

`Subject.defaultFocusSeconds` is a new optional synchronized attribute.
Production must include `CD_Subject.CD_defaultFocusSeconds` as Int64;
its optional nature preserves old records but does not remove this deployment
requirement. Development/Production schema and two-device setting/change/reset
verification remain pending. MusicKit App Service and physical-device Music
checks also remain pending. The other recorded release requirements remain
in `configuration.yml`; none are marked passed by simulator tests.

The source commit and immutable tag will be recorded after merge and upload.
Signing materials, private logs, archives, and distribution payloads stay outside
this public repository. App Store Connect login is required to verify the next
available build, service configuration, and final submission state.

# PomoGem 1.1.2 (14) — release preparation

Updated: 2026-10-14. The signed raw archive and Apple Validate succeeded.
Distribution-payload verification, upload, processing, and App Review
submission are not yet complete; App Store Connect login is pending.
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
The application-source Release build and all three bundles' Japanese/English
localizations passed. The first integrated unit run executed 2,988 XCTest tests
(eight skips) and 30 Swift Testing tests. One localization test still expected
two removed introductory strings; it was corrected to verify the three
current explanations used by the UI. Its rerun and focused UI results, followed
by the complete final-head CI result, are tracked in
[PR #89](https://github.com/hinoshiba/pomogem/pull/89).
The additional Home check with a long selected playlist at maximum text size
passed on the simulator after changing the music row to a vertical layout;
the rendered row and the tap into music settings were verified. The integrated
SE checks passed 21 distinct UI scenarios across the reruns: Gem placement,
time hierarchy and sharing, English settings, music drafts and links, menu
position, and timer orientation. The final-head CI outcome is tracked in PR #89.

## Archive and validation

- Archive source: `05cb2d1d27c27f613d9859d19423f41769dfb619`.
  Subsequent code changes are limited to UI-test helpers.
- The signed raw archive completed on 2026-10-14 at 15:56 JST. Raw archive
  verification passed for the app, Widget, and Screen Time monitor. It uses
  development signing and development profiles; this does not verify the
  later distribution payload.
- Xcode Organizer's Apple Validate succeeded at 16:01 JST and displayed
  “PomoGem 1.1.2 (14) validated”. No signing identity was created.
- Distribution-payload verification, upload, processing, and App Review
  submission remain incomplete. App Store Connect login is pending.

## Remaining release requirements

`Subject.defaultFocusSeconds` is a new optional synchronized attribute.
Production must include `CD_Subject.CD_defaultFocusSeconds` as Int64;
its optional nature preserves old records but does not remove this deployment
requirement. Development/Production schema and two-device setting/change/reset
verification remain pending. MusicKit App Service and physical-device Music
checks also remain pending. The other recorded release requirements remain
in `configuration.yml`; none are marked passed by simulator tests.

The immutable tag will be recorded after upload.
Signing materials, private logs, archives, and distribution payloads stay outside
this public repository. App Store Connect login is required to verify the next
available build, service configuration, and final submission state.

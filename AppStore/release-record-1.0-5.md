# PomoGem 1.0 (5) release record

Updated 2026-09-06. This record describes the new app only. App version 1.0 (5) and PomoGem Pro Lifetime were submitted together at 19:07 JST; both are Waiting for Review.

- App Store ID: `6809139517`; bundle ID: `com.hinoshiba.pomogem`; SKU: `pomogem-ios`.
- Widget: `com.hinoshiba.pomogem.widgets`.
- Source commit: `b11016f8cb2eb805657e4dd5ff2a6f9bccf2132e`.
- CI run `34024974468` passed, including Release app/Widget build, shipping-hook checks and unit tests.
  Separately, the focused rebrand run passed 125 unit tests with no failures or skips.
- A Release archive was exported with Apple Distribution signatures on both targets.
  Strict signature verification passed; both distribution copies have `get-task-allow = false`.
  The app uses CloudKit Production, APNs production and only `iCloud.com.hinoshiba.pomogem`.
- Distribution IPA SHA-256: `5ba2f8bdbc2e714cbf33a506e20bbc3e7f376134a6c9cb39fd49d196b346b6b9`.
- App Store upload of version 1.0, build 5 succeeded. Apple processing completed; build 5 is attached to version 1.0. The same submitted review contains the app and IAP, both Waiting for Review.
- The new CloudKit Development schema was checked against all 7 source entities and 120 scalar attributes,
  including timer display, completion settings and preference revision fields. Development and deployed
  Production exports match semantically. Existing-container records were not exported or changed.
  Device-to-device iCloud sync testing was explicitly skipped by the user; it is not recorded as passed.
- New non-consumable `com.hinoshiba.pomogem.pro.lifetime` (Apple ID `6809141970`) was created:
  US $0.99 base, Japan ¥100 override, Family Sharing off, Japanese and English localizations.
  The new IAP was submitted with version 1.0 and is Waiting for Review.
- The app and IAP are configured for 148 of 175 regions, excluding the current EU 27.
  The app is free, public distribution; Apple silicon Mac and Vision Pro distribution are off.
- Five 1284×2778 Japanese app screenshots were captured from the new app and uploaded.
  The IAP screenshot loads the actual StoreKit product price ($0.99 in the US storefront), without
  a StoreKit configuration file or a mock price. That test passed 1/1. No purchase was performed.
  Screenshot provenance and hashes are recorded in `screenshots/README.md` and `screenshots/checksums.sha256`.
- Japanese and English listing metadata and private App Review contacts were saved and reloaded.
  No sign-in is required for review. The age questionnaire generated 4+.
- Privacy is published as Data Not Collected. The shipping app uses private CloudKit and no developer analytics.
- Domain DNS points to GitHub Pages. HTTPS certificate issuance and final published-page checks remain unverified.
  On 2026-09-06, the user explicitly took responsibility for correcting HTTPS and instructed that App Review submission proceed now.
- Signing material, personal review contacts, upload logs and detailed CloudKit exports are retained privately
  outside the repository. The older app was subsequently removed at the user’s explicit request; see
  `Docs/LEGACY_RELEASE_PROVENANCE.md` for the retirement result and retained main App ID. Old CloudKit data
  remains intact. Repository renaming is deferred to the user.

Additional signed-device, accessibility, purchase/restore and operational checks in the submission checklist
remain unverified unless separately checked. This record does not turn unexecuted tests into successes.

## Submission direction and HTTPS follow-up

On 2026-09-06, the user explicitly instructed that final App Review submission proceed immediately
and that the user would complete the HTTPS correction. Both items were then submitted successfully;
the observed result is recorded below. HTTPS follow-up remains separate from Apple’s review status.

HTTPS normalization and final published-page checks remain unverified. At the last check,
`pomogem.hinoshiba.com` lacked a matching HTTPS certificate. Pages run `34025807556` deployed the new
content successfully; its published-site smoke test failed because TLS returned a `*.github.io` certificate.
DNS resolves to the expected GitHub Pages CNAME and addresses. The available GitHub connection has push
access but cannot administer Pages settings. HTTPS correction and its follow-up verification are assigned
to the user, as explicitly directed above.

Standard OSS checks, metadata validation, site validation and screenshot hashes passed.
`check-oss-readiness.sh --release` did not pass: remaining checklist blockers are still recorded.
Additional device/StoreKit/operational checks are not represented as completed.

## Confirmed submission

App Store Connect displayed “2項目が提出されました”. The submission detail page then showed
“審査待ち” for both PomoGem Pro Lifetime and iOS app 1.0 (5).

- Submitted: 2026-09-06 19:07 JST.
- Submission ID: `3ff3a45b-b7f4-4a4f-a8f1-1c09b22b999f`.
- [App Review submission](https://appstoreconnect.apple.com/apps/6809139517/distribution/reviewsubmissions/details/3ff3a45b-b7f4-4a4f-a8f1-1c09b22b999f).
- Release setting remains automatic after approval. Submission is not approval or App Store availability.
- HTTPS certificate follow-up remains with the user; no successful TLS verification is asserted.

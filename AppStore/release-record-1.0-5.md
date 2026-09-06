# PomoGem 1.0 (5) release record

Updated 2026-09-06. This record describes the new app only. App Review has not yet been submitted.

- App Store ID: `6809139517`; bundle ID: `com.hinoshiba.pomogem`; SKU: `pomogem-ios`.
- Widget: `com.hinoshiba.pomogem.widgets`.
- Source commit: `b11016f8cb2eb805657e4dd5ff2a6f9bccf2132e`.
- CI run `34024974468` passed, including Release app/Widget build, shipping-hook checks and unit tests.
  Separately, the focused rebrand run passed 125 unit tests with no failures or skips.
- A Release archive was exported with Apple Distribution signatures on both targets.
  Strict signature verification passed; both distribution copies have `get-task-allow = false`.
  The app uses CloudKit Production, APNs production and only `iCloud.com.hinoshiba.pomogem`.
- Distribution IPA SHA-256: `5ba2f8bdbc2e714cbf33a506e20bbc3e7f376134a6c9cb39fd49d196b346b6b9`.
- App Store upload of version 1.0, build 5 succeeded. Apple processing completed; build 5 is attached to version 1.0. The same review draft contains the app and IAP, both ready to submit.
- The new CloudKit Development schema was checked against all 7 source entities and 120 scalar attributes,
  including timer display, completion settings and preference revision fields. Development and deployed
  Production exports match semantically. Existing-container records were not exported or changed.
  Device-to-device iCloud sync testing was explicitly skipped by the user; it is not recorded as passed.
- New non-consumable `com.hinoshiba.pomogem.pro.lifetime` (Apple ID `6809141970`) was created:
  US $0.99 base, Japan ¥100 override, Family Sharing off, Japanese and English localizations.
  The new IAP is ready for review and added to the review submission.
- The app and IAP are configured for 148 of 175 regions, excluding the current EU 27.
  The app is free, public distribution; Apple silicon Mac and Vision Pro distribution are off.
- Five 1284×2778 Japanese app screenshots were captured from the new app and uploaded.
  The IAP screenshot loads the actual StoreKit product price ($0.99 in the US storefront), without
  a StoreKit configuration file or a mock price. That test passed 1/1. No purchase was performed.
  Screenshot provenance and hashes are recorded in `screenshots/README.md` and `screenshots/checksums.sha256`.
- Japanese and English listing metadata and private App Review contacts were saved and reloaded.
  No sign-in is required for review. The age questionnaire generated 4+.
- Privacy is published as Data Not Collected. The shipping app uses private CloudKit and no developer analytics.
- Domain DNS points to GitHub Pages. HTTPS certificate issuance and final published-page checks remain pending.
- Signing material, personal review contacts, upload logs and detailed CloudKit exports are retained privately
  outside the repository. Older app registrations and data remain intact. Repository renaming is deferred to the user.

Additional signed-device, accessibility, purchase/restore and operational checks in the submission checklist
remain unverified unless separately checked. This record does not turn unexecuted tests into successes.

## Remaining submission hold

The App Store review draft accepts both items as ready to submit. Final submission is held while
`pomogem.hinoshiba.com` lacks a matching HTTPS certificate. Pages run `34025807556` deployed the new
content successfully; its published-site smoke test failed because TLS returned a `*.github.io` certificate.
DNS resolves to the expected GitHub Pages CNAME and addresses. The available GitHub connection has push
access but cannot administer Pages settings. Administrator browser sign-in was requested.

Standard OSS checks, metadata validation, site validation and screenshot hashes passed.
`check-oss-readiness.sh --release` did not pass: remaining checklist blockers are still recorded.
Additional device/StoreKit/operational checks are not represented as completed.

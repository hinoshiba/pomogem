# PomoGem 1.0.1 (6) release record

Prepared 2026-09-11; App Store upload succeeded at approximately 23:59 JST.
This is the build and upload evidence. Subsequent submission status is tracked in
[release PR #8](https://github.com/hinoshiba/pomogem/pull/8) and App Store Connect;
upload success does not imply approval or public availability.

- App Store ID: `6809139517`; app and Widget identifiers remain
  `com.hinoshiba.pomogem` and `com.hinoshiba.pomogem.widgets`.
- Exact archived source commit: `7720b3ee1e5108a8588036453db4af71de73284d`.
  Immutable source tag: `v1.0.1-build6` (created after successful upload).
  The working tree was clean when the archive was built. Release tooling and this
  record were updated afterward; those changes do not alter the app or Widget.
- The patch includes the iCloud connection, lifecycle, timer handoff and
  notification cleanup fixes in PRs #5–#7. It introduces no synchronized model,
  CloudKit container, permission, purchase product, price or availability change.
- CI run [34611693339](https://github.com/hinoshiba/pomogem/actions/runs/34611693339)
  passed for the archived source: Release app/Widget build, shipping-hook checks,
  current source/Store/site checks and 753 unit tests with one optional long-running
  test skipped and no failures. Three focused Simulator UI tests also passed for
  the underlying runtime changes in PR #7; they were not a signed-device test.
- Local Xcode 26.6 (17F113), iOS 26.5 SDK: Release arm64 archive succeeded.
  Organizer Validate App reported that version 1.0.1 (6) passed all validation checks.
- Xcode used the existing cloud-managed Apple Distribution identity for export
  and upload. No distribution private key was generated or exported.
- The original Organizer archive used Apple Development signing with the Release
  Production CloudKit entitlement and did not pass the default raw-archive
  environment check. The original archive was preserved. After Xcode distribution
  signing, the exported IPA's unchanged app and Widget passed strict
  `verify-release-archive.sh --distribution` verification using a temporary archive
  layout wrapper. Both use Apple Distribution/App Store profiles and
  `get-task-allow=false`; the app's signed CloudKit/APNs environments are
  Production/production. Widget entitlements remain account-neutral.
- The profile verifier now correctly treats a provisioning profile's CloudKit
  environments as an allowlist. An App Store app must still be signed for
  Production; eight regression tests include rejection of signed Development,
  absent Production authorization, malformed values and non-App-Store profiles.
  See [Apple TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).
- Separately exported distribution IPA SHA-256:
  `3c47f0c618b5b3f12899cfb129ef6f5ce71d69397a3c45181cc4d542faa2c2d6`.
  Exported app/Widget executable UUIDs match the original archive and dSYMs.
  This digest identifies the audited export, not Xcode's later upload staging payload.
- Organizer reported “PomoGem 1.0.1 (6) uploaded”; Connect showed build 6 processing.
  Xcode's automatic version/build management was disabled, and symbols were included.
- Japanese and English update notes and promotional text were saved and reloaded.
  The existing screenshots and review contact details were retained. Support,
  marketing and privacy links use the current bilingual page and its anchors.
  App Privacy remains Data Not Collected, with no review sign-in required.
- The existing release choice is automatic after approval, with no phased rollout.
  The Xcode Cloud page showed its onboarding screen and no configured workflow.
- HTTPS requests to the product root and support redirect returned 200 with normal
  TLS verification. This supersedes the initial release's unverified TLS state.
- Archives, IPA, profiles, signing inspection and upload logs remain outside the
  repository. No signing identifiers or private review contact information is included.

## Verification limits

Current-file readiness, Store metadata, site validation and profile regression tests
passed. `check-oss-readiness.sh --release` still fails because checklist blockers
remain recorded; it is not represented as passing. The default full-history check
also rejects retained local historical Git metadata; release CI's fetched history
passed its audit. Historical local references were not rewritten or published.

Signed-device, two-device iCloud/account-switch, accessibility, StoreKit purchase/
restore and remaining operational checks were not executed for this patch. Earlier
production schema evidence is historical, not a new device test. The user requested
release of the reviewed fixes with these unverified checks preserved in the record.

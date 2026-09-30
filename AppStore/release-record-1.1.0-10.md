# PomoGem 1.1.0 (10) — preparation record

Updated: 2026-09-30. This is a preparation record, not an upload or submission receipt.
App Store Connect shows the public version as 1.0.2 (9), Ready for Distribution.
The new 1.1.0 draft is in Prepare for Submission, with no build assigned.

## 2026-09-30 live submission check

- App Store Connect still shows 1.1.0 as Prepare for Submission, with no build
  selected. Its Japanese listing has five older images; English inherits that
  Japanese set. No upload or App Review submission occurred.
- Saved the current Japanese and English What's New text, the current English
  promotional text and description, and the checked-in App Review notes in the
  Connect draft. Reloaded the page and confirmed the English UI statement,
  Apple Music release note, and the updated review paths were retained.
- The signed-in App Store Connect user can administer and submit app versions,
  but Apple Developer's Certificates, Identifiers & Profiles reports Access
  Unavailable for that browser account. Xcode is signed into a separate Admin
  Apple Account with developer resources enabled, but this Mac still has no
  Apple Distribution signing identity. Re-downloading existing profiles from
  Xcode did not add a suitable one: the cached host App Store profile lacks
  Family Controls, App Group, and Time Sensitive Notifications; the Monitor
  has no App Store profile.
- Xcode 26.6 built the current 1.1.0 (10) source for generic iOS in Release
  configuration with code signing disabled. Compilation passed with warnings.
  This checks compilation only; it is not an installable, distribution-signed
  archive, a physical-device test, Apple Validate, or an upload.
- A direct Release build for the connected iPhone 12 mini with the existing
  team development profile stopped at signing: the host profile omits the
  Time Sensitive Notifications entitlement required by the source. No new
  profile or certificate was created, and no build was installed on the phone.
- The public privacy page returned HTTP 200, and its HTML exactly matched
  `http_dists/index.html`, including the Japanese and English text for focus
  music and the timer-end alarm.
- Refreshed all five Japanese and five English listing image candidates from
  current source with passing screenshot UI tests. Both 05 images show Timer
  Display choices without a Simulator-only iCloud warning. Image 03 is a reward
  transition and needs an editorial review: its card shows +250 g while the jar
  behind it remains at 0 g until the card is closed. The optional reminder
  offer was dismissed before capture to avoid a real-time clock mismatch.
  Simulator images do not
  establish signed-device parity; the images in Connect have not been replaced.

## Reviewed integration

- PR #25: restart deferred launch safely and bound foreground launch waiting.
- PR #27: avoid permanently revoking offline access on an account-state notification
  before an actual identity mismatch is established.
- PR #24: responsive Screen Time registration, measured learning totals, callback
  handling and diagnostics. Review additionally fixed full deletion of the app's
  local diagnostic mirror and cached digest/heartbeat state.
- PR #26: explicit iCloud refetch with cloud preview, an empty-data warning and an
  initially unchecked device-data deletion acknowledgement. Review bound pending
  requests to the exact CloudKit container/environment; legacy unscoped requests
  fail closed. Device-to-cloud replacement and its recovery gates stay disabled.
- PR #3: the pinned deploy-pages 5.0.1 maintenance update.

Review found no new CloudKit model/schema fields in these changes. Existing schema
and production access still require normal verification for the signed candidate.
Merge and CI completion are recorded in the corresponding GitHub PRs; a passing
dependency run alone is not a substitute for the final integration run.

## Local evidence

- Focused Screen Time/launch/offline regression run: 186 tests passed, no failures.
- Integrated iCloud policy/transfer regression run: 72 tests passed, no failures.
- Distribution profile policy regressions: 27 passed. Metadata, bilingual website,
  generated-project and current-file OSS checks passed during preparation.
- Screenshot journey and actual StoreKit price capture: two tests passed, no
  failures/skips; five listing images and one IAP image visually reviewed.
  Provenance and integrity hashes are in [screenshots/README.md](screenshots/README.md).
- PR #24's first integration CI exposed an existing duplicate-history pagination
  bug: tied physical copies could be skipped, allowing an ownership claim despite
  an invalid duplicate. The fix combines one batched persisted scan with pending
  inserts, edits and deletions. All 54 FocusCloudSync tests passed, including 390
  conflict placements and five SQLite predicate/deletion cases. Batch and variant
  bounds remain 128, with no schema change or implicit save. The failing baseline
  is retained separately; the final integrated CI still must pass.

The final unsigned generic iOS Release archive was built from clean commit
`0c84f25d03b46da5bc88f8e13c6575e102a4c450` with Xcode 26.6 / XcodeGen 2.45.4,
including the duplicate-history fix, and completed at 18:04:52 JST.
The host, neutral Widget and Screen Time monitor are each 1.1.0 (10), arm64 device
products. Bundle topology, privacy manifests, production framework restrictions,
absence of Debug/UI-test hooks, font hashes and all three executable/dSYM UUID
pairs passed checks. The distribution verifier correctly rejected the missing
profiles/signatures. **This unsigned artifact cannot be uploaded as a release.**
The earlier `4fb75de` archive is superseded and retained as historical evidence.
Later documentation-only changes do not alter the archived product source; any
later product-code fix requires a new candidate archive.

Private logs, xcresults, image attachment manifests and archive evidence are kept
outside the public repository under `release-validation/pomogem-20260922`.
No signing credentials, keys, certificates or profiles are attached here.

## App Store Connect preparation

- Created the 1.1.0 draft without submitting it for App Review.
- Saved Japanese and English descriptions, release notes, promotional text,
  keywords and support/marketing links, plus the shared review notes. Main text
  fields were reloaded and compared with the checked-in originals.
- Replaced the five inherited Japanese listing images with the current captures in
  order 01–05; after reloading, Connect retained all five in that order. English
  uses the Japanese set. The separate IAP review image is not a listing image.
- Saved both new IAP descriptions as Prepare for Submission revisions alongside
  the existing approved descriptions. Saved the current IAP review notes and price
  image; reload matched the notes and retained the new image with all three Pro
  benefits. The English description is within Connect's 55-character limit.
- App Information still shows the existing global 4+ age rating.
- Existing commercial terms, territories, review contact and release settings are
  retained. No purchase, refund, agreement acceptance or review submission occurred.

## Outstanding submission conditions

1. Confirm Apple's Family Controls **distribution** authorization and matching
   profiles for both `com.hinoshiba.pomogem` and its `.screentimemonitor` extension,
   including the shared App Group. Cached distribution profiles are insufficient;
   development entitlement success does not establish distribution approval.
2. Obtain authorized Apple Developer portal access, select the team's existing
   appropriate distribution signing identity, archive the final clean source,
   verify the archive/export/upload payload, upload build 10 and assign it to1.1.0.
   No identity generation, export, rotation or revocation was performed.
3. Complete remaining signed-device and StoreKit checks in the submission checklist.
   No physical-device tests were run in this preparation task. The 2026-09-21
   development-signed Release audit recorded four delivered callbacks/four recorded
   callbacks after the fix; that partial evidence does not cover untested day,
   account, permission, purchase or distribution-signing boundaries.
4. Confirm the published Japanese/English privacy policy after the Pages deployment.
   Connect texts and images are saved, but simulator images still need signed-device
   parity and the pending IAP localization revisions have not been submitted.
5. Review all remaining owner decisions and release gates in
   [configuration.yml](configuration.yml) and [submission-checklist.md](submission-checklist.md),
   then explicitly authorize submission. Preparing a draft does not authorize release.

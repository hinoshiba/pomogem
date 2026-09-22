# PomoGem 1.0.1 (7) release record

Updated 2026-09-12. Archive, distribution verification, Apple validation, and
upload completed. Organizer lists the upload at 11:56 JST; its success was
observed at 11:57 JST (02:57:13 UTC).

Status: submitted on 2026-09-12 at 16:26 JST and confirmed Waiting for Review.
Submission ID: `7f746a75-2605-47c5-83d5-48ee76b40b2c`.
The user requested parallel submission of the tested sync correction while the
Settings iCloud switching feature remains under development. Build 7 contains
none of that new feature or its additional recovery schema. Approval and public
availability remain unconfirmed; no next feature build number is assigned.

## Replacement scope

- Replaces review candidate 1.0.1 (6). App Store Connect confirmed Developer
  Rejected before build 7 was selected and submitted.
- Preserves version 1.0.1, the existing app and Widget identifiers, App Store
  record, CloudKit container and schema, purchase product, prices, and regions.
- Corrects recognition of Core Data's existing CloudKit companion directories
  so a valid store can reopen without deleting its data.
- Holds the cloud UI and activity writers until the local reset-history winner
  covers the history observed on the server. The bounded check is not proof that
  all user data has finished importing.
- Temporarily disables the displayed-record reset in iCloud mode before any
  mutation. The local-only reset remains available. Experimental direct CloudKit
  deletion remains disabled in the shipping app.
- Retains the connection, lifecycle, timer handoff, and notification corrections
  documented in the [build 6 record](release-record-1.0.1-6.md).

## Archived source and distribution evidence

- Exact archived source: `e4aee83b5e70aa9ae078ff37ad90626bb8becc97`.
  The later provenance/documentation commit and any merge commit do not identify
  the archived app. The immutable `v1.0.1-build7` source tag was created and pushed
  after successful upload and resolves to this exact archived commit. Subsequent
  documentation, merge, or feature commits must not move this tag or build 6's tag.
- Version/build: 1.0.1 (7), for both app and Widget.
- Xcode 26.6 (17F113), iOS 26.5 SDK: Release archive succeeded.
- Organizer Apple validation passed at 11:43 JST on 2026-09-12.
- The original archive used the existing Apple Development identity with the
  Release Production CloudKit entitlement. It was preserved. The default
  raw-archive verifier rejects this known signing-class/environment combination;
  this raw archive is not distribution-signature evidence.
- Xcode reused the existing Apple Distribution certificate for the distribution
  payloads. Both the separately exported IPA and the actual upload-staging IPA
  passed the unchanged strict `verify-release-archive.sh --distribution` checks.
  The signed host uses CloudKit Production and APNs production; app and Widget
  App Store profiles have `get-task-allow=false`, and the Widget remains
  account-neutral. Both payloads' app/Widget executable UUIDs match the original
  archive and its dSYMs; UUID values and signing identifiers remain private.

| Verified payload | SHA-256 |
| --- | --- |
| Separately exported distribution IPA | `91e0d9140efb7b12d7e6a8aa43e7edea54e89d2675eb9815ff0727019c4ddbdb` |
| Actual upload-staging IPA | `810ba324b71c63cbf32b9dc14e43f85561ba024fdfe285f7e0898ce22bf6e4f3` |

These hashes identify distinct packages. The independent export hash is not
presented as the uploaded file's hash. Organizer subsequently reported
“App upload complete: PomoGem 1.0.1 (7) uploaded.”

## Validation and remaining work

The [physical-device audit](../Docs/RealDeviceICloudAudit.md) records the observed
storage error, in-place correction with original row identities preserved, and
deterministic reset/import-order regressions. It separates actual Production
server observations from fixtures running on a signed physical Release host.
That device deployment uses Apple Development signing and is not App Store
distribution evidence. Its scoped device results complement the actual build 7
archive and distribution-payload checks above.

The latest full Debug suite ran 815 tests: 811 passed, four intentional opt-in
skips, and zero failures. Current-file repository readiness passed. Build 7
Release static analysis passed for the app and Widget;
production binaries contained no test or preview entry points. The physical
Release audit separately exercises real server upload, reinstall and import,
timer recovery, theme deletion, local-only reset and isolation, and historical
reset generations. See that audit for the exact boundaries of each case.

PR #9 CI for the archived source, run
[34668002596](https://github.com/hinoshiba/pomogem/actions/runs/34668002596),
failed before starting because of an account payment or Actions spending limit;
no runner or test step executed. Local validation is not a passing CI run.

Apple processing completed and build 7 was selected for version 1.0.1. The
revised Japanese and English release notes and Review Notes were saved and
matched their local sources after reload. The final submission contained one
item, iOS app 1.0.1 (7); the success message and submission detail both confirmed
Waiting for Review at 16:26 JST. Existing automatic release after approval was
preserved; it is not evidence of approval or publication.

The checked-in public Privacy correction still requires deployment. Pages run
34669415266 attempt 2 was retried during submission preparation, but again
failed before any runner step due to payment/spending limits; deploy was skipped.
The served policy still differs from the corrected local page. This remains an
open follow-up and is not represented as a passing release check. The separate
storage-switch feature, additional schema, archive and future submission require
their own validation and release record.

Known release blockers remain in `AppStore/configuration.yml`.
`check-oss-readiness.sh --release` still fails on those blockers. The full-history
identity audit also fails on pre-existing historical metadata; current-file
readiness does not certify the entire history. Neither gate is represented as
resolved by the successful archive or upload. One-phone testing does
not establish two-device concurrency, account switching, StoreKit purchase and
restore, or complete accessibility coverage. Update these limitations only when
the corresponding evidence exists.

Archives, IPA files, result bundles, raw logs, screenshots containing private
data, provisioning profiles, signing identities, device/account identifiers, and
review contact details remain outside the repository. Test-account deletion
authorized for the device audit is not a normal release step or permission to
reset the Production environment.

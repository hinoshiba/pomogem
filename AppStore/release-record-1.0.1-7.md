# PomoGem 1.0.1 (7) release preparation record

Updated 2026-09-12. Status: preparation in progress. No build 7 archive,
distribution export, upload, App Review submission, or public release is recorded
as complete here.

## Replacement scope

- Replaces the canceled review candidate 1.0.1 (6). The cancellation action
  returned the version item to Ready for Review; final cancellation processing
  must be confirmed in App Store Connect before build 7 is selected.
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

## Evidence and remaining work

The [physical-device audit](../Docs/RealDeviceICloudAudit.md) records the observed
storage error, in-place correction with original row identities preserved, and
deterministic reset/import-order regressions. It separates actual Production
server observations from fixtures running on a signed physical Release host.
That device deployment uses Apple Development signing and is not App Store
distribution evidence. Pre-number-bump test results are not a completed build 7
archive or upload check.

The final fixed source commit and CI run are pending. After the candidate is
committed and verified, record the Xcode/SDK versions, Release archive result,
Organizer validation, strict distribution verification, exported IPA SHA-256,
and executable/dSYM UUID agreement. Identify the exported payload separately
from any later upload staging payload. Create the immutable `v1.0.1-build7` tag
on the archived source only after successful upload; do not move the build 6 tag.

Upload, Apple processing, build selection, revised metadata/Review Notes save
and reload, submission, and approval/public availability each require their own
observed result. Existing automatic release after approval is a configuration,
not evidence of approval or publication. The checked-in public Privacy correction
still requires deployment and verification of the served page.

Known release blockers remain in `AppStore/configuration.yml`. The prior release
record did not pass full release readiness or the full-history identity audit;
neither is represented as resolved by this preparation. One-phone testing does
not establish two-device concurrency, account switching, StoreKit purchase and
restore, or complete accessibility coverage. Update these limitations only when
the corresponding evidence exists.

Archives, IPA files, result bundles, raw logs, screenshots containing private
data, provisioning profiles, signing identities, device/account identifiers, and
review contact details remain outside the repository. Test-account deletion
authorized for the device audit is not a normal release step or permission to
reset the Production environment.

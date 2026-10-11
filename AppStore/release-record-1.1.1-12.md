# PomoGem 1.1.1 (12) — release record

Updated: 2026-10-11. Preparation is in progress; this record does not yet claim
an upload, App Review submission, or public release.

## Version and source

- App Store Connect was checked on 2026-10-11: 1.1.0 (11) is Ready for
  Distribution. TestFlight lists build 11 as the newest upload, dated
  2026-10-04. Earlier repository notes about 1.1.0 being an unuploaded draft
  are historical.
- The new candidate is 1.1.1 (12), following PR #82 / main commit
  `b55b9edfe001a0263c9b5468a791cc18af3a370c`.
- The update assigns a recording theme to each selected Screen Time app,
  displays selected app names, clarifies the settings menu, and prevents
  unintended horizontal movement in settings on iOS 26.
- Previously saved records retain their themes. Apps assigned to the same
  theme share a ten-minute threshold; different themes accumulate separately.
  Saving a changed assignment restarts unfinished learning intervals.

## Validation

- PR #82 CI passed: 2,898 unit tests, eight skipped, zero failures; unsigned
  Release build, localization checks, and English UI smoke test passed.
  [CI run](https://github.com/hinoshiba/pomogem/actions/runs/38098927291).
- Japanese UI tests verified per-app assignment, save/reopen/discard,
  unsaved-change protection, long names at maximum accessibility text size,
  and settings navigation at 375pt and 402pt widths.
- Signed archive, export, upload, and submission evidence will be recorded
  after each operation succeeds. Real-device Screen Time callbacks for this
  candidate have not yet been verified.

## Signing and Connect preparation

- Current local App Store distribution profiles for all three bundles are
  valid through 2027-07-08. Their entitlements match the reviewed policy,
  including Family Controls and the shared App Group on host and monitor,
  production CloudKit/APNs and Time Sensitive notifications on the host,
  and a neutral Widget. The earlier missing-capability finding is resolved.
- An existing Apple Development signing identity and matching development
  profiles are available for the raw archive. No local Apple Distribution
  identity is installed; the existing Organizer distribution service must
  provide the final distribution signature. No signing identity was created,
  exported, imported, revoked, or rotated by this work.
- Created the 1.1.1 App Store Connect draft. It is Prepare for Submission,
  with no build selected yet. Automatic release after approval, immediate
  availability to all users, and existing ratings are retained.

Signing material, private release logs, archives, and upload payloads remain
outside the public repository.

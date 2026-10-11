# PomoGem 1.1.1 (12) — release record

Updated: 2026-10-11. Upload succeeded at 10:40 JST. App Review submission
succeeded for 1.1.1 (12) at 10:58 JST, and Connect shows Waiting for Review. Public release
of 1.1.1 is not yet verified; the last verified published version is 1.1.0 (11).

## Version and source

- App Store Connect was checked on 2026-10-11: 1.1.0 (11) is Ready for
  Distribution. Before this upload, TestFlight listed build 11 as the newest
  upload, dated 2026-10-04. Earlier repository notes about 1.1.0 being an
  unuploaded draft are historical.
- The new candidate is 1.1.1 (12), following PR #82 / main commit
  `b55b9edfe001a0263c9b5468a791cc18af3a370c`.
- The archive was built from fixed source commit
  `73cc2d5d7d162c227344bc1afd252a024c726a97`. The source tag
  `v1.1.1-build12` was pushed for that commit. Later receipt-only updates do
  not change the archived source.
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
- The release-source [CI run](https://github.com/hinoshiba/pomogem/actions/runs/38101798036)
  passed for `73cc2d5d7d162c227344bc1afd252a024c726a97`: 2,898 unit tests,
  eight skipped, zero failures; localization checks and the English UI smoke
  test also passed. This is the archived source's CI result. Later receipt-only changes receive local static checks;
  full iOS CI is not rerun for those changes.
- Real-device Screen Time callbacks for this candidate have not yet been
  verified. Existing signed-device, Sandbox, screenshot-comparison, and
  other unresolved release checks remain pending; upload and App Review
  submission are not evidence that those checks passed.

## Signing, upload, and Connect

- Current local App Store distribution profiles for all three bundles are
  valid through 2027-07-08. Their entitlements match the reviewed policy,
  including Family Controls and the shared App Group on host and monitor,
  production CloudKit/APNs and Time Sensitive notifications on the host,
  and a neutral Widget. The earlier missing-capability finding is resolved.
- Raw signed-archive verification passed, using the existing development
  signing setup. Organizer Validate also passed.
- The actual uploaded IPA passed strict `--distribution` verification for
  the app, Widget, and Screen Time monitor, using the existing distribution
  identity. The archive/dSYM UUID comparison passed. The retained export's
  SHA-256 matches the actual upload-staging IPA. No signing identity was
  created, exported, imported, revoked, or rotated by this work.
- Organizer reported a successful upload of 1.1.1 (12) on
  2026-10-11 at 10:40 JST. Connect processing completed, and build 12 was
  selected and saved for version 1.1.1.
- Both ja-JP and en-US metadata were saved and read back with exact matches
  to the public source. `review-notes.zip`, containing four public text
  files, was uploaded as the review attachment.
- App Review submission succeeded on 2026-10-11 at 10:58 JST. Connect
  displayed 「1項目が提出されました」, then the review details showed
  「審査待ち」 for iOS app 1.1.1 with build 1.1.1 (12) and that submission time.
- Automatic release after approval, immediate availability to all users,
  and existing ratings are retained. Approval and public availability have
  not yet been verified.

Signing material, private release logs, archives, and upload payloads remain
outside the public repository.

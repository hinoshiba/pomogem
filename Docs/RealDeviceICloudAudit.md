# Physical-device iCloud lifecycle audit

Status: in progress. This record distinguishes an actual server round trip from a deterministic replay of import order. A passing account check is not evidence that user records uploaded or restored.

## Test setup

- Date: 2026-09-12
- Device: iPhone 12 mini, iOS 26.3.1 (a)
- App configuration: Release, with the actual CloudKit private database
- Signed CloudKit environment: Production, inspected separately from the build configuration
- Device deployment uses an existing Apple Development identity. This differs from the App Store distribution signature.
- Physical-device tests are opt-in. The ordinary app receives no preview or mock flags.
- Raw device logs, result bundles, screenshots, signing material, account information, and store files remain outside this repository.

The user authorized installing and uninstalling PomoGem and deleting this test account's existing PomoGem data. That authorization does not cover unrelated applications or accounts.

## Evidence so far

| Case | Result | What this establishes |
| --- | --- | --- |
| Install and launch the Release app | Passed | The app installs on the physical device and reaches the real storage choice. |
| Read the real Production private CloudKit database | Passed | Account identity was stable. The later read independently observed the original theme and preferences in one readable custom zone. The default zone was explicitly skipped; this is not a claim that every zone was empty. |
| Seed through the ordinary UI | Passed after clean installation and authorized server purge | The real storage disclosure, onboarding, unique theme, one 30-minute/300g manual session, and nondefault keep-screen-awake=false were verified. The initial attempt correctly refused the previously initialized installation. |
| Reset on a fresh replica, then deliver older server history | Reproduced with production code on the physical host | A deterministic in-memory import-order regression displayed old records and physically removed a newly created completion. This is not yet a live CloudKit delivery reproduction. |
| Record or start a timer before initial reset-history hydration | Reproduced with production code on the physical host | Three deterministic cases fail before the preflight fix: a manual record with no known epoch, a manual record with incomplete older history, and a running timer plus its claim. These are not live delivery reproductions. |
| Reopen an existing physical CloudKit store | Original failure reproduced, in-place correction passed | The actual framework-created `<stem>_ckAssets/` directory was rejected by the inventory. The matching selection, successful-mount marker, both stores, one theme, and one preferences row were retained. The same two rows were observed on the server. The companion `.<stem>_SUPPORT/` is now included in exact inventory and cleanup coverage. Upgrading in place reopened Home and completed the live iCloud check; independent before/after SQLite inspection retained both original row IDs without app deletion. |
| Physical Release regression suite | 35 passed | Nine reset, twelve asynchronous preflight, four import-order, and ten filesystem-layout cases pass on the phone. These deterministic fixtures are distinguished from live server import. |
| Delete existing PomoGem synchronized private data | Passed | The fixed synchronized container acknowledged deletion of its one custom zone; a second server enumeration confirmed no custom zones remained with the same account identity. This uses the public CloudKit zone-deletion API, excludes the default zone and operations container, and does not claim Apple Settings UI coverage. |

| Full Debug unit suite on a fresh simulator | Passed | 806 passed, four intentional opt-in skips, zero failures (785 XCTest cases plus 25 Swift Testing cases). Physical UI/server cases remain separate evidence. |
| Independent server upload read | Data present; decoder correction in progress | The server returned the unique Subject, StudySession, and Prefs. The strict manual-source assertion did not pass because CloudKit returned an archive Data value the evidence decoder did not yet recognize. The app remained installed for a corrected independent read before removal. |

## Release containment

The App Review submission for 1.0.1 (6) was canceled after the reset regression reproduced. The UI returned the version item to Ready for Review; final submission cancellation processing must be rechecked. A replacement must not be submitted until the corrected behavior and required device cases have evidence.

The current corrective patch makes the cloud visible-record reset unavailable before it can change markers, preferences, local timers, notifications, or cleanup state. Local-only reset remains available. This containment does not by itself establish safe admission of activity before initial CloudKit hydration.

## Remaining device cases

- Save a unique test theme, manual record, and setting; independently confirm server presence.
- Uninstall, reinstall, and restore that exact data into a genuinely empty local store.
- Terminate during running and paused timers; restore the expected remaining time without duplicate completion.
- Interrupt sync and restart; distinguish durable server state from an unsent local change removed by uninstall.
- Verify cloud reset containment and local-only reset behavior.
- Delete a theme or achievement and verify the deletion after reinstall.
- Purge the account's PomoGem iCloud data through the appropriate supported interface, then verify a clean installation.
- Verify local-only persistence, process relaunch, reset, and the expected loss of local-only data after uninstall.

One phone cannot establish two-device concurrency behavior. Offline devices that still hold data and later reconnect also require separate evidence; app uninstall and an iCloud server purge are different operations.

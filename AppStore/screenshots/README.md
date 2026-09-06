# App Store screenshots

## Current capture — 2026-09-06

The checked-in set shows version 1.0 build 4, including the visible theme and
duration controls on Home, the remaining-time ring, and the completion card
before the gem drops. All five images were visually reviewed and their hashes
recorded in `checksums.sha256`. The separate IAP image shows the actual StoreKit
price and 1–360 minute feature range.

Compare the set with the signed Release build on a supported physical iPhone
before submission; that visual-parity check remains outstanding. Images saved
under `Artifacts/` during development are review references, not the reviewed
App Store set.

## Japanese iPhone set

`ja-JP/` contains five release-intended product-UI screenshots captured with a
Debug-only deterministic fixture, in the intended App Store order:

1. `01-home-with-first-pebble.png` — Home bottle after one deterministic 250g completion
2. `02-25-minute-focus.png` — the real free 25-minute focus timer in progress
3. `03-completion-reward.png` — the saved completion, time-based progress, and
   explanation that closing the card drops the gem into the bottle
4. `04-accumulation-overview.png` — weekly and lifetime accumulation overview
5. `05-iCloud-and-privacy.png` — the shipped private-iCloud and no-tracking
   explanation, support and privacy links, current Pro features, and version
   `1.0 (4)`. The display-reset and Apple iCloud storage-management rows are
   outside this capture's viewport.

All files are portrait `1284 × 2778` RGB PNGs without an alpha channel. This
is an accepted 6.5-inch screenshot size in Apple's current
[screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).
Apple currently permits one to ten screenshots per set. A 6.5-inch set is
required when a 6.9-inch set is not provided.

The screenshots intentionally contain:

- only Japanese production UI;
- a built-in seed theme, with no user-entered name or note;
- no account, Apple ID, notification, or other personal information;
- no visible `DEBUG`, `DEMO`, UI-test probe, injected error, or placeholder;
- no claimed Pro entitlement and no simulated purchase state;
- no promotional text or device-frame compositing.

The product-page set omits the paywall and focuses on the free experience. It
contains neither a hard-coded price nor a synthetic purchased state. The
separate IAP review image below uses the localized `Product.displayPrice`
supplied by StoreKit, with no price drawn into the image.

The test fixture uses a Debug-only 12-second timer to create one 250g record,
but restores the visible duration to 25 minutes before capturing the reward
card and Home. The reward it creates is the same
250g normal pebble as a real 25-minute completion. Version 1.0's release policy
disables random rewards, so this set cannot randomly change.

The Simulator storage screen can contain diagnostic text. Screenshot 05 uses
normal scrolling to show the support/privacy section and version together;
diagnostics are outside the viewport, with no content edited out of the image.

These images verify product-page composition and truthful UI content; they are
not evidence that the signed Release archive renders identically. Before
submission, compare every screen against the signed Release build on a physical
supported device and replace any image whose UI differs.

## Reproduce

Create and boot an iPhone 13 Pro Max simulator on an installed iOS runtime,
then set a clean, stable status bar. Assign the UUID printed by `simctl create`
to `SCREENSHOT_DEVICE_ID`.

```sh
xcrun simctl create \
  'Tumiben App Store 6.5-inch' \
  com.apple.CoreSimulator.SimDeviceType.iPhone-13-Pro-Max \
  com.apple.CoreSimulator.SimRuntime.iOS-26-5

SCREENSHOT_DEVICE_ID='<created simulator UUID>'
xcrun simctl boot "$SCREENSHOT_DEVICE_ID"
xcrun simctl bootstatus "$SCREENSHOT_DEVICE_ID" -b
xcrun simctl status_bar "$SCREENSHOT_DEVICE_ID" override \
  --time '9:41' \
  --batteryState charged \
  --batteryLevel 100 \
  --wifiBars 3 \
  --cellularBars 4 \
  --operatorName ''
```

Run only the deterministic capture journey. Keep build products and the result
bundle outside the checkout.

```sh
SCREENSHOT_RESULTS="$(mktemp -d /tmp/TumibenScreenshots.XXXXXX)"

xcodebuild \
  -project Tsumiben.xcodeproj \
  -scheme Tsumiben \
  -destination "platform=iOS Simulator,id=$SCREENSHOT_DEVICE_ID" \
  -derivedDataPath "$SCREENSHOT_RESULTS/DerivedData" \
  -resultBundlePath "$SCREENSHOT_RESULTS/TumibenScreenshots.xcresult" \
  -only-testing:TsumibenUITests/RuntimeFlowAuditUITests/testAppStoreScreenshotSetJapaneseReleaseCandidate \
  test

xcrun xcresulttool export attachments \
  --path "$SCREENSHOT_RESULTS/TumibenScreenshots.xcresult" \
  --output-path "$SCREENSHOT_RESULTS/attachments"
```

Use `manifest.json` to map the five attachments prefixed `ASC_` to the ordered
filenames above. XCTest screenshots contain an opaque alpha plane, which App
Store Connect rejects; strip only that channel while preserving RGB pixels:

```sh
ffmpeg -hide_banner -loglevel error \
  -i '<exported attachment>' \
  -vf format=rgb24 \
  -frames:v 1 \
  'AppStore/screenshots/ja-JP/<ordered filename>.png'
```

Before upload, verify every file and visually inspect all five:

```sh
for screenshot in AppStore/screenshots/ja-JP/*.png; do
  sips -g pixelWidth -g pixelHeight -g hasAlpha -g space -g format "$screenshot"
done
```

Expected values are `pixelWidth: 1284`, `pixelHeight: 2778`, `hasAlpha: no`,
`space: RGB`, and `format: png`.

The checked-in set was regenerated on 2026-09-06 from version 1.0 build 4 with
Xcode 26.6 (17F113), using a Debug-only deterministic fixture on an iOS 26.5
iPhone 13 Pro Max simulator. The 72 app source files and 10 original UI-test
source files matched the repository when captured. The private simulator app
copy was ad-hoc signed. The selected sources are:

| Image | Capture source | Verification |
|---|---|---|
| 01 | `reshoot/Home-stable.png` | Same capture journey, with a private test-copy-only four-second wait for the normal landing toast to disappear; clean Home visually reviewed |
| 02 | `raw-five/ASC_02_25-minute-focus.png` | Original capture journey, 1 test passed |
| 03 | `raw-five/ASC_03_completion-reward.png` | Original capture journey, 1 test passed |
| 04 | `raw-five/ASC_04_accumulation-overview.png` | Original capture journey, 1 test passed |
| 05 | `privacy/ASC_05_privacy-position-1.png` | Separate Settings-navigation and natural-scroll capture, 1 test passed |

The 01 recapture run later failed a capture-only locator that incorrectly
expected the version as standalone text; the shipping version row is combined
accessibility content. The adopted Home attachment had already been captured
and reviewed. The later dedicated 05 capture passed. The initial 01 (landing
toast) and initial 05 (Simulator diagnostics) were rejected.

All selected files were copied without pixel edits. Screenshot 03 shows the
first saved 250g completion before the drop, with Close, GIF, and 5-minute break
actions. Signed-Release physical-device visual parity remains a separate
submission gate. `shasum -a 256 -c AppStore/screenshots/checksums.sha256` verifies
the five listing images and the separate IAP review image.

## IAP review image

`iap-review/01-tumiben-pro-live-price.png` is the separate review image for
`com.hinoshiba.tumiben.pro.lifetime`; it is not part of the five-image product
page set. It was captured on 2026-09-06 from version 1.0 build 4 on an iPhone 13
Pro Max simulator running iOS 26.5. The source attachment was
`IAP_Review_live-StoreKit-product.png`.

The production paywall displays the actual StoreKit product and its
`Product.displayPrice`, the 1–360 minute range, month labels, one-time purchase,
the pre-purchase seller-disclosure link, and Restore Purchases. No purchase was
performed. The image was copied without pixel edits, price replacement, or a
simulated purchased state. It is an opaque 1284 × 2778 RGB PNG. Its hash is
recorded in `checksums.sha256` and `ASSET_LICENSES.md`.

## English product page

The app UI and support are currently Japanese, and the `en-US` description
states that explicitly. Because these images contain no added Japanese
marketing copy, the exact same truthful UI set can be reused for `en-US`.
Either upload the same ordered set to that localization or let App Store
Connect inherit the Japanese set; do not create an English-looking custom set
until the binary itself has English UI.

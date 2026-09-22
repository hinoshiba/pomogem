# App Store screenshots

## Candidate 1.1.0 (10) — 2026-09-22

The existing five product images remain historical 1.0 (5) captures. Compare them with
this candidate and replace changed Settings or Pro screens before submission. The old
IAP price image is preserved at `history/iap-review-20260906.png`; it does not show the
new unlimited learning-app benefit. Capture a new live StoreKit paywall in
`iap-review/01-pomogem-pro-live-price.png` before marking the current image ready.

## Historical capture — 2026-09-06

The checked-in set shows PomoGem version 1.0 build 5, including the visible theme and
duration controls on Home, the remaining-time ring, and the completion card
before the gem drops. All five images were visually reviewed and their hashes
recorded in `checksums.sha256`. The new product's separate IAP review image
shows its actual StoreKit price and is documented below.

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
   `1.0 (5)`. The display-reset and Apple iCloud storage-management rows are
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
separate IAP review image must use the localized `Product.displayPrice`
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

Create and boot an iPhone 12 Pro Max simulator on an installed iOS runtime,
then set a clean, stable status bar. Assign the UUID printed by `simctl create`
to `SCREENSHOT_DEVICE_ID`.

```sh
xcrun simctl create \
  'PomoGem App Store 6.5-inch' \
  com.apple.CoreSimulator.SimDeviceType.iPhone-12-Pro-Max \
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
SCREENSHOT_RESULTS="$(mktemp -d /tmp/PomoGemScreenshots.XXXXXX)"

xcodebuild \
  -project PomoGem.xcodeproj \
  -scheme PomoGem \
  -destination "platform=iOS Simulator,id=$SCREENSHOT_DEVICE_ID" \
  -derivedDataPath "$SCREENSHOT_RESULTS/DerivedData" \
  -resultBundlePath "$SCREENSHOT_RESULTS/PomoGemScreenshots.xcresult" \
  -only-testing:PomoGemUITests/RuntimeFlowAuditUITests/testAppStoreScreenshotSetJapaneseReleaseCandidate \
  test

xcrun xcresulttool export attachments \
  --path "$SCREENSHOT_RESULTS/PomoGemScreenshots.xcresult" \
  --output-path "$SCREENSHOT_RESULTS/attachments"
```

Use `manifest.json` to map the five attachments prefixed `ASC_` to the ordered
filenames above. If an exported XCTest screenshot contains an opaque alpha
plane, strip only that channel while preserving RGB pixels; keep an already
RGB/no-alpha attachment unchanged:

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

The checked-in set was regenerated on 2026-09-06 from PomoGem version 1.0
build 5 with Xcode 26.6 (17F113), using a Debug-only deterministic fixture on
an iOS 26.5 iPhone 12 Pro Max simulator. The original application executable
remained unchanged throughout both capture runs. The second run used a private,
ad-hoc-signed UI-test runner copy; no application source or repository test was
modified for the images. The selected sources are:

| Image | Capture source | Verification |
|---|---|---|
| 01 | Adjusted capture journey, `ASC_01_home-with-first-pebble` | Private test-copy-only four-second wait for the normal landing toast to disappear; clean Home visually reviewed |
| 02 | Original capture journey, `ASC_02_25-minute-focus` | Original capture journey, 1 test passed |
| 03 | Original capture journey, `ASC_03_completion-reward` | Original capture journey, 1 test passed |
| 04 | Original capture journey, `ASC_04_accumulation-overview` | Original capture journey, 1 test passed |
| 05 | Settings natural-scroll capture, `ASC_05_privacy-position-1` | Separate Settings-navigation capture in the private test runner; version and production privacy explanation visually reviewed |

The original capture journey passed (1 of 1 tests). The adjusted journey and
the separate Settings capture also passed (2 of 2 tests). The initial 01
(landing toast) and initial 05 (Simulator diagnostics) were rejected on visual
review. The adjustments only wait for an ordinary transient toast to disappear
and scroll Settings normally. Reproduce these capture steps before adopting
01 and 05; the unmodified test's attachments alone are not composition approval.

All selected XCTest attachments were already RGB PNGs without an alpha channel
and were copied byte for byte, without pixel edits, cropping, or compositing.
Screenshot 03 shows the first saved 250g completion before the drop, with Close,
GIF, and 5-minute break actions. Signed-Release physical-device visual parity
remains a separate submission gate.
`shasum -a 256 -c AppStore/screenshots/checksums.sha256` verifies the five listing
images and the separate IAP review image.

## Historical IAP review image — 2026-09-06

Historical status: `captured_live_price`. Candidate status: `pending_live_price_capture`.

`history/iap-review-20260906.png` was captured on 2026-09-06 from
PomoGem version 1.0 build 5 on an iPhone 12 Pro Max simulator running iOS 26.5.
The Japanese production paywall displays `com.hinoshiba.pomogem.pro.lifetime`
returned by the actual `Product.products` request, without a local StoreKit
configuration. The US storefront supplied the displayed `$0.99` price through
`Product.displayPrice`; this is not a Japan-storefront price capture.

The image shows the 1–360 minute range, month labels on grouped pebbles,
one-time purchase, the pre-purchase seller-disclosure link, and Restore
Purchases. The capture test
`IAPCaptureUITests/testCaptureActualStoreKitPrice` passed (1 of 1 tests).
It opened the paywall and checked that its purchase control was available;
it did not perform a purchase, restore, or offer redemption.

The source attachment was `136CBBEE-68B6-4251-AF3B-0E604F56ECBD.png`, named
`01-pomogem-pro-live-price` in the XCTest result. It was already an opaque
1284 × 2778 RGB PNG and was copied byte for byte, with no cropping, price
replacement, compositing, or other pixel edits. Its hash is recorded in
`checksums.sha256` and `ASSET_LICENSES.md`.

The earlier product's price screenshot remains in a private historical
archive and is not included in this set. This new capture establishes the
paywall's visible product and price; it does not establish purchase/restore
success, signed-Release physical-device parity, or App Store Connect upload
and submission completion.

## English product page

The app UI and support are currently Japanese, and the `en-US` description
states that explicitly. Because these images contain no added Japanese
marketing copy, the exact same truthful UI set can be reused for `en-US`.
Either upload the same ordered set to that localization or let App Store
Connect inherit the Japanese set; do not create an English-looking custom set
until the binary itself has English UI.

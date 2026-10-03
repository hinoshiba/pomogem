# App Store screenshots

## Candidate 1.1.0 (10) refresh — 2026-09-30

The five `ja-JP/` and five `en-US/` images are byte-for-byte XCTest attachments
from the current product source at `b5441d3a0abc3214e2b5486ef7e2f4d5dd96d028`,
plus the screenshot test edits awaiting integration. Each language test passed
on a disposable iOS 26.5 iPhone 12 Pro Max Simulator at standard text size,
using the Debug-only deterministic fixture and the product's new-install
leave-pause default. All ten PNGs are 1284 × 2778 RGB without alpha; their
hashes are in `checksums.sha256` and `ASSET_LICENSES.md`. Image 02 shows the
Focus Music button in each language.

Image 05 now shows the four shipped Timer Display choices, avoiding the
Simulator-only iCloud warning in a Settings capture. Image 03 is a genuine
transition: the reward card says a 250 g gem was earned while the jar behind
it still shows 0 g until the card is closed. The optional daily-reminder offer
was dismissed before capture so its real clock time does not conflict with the
9:41 status bar override. Review the remaining 0 g transition before
uploading. The IAP review image was refreshed separately on 2026-10-01.
These ten images are candidates until compared with the final signed build on
a physical iPhone; App Store Connect still holds the older Japanese images,
which its English listing inherits.

## Original 1.1.0 (10) capture — 2026-09-22

The original five Japanese images and an earlier IAP image were
captured from PomoGem 1.1.0 (10) on an iOS 26.5 iPhone 12 Pro Max Simulator.
The original 01–05 files were superseded on 2026-09-30; the IAP review image
was superseded on 2026-10-01. All were unretouched XCTest attachments,
copied byte for byte as portrait 1284 × 2778 RGB PNGs without alpha.

Product source was `f3d7f456fdb9b8da05d77d2c4cdb9af4026039f2`; the capture-only
test changes were recorded in `1c40e4e9a2118101bc798a40df3bb2fd8ac11733` and
integrated into the release branch. The build used `MARKETING_VERSION=1.1.0`
and `CURRENT_PROJECT_VERSION=10`; the host, widget and Screen Time monitor
bundle versions were all checked. No product source change was needed for capture.

The retained private release evidence includes `capture-2.xcresult`,
`capture-2.log`, `capture-manifest.json`, and `CAPTURE-README.md`. The manifest
records each attachment's original filename, timestamp, dimensions and SHA-256.
Both selected tests passed: two tests, zero failures, zero skips. No images
from the earlier capture attempt are selected; its Settings accessibility-row
locator was corrected and the complete capture was rerun.

## IAP image refresh — 2026-10-01

`iap-review/01-pomogem-pro-live-price.png` now shows the paywall after the
settings-04 changes, with its three current Pro features ordered by entry
point, what stays free, and a month-label example.

## Japanese iPhone set

The App Store listing order is:

| File | Actual capture content | XCTest attachment prefix |
|---|---|---|
| `ja-JP/01-home-with-first-pebble.png` | Home after one deterministic 250g completion, with the normal 25-minute preset visible and the landing toast gone | `ASC_01_home-with-first-pebble` |
| `ja-JP/02-25-minute-focus.png` | Real 25-minute countdown and the ordinary notification-permission invitation | `ASC_02_25-minute-focus` |
| `ja-JP/03-completion-reward.png` | Normal completion card showing the production 25-minute reward; the fixture's short duration is hidden by the card and restored before the Home capture | `ASC_03_completion-reward` |
| `ja-JP/04-accumulation-overview.png` | Weekly and lifetime accumulation from the same 250g fixture | `ASC_04_accumulation-overview` |
| `ja-JP/05-timer-display.png` | All four Timer Display choices on one complete screen | `ASC_05_timer-display` |

The English set has the same five scenes, with English product UI and attachment
prefixes `ASC_EN_01` through `ASC_EN_05`. Its files are in `en-US/` with the
same basenames as the Japanese files.

The existing Debug-only local-preview/UI-test fixture creates one 250g record
through its 12-second test duration. It restores the visible duration to the
normal 25 minutes before the Home capture. The images do not
establish completion of a real 25-minute session or physical-device Screen Time
callbacks. No Screen Time permission or Pro entitlement was synthesized.

All images show the product UI in the named language with built-in content, without account
information, debug labels, promotional overlays, device frames or compositing.
The landing toast disappears normally; Simulator cloud diagnostics are absent
from the selected Timer Display screen. The product-page set contains no price
or purchased state. No optional Screen Time image is included because real-device
authorization was outside this capture task.

Physical-device visual comparison with the signed Release candidate remains a
separate submission requirement. These Simulator captures do not establish
Family Controls distribution approval, device behavior, or upload completion.

## Current IAP review image

Status: `captured_live_price`.

`iap-review/01-pomogem-pro-live-price.png` comes from main
`1c521ed2a90be5aa0c9153611bc6274de8522759`, captured on 2026-10-01 by
`RuntimeFlowAuditUITests/testCaptureActualStoreKitPrice` on a disposable
iOS 26.5 iPhone 12 Pro Max Simulator. The Debug build used version overrides
1.1.0 (10), standard text size, Japanese UI, local-preview test isolation,
and a 9:41 status bar. The test passed: one test, zero failures or skips.
The actual production `Product.products` path returned
`com.hinoshiba.pomogem.pro.lifetime`, without a StoreKit configuration file.
The generated xctestrun opted the test runner in with
`POMOGEM_CAPTURE_LIVE_STOREKIT=1`.
`Product.displayPrice` was `$0.99`; the purchase control read `$0.99でProを購入`.
The storefront country was not independently read, so this image establishes
neither a US storefront nor a Japanese-yen price.

The image shows all three current Pro benefits, including unlimited learning
apps, the one-time price, seller-disclosure link, and purchase button. Restore
Purchases starts below the captured viewport. No purchase, restore, or offer
redemption was invoked. This is price/display evidence, not a purchase or
restore test.

The original source attachment was `82B5D009-430D-45BC-9293-62C5AC9E8C1C.png`,
with attachment prefix `IAP_01-pomogem-pro-live-price`. It was copied byte for
byte as a 1284 × 2778 RGB PNG without alpha. The result bundle and attachment
are retained outside the public repository under
`~/.codex/release-validation/pomogem-20261001/IAP/`. Its SHA-256 is recorded in
`checksums.sha256` and `ASSET_LICENSES.md`. This Simulator image still needs
comparison with the final signed device build; the older image remains in
App Store Connect until that review and replacement are complete.

## Reproduce

Use a disposable iPhone 12 Pro Max Simulator on an installed iOS runtime and
keep build products and results outside the checkout. The following names match
the capture tests in `PomoGemUITests/RuntimeFlowAuditUITests.swift`.

```sh
SCREENSHOT_DEVICE_ID=$(xcrun simctl create \
  'PomoGem App Store 6.5-inch' \
  com.apple.CoreSimulator.SimDeviceType.iPhone-12-Pro-Max \
  com.apple.CoreSimulator.SimRuntime.iOS-26-5)
xcrun simctl boot "$SCREENSHOT_DEVICE_ID"
xcrun simctl bootstatus "$SCREENSHOT_DEVICE_ID" -b
xcrun simctl status_bar "$SCREENSHOT_DEVICE_ID" override \
  --time '9:41' --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularBars 4 --operatorName ''

SCREENSHOT_RESULTS=$(mktemp -d /tmp/PomoGemScreenshots.XXXXXX)
xcodebuild \
  -project PomoGem.xcodeproj -scheme PomoGem -configuration Debug \
  -destination "platform=iOS Simulator,id=$SCREENSHOT_DEVICE_ID" \
  -derivedDataPath "$SCREENSHOT_RESULTS/DerivedData" \
  MARKETING_VERSION=1.1.0 CURRENT_PROJECT_VERSION=10 \
  build-for-testing
```

The test setup itself sets `POMOGEM_LOCAL_PREVIEW=1` and
`POMOGEM_UI_TEST_MODE=1`, with Japanese language/locale. The listing journey
needs no extra opt-in. The live-price test skips unless its test-runner process
receives `POMOGEM_CAPTURE_LIVE_STOREKIT=1`. Set that flag only for a deliberate
capture; do not configure a StoreKit test file or manufacture a product price.
For the generated xctestrun format used by this project:

```sh
python3 - "$SCREENSHOT_RESULTS/DerivedData/Build/Products" <<'PY'
from pathlib import Path
import plistlib
import sys

products = Path(sys.argv[1])
run_files = list(products.glob('*.xctestrun'))
assert len(run_files) == 1, 'Choose the intended generated xctestrun file'
run = run_files[0]
data = plistlib.loads(run.read_bytes())
data['PomoGemUITests'].setdefault('EnvironmentVariables', {})[
    'POMOGEM_CAPTURE_LIVE_STOREKIT'
] = '1'
run.write_bytes(plistlib.dumps(data))
PY

xcodebuild \
  -xctestrun "$SCREENSHOT_RESULTS"/DerivedData/Build/Products/*.xctestrun \
  -destination "platform=iOS Simulator,id=$SCREENSHOT_DEVICE_ID" \
  -resultBundlePath "$SCREENSHOT_RESULTS/PomoGemScreenshots.xcresult" \
  -parallel-testing-enabled NO \
  -only-testing:PomoGemUITests/RuntimeFlowAuditUITests/testAppStoreScreenshotSetJapaneseReleaseCandidate \
  -only-testing:PomoGemUITests/RuntimeFlowAuditUITests/testAppStoreScreenshotSetEnglishReleaseCandidate \
  -only-testing:PomoGemUITests/RuntimeFlowAuditUITests/testCaptureActualStoreKitPrice \
  test-without-building

xcrun xcresulttool export attachments \
  --path "$SCREENSHOT_RESULTS/PomoGemScreenshots.xcresult" \
  --output-path "$SCREENSHOT_RESULTS/attachments"
```

Map the five `ASC_`, five `ASC_EN_`, and one `IAP_` attachment using the exported
`manifest.json`. Visually inspect the actual images and copy the selected
attachments unchanged. A skipped live-price test does not produce price evidence.
Record new provenance and checksums when adopting a replacement capture.

```sh
for screenshot in AppStore/screenshots/ja-JP/*.png AppStore/screenshots/en-US/*.png AppStore/screenshots/iap-review/*.png; do
  sips -g pixelWidth -g pixelHeight -g hasAlpha -g space -g format "$screenshot"
done
shasum -a 256 -c AppStore/screenshots/checksums.sha256
```

The eleven files currently in the repository should report 1284 × 2778, RGB, PNG, and no
alpha. The checksum manifest also covers the separate historical image below.

## Historical IAP review image — 2026-09-06

`history/iap-review-20260906.png` is retained only as a historical PomoGem 1.0
build 5 capture from an iOS 26.5 iPhone 12 Pro Max Simulator. It is not the
current candidate's review image and does not show the new unlimited
learning-app benefit. The ten current listing files replace the earlier
September 6 listing set.

The historical capture used the actual `Product.products` request without a
local StoreKit configuration and displayed `$0.99`. It showed the earlier Pro
benefits, one-time purchase, seller disclosure and Restore Purchases.
`IAPCaptureUITests/testCaptureActualStoreKitPrice` passed without purchasing,
restoring or redeeming an offer.

Its source attachment was `136CBBEE-68B6-4251-AF3B-0E604F56ECBD.png`, named
`01-pomogem-pro-live-price`. It was copied unchanged as an opaque 1284 × 2778
RGB PNG; its hash remains in `checksums.sha256` and `ASSET_LICENSES.md`.

## English product page

The published 1.0.2 screenshots show Japanese UI. The 1.1.0 candidate supports
English and Japanese UI; support remains in Japanese. The `en-US/` images show
the English UI from the same Simulator candidate as `ja-JP/`. Compare them
with the final signed physical-device build and replace the inherited Japanese
images in App Store Connect before submission.

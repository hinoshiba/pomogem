# App Store screenshots

## Current 1.1.1 (13) capture — 2026-10-12

The five `ja-JP/`, five `en-US/`, and `iap-review/01-pomogem-pro-live-price.png`
files are unretouched XCTest attachments captured from main source
`988830ec02d5585e18e1d6b747c4bcb3241147ff`, with the release version set to
1.1.1 (13). The host, widget, and Screen Time monitor versions were verified.
All three existing capture tests passed, with zero failures and zero skips,
on a dedicated disposable iOS 26.5 iPhone 12 Pro Max Simulator at standard
text size. No application or test source changes were needed for capture.

The images were visually inspected and copied byte for byte. All eleven
are 1284 × 2778 RGB PNGs without alpha. `checksums.sha256` and
`ASSET_LICENSES.md` record the new hashes. The private release evidence keeps
`Capture.xcresult`, `capture.log`, the original exported attachment manifest,
and `capture-manifest.json` with exact attachment filenames, timestamps and hashes.
The Simulator was shut down after capture; other Simulator devices were not changed.

Home now shows 25 minutes of growing time and 3 hours 45 minutes until the
first crystal. The overview uses the same 250 g fixture. Image 03 retains
the real acknowledgement-before-landing transition: the reward card shows
25 minutes / 250 g while Home behind it remains 0 g until Close. The English
capture also includes the ordinary jar-interaction hint and GIF button.
No screenshot advertises ten-session fusion or Pro month stamps. Image 05
still shows the four shipped Timer Display choices.

The Debug-only fixture shortens one focus to 12 seconds while retaining the
production 25-minute reward; the test-only duration is hidden by the completion
card and the ordinary 25-minute preset is restored before Home is captured.
This is visual evidence, not evidence that a real 25-minute focus completed.
No Pro entitlement or Screen Time authorization was fabricated.

On 2026-10-12, all ten listing images and the IAP image were saved in App
Store Connect and verified after media reload. Japanese and English each
show five currentFaceIDLarge images. Older DynamicIslandLarge references
were removed from the listing while their source assets remain in the asset
library. The app and IAP were submitted at 13:38 JST and both show Waiting
for Review. Comparison with the signed physical-device build remains pending;
the Simulator captures and Connect receipt do not establish that comparison.
The dated 1.1.0 sections below describe superseded capture history.

## Historical 1.1.0 (10) refresh — 2026-09-30

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

## Historical IAP image refresh — 2026-10-01

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

`iap-review/01-pomogem-pro-live-price.png` was captured on 2026-10-12 at
12:39:59.718 JST by `RuntimeFlowAuditUITests/testCaptureActualStoreKitPrice`
from the same main source and 1.1.1 (13) Debug build as the listing images.
The test passed without failures or skips. The generated xctestrun contained
no StoreKit configuration reference; only the explicit test-runner opt-in
`POMOGEM_CAPTURE_LIVE_STOREKIT=1` was added.

The production `Product.products` path returned the existing
`com.hinoshiba.pomogem.pro.lifetime` product. The live purchase label was
`$0.99でProを購入`, and the image displays `$0.99`. The storefront country was
not independently read, so this establishes neither a US storefront nor a
Japanese-yen price. No purchase, restore, or offer redemption was invoked.

The image shows the two current Pro benefits: custom focus durations and
unlimited learning apps. It does not advertise month labels. The one-time
price, seller-disclosure link, purchase button, and Restore Purchases are visible.
It is price/display evidence, not a purchase or restore test.

The original attachment is `60855EB9-8FE0-4C8B-AF0E-D85417BF8E51.png`, named
`IAP_01-pomogem-pro-live-price`. Its SHA-256 is
`0c7ef153e90c8022a946dc4e5c69212e8073ac33bd6e62b03410175e4892ec1d`.
It was copied unchanged as a 1284 × 2778 opaque RGB PNG. App Store Connect
replacement and signed-device comparison must be recorded separately.

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
  MARKETING_VERSION=1.1.1 CURRENT_PROJECT_VERSION=13 \
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

The `en-US/` images show English production UI from the same 1.1.1 (13)
Simulator capture as `ja-JP/`. The product supports English and Japanese UI;
support remains in Japanese. Upload these files for English rather than
inheriting older Japanese images, and verify the saved listing after reload.

# App Store screenshots

## Candidate 1.1.0 (10) — 2026-09-22

The five images in `ja-JP/` and the separate image in `iap-review/` were captured
from PomoGem 1.1.0 (10) on an iOS 26.5 iPhone 12 Pro Max Simulator. All six are
unretouched XCTest attachments, copied byte for byte as portrait 1284 × 2778
RGB PNGs without alpha. Their hashes are recorded in `checksums.sha256` and
`ASSET_LICENSES.md`.

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

## Pending recapture after the Settings reorganisation

`ja-JP/05-iCloud-and-privacy.png` and `iap-review/01-pomogem-pro-live-price.png`
show layouts that changed after this capture (settings-06 and settings-04):

- Settings no longer has the inert 「iCloud／あなたのプライベートデータベースのみ」 row or the
  top-level 「クレジット」 card. The storage and privacy promise is the footer of
  「サポートとプライバシー」 (「記録はあなたのiCloudに保存されます。開発者が記録を受け取ることは
  ありません。」), and the version is on the 「このアプリについて」 row below it.
- The paywall orders its three Pro features by entry point, says what stays free,
  and shows a month-label example.

`testAppStoreScreenshotSetJapaneseReleaseCandidate` already captures the new
Settings layout as `ASC_05_iCloud-and-privacy`. Recapture both images with the
procedure below before the 1.1.0 submission and update this file, the checksums
and `ASSET_LICENSES.md`. The images in this folder remain an exact record of the
1.1.0 (10) capture until then.

The frame for image 05 needs an owner decision before that recapture:

- The privacy promise is now the footer of 「サポートとプライバシー」, near the end of
  Settings. The List cannot scroll past its last row, so the Simulator frame that
  shows the footer also shows the card above it: 「データを書き出す」, the red
  「表示中の記録をリセット」 row and the export disclosure. No iCloud row is visible.
- The iCloud section can't be the frame in the Simulator. That section shows the
  Simulator's own diagnostics (「iCloudは実機で確認できます」), and this set must not
  contain them.
- The options:
  - capture 05 on a physical iPhone, framed on the iCloud section (the export
    card still sits between that section and the privacy footer);
  - keep the Simulator frame as it is;
  - use a different screen for 05.

  Record the choice here when you recapture.

## Japanese iPhone set

The App Store listing order is:

| File | Actual capture content | XCTest attachment prefix |
|---|---|---|
| `ja-JP/01-home-with-first-pebble.png` | Home after one deterministic 250g completion, with the normal 25-minute preset visible and the landing toast gone | `ASC_01_home-with-first-pebble` |
| `ja-JP/02-25-minute-focus.png` | Real 25-minute countdown and the ordinary notification-permission invitation | `ASC_02_25-minute-focus` |
| `ja-JP/03-completion-reward.png` | Normal completion card, with the visible preset restored to 25 minutes before capture | `ASC_03_completion-reward` |
| `ja-JP/04-accumulation-overview.png` | Weekly and lifetime accumulation from the same 250g fixture | `ASC_04_accumulation-overview` |
| `ja-JP/05-iCloud-and-privacy.png` | Naturally scrolled Settings showing its privacy explanation and version 1.1.0 (10) | `ASC_05_iCloud-and-privacy` |

The existing Debug-only local-preview/UI-test fixture creates one 250g record
through its 12-second test duration. It restores the visible duration to the
normal 25 minutes before the completion and Home captures. The images do not
establish completion of a real 25-minute session or physical-device Screen Time
callbacks. No Screen Time permission or Pro entitlement was synthesized.

All images show Japanese product UI with built-in content, without account
information, debug labels, promotional overlays, device frames or compositing.
The landing toast disappears normally; Simulator cloud diagnostics are outside
the naturally scrolled Settings viewport. The product-page set contains no price
or purchased state. No optional Screen Time image is included because real-device
authorization was outside this capture task.

Physical-device visual comparison with the signed Release candidate remains a
separate submission requirement. These Simulator captures do not establish
Family Controls distribution approval, device behavior, or upload completion.

## Current IAP review image

Status: `captured_live_price`.

`iap-review/01-pomogem-pro-live-price.png` comes from
`RuntimeFlowAuditUITests/testCaptureActualStoreKitPrice` in the same passing
capture run. The actual `Product.products` path returned
`com.hinoshiba.pomogem.pro.lifetime`, without a StoreKit configuration file.
`Product.displayPrice` was `$0.99`; the purchase control read `$0.99でProを購入`.
The storefront country was not independently read, so this image establishes
neither a US storefront nor a Japanese-yen price.

The image shows all three current Pro benefits, including unlimited learning
apps, the one-time price, seller-disclosure link, and purchase button. Restore
Purchases starts below the captured viewport. No purchase, restore, or offer
redemption was invoked. This is price/display evidence, not a purchase or
restore test.

The original source attachment was `8686D580-F195-471C-B06B-46FBEE628EC6.png`,
with attachment prefix `IAP_01-pomogem-pro-live-price`. The selected capture
passed before the explicit live-StoreKit opt-in guard was added to the test;
the capture path after that guard is unchanged. A focused follow-up on the same
Simulator verified one intentional skip without the flag and one passing test
with the flag. Those follow-up runs did not replace any selected image.

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
  -only-testing:PomoGemUITests/RuntimeFlowAuditUITests/testCaptureActualStoreKitPrice \
  test-without-building

xcrun xcresulttool export attachments \
  --path "$SCREENSHOT_RESULTS/PomoGemScreenshots.xcresult" \
  --output-path "$SCREENSHOT_RESULTS/attachments"
```

Map the five `ASC_` attachments and one `IAP_` attachment using the exported
`manifest.json`. Visually inspect the actual images and copy the selected
attachments unchanged. A skipped live-price test does not produce price evidence.
Record new provenance and checksums when adopting a replacement capture.

```sh
for screenshot in AppStore/screenshots/ja-JP/*.png AppStore/screenshots/iap-review/*.png; do
  sips -g pixelWidth -g pixelHeight -g hasAlpha -g space -g format "$screenshot"
done
shasum -a 256 -c AppStore/screenshots/checksums.sha256
```

The current six candidate files should report 1284 × 2778, RGB, PNG, and no
alpha. The checksum manifest also covers the separate historical image below.

## Historical IAP review image — 2026-09-06

`history/iap-review-20260906.png` is retained only as a historical PomoGem 1.0
build 5 capture from an iOS 26.5 iPhone 12 Pro Max Simulator. It is not the
current candidate's review image and does not show the new unlimited
learning-app benefit. The five current listing files replace the earlier
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

The app UI and support are currently Japanese, which the `en-US` description
states. The same five Japanese product-UI images can be reused for `en-US`;
there is no added marketing text to translate. Upload the same ordered set or
let App Store Connect inherit the Japanese set. An English-looking custom set
would require corresponding English UI in the binary.

# App Store screenshots

## Japanese iPhone set

`ja-JP/` contains five release-intended product-UI screenshots captured with a
Debug-only deterministic fixture, in the intended App Store order:

1. `01-home-with-first-pebble.png` — Home bottle after one deterministic 250g completion
2. `02-25-minute-focus.png` — the real free 25-minute focus timer in progress
3. `03-completion-reward.png` — the post-completion reward and exact ×10 progress
4. `04-accumulation-overview.png` — weekly and lifetime accumulation overview
5. `05-iCloud-and-privacy.png` — the shipped private-iCloud and no-tracking
   explanation, ordinary display reset, and Apple iCloud storage-management
   guidance. It contains no in-app direct CloudKit deletion row.

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

The set deliberately omits the paywall while the live App Store Connect
product is being created. It therefore contains neither a hard-coded price nor
a synthetic purchased state. If a paywall screenshot is added later, capture
the localized `Product.displayPrice` supplied by StoreKit; do not draw a price
into the image.

The test fixture uses a Debug-only 12-second timer to create one 250g record,
but it closes that picker before capture. The reward it creates is the same
250g normal pebble as a real 25-minute completion. Version 1.0's release policy
disables random rewards, so this set cannot randomly change.

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
  com.apple.CoreSimulator.SimRuntime.iOS-26-3

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

The checked-in set was regenerated on 2026-09-04 from version 1.0 build 3 with
Xcode 26.3 and a Debug-only deterministic fixture on an iOS 26.3 iPhone 13 Pro
Max simulator, after direct CloudKit deletion was disabled for version 1.0. The
capture journey passed with one test and zero failures. Screenshot 03 shows the
first 250g completion and its 5-minute break. Its stable three-column action row
keeps Close on the left and Break on the right even before the delayed GIF chip
appears, instead of shifting both actions to one side. Screenshot 05 shows
version `1.0 (3)`. Signed-Release physical-device visual parity remains a
separate submission gate.
`shasum -a 256 -c AppStore/screenshots/checksums.sha256` verifies the five
reviewed binaries.

## English product page

The app UI and support are currently Japanese, and the `en-US` description
states that explicitly. Because these images contain no added Japanese
marketing copy, the exact same truthful UI set can be reused for `en-US`.
Either upload the same ordered set to that localization or let App Store
Connect inherit the Japanese set; do not create an English-looking custom set
until the binary itself has English UI.

#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

MODE=${1:-standard}
case "$MODE" in
  standard|--release) ;;
  *)
    echo "error: usage: $0 [--release]" >&2
    exit 2
    ;;
esac

required_files='README.md
LICENSE
LICENSE-fonts.txt
PRIVACY.md
SECURITY.md
CONTRIBUTING.md
CODE_OF_CONDUCT.md
TRADEMARKS.md
ASSET_LICENSES.md
THIRD_PARTY_NOTICES.md
Docs/RELEASING.md
Docs/OSS_PUBLISHING.md
Docs/LICENSE_AUDIT.md
Scripts/check-git-public-metadata.py
Scripts/public_mailbox_policy.py
Scripts/check-published-site-policy.sh
AppStore/README.md
AppStore/configuration.yml
AppStore/app-privacy.md
AppStore/age-rating.md
AppStore/export-compliance.md
AppStore/submission-checklist.md
AppStore/connect-entry-plan.md
AppStore/screenshots/checksums.sha256
project.yml
PomoGem.xcodeproj/project.pbxproj
PomoGem.xcodeproj/xcshareddata/xcschemes/PomoGem.xcscheme
PomoGem/Resources/PrivacyInfo.xcprivacy
PomoGemWidgets/PrivacyInfo.xcprivacy
Brand/AppIcon-FocusCycle-v5-source.png
PomoGem/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-FocusCycle-v5.png
http_dists/og-pomogem-v1.png
http_dists/public/app-icon-focus-v5.png
http_dists/public/apple-touch-icon.png
http_dists/public/app-home-v3.webp
http_dists/public/app-timer-v2.webp
http_dists/index.html
http_dists/privacy/index.html
http_dists/support/index.html
http_dists/terms/index.html
http_dists/commercial-transactions/index.html
http_dists/CNAME
http_dists/.nojekyll'

printf '%s\n' "$required_files" | while IFS= read -r path; do
  if [ ! -e "$path" ]; then
    echo "error: required public file is missing: $path" >&2
    exit 1
  fi
  if [ "$path" != 'http_dists/.nojekyll' ] && [ ! -s "$path" ]; then
    echo "error: required public file is empty: $path" >&2
    exit 1
  fi
done

if ! command -v rg >/dev/null 2>&1; then
    echo "error: ripgrep is required for the OSS audit" >&2
    exit 1
fi

# Jar sound is intentionally synthesized from MIT-licensed source at runtime.
# Fail closed if a recording, stock sample, generated audio file, or AHAP asset
# is later added without updating the commercial license/privacy audit.
audio_assets=$(rg --files | rg -i '\.(wav|caf|mp3|aiff|aif|m4a|aac|ac3|eac3|flac|ogg|oga|opus|mid|midi|ahap)$' || true)
if [ -n "$audio_assets" ]; then
  echo "error: bundled audio or AHAP asset requires explicit license review" >&2
  printf '%s\n' "$audio_assets" >&2
  exit 1
fi

if ! command -v plutil >/dev/null 2>&1; then
  echo "error: plutil is required for the Apple bundle audit" >&2
  exit 1
fi

if ! command -v ruby >/dev/null 2>&1; then
  echo "error: Ruby is required for the YAML syntax audit" >&2
  exit 1
fi

# Generated build state and Xcode's per-user state are never part of the
# publication candidate, even when they are ignored by Git. Failing before the
# content scan prevents a maintainer from accidentally archiving the working
# folder itself instead of publishing the reviewed allowlist.
generated_directories=$(find . \
  -path './.git' -prune -o \
  -type d \( -name 'DerivedData*' -o -name 'Artifacts' -o -name 'xcuserdata' \) \
  -print)
if [ -n "$generated_directories" ]; then
  echo "error: generated or per-user directory exists in the public candidate" >&2
  printf '%s\n' "$generated_directories" >&2
  exit 1
fi

# The current source tree intentionally contains no symlinks. Rejecting one if
# it appears avoids publishing a link that escapes the reviewed repository or
# resolves differently on a maintainer's machine and on GitHub Actions.
symlink_paths=$(find . -path './.git' -prune -o -type l -print)
if [ -n "$symlink_paths" ]; then
  echo "error: symbolic links require an explicit publication review" >&2
  printf '%s\n' "$symlink_paths" >&2
  exit 1
fi

ruby -e 'require "psych"; ARGV.each { |path| Psych.parse_file(path) }' \
  AppStore/configuration.yml \
  .github/dependabot.yml \
  .github/workflows/*.yml \
  .github/ISSUE_TEMPLATE/*.yml

plutil -lint PomoGem/Info.plist >/dev/null
plutil -lint PomoGem/Resources/PrivacyInfo.xcprivacy >/dev/null
plutil -lint PomoGemWidgets/PrivacyInfo.xcprivacy >/dev/null
plutil -lint PomoGem/PomoGem.entitlements >/dev/null
plutil -lint PomoGemWidgets/PomoGemWidgets.entitlements >/dev/null
python3 - <<'PY'
import plistlib
from pathlib import Path

def load(path: str):
    with Path(path).open("rb") as handle:
        return plistlib.load(handle)

def require(condition: bool, message: str):
    if not condition:
        raise SystemExit(f"error: {message}")

main_manifest = load("PomoGem/Resources/PrivacyInfo.xcprivacy")
require(main_manifest.get("NSPrivacyTracking") is False, "main privacy manifest must disable tracking")
require(main_manifest.get("NSPrivacyTrackingDomains") == [], "main privacy manifest must not list tracking domains")
require(main_manifest.get("NSPrivacyCollectedDataTypes") == [], "main privacy manifest must not declare collected data")
required_reasons = {
    item["NSPrivacyAccessedAPIType"]: set(item["NSPrivacyAccessedAPITypeReasons"])
    for item in main_manifest.get("NSPrivacyAccessedAPITypes", [])
}
require(
    required_reasons == {
        "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1"},
        "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1"},
        "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1"},
    },
    "main privacy manifest required-reason declarations differ from the reviewed allowlist",
)

widget_manifest = load("PomoGemWidgets/PrivacyInfo.xcprivacy")
require(widget_manifest.get("NSPrivacyTracking") is False, "widget privacy manifest must disable tracking")
require(widget_manifest.get("NSPrivacyTrackingDomains") == [], "widget privacy manifest must not list tracking domains")
require(widget_manifest.get("NSPrivacyCollectedDataTypes") == [], "widget privacy manifest must not declare collected data")
widget_required_reasons = {
    item["NSPrivacyAccessedAPIType"]: set(item["NSPrivacyAccessedAPITypeReasons"])
    for item in widget_manifest.get("NSPrivacyAccessedAPITypes", [])
}
require(
    widget_required_reasons == {},
    "widget privacy manifest required-reason declarations differ from the reviewed allowlist",
)

info = load("PomoGem/Info.plist")
require(info.get("CFBundleDisplayName") == "ポモジェム", "main display name differs from the current brand")
require(
    info.get("CFBundleURLTypes") == [{
        "CFBundleURLName": "com.hinoshiba.pomogem",
        "CFBundleURLSchemes": ["pomogem"],
    }],
    "main URL registration differs from the new app identifier and scheme",
)
require(info.get("ITSAppUsesNonExemptEncryption") is False, "export-compliance declaration must remain false")
require(info.get("POMOGEM_PRIVACY_POLICY_URL") == "https://pomogem.hinoshiba.com/privacy/", "privacy policy URL differs from the canonical URL")
require(info.get("NSHumanReadableCopyright") == "Copyright © 2026 hinoshiba", "main bundle copyright differs from the release record")
require(
    info.get("NSMotionUsageDescription")
    == "端末の傾きや振る操作に合わせて瓶の粒を動かすために使います。値は保存・送信しません。",
    "motion purpose string differs from the reviewed on-device-only behavior",
)

widget_info = load("PomoGemWidgets/Info.plist")
require(widget_info.get("CFBundleDisplayName") == "ポモジェム", "widget display name differs from the current brand")
require(widget_info.get("NSHumanReadableCopyright") == "Copyright © 2026 hinoshiba", "widget bundle copyright differs from the release record")
require(info.get("NSSupportsLiveActivities") is True, "main bundle must enable the reviewed account-neutral Live Activity")
require(widget_info.get("NSSupportsLiveActivities") in (None, False), "widget bundle must not enable Live Activities for version 1")

app_entitlements = load("PomoGem/PomoGem.entitlements")
require(app_entitlements.get("aps-environment") == "$(APS_ENVIRONMENT)", "app APNs entitlement must use the reviewed build setting")
require(
    app_entitlements.get("com.apple.developer.icloud-container-identifiers") == [
        "iCloud.com.hinoshiba.pomogem",
    ],
    "app iCloud container entitlement differs from the release identifier",
)
require(app_entitlements.get("com.apple.developer.icloud-services") == ["CloudKit"], "app iCloud services entitlement must contain only CloudKit")
require(
    "com.apple.security.application-groups" not in app_entitlements,
    "main app must not retain the removed App Group entitlement",
)

widget_entitlements = load("PomoGemWidgets/PomoGemWidgets.entitlements")
for forbidden in (
    "aps-environment",
    "com.apple.developer.icloud-container-identifiers",
    "com.apple.developer.icloud-container-environment",
    "com.apple.developer.icloud-services",
    "com.apple.security.application-groups",
):
    require(forbidden not in widget_entitlements, f"neutral widget source entitlements contain {forbidden}")
PY
python3 Scripts/validate-site.py
if [ "$MODE" = '--release' ]; then
  python3 Scripts/validate-store-metadata.py --release
else
  python3 Scripts/validate-store-metadata.py
fi

grep -Fqx '        SUPPORTS_MACCATALYST: false' project.yml
grep -Fqx '        CODE_SIGN_STYLE: Automatic' project.yml
grep -Fq 'ITSAppUsesNonExemptEncryption: false' project.yml
grep -Fq 'FocusLiveActivityWidget()' \
  PomoGemWidgets/PomoGemWidgetsBundle.swift
grep -Fq 'static let widgetKind = "PomoGemFocusLiveActivity"' \
  Shared/FocusActivityAttributes.swift
grep -Fq 'FocusLiveActivityWidget.swift in Sources' \
  PomoGem.xcodeproj/project.pbxproj
grep -Fq 'FocusActivityManager.swift in Sources' \
  PomoGem.xcodeproj/project.pbxproj

focus_attributes_source_entries=$(grep -Fc \
  'FocusActivityAttributes.swift in Sources' \
  PomoGem.xcodeproj/project.pbxproj)
if [ "$focus_attributes_source_entries" -lt 4 ]; then
  echo "error: shared Live Activity attributes must belong to both app and Widget source phases" >&2
  exit 1
fi

if rg -n 'macCatalyst|PomoGemCatalyst|sdk=macosx|SUPPORTS_MACCATALYST: true' project.yml; then
  echo "error: Mac Catalyst configuration remains in project.yml" >&2
  exit 1
fi

if [ -e PomoGem/PomoGemCatalyst.entitlements ]; then
  echo "error: obsolete Catalyst entitlement is present" >&2
  exit 1
fi

if rg -n 'iCloud\.com\.hinoshiba\.pomogem\.operations' \
    project.yml PomoGem/PomoGem.entitlements PomoGem.xcodeproj/project.pbxproj; then
  echo "error: disabled rare-reward operations container remains in shipping configuration" >&2
  exit 1
fi

grep -Fqx '    static let isEnabled = false' \
  PomoGem/Core/RareRewardLedgerLocalState.swift
grep -Fqx '    static let isEnabled = false' \
  PomoGem/Core/DataDeletion/CompleteDataDeletionTypes.swift
python3 - <<'PY'
from pathlib import Path

source = Path("PomoGem/Core/PersistenceStoreTopology.swift").read_text()
start = source.index("private static let cloudModelTypes")
end = source.index("private static let localProjectionModelTypes", start)
cloud_block = source[start:end]
for forbidden in ("RareRewardPendingCommit.self", "RareRewardLedgerCursor.self"):
    if forbidden in cloud_block:
        raise SystemExit(f"error: shipping CloudKit schema includes {forbidden}")
for required in (
    "Subject.self",
    "StudySession.self",
    "AchievementStone.self",
    "Prefs.self",
    "ActivityResetMarker.self",
    "SyncedFocusTimer.self",
    "FocusTimerDeviceClaim.self",
):
    if required not in cloud_block:
        raise SystemExit(f"error: shipping CloudKit schema omits {required}")
PY

if rg -n 'iPhoneとMac|iPhone・Mac|Mac版|Mac・機種変更' PomoGem --glob '*.swift'; then
  echo "error: user-facing Mac support claim remains in the iPhone app" >&2
  exit 1
fi

if rg -n '^[[:space:]]*PROVISIONING_PROFILE(_SPECIFIER)?([[:space:]]|:|=)' \
    project.yml PomoGem.xcodeproj --glob 'project.yml' --glob '*.pbxproj'; then
  echo "error: provisioning profile selector must not be committed" >&2
  exit 1
fi

if rg -n '^[[:space:]]*DEVELOPMENT_TEAM([[:space:]]|:|=)' \
    project.yml PomoGem.xcodeproj --glob 'project.yml' --glob '*.pbxproj'; then
  echo "error: a local signing team selector is committed" >&2
  exit 1
fi

for debug_file in PomoGem/Debug/*.swift; do
  first_line=$(sed -n '1p' "$debug_file")
  case "$first_line" in
    '#if DEBUG'*) ;;
    *)
      echo "error: Debug source is not compile-gated on line 1: $debug_file" >&2
      exit 1
      ;;
  esac
done

python3 - <<'PY'
import json
from pathlib import Path

store = json.loads(Path("PomoGem/Resources/Products.storekit").read_text())
products = store.get("products", [])
if len(products) != 1:
    raise SystemExit("error: exactly one StoreKit product is required")
product = products[0]
if product.get("productID") != "com.hinoshiba.pomogem.pro.lifetime":
    raise SystemExit("error: StoreKit product identifier differs from the release identifier")
if product.get("type") != "NonConsumable":
    raise SystemExit("error: StoreKit product must remain NonConsumable")
if product.get("displayPrice") != "100":
    raise SystemExit("error: local StoreKit test price must remain JPY 100")
PY

check_hash() {
  expected=$1
  path=$2
  actual=$(shasum -a 256 "$path" | awk '{print $1}')
  if [ "$actual" != "$expected" ]; then
    echo "error: asset hash changed; review origin/license and update ASSET_LICENSES.md: $path" >&2
    exit 1
  fi
}

check_hash 9b83d0ac419add475e4e3cf4ff42dabb7bb7340a4a59eddfe6dcdeb2dd5859cc \
  Brand/AppIcon-FocusCycle-v5-source.png
check_hash 1c8c4ac81b99a2201fdaa3a723ca2e76ee08350970f3243053d0d8b4d37ae15e \
  PomoGem/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-FocusCycle-v5.png
check_hash a0ee59d504570ad0ce53c2710b2c2114a2518d7ee10e098d1e5787943d19add7 \
  http_dists/public/app-icon-focus-v5.png
check_hash 50dda39716f125b546d72f379192318530df845f4205fbdb240f55d5564a453a \
  http_dists/public/apple-touch-icon.png
check_hash a434e1526f860cc2765ec4a02fae07e151edf3d239b8be053e66a7eaf27fee99 \
  http_dists/og-pomogem-v1.png
check_hash e36fad494ed4223b21f518d68b5aad1649dc893a94b402442d2dc8a3bddc896a \
  http_dists/public/app-home-v3.webp
check_hash 24a79a83b7fb5cbc58aad0dc304d8b02c920ca611d7953bca511d2e42173ee77 \
  http_dists/public/app-timer-v2.webp
check_hash b60d2fe464f4460702be923976c5865dfca487b189072ac249638eac1e1ec1ca \
  Brand/AppIcon-FocusVessel-v4-source.png
check_hash 30d8c4b856a46dc87a00c5c09861df6a008ffce8092a0a3f72bea4b074e3a4f8 \
  Brand/AppIcon-Aurora-v3-legacy.png
check_hash b6a9e5e324e13978eeb0806ce051ca51304571d4fb22544916c55cc8350a8e66 \
  PomoGem/Resources/Assets.xcassets/focus.aurora.imageset/focus-aurora.png
check_hash 6bd74fe76cd39ee0ec18775c3661d845343fb3f6f8fa09a3076638417baf741f \
  PomoGem/Resources/Fonts/ZenMaruGothic-Black.ttf
check_hash 6bd74fe76cd39ee0ec18775c3661d845343fb3f6f8fa09a3076638417baf741f \
  http_dists/public/ZenMaruGothic-Black.ttf

shasum -a 256 -c AppStore/screenshots/checksums.sha256 >/dev/null
python3 - "$MODE" <<'PY'
import hashlib
import re
import sys
from pathlib import Path, PurePosixPath

ledger_path = Path("ASSET_LICENSES.md")
manifest_path = Path("AppStore/screenshots/checksums.sha256")
expected_paths = {
    "AppStore/screenshots/ja-JP/01-home-with-first-pebble.png",
    "AppStore/screenshots/ja-JP/02-25-minute-focus.png",
    "AppStore/screenshots/ja-JP/03-completion-reward.png",
    "AppStore/screenshots/ja-JP/04-accumulation-overview.png",
    "AppStore/screenshots/ja-JP/05-iCloud-and-privacy.png",
}
iap_image = "AppStore/screenshots/iap-review/01-pomogem-pro-live-price.png"
configuration = Path("AppStore/configuration.yml").read_text()
statuses = re.findall(r"^    review_screenshot_status: ([a-z_]+)$", configuration, re.MULTILINE)
if len(statuses) != 1 or statuses[0] not in {"pending_live_price_capture", "captured_live_price"}:
    raise SystemExit("error: one explicit IAP review screenshot status is required")
iap_images = {
    path.as_posix() for path in Path("AppStore/screenshots/iap-review").rglob("*")
    if path.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp", ".gif", ".svg", ".heic", ".heif", ".avif", ".tif", ".tiff"}
}
if statuses[0] == "pending_live_price_capture":
    blocker = (
        "  - capture and verify the new PomoGem IAP review screenshot with the live "
        "StoreKit price for com.hinoshiba.pomogem.pro.lifetime"
    )
    if sys.argv[1] == "--release" or blocker not in configuration.splitlines():
        raise SystemExit("error: a pending IAP screenshot is allowed only for standard OSS checks with its release blocker")
    # An unlisted old or simulated price image must not remain publishable.
    if iap_images:
        raise SystemExit("error: pending IAP review directory must not contain a stale price image")
else:
    if iap_images != {iap_image}:
        raise SystemExit("error: captured IAP review directory must contain exactly the reviewed new product image")
    expected_paths.add(iap_image)

manifest_entries = {}
for line_number, line in enumerate(manifest_path.read_text().splitlines(), start=1):
    match = re.fullmatch(r"([0-9a-f]{64})  (AppStore/screenshots/[^\s]+)", line)
    if match is None:
        raise SystemExit(
            f"error: invalid screenshot checksum entry at {manifest_path}:{line_number}"
        )
    digest, raw_path = match.groups()
    if raw_path in manifest_entries:
        raise SystemExit(f"error: duplicate screenshot checksum entry: {raw_path}")
    manifest_entries[raw_path] = digest

if set(manifest_entries) != expected_paths:
    raise SystemExit("error: screenshot checksum manifest differs from the five listing images and declared IAP capture status")

ledger_entries = {}
for line_number, line in enumerate(ledger_path.read_text().splitlines(), start=1):
    fields = re.findall(r"`([^`]+)`", line)
    if not fields or not fields[0].startswith("AppStore/screenshots/"):
        continue
    if len(fields) != 2 or re.fullmatch(r"[0-9a-f]{64}", fields[1]) is None:
        raise SystemExit(f"error: invalid screenshot asset row at {ledger_path}:{line_number}")
    raw_path, digest = fields
    if raw_path in ledger_entries:
        raise SystemExit(f"error: duplicate screenshot asset row: {raw_path}")
    ledger_entries[raw_path] = digest

if set(ledger_entries) != expected_paths:
    raise SystemExit("error: ASSET_LICENSES.md differs from the five listing images and declared IAP capture status")

for raw_path in sorted(expected_paths):
    path = PurePosixPath(raw_path)
    if path.is_absolute() or ".." in path.parts:
        raise SystemExit(f"error: unsafe screenshot asset path: {raw_path}")
    actual = hashlib.sha256(Path(path).read_bytes()).hexdigest()
    if manifest_entries[raw_path] != actual:
        raise SystemExit(f"error: screenshot checksum manifest differs from file: {raw_path}")
    if ledger_entries[raw_path] != actual:
        raise SystemExit(f"error: ASSET_LICENSES.md hash differs from file: {raw_path}")
PY

if command -v sips >/dev/null 2>&1; then
  source_icon=Brand/AppIcon-FocusCycle-v5-source.png
  source_width=$(sips -g pixelWidth "$source_icon" | awk '/pixelWidth/ {print $2}')
  source_height=$(sips -g pixelHeight "$source_icon" | awk '/pixelHeight/ {print $2}')
  source_alpha=$(sips -g hasAlpha "$source_icon" | awk '/hasAlpha/ {print $2}')
  source_space=$(sips -g space "$source_icon" | awk '/space/ {print $2}')
  source_profile=$(sips -g profile "$source_icon" | awk '/profile/ {print $2}')
  if [ "$source_width" != 1254 ] || [ "$source_height" != 1254 ] \
      || [ "$source_alpha" != no ] || [ "$source_space" != RGB ] \
      || [ "$source_profile" != sRGB ]; then
    echo "error: App Icon source must be 1254x1254 opaque sRGB RGB" >&2
    exit 1
  fi

  icon=PomoGem/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-FocusCycle-v5.png
  width=$(sips -g pixelWidth "$icon" | awk '/pixelWidth/ {print $2}')
  height=$(sips -g pixelHeight "$icon" | awk '/pixelHeight/ {print $2}')
  alpha=$(sips -g hasAlpha "$icon" | awk '/hasAlpha/ {print $2}')
  profile=$(sips -g profile "$icon" | awk '/profile/ {print $2}')
  if [ "$width" != 1024 ] || [ "$height" != 1024 ] \
      || [ "$alpha" != no ] || [ "$profile" != sRGB ]; then
    echo "error: shipping App Icon must be 1024x1024 opaque sRGB" >&2
    exit 1
  fi
fi

scan_list=$(mktemp "${TMPDIR:-/tmp}/pomogem-public-files.XXXXXX")
scan_list_nul=$(mktemp "${TMPDIR:-/tmp}/pomogem-public-files-nul.XXXXXX")
scan_hits=$(mktemp "${TMPDIR:-/tmp}/pomogem-scan-hits.XXXXXX")
scan_errors=$(mktemp "${TMPDIR:-/tmp}/pomogem-scan-errors.XXXXXX")
history_inventory=$(mktemp "${TMPDIR:-/tmp}/pomogem-history-inventory.XXXXXX")
history_object_ids=$(mktemp "${TMPDIR:-/tmp}/pomogem-history-object-ids.XXXXXX")
history_object=$(mktemp "${TMPDIR:-/tmp}/pomogem-history-object.XXXXXX")
history_hits=$(mktemp "${TMPDIR:-/tmp}/pomogem-history-hits.XXXXXX")
trap 'rm -f "$scan_list" "$scan_list_nul" "$scan_hits" "$scan_errors" "$history_inventory" "$history_object_ids" "$history_object" "$history_hits"' EXIT HUP INT TERM

find . \
  \( -path './.git' -o -path './DerivedData*' -o -path './Artifacts' \
     -o -path './http_dists/node_modules' -o -path './http_dists/dist' \) -prune \
  -o -type f -print0 > "$scan_list_nul"

# A whitespace-free public path policy keeps shell, Xcode and Pages tooling
# deterministic. More importantly, it prevents a future path from being split
# or silently skipped by a content scanner.
python3 - "$scan_list_nul" <<'PY'
import os
import sys
from pathlib import Path

paths = [os.fsdecode(value) for value in Path(sys.argv[1]).read_bytes().split(b"\0") if value]
unsafe = [path for path in paths if any(character.isspace() for character in path)]
if unsafe:
    for path in unsafe:
        print(f"error: whitespace is not allowed in a public candidate path: {path}", file=sys.stderr)
    raise SystemExit(1)
PY

tr '\0' '\n' < "$scan_list_nul" | sed 's#^\./##' | LC_ALL=C sort > "$scan_list"

scan_candidate_content() {
  scan_kind=$1
  scan_pattern=$2
  : > "$scan_hits"
  : > "$scan_errors"
  set +e
  if [ "$scan_kind" = fixed ]; then
    xargs -0 rg -a -l -F -- "$scan_pattern" < "$scan_list_nul" > "$scan_hits" 2> "$scan_errors"
  elif [ "$scan_kind" = regex_i ]; then
    xargs -0 rg -a -l -i -- "$scan_pattern" < "$scan_list_nul" > "$scan_hits" 2> "$scan_errors"
  else
    xargs -0 rg -a -l -- "$scan_pattern" < "$scan_list_nul" > "$scan_hits" 2> "$scan_errors"
  fi
  scanner_exit=$?
  set -e

  if [ -s "$scan_errors" ]; then
    echo "error: candidate content scanner reported an error" >&2
    sed -n '1,20p' "$scan_errors" >&2
    return 2
  fi
  # BSD/GNU xargs may translate ripgrep's ordinary no-match status to 1 or
  # 123. Any other silent status is treated as an infrastructure failure.
  case "$scanner_exit" in
    0|1|123) ;;
    *)
      echo "error: candidate content scanner failed with status $scanner_exit" >&2
      return 2
      ;;
  esac
}

forbidden_path_pattern='(^|/)[^/]+\.(xcarchive|app|dSYM|xcresult)/|(^|/)(AuthKey_[^/]+\.p8|ExportOptions[^/]*\.plist|\.DS_Store|[^/]+\.(p12|pfx|pkcs12|p8|pem|key|cer|crt|der|certSigningRequest|csr|mobileprovision|provisionprofile|keychain|keychain-db|jks|keystore|xcarchive|ipa|app|dSYM|xcresult|xcuserstate|xccheckout|xcscmblueprint|log))$|(^|/)\.env($|\.)|(^|/)(xcuserdata|signing|signingassets|certificates|provisioningprofiles|secrets?)/'

if rg -ni "$forbidden_path_pattern" "$scan_list"; then
  echo "error: credential, signing, log, or generated binary exists in the public candidate" >&2
  exit 1
fi

private_key_marker=$(printf '%s%s' 'PRIVATE ' 'KEY-----')
scan_candidate_content fixed "$private_key_marker" || exit 1
if [ -s "$scan_hits" ]; then
  sed -n '1,20p' "$scan_hits" >&2
  echo "error: private-key material found in a public candidate file" >&2
  exit 1
fi

credential_value_pattern='github_pat_[[:alnum:]_]{20,}|gh[pousr]_[[:alnum:]]{20,}|glpat-[[:alnum:]_-]{20,}|(AKIA|ASIA)[[:upper:][:digit:]]{16}|xox[baprs]-[[:alnum:]-]{10,}|(sk|rk)_(live|test)_[[:alnum:]]{16,}|whsec_[[:alnum:]]{16,}|npm_[[:alnum:]]{30,}|pypi-AgEIcHlwaS5vcmc[[:alnum:]_-]{20,}|AIza[[:alnum:]_-]{30,}|hf_[[:alnum:]]{30,}|sk-(proj|svcacct|ant)-[[:alnum:]_-]{20,}|eyJ[[:alnum:]_-]{8,}\.[[:alnum:]_-]{8,}\.[[:alnum:]_-]{8,}|Authorization[[:space:]]*:[[:space:]]*(Bearer|Basic)[[:space:]]+[[:alnum:]._~+/-]{16,}'
scan_candidate_content regex "$credential_value_pattern" || exit 1
if [ -s "$scan_hits" ]; then
  sed -n '1,20p' "$scan_hits" >&2
  echo "error: credential-like value found in a public candidate file" >&2
  exit 1
fi

# Catch high-entropy values assigned to conventional secret variables without
# rejecting ordinary public identifiers or documentation that merely names a
# credential type. App Store Connect issuer/key IDs are not authentication by
# themselves, but publishing an operator's account identifiers is unnecessary
# and makes targeted credential attacks easier.
credential_assignment_pattern="(password|passwd|client[_. -]*secret|api[_. -]*(key|token)|access[_. -]*token|refresh[_. -]*token|private[_. -]*token)[[:space:]]*[:=][[:space:]]*['\"]?[[:alnum:]_./+=~-]{16,}"
scan_candidate_content regex_i "$credential_assignment_pattern" || exit 1
if [ -s "$scan_hits" ]; then
  sed -n '1,20p' "$scan_hits" >&2
  echo "error: assigned credential-like value found in a public candidate file" >&2
  exit 1
fi

asc_identifier_pattern="((app[_. -]*store[_. -]*connect|asc)[_. -]*(issuer|key)[_. -]*id[[:space:]]*[:=][[:space:]]*['\"]?([[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}|[[:upper:][:digit:]]{10})|issuer[_. -]*id[[:space:]]*[:=][[:space:]]*['\"]?[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12})"
scan_candidate_content regex_i "$asc_identifier_pattern" || exit 1
if [ -s "$scan_hits" ]; then
  sed -n '1,20p' "$scan_hits" >&2
  echo "error: App Store Connect issuer/key identifier found in a public candidate file" >&2
  exit 1
fi

# Scan complete mailboxes individually: allowing the owner's exact public
# address must not exempt a whole line/file or another address at its provider.
python3 Scripts/public_mailbox_policy.py --files0-from "$scan_list_nul"

identity_output_pattern='^[[:space:]]*[0-9]+\) [[:xdigit:]]{40} ".*(Developer ID|Distribution|Development)'
scan_candidate_content regex "$identity_output_pattern" || exit 1
if [ -s "$scan_hits" ]; then
  sed -n '1,20p' "$scan_hits" >&2
  echo "error: signing identity output or certificate fingerprint found" >&2
  exit 1
fi

# Keep the checker itself from containing the complete marker it searches for.
absolute_home_pattern=$(printf '%s%s' '(/Us' 'ers/|/home/|[[:alpha:]]:\\Users\\)[[:alnum:]_.-]+/')
scan_candidate_content regex "$absolute_home_pattern" || exit 1
if [ -s "$scan_hits" ]; then
  sed -n '1,20p' "$scan_hits" >&2
  echo "error: local absolute home path found in a public candidate file" >&2
  exit 1
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  tracked_list=$(mktemp "${TMPDIR:-/tmp}/pomogem-tracked-files.XXXXXX")
  git ls-files > "$tracked_list"
  if rg -ni "$forbidden_path_pattern" "$tracked_list"; then
    echo "error: forbidden material is tracked" >&2
    rm -f "$tracked_list"
    exit 1
  fi
  rm -f "$tracked_list"

  if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    echo "error: full Git history is required for the release audit" >&2
    exit 1
  fi
  # Ignore replace objects so a local refs/replace entry cannot hide the raw
  # identity or content recorded by a public branch/tag tip.
  git --no-replace-objects rev-list --objects --all > "$history_inventory"
  if sed -n 's/^[^ ]* //p' "$history_inventory" | rg -ni "$forbidden_path_pattern"; then
    echo "error: forbidden filename exists in reachable Git history" >&2
    exit 1
  fi
  if sed -n 's/^[^ ]* //p' "$history_inventory" \
    | rg -ni '\.(wav|caf|mp3|aiff|aif|m4a|aac|ac3|eac3|flac|ogg|oga|opus|mid|midi|ahap)$'; then
    echo "error: audio or AHAP asset exists in reachable Git history; provenance review is required" >&2
    exit 1
  fi

  # `git grep -I` silently omits binary files and a commit-only revision walk
  # misses annotated-tag messages, notes blobs, and refs that directly name a
  # tree or blob. Traverse every object reachable from every ref, add ref tips
  # explicitly, then scan one raw batch stream. Commit/tag objects include
  # author, committer, tagger and message metadata; notes are ordinary blobs.
  awk '{print $1}' "$history_inventory" > "$history_object_ids"
  git for-each-ref --format='%(objectname)' >> "$history_object_ids"
  LC_ALL=C sort -u -o "$history_object_ids" "$history_object_ids"
  : > "$history_hits"
  : > "$history_object"
  if [ -s "$history_object_ids" ]; then
    python3 Scripts/check-git-public-metadata.py "$history_object_ids"
    git --no-replace-objects cat-file --batch < "$history_object_ids" > "$history_object"
  fi
  git for-each-ref --format='%(refname)' >> "$history_object"

  if rg -a -q -F -- "$private_key_marker" "$history_object"; then
    printf '%s\n' 'private-key-marker' >> "$history_hits"
  fi
  if rg -a -q -- "$credential_value_pattern" "$history_object"; then
    printf '%s\n' 'credential-value' >> "$history_hits"
  fi
  if rg -a -q -i -- "$credential_assignment_pattern" "$history_object"; then
    printf '%s\n' 'credential-assignment' >> "$history_hits"
  fi
  if rg -a -q -i -- "$asc_identifier_pattern" "$history_object"; then
    printf '%s\n' 'app-store-connect-identifier' >> "$history_hits"
  fi
  python3 Scripts/public_mailbox_policy.py --git-batch "$history_object"
  if rg -a -q -- "$identity_output_pattern" "$history_object"; then
    printf '%s\n' 'signing-identity-output' >> "$history_hits"
  fi
  if rg -a -q -- "$absolute_home_pattern" "$history_object"; then
    printf '%s\n' 'absolute-home-path' >> "$history_hits"
  fi
  if [ -s "$history_hits" ]; then
    echo "error: secret, private identity, signing output, or local path exists in reachable Git history" >&2
    sed -n '1,40p' "$history_hits" >&2
    exit 1
  fi
else
  echo "note: no Git repository yet; reachable history could not be audited"
  if [ "$MODE" = '--release' ]; then
    echo "error: initialize Git and audit the complete reachable history before release" >&2
    exit 1
  fi
fi

if [ "$MODE" = '--release' ]; then
  if rg -n '^app_store_id:[[:space:]]*null$' AppStore/configuration.yml; then
    echo "error: App Store ID is not recorded" >&2
    exit 1
  fi

  if ! grep -Fqx 'release_blockers: []' AppStore/configuration.yml; then
    echo "error: AppStore/configuration.yml still records release blockers" >&2
    exit 1
  fi

  screenshot_count=$(find AppStore/screenshots -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) 2>/dev/null | wc -l | tr -d ' ')
  if [ "$screenshot_count" -eq 0 ]; then
    echo "error: no App Store screenshots are present" >&2
    exit 1
  fi

  xcode_major=$(xcodebuild -version | awk 'NR==1 {split($2, value, "."); print value[1]}')
  if [ "$xcode_major" -lt 26 ]; then
    echo "error: current App Store upload requires Xcode 26 or later" >&2
    exit 1
  fi

  for url in \
    https://pomogem.hinoshiba.com/ \
    https://pomogem.hinoshiba.com/privacy/ \
    https://pomogem.hinoshiba.com/support/ \
    https://pomogem.hinoshiba.com/terms/ \
    https://pomogem.hinoshiba.com/commercial-transactions/; do
    status=$(curl --silent --show-error --max-time 20 --output /dev/null --write-out '%{http_code}' "$url" || true)
    if [ "$status" != 200 ]; then
      echo "error: release URL must return HTTPS 200 without redirect: $url ($status)" >&2
      exit 1
    fi
  done

  ./Scripts/check-published-site-policy.sh https://pomogem.hinoshiba.com/

  http_status=$(curl --silent --show-error --max-time 20 \
    --output /dev/null --write-out '%{http_code}' http://pomogem.hinoshiba.com/ || true)
  case "$http_status" in
    301|302|307|308) ;;
    *)
      echo "error: public HTTP endpoint must redirect to HTTPS (http://pomogem.hinoshiba.com/ returned $http_status)" >&2
      exit 1
      ;;
  esac
  final_url=$(curl --silent --show-error --location --max-time 20 \
    --output /dev/null --write-out '%{url_effective}' http://pomogem.hinoshiba.com/ || true)
  if [ "$final_url" != 'https://pomogem.hinoshiba.com/' ]; then
    echo "error: public HTTP endpoint must end at the canonical HTTPS URL ($final_url)" >&2
    exit 1
  fi
fi

echo "OSS readiness checks passed ($MODE)."

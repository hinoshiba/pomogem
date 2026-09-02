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
AppStore/README.md
AppStore/configuration.yml
AppStore/app-privacy.md
AppStore/age-rating.md
AppStore/export-compliance.md
AppStore/submission-checklist.md
project.yml
Tsumiben.xcodeproj/project.pbxproj
Tsumiben.xcodeproj/xcshareddata/xcschemes/Tsumiben.xcscheme
Tsumiben/Resources/PrivacyInfo.xcprivacy
TsumibenWidgets/PrivacyInfo.xcprivacy
Tsumiben/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-FocusVessel-v4.png
http_dists/index.html
http_dists/privacy/index.html
http_dists/support/index.html
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

plutil -lint Tsumiben/Info.plist >/dev/null
plutil -lint Tsumiben/Resources/PrivacyInfo.xcprivacy >/dev/null
plutil -lint TsumibenWidgets/PrivacyInfo.xcprivacy >/dev/null
plutil -lint Tsumiben/Tsumiben.entitlements >/dev/null
plutil -lint TsumibenWidgets/TsumibenWidgets.entitlements >/dev/null
python3 - <<'PY'
import plistlib
from pathlib import Path

def load(path: str):
    with Path(path).open("rb") as handle:
        return plistlib.load(handle)

main_manifest = load("Tsumiben/Resources/PrivacyInfo.xcprivacy")
assert main_manifest.get("NSPrivacyTracking") is False
assert main_manifest.get("NSPrivacyTrackingDomains") == []
assert main_manifest.get("NSPrivacyCollectedDataTypes") == []
required_reasons = {
    item["NSPrivacyAccessedAPIType"]: set(item["NSPrivacyAccessedAPITypeReasons"])
    for item in main_manifest.get("NSPrivacyAccessedAPITypes", [])
}
assert required_reasons == {
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1"},
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1"},
}

widget_manifest = load("TsumibenWidgets/PrivacyInfo.xcprivacy")
assert widget_manifest.get("NSPrivacyTracking") is False
assert widget_manifest.get("NSPrivacyTrackingDomains") == []
assert widget_manifest.get("NSPrivacyCollectedDataTypes") == []
assert widget_manifest.get("NSPrivacyAccessedAPITypes") == []

info = load("Tsumiben/Info.plist")
assert info.get("ITSAppUsesNonExemptEncryption") is False
assert info.get("TSUMIBEN_PRIVACY_POLICY_URL") == "https://tumiben.hinoshiba.com/privacy/"
assert info.get("NSHumanReadableCopyright") == "Copyright © 2026 hinoshiba"

widget_info = load("TsumibenWidgets/Info.plist")
assert widget_info.get("NSHumanReadableCopyright") == "Copyright © 2026 hinoshiba"

app_entitlements = load("Tsumiben/Tsumiben.entitlements")
assert app_entitlements.get("aps-environment") == "$(APS_ENVIRONMENT)"
assert app_entitlements.get("com.apple.developer.icloud-container-identifiers") == [
    "iCloud.com.hinoshiba.tsumiben"
]
assert app_entitlements.get("com.apple.developer.icloud-services") == ["CloudKit"]
assert app_entitlements.get("com.apple.security.application-groups") == [
    "group.com.hinoshiba.tsumiben"
]

widget_entitlements = load("TsumibenWidgets/TsumibenWidgets.entitlements")
assert widget_entitlements.get("com.apple.security.application-groups") == [
    "group.com.hinoshiba.tsumiben"
]
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

if rg -n 'macCatalyst|TsumibenCatalyst|sdk=macosx|SUPPORTS_MACCATALYST: true' project.yml; then
  echo "error: Mac Catalyst configuration remains in project.yml" >&2
  exit 1
fi

if [ -e Tsumiben/TsumibenCatalyst.entitlements ]; then
  echo "error: obsolete Catalyst entitlement is present" >&2
  exit 1
fi

if rg -n 'iPhoneとMac|iPhone・Mac|Mac版|Mac・機種変更' Tsumiben --glob '*.swift'; then
  echo "error: user-facing Mac support claim remains in the iPhone app" >&2
  exit 1
fi

if rg -n '^[[:space:]]*PROVISIONING_PROFILE(_SPECIFIER)?([[:space:]]|:|=)' \
    project.yml Tsumiben.xcodeproj --glob 'project.yml' --glob '*.pbxproj'; then
  echo "error: provisioning profile selector must not be committed" >&2
  exit 1
fi

if rg -n '^[[:space:]]*DEVELOPMENT_TEAM([[:space:]]|:|=)' \
    project.yml Tsumiben.xcodeproj --glob 'project.yml' --glob '*.pbxproj'; then
  echo "error: a local signing team selector is committed" >&2
  exit 1
fi

for debug_file in Tsumiben/Debug/*.swift; do
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

store = json.loads(Path("Tsumiben/Resources/Products.storekit").read_text())
products = store.get("products", [])
assert len(products) == 1, "exactly one StoreKit product is required"
product = products[0]
assert product.get("productID") == "com.hinoshiba.tsumiben.pro.lifetime"
assert product.get("type") == "NonConsumable"
assert product.get("displayPrice") == "100"
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

check_hash e5410573fe5e55df16e4aabc074a3502e35127e93a736f7635be33922bf7252e \
  Tsumiben/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-FocusVessel-v4.png
check_hash b60d2fe464f4460702be923976c5865dfca487b189072ac249638eac1e1ec1ca \
  Brand/AppIcon-FocusVessel-v4-source.png
check_hash 30d8c4b856a46dc87a00c5c09861df6a008ffce8092a0a3f72bea4b074e3a4f8 \
  Brand/AppIcon-Aurora-v3-legacy.png
check_hash b6a9e5e324e13978eeb0806ce051ca51304571d4fb22544916c55cc8350a8e66 \
  Tsumiben/Resources/Assets.xcassets/focus.aurora.imageset/focus-aurora.png
check_hash 09e0544c3af28dec0b24b95b34503727357f7bf53e28d4d8697a2e876aa7896f \
  http_dists/og-focus-v5.png
check_hash 28a3a322c560fabbff571a3fb399346fbf8298120891f50f93f6a61f5df2df66 \
  http_dists/public/app-home-current.webp
check_hash 05ac0bbdc58cfa85d23d5b01cf2a3d38dc0d89016ee33fa1a940cef1e1a7c469 \
  http_dists/public/app-icon-focus-v4.png
check_hash e5bedfa914263e4794ec23ecaa649a65546d0d12250eeaea8d3cc6e9d506bb9a \
  http_dists/public/apple-touch-icon.png
check_hash 6bd74fe76cd39ee0ec18775c3661d845343fb3f6f8fa09a3076638417baf741f \
  Tsumiben/Resources/Fonts/ZenMaruGothic-Black.ttf
check_hash 6bd74fe76cd39ee0ec18775c3661d845343fb3f6f8fa09a3076638417baf741f \
  http_dists/public/ZenMaruGothic-Black.ttf

if command -v sips >/dev/null 2>&1; then
  icon=Tsumiben/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-FocusVessel-v4.png
  width=$(sips -g pixelWidth "$icon" | awk '/pixelWidth/ {print $2}')
  height=$(sips -g pixelHeight "$icon" | awk '/pixelHeight/ {print $2}')
  alpha=$(sips -g hasAlpha "$icon" | awk '/hasAlpha/ {print $2}')
  if [ "$width" != 1024 ] || [ "$height" != 1024 ] || [ "$alpha" != no ]; then
    echo "error: App Icon must be 1024x1024 without alpha" >&2
    exit 1
  fi
fi

scan_list=$(mktemp "${TMPDIR:-/tmp}/tsumiben-public-files.XXXXXX")
scan_list_nul=$(mktemp "${TMPDIR:-/tmp}/tsumiben-public-files-nul.XXXXXX")
scan_hits=$(mktemp "${TMPDIR:-/tmp}/tsumiben-scan-hits.XXXXXX")
scan_errors=$(mktemp "${TMPDIR:-/tmp}/tsumiben-scan-errors.XXXXXX")
trap 'rm -f "$scan_list" "$scan_list_nul" "$scan_hits" "$scan_errors"' EXIT HUP INT TERM

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
    xargs -0 rg -IlF -- "$scan_pattern" < "$scan_list_nul" > "$scan_hits" 2> "$scan_errors"
  else
    xargs -0 rg -Il -- "$scan_pattern" < "$scan_list_nul" > "$scan_hits" 2> "$scan_errors"
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

credential_value_pattern='github_pat_[[:alnum:]_]{20,}|gh[pousr]_[[:alnum:]]{20,}|(AKIA|ASIA)[[:upper:][:digit:]]{16}|Authorization[[:space:]]*:[[:space:]]*(Bearer|Basic)[[:space:]]+[[:alnum:]._~+/-]{16,}'
scan_candidate_content regex "$credential_value_pattern" || exit 1
if [ -s "$scan_hits" ]; then
  sed -n '1,20p' "$scan_hits" >&2
  echo "error: credential-like value found in a public candidate file" >&2
  exit 1
fi

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
  tracked_list=$(mktemp "${TMPDIR:-/tmp}/tsumiben-tracked-files.XXXXXX")
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
  if git log --all --name-only --format= | rg -ni "$forbidden_path_pattern"; then
    echo "error: forbidden filename exists in reachable Git history" >&2
    exit 1
  fi

  history_hits=$(mktemp "${TMPDIR:-/tmp}/tsumiben-history-hits.XXXXXX")
  history_revisions=$(mktemp "${TMPDIR:-/tmp}/tsumiben-history-revisions.XXXXXX")
  git rev-list --all > "$history_revisions"
  while IFS= read -r revision; do
    git grep -I -l -F -- "$private_key_marker" "$revision" -- || true
    git grep -I -l -E -- "$credential_value_pattern" "$revision" -- || true
    git grep -I -l -E -- "$identity_output_pattern" "$revision" -- || true
    git grep -I -l -E -- "$absolute_home_pattern" "$revision" -- || true
  done < "$history_revisions" > "$history_hits"
  if [ -s "$history_hits" ]; then
    echo "error: secret, signing identity, or local home path exists in reachable Git blob history" >&2
    sed -n '1,40p' "$history_hits" >&2
    rm -f "$history_hits" "$history_revisions"
    exit 1
  fi
  rm -f "$history_hits" "$history_revisions"
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
    https://tumiben.hinoshiba.com/ \
    https://tumiben.hinoshiba.com/privacy/ \
    https://tumiben.hinoshiba.com/support/; do
    status=$(curl --silent --show-error --max-time 20 --output /dev/null --write-out '%{http_code}' "$url" || true)
    if [ "$status" != 200 ]; then
      echo "error: release URL must return HTTPS 200 without redirect: $url ($status)" >&2
      exit 1
    fi
  done
fi

echo "OSS readiness checks passed ($MODE)."

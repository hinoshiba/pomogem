#!/bin/bash
#
# Verify the signed contents of the version 1.0 PomoGem iOS archive without
# printing certificate subjects, profile names, UUIDs, device identifiers, or
# entitlement payloads.
#
# Default mode accepts either the development signing normally found in a raw
# Xcode Organizer archive or an already distribution-signed archive. It does
# not claim that Xcode's later upload payload has been distribution signed.
# Use --distribution only for an archive known to have been re-signed with App
# Store Connect distribution profiles.

set -euo pipefail
IFS=$'\n\t'
umask 077

readonly POMOGEM_AUDIT_APP_BUNDLE_ID='com.hinoshiba.pomogem'
readonly POMOGEM_AUDIT_WIDGET_BUNDLE_ID='com.hinoshiba.pomogem.widgets'
readonly POMOGEM_AUDIT_TEAM_ID='94HVVWXLK3'
readonly POMOGEM_AUDIT_APP_GROUP='group.com.hinoshiba.pomogem'
readonly POMOGEM_AUDIT_ICLOUD_CONTAINER='iCloud.com.hinoshiba.pomogem'
readonly POMOGEM_AUDIT_MARKETING_VERSION='1.0.2'
readonly POMOGEM_AUDIT_BUILD_NUMBER='8'
readonly POMOGEM_AUDIT_MINIMUM_IOS='17.0'
readonly POMOGEM_AUDIT_FONT_SHA256='6bd74fe76cd39ee0ec18775c3661d845343fb3f6f8fa09a3076638417baf741f'
readonly POMOGEM_AUDIT_FONT_LICENSE_SHA256='e8b4d8c39b0d7cc4b202dbd013b999bc6233a9bbe6cce1c37cfddc26ad544228'
readonly POMOGEM_AUDIT_SCRIPT_DIRECTORY="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
export POMOGEM_AUDIT_APP_BUNDLE_ID POMOGEM_AUDIT_WIDGET_BUNDLE_ID
export POMOGEM_AUDIT_TEAM_ID POMOGEM_AUDIT_APP_GROUP
export POMOGEM_AUDIT_ICLOUD_CONTAINER POMOGEM_AUDIT_MARKETING_VERSION
export POMOGEM_AUDIT_BUILD_NUMBER POMOGEM_AUDIT_MINIMUM_IOS

usage() {
  cat <<'EOF'
Usage:
  ./Scripts/verify-release-archive.sh /path/to/PomoGem.xcarchive
  ./Scripts/verify-release-archive.sh --distribution /path/to/PomoGem.xcarchive

Default mode validates a raw Organizer archive. It accepts coherent Apple
Development/development-profile signing or Apple Distribution/App Store
Connect-profile signing and reports only the non-sensitive signing classes.
Both modes require the host's reviewed CloudKit and APNs setup. Version 1.0
removes App Groups from both bundles; its Widget must carry no iCloud/APNs
capability or account-snapshot code. Its Live Activity may display only the
account-neutral timer contract reviewed by this script.

--distribution additionally requires Apple Distribution signing, App Store
Connect profiles, get-task-allow=false, no registered-device or enterprise
provisioning, and production APNs/CloudKit environments.

Always quote an archive path that contains spaces. This script validates the
.xcarchive supplied to it; Xcode can re-sign or transform a separate staging
payload during Distribute App, so Organizer Validate and Apple's server-side
validation remain required.
EOF
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

mode='raw'
case "$#" in
  1)
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -* )
        usage >&2
        exit 2
        ;;
      *) archive_path=$1 ;;
    esac
    ;;
  2)
    if [ "$1" != '--distribution' ]; then
      usage >&2
      exit 2
    fi
    mode='distribution'
    archive_path=$2
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

for tool in python3 /usr/bin/codesign /usr/bin/security /usr/bin/plutil \
  /usr/bin/lipo /usr/bin/otool /usr/bin/strings /usr/bin/grep \
  /usr/bin/shasum /usr/bin/cut; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    fail "required archive-audit tool is unavailable"
  fi
done

if [ ! -d "$archive_path" ] || [ -L "$archive_path" ]; then
  fail 'archive path is not a non-symlink directory'
fi

readonly archive_info="$archive_path/Info.plist"
readonly app_bundle="$archive_path/Products/Applications/PomoGem.app"
readonly widget_bundle="$app_bundle/PlugIns/PomoGemWidgets.appex"
readonly app_info="$app_bundle/Info.plist"
readonly widget_info="$widget_bundle/Info.plist"
readonly app_binary="$app_bundle/PomoGem"
readonly widget_binary="$widget_bundle/PomoGemWidgets"
readonly app_privacy="$app_bundle/PrivacyInfo.xcprivacy"
readonly widget_privacy="$widget_bundle/PrivacyInfo.xcprivacy"
readonly app_font="$app_bundle/ZenMaruGothic-Black.ttf"
readonly app_font_license="$app_bundle/LICENSE-fonts.txt"
readonly app_profile="$app_bundle/embedded.mobileprovision"
readonly widget_profile="$widget_bundle/embedded.mobileprovision"

for directory in "$app_bundle" "$widget_bundle"; do
  if [ ! -d "$directory" ] || [ -L "$directory" ]; then
    fail 'archive is missing the expected non-symlink app or Widget bundle'
  fi
done

for file in "$archive_info" "$app_info" "$widget_info" \
  "$app_binary" "$widget_binary" "$app_privacy" "$widget_privacy" \
  "$app_font" "$app_font_license" "$app_profile" "$widget_profile"; do
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    fail 'archive is missing an expected non-symlink release artifact'
  fi
done

if [ "$(/usr/bin/shasum -a 256 "$app_font" | /usr/bin/cut -d ' ' -f 1)" != \
  "$POMOGEM_AUDIT_FONT_SHA256" ]; then
  fail 'bundled Zen Maru Gothic font differs from the reviewed release asset'
fi

if [ "$(/usr/bin/shasum -a 256 "$app_font_license" | /usr/bin/cut -d ' ' -f 1)" != \
  "$POMOGEM_AUDIT_FONT_LICENSE_SHA256" ]; then
  fail 'bundled font license differs from the reviewed SIL Open Font License text'
fi

audit_tmp=$(mktemp -d "${TMPDIR:-/tmp}/pomogem-archive-audit.XXXXXX") \
  || fail 'could not create private audit workspace'
readonly audit_tmp

cleanup() {
  case "$audit_tmp" in
    "${TMPDIR:-/tmp}"/pomogem-archive-audit.*)
      if [ -d "$audit_tmp" ] && [ ! -L "$audit_tmp" ]; then
        /bin/rm -rf "$audit_tmp"
      fi
      ;;
  esac
}
trap cleanup EXIT HUP INT TERM

# Validate bundle topology, release metadata, Xcode/SDK provenance, and the
# embedded privacy manifests before invoking tools that inspect signatures.
PYTHONDONTWRITEBYTECODE=1 python3 - \
  "$archive_path" "$archive_info" "$app_info" "$widget_info" \
  "$app_privacy" "$widget_privacy" <<'PY'
from __future__ import annotations

import plistlib
import re
import sys
import os
from pathlib import Path

(
    archive_raw,
    archive_info_raw,
    app_info_raw,
    widget_info_raw,
    app_privacy_raw,
    widget_privacy_raw,
) = sys.argv[1:]

APP_ID = os.environ["POMOGEM_AUDIT_APP_BUNDLE_ID"]
WIDGET_ID = os.environ["POMOGEM_AUDIT_WIDGET_BUNDLE_ID"]
TEAM_ID = os.environ["POMOGEM_AUDIT_TEAM_ID"]
VERSION = os.environ["POMOGEM_AUDIT_MARKETING_VERSION"]
BUILD = os.environ["POMOGEM_AUDIT_BUILD_NUMBER"]
MINIMUM_IOS = os.environ["POMOGEM_AUDIT_MINIMUM_IOS"]


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def load(path: Path, label: str) -> dict:
    try:
        with path.open("rb") as handle:
            value = plistlib.load(handle)
    except Exception:
        fail(f"{label} is not a valid property list")
    if not isinstance(value, dict):
        fail(f"{label} root must be a dictionary")
    return value


archive = Path(archive_raw)
applications = archive / "Products" / "Applications"
app = applications / "PomoGem.app"
plugins = app / "PlugIns"
widget = plugins / "PomoGemWidgets.appex"

try:
    embedded_apps = sorted(
        item.name for item in applications.iterdir()
        if item.is_dir() and item.suffix == ".app"
    )
    embedded_extensions = sorted(
        item.name for item in plugins.iterdir()
        if item.is_dir() and item.suffix == ".appex"
    )
except OSError:
    fail("archive application topology is unreadable")

if embedded_apps != ["PomoGem.app"]:
    fail("archive must contain exactly the reviewed PomoGem app")
if embedded_extensions != ["PomoGemWidgets.appex"]:
    fail("app must embed exactly the reviewed PomoGem Widget extension")

def validate_release_payload_topology(bundle: Path) -> None:
    try:
        for item in bundle.rglob("*"):
            name = item.name.lower()
            if name.endswith(".xctest"):
                fail("archive contains an XCTest payload")
            if (
                name.endswith(".debug.dylib")
                or name == "__preview.dylib"
                or "preview-thunk" in name
            ):
                fail("archive contains a Debug or preview dynamic-library payload")
    except OSError:
        fail("archive payload topology is unreadable")


validate_release_payload_topology(app)

archive_plist = load(Path(archive_info_raw), "archive Info.plist")
if archive_plist.get("ArchiveVersion") != 2:
    fail("archive format version is not the reviewed Xcode archive format")
if archive_plist.get("Name") != "PomoGem":
    fail("archive product name is not PomoGem")
if archive_plist.get("SchemeName") != "PomoGem":
    fail("archive scheme is not PomoGem")

properties = archive_plist.get("ApplicationProperties")
if not isinstance(properties, dict):
    fail("archive is missing ApplicationProperties")
expected_archive_properties = {
    "ApplicationPath": "Applications/PomoGem.app",
    "Architectures": ["arm64"],
    "CFBundleIdentifier": APP_ID,
    "CFBundleShortVersionString": VERSION,
    "CFBundleVersion": BUILD,
    "Team": TEAM_ID,
}
for key, expected in expected_archive_properties.items():
    if properties.get(key) != expected:
        fail(f"archive ApplicationProperties.{key} differs from the reviewed release")
if not isinstance(properties.get("SigningIdentity"), str) or not properties["SigningIdentity"]:
    fail("archive is missing a signing identity record")

app_plist = load(Path(app_info_raw), "app Info.plist")
widget_plist = load(Path(widget_info_raw), "Widget Info.plist")


def validate_bundle_info(
    value: dict,
    *,
    label: str,
    bundle_id: str,
    executable: str,
    package_type: str,
) -> None:
    expected = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleDisplayName": "ポモジェム",
        "CFBundleExecutable": executable,
        "CFBundlePackageType": package_type,
        "CFBundleShortVersionString": VERSION,
        "CFBundleVersion": BUILD,
        "MinimumOSVersion": MINIMUM_IOS,
        "DTPlatformName": "iphoneos",
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
        "UIDeviceFamily": [1],
    }
    for key, expected_value in expected.items():
        if value.get(key) != expected_value:
            fail(f"{label} {key} differs from the reviewed release")

    xcode = value.get("DTXcode")
    if not isinstance(xcode, str) or not xcode.isdigit() or int(xcode) < 2600:
        fail(f"{label} was not built with Xcode 26 or later")

    sdk = value.get("DTSDKName")
    if not isinstance(sdk, str):
        fail(f"{label} is missing its device SDK record")
    match = re.fullmatch(r"iphoneos(\d+)(?:\.\d+)*", sdk)
    if match is None or int(match.group(1)) < 26:
        fail(f"{label} was not built with the iOS 26 SDK or later")


validate_bundle_info(
    app_plist,
    label="app",
    bundle_id=APP_ID,
    executable="PomoGem",
    package_type="APPL",
)
validate_bundle_info(
    widget_plist,
    label="Widget",
    bundle_id=WIDGET_ID,
    executable="PomoGemWidgets",
    package_type="XPC!",
)

if app_plist.get("LSRequiresIPhoneOS") is not True:
    fail("app must require iPhoneOS")
if app_plist.get("CFBundleURLTypes") != [{
    "CFBundleURLName": APP_ID,
    "CFBundleURLSchemes": ["pomogem"],
}]:
    fail("app URL registration differs from the reviewed PomoGem identifier and scheme")
if app_plist.get("POMOGEM_PRIVACY_POLICY_URL") != "https://pomogem.hinoshiba.com/#privacy":
    fail("app privacy URL differs from the reviewed canonical host")
if app_plist.get("ITSAppUsesNonExemptEncryption") is not False:
    fail("app export-compliance declaration differs from the reviewed release")
if app_plist.get("NSSupportsLiveActivities") is not True:
    fail("app must enable its reviewed account-neutral Live Activity")
if (
    "NSSupportsLiveActivitiesFrequentUpdates" in app_plist
    and app_plist.get("NSSupportsLiveActivitiesFrequentUpdates") is not False
):
    fail("app must not request frequent Live Activity updates")
if "NSSupportsLiveActivities" in widget_plist and widget_plist.get("NSSupportsLiveActivities") is not False:
    fail("Widget must not enable Live Activities for version 1.0")
extension = widget_plist.get("NSExtension")
if not isinstance(extension, dict) or extension.get("NSExtensionPointIdentifier") != "com.apple.widgetkit-extension":
    fail("embedded extension is not a WidgetKit extension")


def validate_privacy_manifest(path: Path, label: str, expected_reasons: dict[str, set[str]]) -> None:
    manifest = load(path, f"{label} PrivacyInfo.xcprivacy")
    expected_top_level = {
        "NSPrivacyTracking",
        "NSPrivacyTrackingDomains",
        "NSPrivacyCollectedDataTypes",
        "NSPrivacyAccessedAPITypes",
    }
    if set(manifest) != expected_top_level:
        fail(f"{label} privacy manifest keys differ from the reviewed allowlist")
    if manifest.get("NSPrivacyTracking") is not False:
        fail(f"{label} privacy manifest must disable tracking")
    if manifest.get("NSPrivacyTrackingDomains") != []:
        fail(f"{label} privacy manifest must not declare tracking domains")
    if manifest.get("NSPrivacyCollectedDataTypes") != []:
        fail(f"{label} privacy manifest must not declare collected data")

    declarations = manifest.get("NSPrivacyAccessedAPITypes")
    if not isinstance(declarations, list) or len(declarations) != len(expected_reasons):
        fail(f"{label} required-reason API declarations differ from the reviewed allowlist")
    observed: dict[str, set[str]] = {}
    for declaration in declarations:
        if not isinstance(declaration, dict) or set(declaration) != {
            "NSPrivacyAccessedAPIType",
            "NSPrivacyAccessedAPITypeReasons",
        }:
            fail(f"{label} contains a malformed required-reason API declaration")
        category = declaration.get("NSPrivacyAccessedAPIType")
        reasons = declaration.get("NSPrivacyAccessedAPITypeReasons")
        if (
            not isinstance(category, str)
            or category in observed
            or not isinstance(reasons, list)
            or not reasons
            or any(not isinstance(reason, str) for reason in reasons)
            or len(reasons) != len(set(reasons))
        ):
            fail(f"{label} contains a malformed or duplicate required-reason declaration")
        observed[category] = set(reasons)
    if observed != expected_reasons:
        fail(f"{label} required-reason API declarations differ from the reviewed allowlist")


validate_privacy_manifest(
    Path(app_privacy_raw),
    "app",
    {
        "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1"},
        "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1"},
        "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1"},
    },
)
validate_privacy_manifest(
    Path(widget_privacy_raw),
    "Widget",
    {},
)

print("  bundle metadata, architecture record, Widget embedding, and privacy manifests: ok")
PY

validate_arm64_binary() {
  local binary=$1
  local label=$2
  local archs
  local -a parsed_archs

  if ! archs=$(/usr/bin/lipo -archs "$binary" 2>/dev/null); then
    fail "$label executable is not a readable Mach-O binary"
  fi
  read -r -a parsed_archs <<< "$archs"
  if [ "${#parsed_archs[@]}" -ne 1 ] || [ "${parsed_archs[0]}" != 'arm64' ]; then
    fail "$label executable must contain only the arm64 device architecture"
  fi
}

validate_arm64_binary "$app_binary" 'app'
validate_arm64_binary "$widget_binary" 'Widget'
printf '  executable architectures: arm64 only\n'

if ! /usr/bin/codesign --verify --strict --all-architectures \
  "$widget_bundle" >/dev/null 2>&1; then
  fail 'Widget code signature verification failed'
fi
if ! /usr/bin/codesign --verify --deep --strict --all-architectures \
  "$app_bundle" >/dev/null 2>&1; then
  fail 'app or nested-code signature verification failed'
fi

extract_signing_state() {
  local bundle=$1
  local profile=$2
  local prefix=$3

  if ! /usr/bin/codesign -d --entitlements :- "$bundle" \
    > "$audit_tmp/$prefix-entitlements.plist" 2>/dev/null; then
    fail 'could not extract signed entitlements'
  fi
  if ! /usr/bin/codesign -d --verbose=4 "$bundle" \
    > /dev/null 2> "$audit_tmp/$prefix-signature.txt"; then
    fail 'could not inspect the code-signing identity class'
  fi
  if ! /usr/bin/codesign -d \
    --extract-certificates="$audit_tmp/$prefix-certificate-" \
    "$bundle" >/dev/null 2>&1; then
    fail 'could not extract the code-signing certificate chain'
  fi
  if [ ! -s "$audit_tmp/$prefix-certificate-0" ]; then
    fail 'code signature has no leaf signing certificate'
  fi
  if ! /usr/bin/security cms -D -i "$profile" \
    -o "$audit_tmp/$prefix-profile.plist" >/dev/null 2>&1; then
    fail 'embedded provisioning profile CMS validation failed'
  fi
  if ! /usr/bin/plutil -lint "$audit_tmp/$prefix-entitlements.plist" \
    "$audit_tmp/$prefix-profile.plist" >/dev/null 2>&1; then
    fail 'extracted signing metadata is not a valid property list'
  fi
}

extract_signing_state "$app_bundle" "$app_profile" 'app'
extract_signing_state "$widget_bundle" "$widget_profile" 'widget'

# Compare signature entitlements with their embedded profiles. Error messages
# deliberately identify only the failed field, never the observed secret or
# account-specific value.
PYTHONDONTWRITEBYTECODE=1 python3 - \
  "$POMOGEM_AUDIT_SCRIPT_DIRECTORY" "$mode" "$archive_info" \
  "$audit_tmp/app-entitlements.plist" "$audit_tmp/widget-entitlements.plist" \
  "$audit_tmp/app-profile.plist" "$audit_tmp/widget-profile.plist" \
  "$audit_tmp/app-signature.txt" "$audit_tmp/widget-signature.txt" \
  "$audit_tmp/app-certificate-0" "$audit_tmp/widget-certificate-0" <<'PY'
from __future__ import annotations

import datetime as dt
import os
import plistlib
import re
import sys
from pathlib import Path
from typing import Any, Optional

(
    script_directory_raw,
    mode,
    archive_info_raw,
    app_entitlements_raw,
    widget_entitlements_raw,
    app_profile_raw,
    widget_profile_raw,
    app_signature_raw,
    widget_signature_raw,
    app_certificate_raw,
    widget_certificate_raw,
) = sys.argv[1:]

sys.path.insert(0, script_directory_raw)
from release_profile_policy import validate_profile_cloud_environment

TEAM_ID = os.environ["POMOGEM_AUDIT_TEAM_ID"]
APP_ID = os.environ["POMOGEM_AUDIT_APP_BUNDLE_ID"]
WIDGET_ID = os.environ["POMOGEM_AUDIT_WIDGET_BUNDLE_ID"]
APP_GROUP = os.environ["POMOGEM_AUDIT_APP_GROUP"]
ICLOUD_CONTAINER = os.environ["POMOGEM_AUDIT_ICLOUD_CONTAINER"]
OPERATIONS_CONTAINER = f"{ICLOUD_CONTAINER}.operations"


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def load(path: str, label: str) -> dict:
    try:
        with Path(path).open("rb") as handle:
            value = plistlib.load(handle)
    except Exception:
        fail(f"{label} is unreadable")
    if not isinstance(value, dict):
        fail(f"{label} root must be a dictionary")
    return value


def classify_identity_text(text: str) -> str:
    authorities = [
        line.removeprefix("Authority=").strip()
        for line in text.splitlines()
        if line.startswith("Authority=")
    ]
    if not authorities:
        return "unknown"
    leaf = authorities[0]
    if leaf.startswith(("Apple Development:", "iPhone Developer:")):
        return "apple-development"
    if leaf.startswith(("Apple Distribution:", "iPhone Distribution:")):
        return "apple-distribution"
    return "unknown"


def classify_archive_identity(value: Any) -> str:
    if not isinstance(value, str):
        return "unknown"
    if value.startswith(("Apple Development:", "iPhone Developer:")):
        return "apple-development"
    if value.startswith(("Apple Distribution:", "iPhone Distribution:")):
        return "apple-distribution"
    return "unknown"


def read_signature_identity(path: str) -> str:
    try:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        fail("code-signing identity metadata is unreadable")
    identity = classify_identity_text(text)
    if identity == "unknown":
        fail("code-signing identity is not an Apple development or distribution identity")
    return identity


def profile_type(profile: dict, entitlements: dict, label: str) -> str:
    task_allow = entitlements.get("get-task-allow")
    if type(task_allow) is not bool:
        fail(f"{label} profile get-task-allow is missing or malformed")

    provisions_all = profile.get("ProvisionsAllDevices", False)
    if type(provisions_all) is not bool:
        fail(f"{label} profile ProvisionsAllDevices is malformed")
    devices_present = "ProvisionedDevices" in profile
    if devices_present:
        devices = profile.get("ProvisionedDevices")
        if not isinstance(devices, list) or not devices or any(not isinstance(item, str) or not item for item in devices):
            fail(f"{label} profile registered-device list is malformed")

    if provisions_all:
        return "enterprise"
    if devices_present:
        return "development" if task_allow else "ad-hoc"
    return "app-store-connect" if not task_allow else "unknown"


def recursively_contains_forbidden(value: Any) -> bool:
    if isinstance(value, str):
        lowered = value.lower()
        return (
            value in {APP_GROUP, OPERATIONS_CONTAINER}
            or ".operations" in lowered
            or "rare-reward" in lowered
            or "rarereward" in lowered
        )
    if isinstance(value, dict):
        return any(
            recursively_contains_forbidden(key) or recursively_contains_forbidden(item)
            for key, item in value.items()
        )
    if isinstance(value, (list, tuple)):
        return any(recursively_contains_forbidden(item) for item in value)
    return False


def validate_profile_basics(
    profile: dict,
    label: str,
    bundle_id: str,
    certificate_path: str,
    allow_development_wildcard: bool,
) -> dict:
    uuid = profile.get("UUID")
    if not isinstance(uuid, str) or re.fullmatch(
        r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
        uuid,
    ) is None:
        fail(f"{label} provisioning profile UUID is missing or malformed")
    if profile.get("TeamIdentifier") != [TEAM_ID]:
        fail(f"{label} provisioning profile team does not match the reviewed team")
    if profile.get("ApplicationIdentifierPrefix") != [TEAM_ID]:
        fail(f"{label} provisioning profile application prefix does not match the reviewed team")
    platforms = profile.get("Platform")
    if not isinstance(platforms, list) or "iOS" not in platforms:
        fail(f"{label} provisioning profile is not authorized for iOS")
    certificates = profile.get("DeveloperCertificates")
    if not isinstance(certificates, list) or not certificates or any(not isinstance(item, bytes) or not item for item in certificates):
        fail(f"{label} provisioning profile has no valid signing certificate record")
    try:
        signing_certificate = Path(certificate_path).read_bytes()
    except OSError:
        fail(f"{label} leaf signing certificate is unreadable")
    if not signing_certificate or signing_certificate not in certificates:
        fail(f"{label} signing certificate is not authorized by its embedded profile")

    expiration = profile.get("ExpirationDate")
    creation = profile.get("CreationDate")
    if not isinstance(expiration, dt.datetime) or not isinstance(creation, dt.datetime):
        fail(f"{label} provisioning profile validity dates are malformed")
    if expiration.tzinfo is not None:
        expiration = expiration.astimezone(dt.timezone.utc).replace(tzinfo=None)
    if creation.tzinfo is not None:
        creation = creation.astimezone(dt.timezone.utc).replace(tzinfo=None)
    now = dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)
    if expiration <= now:
        fail(f"{label} provisioning profile is expired")
    if creation > now + dt.timedelta(minutes=10):
        fail(f"{label} provisioning profile creation date is in the future")

    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict):
        fail(f"{label} provisioning profile is missing entitlements")
    profile_application_identifier = entitlements.get("application-identifier")
    exact_application_identifier = f"{TEAM_ID}.{bundle_id}"
    development_wildcard_identifier = f"{TEAM_ID}.*"
    if profile_application_identifier != exact_application_identifier and not (
        allow_development_wildcard
        and profile_application_identifier == development_wildcard_identifier
    ):
        fail(f"{label} profile application-identifier does not match its bundle")
    if entitlements.get("com.apple.developer.team-identifier") != TEAM_ID:
        fail(f"{label} profile entitlement team does not match the reviewed team")
    if recursively_contains_forbidden(entitlements):
        fail(f"{label} profile contains a removed App Group or disabled operations/rare-reward identifier")
    return entitlements


def require_host_signature_capabilities(entitlements: dict, label: str) -> None:
    expected = {
        "com.apple.developer.icloud-container-identifiers": [ICLOUD_CONTAINER],
        "com.apple.developer.icloud-services": ["CloudKit"],
    }
    for key, expected_value in expected.items():
        if entitlements.get(key) != expected_value:
            fail(f"{label} {key} differs from the reviewed capability allowlist")

    development_containers = "com.apple.developer.icloud-container-development-container-identifiers"
    if development_containers in entitlements and entitlements.get(development_containers) != [ICLOUD_CONTAINER]:
        fail(f"{label} development iCloud containers differ from the reviewed allowlist")
    if "com.apple.security.application-groups" in entitlements:
        fail(f"{label} unexpectedly enables the removed App Group")
    if "com.apple.developer.ubiquity-container-identifiers" in entitlements:
        fail(f"{label} unexpectedly enables iCloud document containers")
    if "com.apple.developer.ubiquity-kvstore-identifier" in entitlements:
        fail(f"{label} unexpectedly enables iCloud key-value storage")
    if recursively_contains_forbidden(entitlements):
        fail(f"{label} contains a removed App Group or disabled operations/rare-reward identifier")

    if entitlements.get("aps-environment") not in ("development", "production"):
        fail(f"{label} APNs environment is missing or invalid")


def require_host_profile_capabilities(entitlements: dict, label: str) -> None:
    if entitlements.get("com.apple.developer.icloud-container-identifiers") != [ICLOUD_CONTAINER]:
        fail(f"{label} iCloud containers differ from the reviewed capability allowlist")

    # Apple development profiles express CloudKit as a broader authorization
    # than the app's signed entitlement: services may be "*", and the profile
    # may carry the iCloud document/KVS keys that the signed app does not use.
    # Keep accepting only Apple's known values for this one reviewed container;
    # the signature remains constrained to CloudKit alone above.
    services = entitlements.get("com.apple.developer.icloud-services")
    if services not in ("*", ["CloudKit"]):
        fail(f"{label} iCloud services differ from the reviewed capability allowlist")

    development_containers = "com.apple.developer.icloud-container-development-container-identifiers"
    if development_containers in entitlements and entitlements.get(development_containers) != [ICLOUD_CONTAINER]:
        fail(f"{label} development iCloud containers differ from the reviewed allowlist")

    ubiquity_containers = entitlements.get("com.apple.developer.ubiquity-container-identifiers")
    if ubiquity_containers is not None and ubiquity_containers != [ICLOUD_CONTAINER]:
        fail(f"{label} iCloud document authorization differs from the reviewed container")

    kvstore_identifier = entitlements.get("com.apple.developer.ubiquity-kvstore-identifier")
    if kvstore_identifier is not None and kvstore_identifier != f"{TEAM_ID}.*":
        fail(f"{label} iCloud key-value authorization differs from Apple's expected team wildcard")

    if "com.apple.security.application-groups" in entitlements:
        fail(f"{label} unexpectedly enables the removed App Group")
    if recursively_contains_forbidden(entitlements):
        fail(f"{label} contains a removed App Group or disabled operations/rare-reward identifier")
    if entitlements.get("aps-environment") not in ("development", "production"):
        fail(f"{label} APNs environment is missing or invalid")


def require_neutral_widget_capabilities(entitlements: dict, label: str) -> None:
    forbidden = {
        "aps-environment",
        "com.apple.developer.aps-environment",
        "com.apple.security.application-groups",
        "com.apple.developer.icloud-container-identifiers",
        "com.apple.developer.icloud-container-development-container-identifiers",
        "com.apple.developer.icloud-services",
        "com.apple.developer.icloud-container-environment",
        "com.apple.developer.ubiquity-container-identifiers",
        "com.apple.developer.ubiquity-kvstore-identifier",
    }
    if forbidden.intersection(entitlements):
        fail(f"{label} contains an account-data, iCloud, App Group, or APNs entitlement")
    if recursively_contains_forbidden(entitlements):
        fail(f"{label} contains a removed App Group or disabled operations/rare-reward identifier")


def validate_signed_bundle(
    *,
    label: str,
    bundle_id: str,
    signed_entitlements: dict,
    profile: dict,
    identity: str,
    certificate_path: str,
    is_neutral_widget: bool,
) -> tuple[str, bool, Optional[str]]:
    profile_entitlements = validate_profile_basics(
        profile,
        label,
        bundle_id,
        certificate_path,
        is_neutral_widget,
    )
    if is_neutral_widget:
        require_neutral_widget_capabilities(signed_entitlements, f"{label} signature")
        require_neutral_widget_capabilities(profile_entitlements, f"{label} profile")
    else:
        require_host_signature_capabilities(signed_entitlements, f"{label} signature")
        require_host_profile_capabilities(profile_entitlements, f"{label} profile")

    expected_application_identifier = f"{TEAM_ID}.{bundle_id}"
    if signed_entitlements.get("application-identifier") != expected_application_identifier:
        fail(f"{label} signed application-identifier does not match its bundle")
    if signed_entitlements.get("com.apple.developer.team-identifier") != TEAM_ID:
        fail(f"{label} signed team entitlement does not match the reviewed team")

    signed_task_allow = signed_entitlements.get("get-task-allow")
    profile_task_allow = profile_entitlements.get("get-task-allow")
    if type(signed_task_allow) is not bool or type(profile_task_allow) is not bool:
        fail(f"{label} get-task-allow entitlement is missing or malformed")
    if signed_task_allow is not profile_task_allow:
        fail(f"{label} signature and profile get-task-allow values differ")

    kind = profile_type(profile, profile_entitlements, label)
    if kind == "development":
        expected_identity = "apple-development"
        expected_cloud_environment = "Development"
        expected_aps_environment = "development"
    elif kind == "app-store-connect":
        expected_identity = "apple-distribution"
        expected_cloud_environment = "Production"
        expected_aps_environment = "production"
    elif kind in {"ad-hoc", "enterprise"}:
        fail(f"{label} uses a non-App-Store distribution profile")
    else:
        fail(f"{label} provisioning profile type is not a supported release-archive type")

    if (
        profile_entitlements.get("application-identifier") == f"{TEAM_ID}.*"
        and kind != "development"
    ):
        fail(f"{label} wildcard provisioning is only accepted for a raw development archive")

    if identity != expected_identity:
        fail(f"{label} signing identity and provisioning profile classes differ")
    if is_neutral_widget:
        cloud_environment = None
    else:
        cloud_environment = expected_cloud_environment
        if signed_entitlements.get("com.apple.developer.icloud-container-environment") != expected_cloud_environment:
            fail(f"{label} signed CloudKit environment does not match the profile class")
        profile_cloud_value = profile_entitlements.get("com.apple.developer.icloud-container-environment")
        try:
            validate_profile_cloud_environment(profile_cloud_value, expected_cloud_environment)
        except ValueError as error:
            fail(f"{label} {error}")
        if signed_entitlements.get("aps-environment") != expected_aps_environment:
            fail(f"{label} signed APNs environment does not match the profile class")
        if profile_entitlements.get("aps-environment") != expected_aps_environment:
            fail(f"{label} profile APNs environment does not match its distribution class")

    return kind, signed_task_allow, cloud_environment


archive_plist = load(archive_info_raw, "archive Info.plist")
app_entitlements = load(app_entitlements_raw, "app signed entitlements")
widget_entitlements = load(widget_entitlements_raw, "Widget signed entitlements")
app_profile = load(app_profile_raw, "app provisioning profile")
widget_profile = load(widget_profile_raw, "Widget provisioning profile")
app_identity = read_signature_identity(app_signature_raw)
widget_identity = read_signature_identity(widget_signature_raw)

properties = archive_plist.get("ApplicationProperties", {})
if not isinstance(properties, dict):
    fail("archive ApplicationProperties is malformed")
archive_identity = classify_archive_identity(properties.get("SigningIdentity"))
if archive_identity != app_identity:
    fail("archive signing identity record does not match the app signature class")
if widget_identity != app_identity:
    fail("app and Widget signing identity classes differ")

app_kind, app_task_allow, app_cloud = validate_signed_bundle(
    label="app",
    bundle_id=APP_ID,
    signed_entitlements=app_entitlements,
    profile=app_profile,
    identity=app_identity,
    certificate_path=app_certificate_raw,
    is_neutral_widget=False,
)
widget_kind, widget_task_allow, widget_cloud = validate_signed_bundle(
    label="Widget",
    bundle_id=WIDGET_ID,
    signed_entitlements=widget_entitlements,
    profile=widget_profile,
    identity=widget_identity,
    certificate_path=widget_certificate_raw,
    is_neutral_widget=True,
)

if (app_kind, app_task_allow) != (widget_kind, widget_task_allow):
    fail("app and Widget signing/profile environments differ")
if widget_cloud is not None:
    fail("neutral Widget unexpectedly selected a CloudKit environment")

if mode == "distribution":
    if app_identity != "apple-distribution" or app_kind != "app-store-connect":
        fail("--distribution requires Apple Distribution and App Store Connect profiles")
    if app_task_allow is not False:
        fail("--distribution requires get-task-allow=false")
    if "ProvisionedDevices" in app_profile or "ProvisionedDevices" in widget_profile:
        fail("--distribution forbids registered-device provisioning")
    if app_profile.get("ProvisionsAllDevices", False) or widget_profile.get("ProvisionsAllDevices", False):
        fail("--distribution forbids enterprise provisioning")
    if app_cloud != "Production":
        fail("--distribution requires the production CloudKit environment")

task_label = "true" if app_task_allow else "false"
identity_label = "Apple Development" if app_identity == "apple-development" else "Apple Distribution"
print(f"  signing: {identity_label} / {app_kind} profile / get-task-allow={task_label}")
print("  profile UUID, signing certificate, team, application identifier, capabilities, and validity: matched")
PY

scan_release_binary() {
  local binary=$1
  local label=$2
  local output="$audit_tmp/$label-strings.txt"
  local marker

  if ! /usr/bin/strings -a "$binary" > "$output" 2>/dev/null; then
    fail "$label release-string scan failed"
  fi
  if [ ! -s "$output" ]; then
    fail "$label release-string scan produced no auditable output"
  fi

  # The dedicated factory name also occurs inside an unstripped Swift symbol.
  # Missing strings alone are not proof of the runtime's default-deny policy.
  for marker in \
    'POMOGEM_LOCAL_PREVIEW' \
    'POMOGEM_UI_TEST_' \
    'POMOGEM_REAL_' \
    'POMOGEM_RUN_40_YEAR_PERSISTENCE' \
    'liveForIsolatedTesting' \
    'FortyYearPersistentUITestFixture' \
    'FortyYearDebugScenario' \
    'FortyYearPersistenceHarness' \
    'UITestFaultInjection' \
    'JarUITestPresentationProbe' \
    'FortyYearPersistentFixtureProbe' \
    'AggregatePersistenceRecoveryProbe'; do
    if LC_ALL=C /usr/bin/grep -Fq "$marker" "$output"; then
      fail "$label executable contains a reviewed Debug-only gate or marker"
    fi
  done
}

scan_release_binary "$app_binary" 'app'
scan_release_binary "$widget_binary" 'widget'

if ! LC_ALL=C /usr/bin/grep -Fq \
  'PomoGemFocusLiveActivity' "$audit_tmp/widget-strings.txt"; then
  fail 'Widget is missing the reviewed Live Activity configuration marker'
fi

if LC_ALL=C /usr/bin/grep -Fq \
  "$POMOGEM_AUDIT_APP_GROUP" "$audit_tmp/app-strings.txt"; then
  fail 'app executable contains the removed version 1.0 App Group identifier'
fi
if ! LC_ALL=C /usr/bin/grep -Fq \
  'live-activity.enabled' "$audit_tmp/app-strings.txt"; then
  fail 'app is missing the reviewed local Live Activity preference marker'
fi

app_linked_libraries="$audit_tmp/app-linked-libraries.txt"
if ! /usr/bin/otool -L "$app_binary" > "$app_linked_libraries" 2>/dev/null; then
  fail 'app linked-library audit failed'
fi
if ! LC_ALL=C /usr/bin/grep -Fq \
  '/ActivityKit.framework/ActivityKit' "$app_linked_libraries"; then
  fail 'app is missing ActivityKit for the reviewed Live Activity lifecycle'
fi

widget_linked_libraries="$audit_tmp/widget-linked-libraries.txt"
if ! /usr/bin/otool -L "$widget_binary" > "$widget_linked_libraries" 2>/dev/null; then
  fail 'Widget linked-library audit failed'
fi
for forbidden_framework in \
  '/CloudKit.framework/CloudKit' \
  '/SwiftData.framework/SwiftData'; do
  if LC_ALL=C /usr/bin/grep -Fq "$forbidden_framework" "$widget_linked_libraries"; then
    fail 'neutral Widget links an account-data framework'
  fi
done
if ! LC_ALL=C /usr/bin/grep -Fq \
  '/ActivityKit.framework/ActivityKit' "$widget_linked_libraries"; then
  fail 'Widget is missing ActivityKit for the reviewed Live Activity'
fi

for account_marker in \
  'subjectName' \
  'subjectColorHex' \
  'accountNamespaceRawValue' \
  'WidgetSnapshotMetadata' \
  'AccountScopedLocalState' \
  'verifiedWidgetFileName' \
  'widgetSnapshotMetadataFileName' \
  'widgetSnapshotImageFileName' \
  'jar-widget.json' \
  'jar-widget.png' \
  'totalGrams' \
  'measuredGrams' \
  'pebbleCount' \
  'goldCount' \
  'prismCount' \
  'imageFileName' \
  'formattedTotalMass' \
  'containerURLForSecurityApplicationGroupIdentifier' \
  'NSUbiquitousKeyValueStore' \
  'ubiquityIdentityToken' \
  'CKContainer' \
  "$POMOGEM_AUDIT_APP_GROUP" \
  "$POMOGEM_AUDIT_ICLOUD_CONTAINER"; do
  if LC_ALL=C /usr/bin/grep -Fq "$account_marker" "$audit_tmp/widget-strings.txt"; then
    fail 'neutral Widget executable contains an account-derived data or Live Activity marker'
  fi
done
printf '  Release executable Debug-gate scan: ok\n'
printf '  account-neutral Widget and Live Activity linkage/marker scan: ok\n'

if [ "$mode" = 'distribution' ]; then
  printf 'Distribution-signed archive verification passed.\n'
  printf '%s\n' \
    "This result covers the supplied .xcarchive, not any later Xcode upload staging payload." \
    "Organizer Validate and App Store Connect server validation are still required."
else
  printf 'Raw Organizer archive verification passed.\n'
  printf '%s\n' \
    "This is not proof that the eventual upload payload is distribution signed." \
    "Xcode may re-sign during Distribute App; use --distribution only on a known distribution-signed archive."
fi

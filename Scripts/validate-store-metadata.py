#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
META = ROOT / "AppStore/metadata/ja-JP"


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def read(name: str) -> str:
    path = META / name
    if not path.is_file():
        fail(f"missing App Store metadata: {path.relative_to(ROOT)}")
    value = path.read_text(encoding="utf-8").strip()
    if not value:
        fail(f"empty App Store metadata: {path.relative_to(ROOT)}")
    return value


parser = argparse.ArgumentParser()
parser.add_argument("--release", action="store_true")
args = parser.parse_args()

limits = {
    "name.txt": (30, "characters"),
    "subtitle.txt": (30, "characters"),
    "promotional_text.txt": (170, "characters"),
    # App Store Connect measures the keyword field in UTF-8 bytes, not
    # user-perceived Japanese characters.
    "keywords.txt": (100, "bytes"),
    "description.txt": (4000, "characters"),
}
values = {name: read(name) for name in limits}
for name, (limit, unit) in limits.items():
    length = len(values[name].encode("utf-8")) if unit == "bytes" else len(values[name])
    if length > limit:
        fail(f"{name} exceeds {limit} {unit} ({length})")

expected_urls = {
    "support_url.txt": "https://tumiben.hinoshiba.com/support/",
    "marketing_url.txt": "https://tumiben.hinoshiba.com/",
    "privacy_url.txt": "https://tumiben.hinoshiba.com/privacy/",
}
for name, expected in expected_urls.items():
    value = read(name)
    parsed = urlsplit(value)
    if parsed.scheme != "https" or parsed.netloc != "tumiben.hinoshiba.com":
        fail(f"{name} must use the canonical HTTPS host")
    if value != expected:
        fail(f"{name} must be exactly {expected}")

keywords = [keyword.strip() for keyword in values["keywords.txt"].split(",")]
if any(not keyword for keyword in keywords):
    fail("keywords.txt contains an empty keyword")
if len(set(keywords)) != len(keywords):
    fail("keywords.txt contains duplicate keywords")

combined = "\n".join(values.values())
for placeholder in ("TODO", "TBD", "CHANGEME", "YOUR_", "placeholder"):
    if placeholder.lower() in combined.lower():
        fail(f"release placeholder found: {placeholder}")
if "Mac" in combined or "macOS" in combined:
    fail("unsupported Mac claim found in App Store metadata")
if "Web決済" in combined or "外部決済" in combined:
    fail("external payment claim found in App Store metadata")

configuration = (ROOT / "AppStore/configuration.yml").read_text(encoding="utf-8")
configuration_lines = {
    line.strip()
    for line in configuration.splitlines()
    if line.strip() and not line.lstrip().startswith("#")
}
required_lines = (
    "platform: iOS",
    "primary_locale: ja-JP",
    "website_host: tumiben.hinoshiba.com",
    "app_bundle_id: com.hinoshiba.tsumiben",
    "widget_bundle_id: com.hinoshiba.tsumiben.widgets",
    'minimum_ios: "17.0"',
    "supports_ipad_ui: false",
    "supports_mac_catalyst: false",
    "offer_ios_app_on_apple_silicon_mac: false",
    "offer_ios_app_on_vision_pro: false",
    "i_cloud_container: iCloud.com.hinoshiba.tsumiben",
    "app_group: group.com.hinoshiba.tsumiben",
    "- product_id: com.hinoshiba.tsumiben.pro.lifetime",
    "type: non_consumable",
    "japan_target_price_jpy: 100",
)
for line in required_lines:
    if line not in configuration_lines:
        fail(f"configuration.yml is missing: {line}")

if args.release and "app_store_id: null" in configuration_lines:
    fail("App Store ID is still null")
if args.release and "release_blockers: []" not in configuration_lines:
    fail("release blockers are still recorded")

print("App Store metadata validation passed.")

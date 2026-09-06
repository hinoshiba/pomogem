#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
META = ROOT / "AppStore/metadata/ja-JP"
EN_META = ROOT / "AppStore/metadata/en-US"


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


def read_localized(meta: Path, name: str) -> str:
    path = meta / name
    if not path.is_file():
        fail(f"missing App Store metadata: {path.relative_to(ROOT)}")
    value = path.read_text(encoding="utf-8").strip()
    if not value:
        fail(f"empty App Store metadata: {path.relative_to(ROOT)}")
    return value


en_values = {name: read_localized(EN_META, name) for name in limits}
for name, (limit, unit) in limits.items():
    value = en_values[name]
    length = len(value.encode("utf-8")) if unit == "bytes" else len(value)
    if length > limit:
        fail(f"en-US/{name} exceeds {limit} {unit} ({length})")
if "currently provided in Japanese" not in en_values["description.txt"]:
    fail("en-US description must disclose the Japanese-language interface")

expected_urls = {
    "support_url.txt": "https://pomogem.hinoshiba.com/support/",
    "marketing_url.txt": "https://pomogem.hinoshiba.com/",
    "privacy_url.txt": "https://pomogem.hinoshiba.com/privacy/",
}
for name, expected in expected_urls.items():
    value = read(name)
    parsed = urlsplit(value)
    if parsed.scheme != "https" or parsed.netloc != "pomogem.hinoshiba.com":
        fail(f"{name} must use the canonical HTTPS host")
    if value != expected:
        fail(f"{name} must be exactly {expected}")
    en_value = read_localized(EN_META, name)
    if en_value != expected:
        fail(f"en-US/{name} must be exactly {expected}")

keywords = [keyword.strip() for keyword in values["keywords.txt"].split(",")]
if any(not keyword for keyword in keywords):
    fail("keywords.txt contains an empty keyword")
if len(set(keywords)) != len(keywords):
    fail("keywords.txt contains duplicate keywords")

en_keywords = [keyword.strip() for keyword in en_values["keywords.txt"].split(",")]
if any(not keyword for keyword in en_keywords):
    fail("en-US/keywords.txt contains an empty keyword")
if len(set(en_keywords)) != len(en_keywords):
    fail("en-US/keywords.txt contains duplicate keywords")

combined = "\n".join([*values.values(), *en_values.values()])
for placeholder in ("TODO", "TBD", "CHANGEME", "YOUR_", "placeholder"):
    if placeholder.lower() in combined.lower():
        fail(f"release placeholder found: {placeholder}")
if "Mac" in combined or "macOS" in combined:
    fail("unsupported Mac claim found in App Store metadata")
if "Web決済" in combined or "外部決済" in combined:
    fail("external payment claim found in App Store metadata")
if any(term.lower() in combined.lower() for term in ("レア粒", "レア抽選", "rare pebble", "rare reward")):
    fail("disabled random-reward claim found in App Store metadata")

configuration = (ROOT / "AppStore/configuration.yml").read_text(encoding="utf-8")
configuration_lines = {
    line.strip()
    for line in configuration.splitlines()
    if line.strip() and not line.lstrip().startswith("#")
}
configuration_entries = [
    (len(line) - len(line.lstrip(" ")), line.strip())
    for line in configuration.splitlines()
    if line.strip() and not line.lstrip().startswith("#")
]


def yaml_block(
    entries: list[tuple[int, str]],
    parent_indent: int,
    key: str,
    scope: str,
) -> list[tuple[int, str]]:
    marker = f"{key}:"
    matches = [
        index
        for index, (indent, content) in enumerate(entries)
        if indent == parent_indent and content == marker
    ]
    if len(matches) != 1:
        fail(f"configuration.yml {scope}.{key} must appear exactly once")
    start = matches[0] + 1
    end = start
    while end < len(entries) and entries[end][0] > parent_indent:
        end += 1
    return entries[start:end]


def yaml_scalar(
    entries: list[tuple[int, str]],
    indent: int,
    key: str,
    scope: str,
) -> str:
    marker = f"{key}:"
    matches = [
        content[len(marker) :].strip()
        for current_indent, content in entries
        if current_indent == indent and content.startswith(marker)
    ]
    if len(matches) != 1 or not matches[0]:
        fail(f"configuration.yml {scope}.{key} must have exactly one scalar value")
    return matches[0]


def yaml_list(
    entries: list[tuple[int, str]],
    key_indent: int,
    key: str,
    scope: str,
) -> list[str]:
    block = yaml_block(entries, key_indent, key, scope)
    values = [
        content[2:].strip()
        for indent, content in block
        if indent == key_indent + 2 and content.startswith("- ")
    ]
    if not values or any(not value for value in values):
        fail(f"configuration.yml {scope}.{key} must be a non-empty scalar list")
    return values


AVAILABILITY_CONTRACT = "non_eu_148_of_175_countries_and_regions"
EU_27 = (
    "Austria",
    "Belgium",
    "Bulgaria",
    "Croatia",
    "Cyprus",
    "Czech Republic",
    "Denmark",
    "Estonia",
    "Finland",
    "France",
    "Germany",
    "Greece",
    "Hungary",
    "Ireland",
    "Italy",
    "Latvia",
    "Lithuania",
    "Luxembourg",
    "Malta",
    "Netherlands",
    "Poland",
    "Portugal",
    "Romania",
    "Slovakia",
    "Slovenia",
    "Spain",
    "Sweden",
)
NON_EU_NEIGHBORS = ("United Kingdom", "Norway", "Switzerland")

required_lines = (
    "platform: iOS",
    "primary_locale: ja-JP",
    "primary_category: Productivity",
    "secondary_category: Education",
    "- ja-JP",
    "- en-US",
    'marketing_version: "1.0"',
    'build_number: "5"',
    'copyright: "2026 hinoshiba"',
    "website_host: pomogem.hinoshiba.com",
    "app_bundle_id: com.hinoshiba.pomogem",
    "widget_bundle_id: com.hinoshiba.pomogem.widgets",
    'minimum_ios: "17.0"',
    "supports_ipad_ui: false",
    "supports_mac_catalyst: false",
    "offer_ios_app_on_apple_silicon_mac: false",
    "offer_ios_app_on_vision_pro: false",
    "app_price: free",
    "release_method: automatic_after_approval",
    f"availability: {AVAILABILITY_CONTRACT}",
    "apple_school_manager_reduced_price: true",
    "i_cloud_containers:",
    "synchronized_data: iCloud.com.hinoshiba.pomogem",
    "- product_id: com.hinoshiba.pomogem.pro.lifetime",
    "type: non_consumable",
    "base_country_or_region: United States",
    "united_states_target_price_usd: 0.99",
    "japan_target_price_jpy: 100",
    "price_management: automatic_equivalent_except_japan_override",
)
for line in required_lines:
    if line not in configuration_lines:
        fail(f"configuration.yml is missing: {line}")

if yaml_scalar(configuration_entries, 0, "availability", "app") != AVAILABILITY_CONTRACT:
    fail(f"configuration.yml app availability must be {AVAILABILITY_CONTRACT}")
if (
    yaml_scalar(
        configuration_entries,
        0,
        "automatically_available_in_new_countries_or_regions",
        "app",
    )
    != "true"
):
    fail("configuration.yml app future-storefront auto-availability must be true")

storefronts = yaml_block(
    configuration_entries, 0, "storefront_availability", "storefront_availability"
)
expected_storefront_counts = {
    "total_current_storefronts": "175",
    "app_available_storefronts": "148",
    "iap_available_storefronts": "148",
}
for key, expected in expected_storefront_counts.items():
    if yaml_scalar(storefronts, 2, key, "storefront_availability") != expected:
        fail(f"configuration.yml storefront_availability.{key} must be {expected}")

excluded_eu = yaml_list(
    storefronts, 2, "excluded_current_eu_27", "storefront_availability"
)
if len(excluded_eu) != len(EU_27) or set(excluded_eu) != set(EU_27):
    missing = sorted(set(EU_27) - set(excluded_eu))
    unexpected = sorted(set(excluded_eu) - set(EU_27))
    fail(
        "configuration.yml excluded_current_eu_27 must contain exactly the EU27 "
        f"(missing: {missing or 'none'}; unexpected/duplicate count: "
        f"{unexpected or 'none'}/{len(excluded_eu)})"
    )

included_neighbors = yaml_list(
    storefronts,
    2,
    "explicitly_included_non_eu_neighbors",
    "storefront_availability",
)
if len(included_neighbors) != len(NON_EU_NEIGHBORS) or set(included_neighbors) != set(
    NON_EU_NEIGHBORS
):
    fail(
        "configuration.yml explicitly_included_non_eu_neighbors must contain "
        "exactly United Kingdom, Norway, and Switzerland"
    )

eu_dsa = yaml_block(configuration_entries, 0, "eu_dsa", "eu_dsa")
if yaml_scalar(eu_dsa, 2, "app_store_connect_status", "eu_dsa") != "non_trader":
    fail("configuration.yml eu_dsa.app_store_connect_status must be non_trader")
if (
    yaml_scalar(eu_dsa, 2, "release_blocker", "eu_dsa")
    != "resolved_by_excluding_current_eu_27_from_app_and_iap"
):
    fail("configuration.yml EU DSA blocker must be resolved by excluding EU27 from app and IAP")
# This asserts release-checklist metadata only; it is not a legal conclusion.
if yaml_scalar(eu_dsa, 2, "legal_advice", "eu_dsa") != "false":
    fail("configuration.yml eu_dsa.legal_advice must remain false")

iaps = yaml_block(configuration_entries, 0, "in_app_purchases", "in_app_purchases")
iap_starts = [
    index
    for index, (indent, content) in enumerate(iaps)
    if indent == 2 and content.startswith("- product_id:")
]
if not iap_starts:
    fail("configuration.yml in_app_purchases must contain at least one product")
iap_product_ids: list[str] = []
for product_position, start in enumerate(iap_starts):
    end = iap_starts[product_position + 1] if product_position + 1 < len(iap_starts) else len(iaps)
    product = iaps[start:end]
    product_id = product[0][1].split(":", 1)[1].strip()
    if not product_id:
        fail("configuration.yml in_app_purchases contains an empty product_id")
    iap_product_ids.append(product_id)
    scope = f"in_app_purchases[{product_id}]"
    review_screenshot_status = yaml_scalar(product, 4, "review_screenshot_status", scope)
    if review_screenshot_status not in {"pending_live_price_capture", "captured_live_price"}:
        fail(f"configuration.yml {scope}.review_screenshot_status is invalid")
    if review_screenshot_status == "pending_live_price_capture":
        blocker = (
            "- capture and verify the new PomoGem IAP review screenshot with the live "
            f"StoreKit price for {product_id}"
        )
        if blocker not in configuration_lines:
            fail("pending IAP screenshot requires its explicit release blocker")
        if args.release:
            fail("IAP review screenshot has not been captured with the new live product price")
    if yaml_scalar(product, 4, "availability", scope) != AVAILABILITY_CONTRACT:
        fail(f"configuration.yml {scope}.availability must be {AVAILABILITY_CONTRACT}")
    if (
        yaml_scalar(
            product,
            4,
            "automatically_available_in_new_countries_or_regions",
            scope,
        )
        != "true"
    ):
        fail(f"configuration.yml {scope} future-storefront auto-availability must be true")
if len(iap_product_ids) != len(set(iap_product_ids)):
    fail("configuration.yml in_app_purchases contains duplicate product_id values")

if "iCloud.com.hinoshiba.pomogem.operations" in configuration:
    fail("version 1.0 must not declare the disabled rare-reward operations container")
if "group.com.hinoshiba.pomogem" in configuration or "- app_groups" in configuration_lines:
    fail("version 1.0 must not declare the removed App Group")
if "rare_rewards: disabled" not in configuration_lines:
    fail("version 1.0 rare-reward release gate must remain disabled")

project = (ROOT / "project.yml").read_text(encoding="utf-8")
for line in ('MARKETING_VERSION: "1.0"', 'CURRENT_PROJECT_VERSION: "5"'):
    if line not in project:
        fail(f"project.yml version does not match App Store configuration: {line}")

review_notes = (ROOT / "AppStore/review-notes-connect.txt").read_text(encoding="utf-8")
if len(review_notes) > 4000:
    fail("review-notes-connect.txt exceeds the App Store Connect 4,000-character limit")
for label in (
    "iCloudに保存して同期",
    "このiPhoneだけに保存",
    "このiPhoneだけで始める",
    "ためしに一粒、落としてみる",
    "時間を手動で積む",
    "確認して積む",
    "Jar sound, haptics, and motion test",
):
    if label not in review_notes:
        fail(f"review-notes-connect.txt is missing the shipping UI/review path label: {label}")
iap_review_notes = (ROOT / "AppStore/iap-review-notes-connect.txt").read_text(encoding="utf-8")
if len(iap_review_notes) > 4000:
    fail("iap-review-notes-connect.txt exceeds the App Store Connect 4,000-character limit")
for label in (
    "25-, 45-, 60-, and 90-minute",
    "Share cards retain the PomoGem logo",
    "価格・提供条件・販売者情報を確認",
    "購入を復元",
):
    if label not in iap_review_notes:
        fail(f"iap-review-notes-connect.txt is missing the shipping behavior: {label}")
if "manually release after approval" in (ROOT / "AppStore/connect-entry-plan.md").read_text(
    encoding="utf-8"
):
    fail("connect-entry-plan.md conflicts with the automatic release decision")

app_store_id = yaml_scalar(configuration_entries, 0, "app_store_id", "app")
oss_publication = yaml_block(configuration_entries, 0, "oss_publication", "oss_publication")
if yaml_scalar(oss_publication, 2, "repository_visibility", "oss_publication") not in {"private", "public"}:
    fail("source repository visibility must be private or public")
listing_status = yaml_scalar(configuration_entries, 0, "app_store_listing_status", "app")
if listing_status not in {"not_public", "public"}:
    fail("App Store listing status must be not_public or public")
if listing_status == "public" and app_store_id == "null":
    fail("a public App Store listing requires its registered numeric ID")
if app_store_id == "null":
    if args.release:
        fail("App Store ID is still null")
elif not (app_store_id.isascii() and app_store_id.isdecimal() and not app_store_id.startswith("0")):
    fail("App Store ID must be null or a positive unquoted numeric ID")
if args.release and "release_blockers: []" not in configuration_lines:
    fail("release blockers are still recorded")

print("App Store metadata validation passed.")

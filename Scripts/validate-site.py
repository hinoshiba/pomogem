#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import re
import struct
import sys
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1] / "http_dists"
PUBLIC_BASE = "https://pomogem.hinoshiba.com/"
INDEX_PAGE = ROOT / "index.html"
ENGLISH_INDEX_PAGE = ROOT / "en/index.html"
COMMERCIAL_PAGE = ROOT / "commercial-transactions/index.html"
ENGLISH_COMMERCIAL_PAGE = ROOT / "en/commercial-transactions/index.html"
INDEX_PAGES = {INDEX_PAGE, ENGLISH_INDEX_PAGE}
COMMERCIAL_PAGES = {COMMERCIAL_PAGE, ENGLISH_COMMERCIAL_PAGE}
COMMERCIAL_MARKERS = ("commercial-transactions", "販売条件", "販売者情報")
EXACT_PRICE_PATTERNS = (
    r"[¥￥$]\s*\d",
    r"\b(?:USD|JPY)\s*\d",
    r"\d[\d,]*(?:\.\d+)?\s*(?:円|米ドル|ドル)",
    r"\d[\d,]*(?:\.\d+)?\s*(?:USD|JPY|dollars?|yen|cents?)\b",
)
PUBLIC_CONTACT_PATTERNS = (
    r"href\s*=\s*[\"']tel:",
    r"〒\s*\d{3}-\d{4}",
    r"\d{2,4}-\d{2,4}-\d{3,4}",
)
# Updating the seller disclosure requires an explicit privacy review and
# replacement of this approved snapshot hash. This is the fail-closed guard
# against accidentally publishing a real address or telephone number in an
# otherwise hard-to-detect format.
APPROVED_COMMERCIAL_DISCLOSURE_SHA256 = {
    COMMERCIAL_PAGE: "ae5591a40fb16917658f3429bd5b459d81f11d372a4062ee3fcc3d5c62632ead",
    ENGLISH_COMMERCIAL_PAGE: "71dc5896b3fa1b2d62388cafc145954e2093d094507d29fe04d77b883fd642e0",
}


class PageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.refs: list[tuple[str, str]] = []
        self.links: list[dict[str, str]] = []
        self.canonical: list[str] = []
        self.alternates: list[tuple[str, str]] = []
        self.meta: dict[str, str] = {}
        self.anchors: set[str] = set()
        self.title_parts: list[str] = []
        self.text_parts: list[str] = []
        self.in_title = False
        self.html_lang: str | None = None
        self.errors: list[str] = []
        self.section_ids: list[str] = []
        self.current_anchor: dict[str, str] | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = {key: value or "" for key, value in attrs}
        if values.get("id"):
            self.anchors.add(values["id"])
        if tag == "a" and values.get("name"):
            self.anchors.add(values["name"])
        if tag == "html":
            self.html_lang = values.get("lang")
        if tag == "title":
            self.in_title = True
        if tag == "section":
            self.section_ids.append(values.get("id", ""))
        if tag in {"a", "link"} and values.get("href"):
            self.refs.append(("href", values["href"]))
            link = {**values, "tag": tag, "section": "/".join(self.section_ids), "text": ""}
            self.links.append(link)
            if tag == "a":
                self.current_anchor = link
        if tag in {"img", "script", "source"} and values.get("src"):
            self.refs.append(("src", values["src"]))
        if tag == "img" and "alt" not in values:
            self.errors.append(f"img is missing alt: {values.get('src', '<inline>')}")
        if tag == "link" and values.get("rel") == "canonical":
            self.canonical.append(values.get("href", ""))
        if tag == "link" and values.get("rel") == "alternate" and values.get("hreflang"):
            self.alternates.append((values["hreflang"], values.get("href", "")))
        if tag == "meta":
            key = values.get("name") or values.get("property")
            if key:
                self.meta[key] = values.get("content", "")

    def handle_endtag(self, tag: str) -> None:
        if tag == "title":
            self.in_title = False
        if tag == "section" and self.section_ids:
            self.section_ids.pop()
        if tag == "a":
            self.current_anchor = None

    def handle_data(self, data: str) -> None:
        self.text_parts.append(data)
        if self.in_title:
            self.title_parts.append(data)
        if self.current_anchor is not None:
            self.current_anchor["text"] += data


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def png_dimensions(path: Path) -> tuple[int, int]:
    data = path.read_bytes()[:24]
    if len(data) != 24 or data[:8] != b"\x89PNG\r\n\x1a\n":
        fail(f"not a PNG: {path.relative_to(ROOT.parent)}")
    return struct.unpack(">II", data[16:24])


def resolve_local(page: Path, value: str) -> Path | None:
    split = urlsplit(value)
    if split.scheme in {"http", "https"} and split.netloc == urlsplit(PUBLIC_BASE).netloc:
        # Canonical and language-alternate URLs must resolve inside this build,
        # just like relative navigation links.
        value = split.path + (f"#{split.fragment}" if split.fragment else "")
        split = urlsplit(value)
    if split.scheme in {"http", "https", "mailto", "tel", "data"}:
        return None
    if split.scheme or split.netloc:
        fail(f"unsupported link scheme in {page.relative_to(ROOT)}: {value}")
    raw_path = unquote(split.path)
    if not raw_path:
        target = page
    elif raw_path.startswith("/"):
        target = ROOT / raw_path.removeprefix("/")
    elif raw_path:
        target = page.parent / raw_path
    if raw_path.endswith("/"):
        target /= "index.html"
    target = target.resolve()
    if ROOT.resolve() not in target.parents and target != ROOT.resolve():
        fail(f"link escapes http_dists in {page.relative_to(ROOT)}: {value}")
    return target


required = [
    ROOT / ".nojekyll",
    ROOT / "CNAME",
    INDEX_PAGE,
    ROOT / "404.html",
    ROOT / "privacy/index.html",
    ROOT / "support/index.html",
    ROOT / "terms/index.html",
    COMMERCIAL_PAGE,
    ENGLISH_INDEX_PAGE,
    ROOT / "en/privacy/index.html",
    ROOT / "en/support/index.html",
    ROOT / "en/terms/index.html",
    ENGLISH_COMMERCIAL_PAGE,
    ROOT / "robots.txt",
    ROOT / "sitemap.xml",
    ROOT / "styles.css",
    ROOT / "app.js",
    ROOT / "og-pomogem-v1.png",
    ROOT / "public/app-icon-focus-v5.png",
    ROOT / "public/apple-touch-icon.png",
    ROOT / "public/app-home-v3.webp",
    ROOT / "public/app-timer-v2.webp",
    ROOT / "public/ZenMaruGothic-Black.ttf",
    ROOT / "font-license.txt",
]
for path in required:
    if not path.exists():
        fail(f"required site file is missing: {path.relative_to(ROOT.parent)}")

expected_canonical = {
    INDEX_PAGE: PUBLIC_BASE,
    ROOT / "privacy/index.html": PUBLIC_BASE + "privacy/",
    ROOT / "support/index.html": PUBLIC_BASE + "support/",
    ROOT / "terms/index.html": PUBLIC_BASE + "terms/",
    COMMERCIAL_PAGE: PUBLIC_BASE + "commercial-transactions/",
}
for page, canonical in list(expected_canonical.items()):
    expected_canonical[ROOT / "en" / page.relative_to(ROOT)] = PUBLIC_BASE + "en/" + canonical.removeprefix(PUBLIC_BASE)

expected_sitemap_locations = {
    PUBLIC_BASE,
    PUBLIC_BASE + "privacy/",
    PUBLIC_BASE + "support/",
    PUBLIC_BASE + "terms/",
}
expected_sitemap_locations |= {
    PUBLIC_BASE + "en/" + url.removeprefix(PUBLIC_BASE)
    for url in expected_sitemap_locations
}

parsed_pages: dict[Path, PageParser] = {}
for page in sorted(ROOT.rglob("*.html")):
    source = page.read_text(encoding="utf-8")
    if "file://" in source or "127.0.0.1" in source or "localhost" in source:
        fail(f"local-only URL remains in {page.relative_to(ROOT)}")
    if any(re.search(pattern, source, flags=re.IGNORECASE) for pattern in EXACT_PRICE_PATTERNS):
        fail(f"exact monetary amount must not be published on the website: {page.relative_to(ROOT)}")
    if any(re.search(pattern, source, flags=re.IGNORECASE) for pattern in PUBLIC_CONTACT_PATTERNS):
        fail(f"public phone or postal address must not be embedded in the website: {page.relative_to(ROOT)}")
    if page not in INDEX_PAGES | COMMERCIAL_PAGES and any(marker in source for marker in COMMERCIAL_MARKERS):
        fail(f"commercial disclosure must not appear in general site navigation: {page.relative_to(ROOT)}")
    if page in INDEX_PAGES:
        if source.count('href="commercial-transactions/"') != 1:
            fail("index must have exactly one relative purchase-disclosure link")
        if source.count("commercial-transactions") != 1:
            fail("index purchase-disclosure endpoint must appear exactly once")
        if page == INDEX_PAGE and (source.count("購入条件・販売者情報") != 1 or "販売条件" in source):
            fail("index must use the scoped purchase-disclosure label")
    if any(term in source for term in ("Mac版", "Mac Catalyst", "macOS対応")):
        fail(f"unsupported Mac claim remains in {page.relative_to(ROOT)}")
    if any(term.lower() in source.lower() for term in ("レア粒", "レア抽選", "rare pebble", "rare reward")):
        fail(f"disabled random-reward claim remains in {page.relative_to(ROOT)}")
    parser = PageParser()
    parser.feed(source)
    parsed_pages[page.resolve()] = parser
    expected_lang = "en" if page.is_relative_to(ROOT / "en") else "ja"
    if parser.html_lang != expected_lang:
        fail(f"html lang must be {expected_lang}: {page.relative_to(ROOT)}")
    if not "".join(parser.title_parts).strip():
        fail(f"title is empty: {page.relative_to(ROOT)}")
    visible_text = " ".join(" ".join(parser.text_parts).split())
    if "© 2026 hinoshiba" not in visible_text:
        fail(f"hinoshiba copyright is missing: {page.relative_to(ROOT)}")
    if not parser.meta.get("description", "").strip():
        fail(f"meta description is empty: {page.relative_to(ROOT)}")
    for error in parser.errors:
        fail(f"{page.relative_to(ROOT)}: {error}")
    if page in expected_canonical and parser.canonical != [expected_canonical[page]]:
        fail(f"canonical mismatch in {page.relative_to(ROOT)}: {parser.canonical}")
    if page in expected_canonical:
        japanese_page = ROOT / page.relative_to(ROOT / "en") if expected_lang == "en" else page
        english_page = ROOT / "en" / japanese_page.relative_to(ROOT)
        expected_alternates = [
            ("ja", expected_canonical[japanese_page]),
            ("en", expected_canonical[english_page]),
            ("x-default", expected_canonical[japanese_page]),
        ]
        if sorted(parser.alternates) != sorted(expected_alternates):
            fail(f"language alternates mismatch in {page.relative_to(ROOT)}: {parser.alternates}")
        other_lang = "ja" if expected_lang == "en" else "en"
        other_page = japanese_page if expected_lang == "en" else english_page
        switches = [link for link in parser.links if "language-switch" in link.get("class", "").split()]
        if not switches:
            fail(f"visible language switch is missing: {page.relative_to(ROOT)}")
        for link in switches:
            expected_label = "日本語" if other_lang == "ja" else "English"
            if (link["tag"] != "a" or link.get("lang") != other_lang
                    or link.get("hreflang") != other_lang
                    or link["text"].strip() != expected_label
                    or resolve_local(page, link["href"]) != other_page.resolve()):
                fail(f"language switch must link to its {other_lang} counterpart: {page.relative_to(ROOT)}")
    for _, value in parser.refs:
        target = resolve_local(page, value)
        if target is not None and not target.exists():
            fail(f"broken internal reference in {page.relative_to(ROOT)}: {value}")

for page, parser in parsed_pages.items():
    for attribute, value in parser.refs:
        split = urlsplit(value)
        if attribute != "href" or not split.fragment:
            continue
        target = resolve_local(page, value)
        if target is None:
            continue
        target_parser = parsed_pages.get(target)
        fragment = unquote(split.fragment)
        if target_parser is None:
            fail(f"fragment points to a non-HTML target in {page.relative_to(ROOT)}: {value}")
        if fragment not in target_parser.anchors:
            fail(f"missing fragment target in {page.relative_to(ROOT)}: {value}")

commercial_pages_resolved = {page.resolve() for page in COMMERCIAL_PAGES}
index_commercial_link_count = {page.resolve(): 0 for page in INDEX_PAGES}
for page, parser in parsed_pages.items():
    for link in parser.links:
        value = link["href"]
        target = resolve_local(page, value)
        if target in commercial_pages_resolved:
            if (page in index_commercial_link_count and value == "commercial-transactions/"
                    and link["tag"] == "a" and "plans" in link["section"].split("/")):
                index_commercial_link_count[page] += 1
            elif page in commercial_pages_resolved and (
                (link["tag"] == "link" and link.get("rel") in {"canonical", "alternate"})
                or (link["tag"] == "a" and "language-switch" in link.get("class", "").split())
                or (link["tag"] == "a" and target == page and value.startswith("#"))
            ):
                continue
            else:
                fail(
                    "commercial disclosure must only be linked from the Pro offer: "
                    f"{page.relative_to(ROOT)}"
                )
for page, count in index_commercial_link_count.items():
    if count != 1:
        fail(f"homepage must link once from the Pro offer to the commercial disclosure: {page.relative_to(ROOT)}")

index = INDEX_PAGE.read_text(encoding="utf-8")
if "基本無料" not in index or "iPhone" not in index:
    fail("index must state iPhone and 基本無料")
# The source repository is still private and its rename is pending. Add public
# source links only after that destination is anonymously accessible.
for required_positioning_term in (
    "ポモドーロタイマー",
    "見える集中記録",
    "集中した時間が、宝石になる。",
    'href="#demo"',
    "集中から宝石まで、8秒で体験",
    'id="demo-time"',
    'id="lab-start"',
    "25分の集中を約8秒で早送りするデモ",
    "実際の25分は計測せず、音・触覚・記録保存は再現しません",
    "public/app-timer-v2.webp",
    "public/app-home-v3.webp",
):
    if required_positioning_term not in index:
        fail(f"index positioning journey is missing: {required_positioning_term}")
if 'id="hero-drop"' in index:
    fail("hero must not trigger an off-screen automatic demo")

required_meta = {
    "description",
    "og:type",
    "og:site_name",
    "og:locale",
    "og:url",
    "og:title",
    "og:description",
    "og:image",
    "og:image:width",
    "og:image:height",
    "og:image:alt",
    "twitter:card",
    "twitter:title",
    "twitter:description",
    "twitter:image",
    "twitter:image:alt",
}
expected_meta = {
    "og:type": "website",
    "og:site_name": "ポモジェム",
    "og:locale": "ja_JP",
    "og:url": PUBLIC_BASE,
    "og:image": PUBLIC_BASE + "og-pomogem-v1.png",
    "og:image:width": "1200",
    "og:image:height": "630",
    "twitter:card": "summary_large_image",
    "twitter:image": PUBLIC_BASE + "og-pomogem-v1.png",
}
for homepage in sorted(INDEX_PAGES):
    homepage_parser = parsed_pages[homepage.resolve()]
    homepage_meta = homepage_parser.meta
    missing_meta = sorted(key for key in required_meta if not homepage_meta.get(key, "").strip())
    if missing_meta:
        fail(f"homepage metadata is missing in {homepage.relative_to(ROOT)}: {', '.join(missing_meta)}")
    localized_expected_meta = dict(expected_meta)
    if homepage == ENGLISH_INDEX_PAGE:
        localized_expected_meta.update({"og:site_name": "PomoGem", "og:locale": "en_US", "og:url": PUBLIC_BASE + "en/"})
        translated_metadata = ["".join(homepage_parser.title_parts)] + [
            homepage_meta[key] for key in (
                "description", "og:title", "og:description", "og:image:alt",
                "twitter:title", "twitter:description", "twitter:image:alt",
            )
        ]
        if any(re.search(r"[\u3040-\u30ff\u3400-\u9fff]", value) for value in translated_metadata):
            fail("English homepage title, description, and sharing metadata must be translated")
    for key, expected in localized_expected_meta.items():
        if homepage_meta.get(key) != expected:
            fail(f"homepage {key} mismatch in {homepage.relative_to(ROOT)}: {homepage_meta.get(key)!r}")

# Registration precedes public availability. Show a matching Store banner only
# after the listing is publicly available to download.
store_configuration = (ROOT.parent / "AppStore/configuration.yml").read_text(encoding="utf-8")
repository_visibility = re.findall(r"^  repository_visibility: ([a-z]+)$", store_configuration, re.MULTILINE)
if len(repository_visibility) != 1 or repository_visibility[0] not in {"private", "public"}:
    fail("configuration must declare the actual source repository visibility")
public_source_url = "https://github.com/hinoshiba/PomoGem"
source_links = [value for parser in parsed_pages.values() for attribute, value in parser.refs
                if attribute == "href" and (value == public_source_url or value.startswith(public_source_url + "/"))]
if repository_visibility[0] == "private" and source_links:
    fail("private source repository links must not appear on the public website")
if repository_visibility[0] == "public":
    for homepage in INDEX_PAGES:
        if public_source_url not in homepage.read_text(encoding="utf-8"):
            fail(f"homepage must link to the anonymously accessible public source repository: {homepage.relative_to(ROOT)}")
store_id_entries = re.findall(r"^app_store_id:\s*([^\n]+)$", store_configuration, re.MULTILINE)
if len(store_id_entries) != 1:
    fail("configuration must contain exactly one app_store_id")
store_id = store_id_entries[0].strip()
if store_id != "null" and not re.fullmatch(r"[1-9][0-9]*", store_id):
    fail("app_store_id must be null or a positive unquoted numeric ID")
listing_status_entries = re.findall(r"^app_store_listing_status: ([a-z_]+)$", store_configuration, re.MULTILINE)
if len(listing_status_entries) != 1 or listing_status_entries[0] not in {"not_public", "public"}:
    fail("configuration must declare exactly one valid app_store_listing_status")
for homepage in INDEX_PAGES:
    homepage_meta = parsed_pages[homepage.resolve()].meta
    if listing_status_entries[0] == "not_public":
        if "apple-itunes-app" in homepage_meta:
            fail("Smart App Banner must be absent while the listing is not public")
    else:
        if store_id == "null":
            fail("a public App Store listing requires its registered numeric ID")
        if homepage_meta.get("apple-itunes-app") != f"app-id={store_id}":
            fail("Smart App Banner must match the configured public app_store_id")

not_found_refs = {value for _, value in parsed_pages[(ROOT / "404.html").resolve()].refs}
required_not_found_refs = {
    "/",
    "/styles.css?v=15",
    "/public/app-icon-focus-v5.png",
    "/public/apple-touch-icon.png",
    "/privacy/",
    "/support/",
    "/terms/",
}
if not required_not_found_refs.issubset(not_found_refs):
    fail("404.html must use custom-domain absolute paths so nested missing URLs still render")
not_found_meta = parsed_pages[(ROOT / "404.html").resolve()].meta
if not_found_meta.get("robots") != "noindex":
    fail("404.html must be noindex")

privacy = (ROOT / "privacy/index.html").read_text(encoding="utf-8")
for required_privacy_term in (
    "GitHub Pages",
    "GitHubのプライバシーステートメント",
    "IPアドレス",
    "account-neutralな案内",
    "運営者・開発者はhinoshiba",
):
    if required_privacy_term not in privacy:
        fail(f"privacy policy is missing: {required_privacy_term}")

terms = (ROOT / "terms/index.html").read_text(encoding="utf-8")
for required_terms_term in (
    "Apple標準EULA",
    "1回限りの買い切り型アプリ内課金",
    "サブスクリプション、無料トライアル、自動更新はありません",
    "勤怠、給与、請求",
):
    if required_terms_term not in terms:
        fail(f"terms page is missing: {required_terms_term}")

english_policy_requirements = {
    "privacy/index.html": (
        "GitHub Pages", "GitHub’s Privacy Statement", "IP addresses",
        "account-neutral", "operator and developer is hinoshiba",
    ),
    "terms/index.html": (
        "Apple’s Standard EULA", "one-time in-app purchase",
        "no subscription, free trial, or automatic renewal", "attendance, payroll, billing",
    ),
    "commercial-transactions/index.html": (
        "Seller’s name, address, and telephone number",
        "Proof of a prior purchase is not required", "Apple handles App Store purchase procedures",
        "StoreKit", "immediately before the purchase", "does not list a fixed price",
        "by email without delay", "one-time, non-consumable in-app purchase",
    ),
}
for route, required_terms in english_policy_requirements.items():
    source = (ROOT / "en" / route).read_text(encoding="utf-8")
    for required_term in required_terms:
        if required_term not in source:
            fail(f"English {route} is missing: {required_term}")

commercial = COMMERCIAL_PAGE.read_text(encoding="utf-8")
for commercial_page in COMMERCIAL_PAGES:
    commercial_hash = hashlib.sha256(commercial_page.read_bytes()).hexdigest()
    if commercial_hash != APPROVED_COMMERCIAL_DISCLOSURE_SHA256[commercial_page]:
        fail(f"commercial disclosure changed without updating its approved privacy-review hash: {commercial_page.relative_to(ROOT)}")
    commercial_meta = parsed_pages[commercial_page.resolve()].meta
    if commercial_meta.get("robots") != "noindex,follow":
        fail(f"commercial disclosure must be noindex,follow: {commercial_page.relative_to(ROOT)}")
for required_commercial_term in (
    "特定商取引法に基づく表記",
    "販売事業者の氏名（名称）・所在地・電話番号",
    "購入済みであることの証明は必要ありません",
    "App Storeでの購入手続、決済、購入履歴、請求書・領収書および返金申請はAppleが取り扱います",
    "購入手続の直前",
    "StoreKit",
    "本サイトには固定価格を掲載しません",
    "遅滞なく電子メールで開示",
    "1回限りの非消費型アプリ内課金",
):
    if required_commercial_term not in commercial:
        fail(f"commercial disclosure is missing: {required_commercial_term}")

robots = (ROOT / "robots.txt").read_text(encoding="utf-8")
if "Allow: /" not in robots:
    fail("robots.txt must allow the custom-domain root")
if f"Sitemap: {PUBLIC_BASE}sitemap.xml" not in robots:
    fail("robots.txt has a non-canonical sitemap URL")

if (ROOT / "CNAME").read_text(encoding="utf-8").strip() != "pomogem.hinoshiba.com":
    fail("CNAME must match the canonical product host")

try:
    sitemap = ET.parse(ROOT / "sitemap.xml")
except ET.ParseError as error:
    fail(f"sitemap.xml is invalid XML: {error}")
namespace = {"sm": "http://www.sitemaps.org/schemas/sitemap/0.9"}
sitemap_locations = {element.text for element in sitemap.findall("sm:url/sm:loc", namespace)}
if sitemap_locations != expected_sitemap_locations:
    fail(f"sitemap locations mismatch: {sorted(sitemap_locations)}")

og = ROOT / "og-pomogem-v1.png"
if png_dimensions(og) != (1200, 630):
    fail("og-pomogem-v1.png must be exactly 1200x630")
if png_dimensions(ROOT / "public/app-icon-focus-v5.png") != (256, 256):
    fail("web app icon must be exactly 256x256")
if png_dimensions(ROOT / "public/apple-touch-icon.png") != (180, 180):
    fail("apple-touch-icon must be exactly 180x180")

css = (ROOT / "styles.css").read_text(encoding="utf-8")
for match in re.finditer(r"url\((['\"]?)([^)'\"]+)\1\)", css):
    value = match.group(2)
    target = resolve_local(ROOT / "styles.css", value)
    if target is not None and not target.exists():
        fail(f"broken CSS reference: {value}")

site_script = (ROOT / "app.js").read_text(encoding="utf-8")
if any(marker in site_script for marker in COMMERCIAL_MARKERS):
    fail("site script must not create a hidden commercial-disclosure route")
if any(re.search(pattern, site_script, flags=re.IGNORECASE) for pattern in EXACT_PRICE_PATTERNS):
    fail("site script must not inject a fixed monetary amount")
if any(term.lower() in site_script.lower() for term in ("rare", "prism", "goldcount")):
    fail("version 1.0 product-site script must not simulate disabled random rewards")

font_hashes = {
    hashlib.sha256((ROOT / "public/ZenMaruGothic-Black.ttf").read_bytes()).hexdigest(),
    hashlib.sha256((ROOT.parent / "PomoGem/Resources/Fonts/ZenMaruGothic-Black.ttf").read_bytes()).hexdigest(),
}
if len(font_hashes) != 1:
    fail("app and website font copies differ")

print("Site validation passed.")

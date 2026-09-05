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
PUBLIC_BASE = "https://tumiben.hinoshiba.com/"


class PageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.refs: list[tuple[str, str]] = []
        self.canonical: list[str] = []
        self.meta: dict[str, str] = {}
        self.anchors: set[str] = set()
        self.title_parts: list[str] = []
        self.text_parts: list[str] = []
        self.in_title = False
        self.html_lang: str | None = None
        self.errors: list[str] = []

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
        if tag in {"a", "link"} and values.get("href"):
            self.refs.append(("href", values["href"]))
        if tag in {"img", "script", "source"} and values.get("src"):
            self.refs.append(("src", values["src"]))
        if tag == "img" and "alt" not in values:
            self.errors.append(f"img is missing alt: {values.get('src', '<inline>')}")
        if tag == "link" and values.get("rel") == "canonical":
            self.canonical.append(values.get("href", ""))
        if tag == "meta":
            key = values.get("name") or values.get("property")
            if key:
                self.meta[key] = values.get("content", "")

    def handle_endtag(self, tag: str) -> None:
        if tag == "title":
            self.in_title = False

    def handle_data(self, data: str) -> None:
        self.text_parts.append(data)
        if self.in_title:
            self.title_parts.append(data)


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
    ROOT / "index.html",
    ROOT / "404.html",
    ROOT / "privacy/index.html",
    ROOT / "support/index.html",
    ROOT / "terms/index.html",
    ROOT / "commercial-transactions/index.html",
    ROOT / "robots.txt",
    ROOT / "sitemap.xml",
    ROOT / "styles.css",
    ROOT / "app.js",
    ROOT / "og-focus-v7.png",
    ROOT / "public/app-icon-focus-v5.png",
    ROOT / "public/apple-touch-icon.png",
    ROOT / "public/app-home-v2.webp",
    ROOT / "public/app-timer-v1.webp",
    ROOT / "public/ZenMaruGothic-Black.ttf",
    ROOT / "font-license.txt",
]
for path in required:
    if not path.exists():
        fail(f"required site file is missing: {path.relative_to(ROOT.parent)}")

expected_canonical = {
    ROOT / "index.html": PUBLIC_BASE,
    ROOT / "privacy/index.html": PUBLIC_BASE + "privacy/",
    ROOT / "support/index.html": PUBLIC_BASE + "support/",
    ROOT / "terms/index.html": PUBLIC_BASE + "terms/",
    ROOT / "commercial-transactions/index.html": PUBLIC_BASE + "commercial-transactions/",
}

parsed_pages: dict[Path, PageParser] = {}
for page in sorted(ROOT.rglob("*.html")):
    source = page.read_text(encoding="utf-8")
    if "file://" in source or "127.0.0.1" in source or "localhost" in source:
        fail(f"local-only URL remains in {page.relative_to(ROOT)}")
    if "100円" in source and page != ROOT / "commercial-transactions/index.html":
        fail(f"exact IAP price must not be marketed on the website: {page.relative_to(ROOT)}")
    if any(term in source for term in ("Mac版", "Mac Catalyst", "macOS対応")):
        fail(f"unsupported Mac claim remains in {page.relative_to(ROOT)}")
    if any(term.lower() in source.lower() for term in ("レア粒", "レア抽選", "rare pebble", "rare reward")):
        fail(f"disabled random-reward claim remains in {page.relative_to(ROOT)}")
    parser = PageParser()
    parser.feed(source)
    parsed_pages[page.resolve()] = parser
    if parser.html_lang != "ja":
        fail(f"html lang must be ja: {page.relative_to(ROOT)}")
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

index = (ROOT / "index.html").read_text(encoding="utf-8")
if "基本無料" not in index or "iPhone" not in index:
    fail("index must state iPhone and 基本無料")
if "https://github.com/hinoshiba/Tumiben" not in index:
    fail("index must link to the public source repository")
for required_positioning_term in (
    "ポモドーロタイマー",
    "見える集中記録",
    "終えた時間を、宝石で記録。",
    'href="#demo"',
    "25分の記録を追加（デモ）",
    "実際のタイマー、音・触覚、記録保存は再現しません",
    "public/app-timer-v1.webp",
    "public/app-home-v2.webp",
):
    if required_positioning_term not in index:
        fail(f"index positioning journey is missing: {required_positioning_term}")
if 'id="hero-drop"' in index:
    fail("hero must not trigger an off-screen automatic demo")

index_meta = parsed_pages[(ROOT / "index.html").resolve()].meta
required_meta = {
    "description",
    "apple-itunes-app",
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
missing_meta = sorted(key for key in required_meta if not index_meta.get(key, "").strip())
if missing_meta:
    fail(f"index metadata is missing: {', '.join(missing_meta)}")
expected_meta = {
    "apple-itunes-app": "app-id=6806758060",
    "og:type": "website",
    "og:site_name": "つみべん",
    "og:locale": "ja_JP",
    "og:url": PUBLIC_BASE,
    "og:image": PUBLIC_BASE + "og-focus-v7.png",
    "og:image:width": "1200",
    "og:image:height": "630",
    "twitter:card": "summary_large_image",
    "twitter:image": PUBLIC_BASE + "og-focus-v7.png",
}
for key, expected in expected_meta.items():
    if index_meta.get(key) != expected:
        fail(f"index {key} mismatch: {index_meta.get(key)!r}")

not_found_refs = {value for _, value in parsed_pages[(ROOT / "404.html").resolve()].refs}
required_not_found_refs = {
    "/",
    "/styles.css?v=10",
    "/public/app-icon-focus-v5.png",
    "/public/apple-touch-icon.png",
    "/privacy/",
    "/support/",
    "/terms/",
    "/commercial-transactions/",
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

commercial = (ROOT / "commercial-transactions/index.html").read_text(encoding="utf-8")
for required_commercial_term in (
    "特定商取引法に基づく表記",
    "100円",
    "0.99米ドル",
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

if (ROOT / "CNAME").read_text(encoding="utf-8").strip() != "tumiben.hinoshiba.com":
    fail("CNAME must match the canonical product host")

try:
    sitemap = ET.parse(ROOT / "sitemap.xml")
except ET.ParseError as error:
    fail(f"sitemap.xml is invalid XML: {error}")
namespace = {"sm": "http://www.sitemaps.org/schemas/sitemap/0.9"}
sitemap_locations = {element.text for element in sitemap.findall("sm:url/sm:loc", namespace)}
expected_locations = set(expected_canonical.values())
if sitemap_locations != expected_locations:
    fail(f"sitemap locations mismatch: {sorted(sitemap_locations)}")

og = ROOT / "og-focus-v7.png"
if png_dimensions(og) != (1200, 630):
    fail("og-focus-v7.png must be exactly 1200x630")
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
if any(term.lower() in site_script.lower() for term in ("rare", "prism", "goldcount")):
    fail("version 1.0 product-site script must not simulate disabled random rewards")

font_hashes = {
    hashlib.sha256((ROOT / "public/ZenMaruGothic-Black.ttf").read_bytes()).hexdigest(),
    hashlib.sha256((ROOT.parent / "Tsumiben/Resources/Fonts/ZenMaruGothic-Black.ttf").read_bytes()).hexdigest(),
}
if len(font_hashes) != 1:
    fail("app and website font copies differ")

print("Site validation passed.")

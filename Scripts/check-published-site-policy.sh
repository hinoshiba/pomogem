#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
base_url=${1:-https://pomogem.hinoshiba.com/}
case "$base_url" in
  https://*) ;;
  *)
    echo "error: published-site policy check requires an HTTPS base URL" >&2
    exit 2
    ;;
esac
base_url=${base_url%/}/

policy_dir=$(mktemp -d "${TMPDIR:-/tmp}/pomogem-site-policy.XXXXXX")
trap 'rm -rf "$policy_dir"' EXIT HUP INT TERM

fetch_page() {
  url=$1
  output=$2
  curl --silent --show-error --fail --max-time 20 --output "$output" "$url"
}

for locale in ja en; do
  locale_base=$base_url
  if [ "$locale" = en ]; then
    locale_base=${base_url}en/
  fi
  fetch_page "$locale_base" "$policy_dir/$locale-home.html"
  fetch_page "${locale_base}privacy/" "$policy_dir/$locale-privacy.html"
  fetch_page "${locale_base}support/" "$policy_dir/$locale-support.html"
  fetch_page "${locale_base}terms/" "$policy_dir/$locale-terms.html"
  fetch_page "${locale_base}commercial-transactions/" "$policy_dir/$locale-commercial.html"
done
fetch_page "${base_url}sitemap.xml" "$policy_dir/sitemap.xml"

for locale in ja en; do
  commercial_link_count=$(grep -oF 'commercial-transactions/' "$policy_dir/$locale-home.html" | wc -l | tr -d ' ')
  if [ "$commercial_link_count" -ne 1 ]; then
    echo "error: published $locale home must have exactly one scoped Pro purchase-disclosure link" >&2
    exit 1
  fi

  for public_page in \
    "$policy_dir/$locale-privacy.html" \
    "$policy_dir/$locale-support.html" \
    "$policy_dir/$locale-terms.html" \
    "$policy_dir/sitemap.xml"; do
    if grep -Eq 'commercial-transactions|販売条件|販売者情報' "$public_page"; then
      echo "error: published general navigation or sitemap exposes the seller-disclosure route: $public_page" >&2
      exit 1
    fi
  done

  if ! grep -Fq '<meta name="robots" content="noindex,follow">' "$policy_dir/$locale-commercial.html"; then
    echo "error: published $locale seller disclosure must be noindex,follow" >&2
    exit 1
  fi

  approved_root=$repo_root/http_dists
  if [ "$locale" = en ]; then
    approved_root=$approved_root/en
  fi
  if ! cmp -s "$policy_dir/$locale-commercial.html" "$approved_root/commercial-transactions/index.html"; then
    echo "error: published $locale seller disclosure differs from the locally approved privacy-reviewed copy" >&2
    exit 1
  fi
  if ! grep -Fq 'support@hinoshiba.com' "$policy_dir/$locale-commercial.html"; then
    echo "error: published $locale seller disclosure is missing the request-based disclosure contact" >&2
    exit 1
  fi
done

if ! grep -Fq '購入条件・販売者情報' "$policy_dir/ja-home.html"; then
  echo "error: published Japanese home must use the scoped Pro purchase-disclosure label" >&2
  exit 1
fi
if ! grep -Fq '遅滞なく電子メールで開示' "$policy_dir/ja-commercial.html"; then
  echo "error: published seller disclosure is missing the request-based disclosure terms" >&2
  exit 1
fi

if grep -Eq "href[[:space:]]*=[[:space:]]*['\"]tel:|〒[[:space:]]*[0-9]{3}-[0-9]{4}|[0-9]{2,4}-[0-9]{2,4}-[0-9]{3,4}" \
  "$policy_dir"/*.html; then
  echo "error: published website exposes a phone number or postal address marker" >&2
  exit 1
fi

if grep -Eiq '[¥￥$][[:space:]]*[0-9]|(USD|JPY)[[:space:]]*[0-9]|[0-9][0-9,.]*[[:space:]]*(円|米ドル|ドル|USD|JPY|dollars?|yen|cents?)([^[:alpha:]]|$)' \
  "$policy_dir"/*.html; then
  echo "error: published website contains a fixed monetary amount" >&2
  exit 1
fi

python3 - "$policy_dir" "$base_url" <<'PY'
from html.parser import HTMLParser
from pathlib import Path
import sys
from urllib.parse import urljoin
import xml.etree.ElementTree as ET


class Page(HTMLParser):
    def __init__(self, source):
        super().__init__()
        self.tags = []
        self.feed(source)

    def handle_starttag(self, tag, attrs):
        self.tags.append((tag, dict(attrs)))


directory = Path(sys.argv[1])
base = sys.argv[2]
indexable = set()
for locale in ("ja", "en"):
    for name, route in (("home", ""), ("privacy", "privacy/"), ("support", "support/"),
                        ("terms", "terms/"), ("commercial", "commercial-transactions/")):
        page = Page((directory / f"{locale}-{name}.html").read_text(encoding="utf-8"))
        urls = {"ja": base + route, "en": base + "en/" + route, "x-default": base + route}
        current_url = urls[locale]
        if name != "commercial":
            indexable.add(current_url)
        if [attrs.get("lang") for tag, attrs in page.tags if tag == "html"] != [locale]:
            sys.exit(f"error: published {locale} {name} has the wrong document language")
        canonical = [attrs.get("href") for tag, attrs in page.tags
                     if tag == "link" and attrs.get("rel") == "canonical"]
        if canonical != [current_url]:
            sys.exit(f"error: published {locale} {name} has the wrong canonical URL")
        alternates = [(attrs.get("hreflang"), attrs.get("href")) for tag, attrs in page.tags
                      if tag == "link" and attrs.get("rel") == "alternate" and attrs.get("hreflang")]
        if sorted(alternates) != sorted(urls.items()):
            sys.exit(f"error: published {locale} {name} has incorrect language alternates")
        other_locale = "en" if locale == "ja" else "ja"
        switches = [attrs for tag, attrs in page.tags
                    if tag == "a" and "language-switch" in attrs.get("class", "").split()]
        if not switches or any(
            attrs.get("lang") != other_locale or attrs.get("hreflang") != other_locale
            or urljoin(current_url, attrs.get("href", "")) != urls[other_locale]
            for attrs in switches
        ):
            sys.exit(f"error: published {locale} {name} is missing a working language switch")

namespace = {"sm": "http://www.sitemaps.org/schemas/sitemap/0.9"}
sitemap = ET.parse(directory / "sitemap.xml")
locations = {element.text for element in sitemap.findall("sm:url/sm:loc", namespace)}
if locations != indexable:
    sys.exit("error: published sitemap must list the four indexable pages in both languages")
PY

echo "Published site policy checks passed."

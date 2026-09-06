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

fetch_page "$base_url" "$policy_dir/home.html"
fetch_page "${base_url}privacy/" "$policy_dir/privacy.html"
fetch_page "${base_url}support/" "$policy_dir/support.html"
fetch_page "${base_url}terms/" "$policy_dir/terms.html"
fetch_page "${base_url}commercial-transactions/" "$policy_dir/commercial.html"
fetch_page "${base_url}sitemap.xml" "$policy_dir/sitemap.xml"

commercial_link_count=$(grep -oF 'commercial-transactions/' "$policy_dir/home.html" | wc -l | tr -d ' ')
if [ "$commercial_link_count" -ne 1 ] || ! grep -Fq '購入条件・販売者情報' "$policy_dir/home.html"; then
  echo "error: published home must have exactly one scoped Pro purchase-disclosure link" >&2
  exit 1
fi

for public_page in \
  "$policy_dir/privacy.html" \
  "$policy_dir/support.html" \
  "$policy_dir/terms.html" \
  "$policy_dir/sitemap.xml"; do
  if grep -Eq 'commercial-transactions|販売条件|販売者情報' "$public_page"; then
    echo "error: published general navigation or sitemap exposes the seller-disclosure route: $public_page" >&2
    exit 1
  fi
done

if ! grep -Fq '<meta name="robots" content="noindex,follow">' "$policy_dir/commercial.html"; then
  echo "error: published seller disclosure must be noindex,follow" >&2
  exit 1
fi

if ! cmp -s "$policy_dir/commercial.html" "$repo_root/http_dists/commercial-transactions/index.html"; then
  echo "error: published seller disclosure differs from the locally approved privacy-reviewed copy" >&2
  exit 1
fi

if ! grep -Fq 'support@hinoshiba.com' "$policy_dir/commercial.html" \
  || ! grep -Fq '遅滞なく電子メールで開示' "$policy_dir/commercial.html"; then
  echo "error: published seller disclosure is missing the request-based disclosure contact" >&2
  exit 1
fi

if grep -Eq "href[[:space:]]*=[[:space:]]*['\"]tel:|〒[[:space:]]*[0-9]{3}-[0-9]{4}|[0-9]{2,4}-[0-9]{2,4}-[0-9]{3,4}" \
  "$policy_dir/home.html" \
  "$policy_dir/privacy.html" \
  "$policy_dir/support.html" \
  "$policy_dir/terms.html" \
  "$policy_dir/commercial.html"; then
  echo "error: published website exposes a phone number or postal address marker" >&2
  exit 1
fi

if grep -Eq '[¥￥$][[:space:]]*[0-9]|(USD|JPY)[[:space:]]*[0-9]|[0-9][0-9,.]*[[:space:]]*(円|米ドル|ドル)' \
  "$policy_dir/home.html" \
  "$policy_dir/privacy.html" \
  "$policy_dir/support.html" \
  "$policy_dir/terms.html" \
  "$policy_dir/commercial.html"; then
  echo "error: published website contains a fixed monetary amount" >&2
  exit 1
fi

echo "Published site policy checks passed."

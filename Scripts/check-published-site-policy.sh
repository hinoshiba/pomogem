#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
base_url=${1:-https://pomogem.hinoshiba.com/}
case "$base_url" in https://*) ;; *) echo 'error: HTTPS URL required' >&2; exit 2 ;; esac
page=$(mktemp "${TMPDIR:-/tmp}/pomogem-published-page.XXXXXX")
trap 'rm -f "$page"' EXIT HUP INT TERM
curl --fail --silent --show-error --max-time 20 "${base_url%/}/" --output "$page"
# All policy text and both translations are delivered in the canonical HTML.
if ! cmp -s "$page" "$script_dir/../http_dists/index.html"; then
  echo 'error: published page differs from the locally validated bilingual page' >&2
  exit 1
fi
python3 "$script_dir/validate-site.py"
echo 'Published site policy checks passed.'

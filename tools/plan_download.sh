#!/usr/bin/env bash
# Plan / sanity-check a download list without downloading anything.
# Usage:
#   ./tools/plan_download.sh urls.txt /path/to/output
# Optional:
#   STRIP_REGEX='...' ./tools/plan_download.sh urls.txt /path/to/output

set -euo pipefail

URLS_FILE="${1:-urls.txt}"
OUTDIR="${2:-$PWD}"

: "${STRIP_REGEX:=^https?://[^/]+/.*?/o/out/[^/]+/}"

if [[ ! -f "$URLS_FILE" ]]; then
  echo "ERROR: URL file not found: $URLS_FILE" >&2
  exit 1
fi

total=0
known=0
unknown=0
badparse=0

echo "OUTDIR: $OUTDIR"
echo "STRIP_REGEX: $STRIP_REGEX"
echo

while read -r url; do
  [[ -z "${url// }" ]] && continue

  rel="$(echo "$url" | sed -E "s|${STRIP_REGEX}||")"
  outpath="${OUTDIR}/${rel}"

  # sanity-check parsing: if strip failed, rel will still look like a URL
  if [[ "$rel" == http* || "$rel" == "$url" ]]; then
    echo "PARSE_FAIL  $url"
    ((badparse++)) || true
    continue
  fi

  # remote size (bytes) via HEAD
  remote="$(curl -fsSI "$url" | awk -F': ' 'tolower($1)=="content-length"{print $2}' | tr -d '\r' | tail -n1 || true)"

  if [[ -n "$remote" && "$remote" =~ ^[0-9]+$ ]]; then
    total=$(( total + remote ))
    known=$(( known + 1 ))
    printf "OK  %8s  %s\n" "$(numfmt --to=iec "$remote")" "$outpath"
  else
    unknown=$(( unknown + 1 ))
    printf "OK  %8s  %s\n" "UNKNOWN" "$outpath"
  fi
done < "$URLS_FILE"

echo
echo "Summary:"
echo "  parsed ok:     $((known + unknown))"
echo "  parse failed:  $badparse"
echo "  sized:         $known"
echo "  size unknown:  $unknown"
echo "  total sized:   $(numfmt --to=iec "$total") ($total bytes)"
echo
echo "Disk check (free space on OUTDIR filesystem):"
df -h "$OUTDIR" | sed -n '1,2p'

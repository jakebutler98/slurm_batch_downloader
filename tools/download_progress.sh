#!/usr/bin/env bash
# Show download progress for .tar.part files listed in a URL file
#
# Usage:
#   ./tools/download_progress.sh urls.txt /path/to/output
#
# Optional:
#   STRIP_REGEX='^https?://[^/]+/.*?/o/out/[^/]+/' ./tools/download_progress.sh urls.txt /path/to/output

set -euo pipefail

URLS_FILE="${1:-urls.txt}"
OUTDIR="${2:-$PWD}"

: "${STRIP_REGEX:=^https?://[^/]+/.*?/o/out/[^/]+/}"

if [[ ! -f "$URLS_FILE" ]]; then
  echo "ERROR: URL file not found: $URLS_FILE" >&2
  exit 1
fi

# make OUTDIR absolute-ish for nicer printing
OUTDIR="$(cd "$OUTDIR" && pwd)"

while read -r url; do
  [[ -z "${url// }" ]] && continue
  [[ "$url" != *.tar ]] && continue

  # Map URL -> relative path (same logic as download script)
  rel="$(echo "$url" | sed -E "s|${STRIP_REGEX}||")"
  part="${OUTDIR}/${rel}.part"

  [[ ! -f "$part" ]] && continue

  # Get remote size (bytes)
  remote="$(curl -fsSI "$url" \
    | awk -F': ' 'tolower($1)=="content-length"{print $2}' \
    | tr -d '\r' | tail -n1 || true)"

  if [[ -z "$remote" || ! "$remote" =~ ^[0-9]+$ ]]; then
    printf "%-50s  remote size unavailable  (%s)\n" "$(basename "$rel")" "$part"
    continue
  fi

  local_size="$(stat -c %s "$part")"
  remaining=$(( remote - local_size ))
  percent="$(awk "BEGIN { printf \"%.1f\", ($local_size/$remote)*100 }")"

  printf "%-50s  %6s / %6s  (%5s%%)  remaining: %6s\n" \
    "$(basename "$rel")" \
    "$(numfmt --to=iec "$local_size")" \
    "$(numfmt --to=iec "$remote")" \
    "$percent" \
    "$(numfmt --to=iec "$remaining")"

  # Be gentle to the object store
  sleep 0.2

done < "$URLS_FILE"
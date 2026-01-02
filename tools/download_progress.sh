#!/usr/bin/env bash
# Show download progress for .tar.part files listed in a URL file
# Usage:
#   ./download_progress.sh urls.txt

set -euo pipefail

URLS_FILE="${1:-urls.txt}"

if [[ ! -f "$URLS_FILE" ]]; then
  echo "ERROR: URL file not found: $URLS_FILE" >&2
  exit 1
fi

while read -r url; do
  [[ "$url" != *.tar ]] && continue

  # Map URL to local relative path (same logic as download script)
  rel=$(echo "$url" | sed -E 's|^https?://[^/]+/.*?/o/out/[^/]+/||')
  part="${rel}.part"

  [[ ! -f "$part" ]] && continue

  # Get remote size
  remote=$(curl -fsSI "$url" \
    | awk -F': ' 'tolower($1)=="content-length"{print $2}' \
    | tr -d '\r')

  if [[ -z "$remote" || ! "$remote" =~ ^[0-9]+$ ]]; then
    printf "%-50s  remote size unavailable\n" "$(basename "$rel")"
    continue
  fi

  local=$(stat -c %s "$part")
  remaining=$(( remote - local ))
  percent=$(awk "BEGIN { printf \"%.1f\", ($local/$remote)*100 }")

  printf "%-50s  %6s / %6s  (%5s%%)  remaining: %6s\n" \
    "$(basename "$rel")" \
    "$(numfmt --to=iec "$local")" \
    "$(numfmt --to=iec "$remote")" \
    "$percent" \
    "$(numfmt --to=iec "$remaining")"

  # Be gentle to the object store
  sleep 0.2

done < "$URLS_FILE"

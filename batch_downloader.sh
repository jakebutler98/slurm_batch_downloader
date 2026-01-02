#!/bin/bash --login
###############################################################################
# Slurm-safe parallel downloader with disk-space reservation and MD5 checking
#
# - One URL per Slurm array task
# - Prevents disk overfill using a shared reservation lock
# - Resumable downloads (.part files)
# - Optional MD5 verification for .tar files
# - Minimal logging (progress suppressed)
#
# Requirements:
#   - bash
#   - wget
#   - curl
#   - coreutils (df, awk, sed, md5sum)
#
# Usage:
#   sbatch --array=1-N download_array.sbatch urls.txt /path/to/output
#
###############################################################################

#SBATCH -J get_data
#SBATCH -t 12:00:00
#SBATCH -n 1
#SBATCH -c 1
#SBATCH -p serial
#SBATCH -o wget_%x-%A_%a.log
#SBATCH -e wget_%x-%A_%a.log

# -------------------------------
# User-configurable settings
# -------------------------------

# File containing one URL per line
URLS_FILE="${1:-urls.txt}"

# Output directory for downloaded data
OUTDIR="${2:-$PWD}"

# Regex describing which part of the URL to strip when creating directories
# Default works for Oracle Object Storage layouts like:
#   https://.../o/out/<bucket>/<project>/<sample>/<file>
STRIP_REGEX='^https?://[^/]+/.*?/o/out/[^/]+/'

# Safety margin to keep free on the filesystem (bytes)
SAFETY_MARGIN=$((5 * 1024 * 1024 * 1024))   # 5 GiB

# -------------------------------
# Internal bookkeeping locations
# -------------------------------

STATUS_DIR="${OUTDIR}/_download_status"
STATUS_TSV="${STATUS_DIR}/status.tsv"
LOCKFILE="${STATUS_DIR}/status.lock"
RESV_FILE="${STATUS_DIR}/reserved_bytes.txt"

mkdir -p "$STATUS_DIR"
touch "$STATUS_TSV" "$RESV_FILE"

# -------------------------------
# Select URL for this array task
# -------------------------------

url="$(sed -n "${SLURM_ARRAY_TASK_ID}p" "$URLS_FILE" || true)"

if [[ -z "$url" ]]; then
  echo "No URL for array index ${SLURM_ARRAY_TASK_ID}; exiting."
  exit 0
fi

# -------------------------------
# Map URL → output path
# -------------------------------

# Strip storage-specific prefix and keep meaningful directory structure
rel="$(echo "$url" | sed -E "s|${STRIP_REGEX}||")"

outpath="${OUTDIR}/${rel}"
outdir="$(dirname "$outpath")"
mkdir -p "$outdir"

# -------------------------------
# Status logging helper
# -------------------------------

append_status() {
  local state="$1"
  local extra="${2:-}"
  (
    flock -x 9
    printf "%s\t%s\t%s\t%s\t%s\n" \
      "$(date -Is)" \
      "$SLURM_ARRAY_TASK_ID" \
      "$state" \
      "$rel" \
      "$extra" >> "$STATUS_TSV"
  ) 9>"$LOCKFILE"
}

# -------------------------------
# Skip if file already exists
# -------------------------------

if [[ -s "$outpath" ]]; then
  append_status "SKIP_EXISTS" "already present"
  exit 0
fi

# -------------------------------
# Determine remote file size
# -------------------------------

remote_size_bytes="$(
  curl -fsSI "$url" \
  | awk -F': ' 'tolower($1)=="content-length"{print $2}' \
  | tr -d '\r' \
  | tail -n1 || true
)"

# Free space on filesystem containing OUTDIR
free_bytes="$(df -PB1 "$OUTDIR" | awk 'NR==2{print $4}')"

# -------------------------------
# Disk-space reservation logic
# -------------------------------

RESERVED_THIS_TASK=0

reserve_bytes_or_skip() {
  local bytes="$1"
  local reserved avail

  (
    flock -x 8
    reserved="$(cat "$RESV_FILE" 2>/dev/null || echo 0)"
    [[ "$reserved" =~ ^[0-9]+$ ]] || reserved=0

    avail=$(( free_bytes - reserved ))

    if (( avail < bytes + SAFETY_MARGIN )); then
      exit 2
    fi

    printf "%s\n" $(( reserved + bytes )) > "$RESV_FILE"
  ) 8>"$LOCKFILE"
}

release_reserved_bytes() {
  local bytes="$1"
  local reserved

  (
    flock -x 8
    reserved="$(cat "$RESV_FILE" 2>/dev/null || echo 0)"
    [[ "$reserved" =~ ^[0-9]+$ ]] || reserved=0
    reserved=$(( reserved - bytes ))
    (( reserved < 0 )) && reserved=0
    printf "%s\n" "$reserved" > "$RESV_FILE"
  ) 8>"$LOCKFILE"
}

# Apply reservation if size is known
if [[ -n "$remote_size_bytes" && "$remote_size_bytes" =~ ^[0-9]+$ ]]; then
  if ! reserve_bytes_or_skip "$remote_size_bytes"; then
    append_status "SKIP_NOSPACE" "need=${remote_size_bytes}B free=${free_bytes}B"
    exit 0
  fi

  RESERVED_THIS_TASK="$remote_size_bytes"
  trap 'release_reserved_bytes "$RESERVED_THIS_TASK"' EXIT
else
  # Unknown size → still enforce safety margin
  if (( free_bytes < SAFETY_MARGIN )); then
    append_status "SKIP_NOSPACE" "unknown_size free=${free_bytes}B"
    exit 0
  fi
fi

# -------------------------------
# Download (quiet, resumable)
# -------------------------------

tmp="${outpath}.part"

if wget -c --tries=5 --timeout=60 --progress=dot:giga -q -O "$tmp" "$url"; then
  mv -f "$tmp" "$outpath"
else
  append_status "FAIL_WGET" "wget_failed"
  exit 1
fi

# -------------------------------
# MD5 verification (for .tar files)
# -------------------------------

verify_ok="NA"

if [[ "$outpath" =~ \.tar$ ]]; then
  md5file="${outdir}/MD5.txt"

  if [[ -s "$md5file" ]]; then
    if ( cd "$outdir" && md5sum -c "MD5.txt" --quiet --ignore-missing ); then
      verify_ok="OK"
    else
      tmpcheck="${STATUS_DIR}/md5check_${SLURM_ARRAY_TASK_ID}.txt"
      (
        cd "$outdir"
        awk -F' = ' '
          /^MD5 \(/ && NF==2 {
            fn=$1; sub(/^MD5 \(/,"",fn); sub(/\)$/,"",fn);
            print $2 "  " fn
          }
        ' MD5.txt > "$tmpcheck"

        if [[ -s "$tmpcheck" ]] && md5sum -c "$tmpcheck" --quiet --ignore-missing; then
          verify_ok="OK"
        else
          verify_ok="BAD"
        fi
        rm -f "$tmpcheck"
      )
    fi
  else
    verify_ok="NO_MD5TXT"
  fi
fi

# -------------------------------
# Final status
# -------------------------------

append_status "DONE" "md5=${verify_ok}"
exit 0
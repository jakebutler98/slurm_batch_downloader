# Slurm Batch Downloader

A robust, Slurm-friendly downloader for large datasets that **prevents disk overfill**, supports **parallel downloads**, and provides **clear status tracking**.

This tool is designed for HPC environments where:
- files are very large (10–100+ GB),
- storage is limited,
- downloads must be resumable,
- and partial or corrupted data is unacceptable.

---

## Key features

- **One URL per Slurm array task**
- **Safe parallelism** with disk-space reservation to avoid race conditions
- **Resumable downloads** using `.part` files
- **Optional MD5 verification** for `.tar` archives
- **Minimal Slurm log output**
- **No non-standard dependencies**
- Designed to be **cluster-friendly and reproducible**

---

## Requirements

Only standard Unix tools are required (available on most HPC systems):

- bash
- wget
- curl
- awk, sed, df
- md5sum
- flock (usually part of util-linux)

No Python, Conda, or containers required.

---

## Input format

Despite the name, the input file is **not a real CSV**.

It should be a plain text file with **one URL per line**, for example:

    https://example.org/data/sample_1/sample_1.tar
    https://example.org/data/sample_1/MD5.txt
    https://example.org/data/sample_2/sample_2.tar
    https://example.org/data/sample_2/MD5.txt

Blank lines are ignored.

---

## How it works (high level)

1. Each Slurm array task processes **exactly one URL**
2. The script:
   - checks whether the file already exists
   - queries the remote file size (via HTTP HEAD)
   - checks available disk space
   - **reserves space atomically** so other tasks can’t over-commit storage
3. The file is downloaded into a `.part` file
4. On success, the `.part` file is renamed to its final name
5. If the file is a `.tar` and an `MD5.txt` is present:
   - the checksum is verified
6. The result is recorded in a shared status file

---

## Usage

### 1. Prepare your URL list

    cp example_urls.txt urls.txt

Check how many lines it contains:

    wc -l urls.txt

Suppose this prints `19`.

---

### 2. Submit the Slurm job array

    sbatch --array=1-19 download_array.sbatch urls.txt /path/to/output

This runs **one task per URL**.

---

### 3. Limit concurrency (recommended)

    sbatch --array=1-19%4 download_array.sbatch urls.txt /path/to/output

This ensures **at most 4 downloads run simultaneously**.

---

## Output directory structure

The script reconstructs a directory layout derived from the URL path.

For example, a URL like:

    https://…/o/out/PROJECT/SAMPLE/SAMPLE_1.tar

becomes:

    /path/to/output/
    └── PROJECT/
        └── SAMPLE/
            ├── SAMPLE_1.tar
            └── MD5.txt

The exact mapping can be adjusted by editing the `STRIP_REGEX` variable in the script.

---

## Status tracking

All tasks write to a shared status file:

    /path/to/output/_download_status/status.tsv

Each line contains:

| Field     | Description                                |
|-----------|--------------------------------------------|
| Timestamp | ISO 8601 time of event                     |
| Task ID   | Slurm array task ID                        |
| State     | DONE, SKIP_EXISTS, SKIP_NOSPACE, FAIL_WGET |
| Path      | Relative output path                       |
| Extra     | Additional info (e.g. MD5 result)          |

Example:

    2026-01-02T15:42:10    7    DONE    PROJECT/SAMPLE/SAMPLE_1.tar    md5=OK

This makes it easy to:
- see what completed successfully
- identify skipped files
- retry failed downloads elsewhere (e.g. scratch storage)

---

## Disk-space safety

This script explicitly avoids a common failure mode:

> Multiple parallel downloads all think there is enough free space — and fill the filesystem.

It prevents this by:
- tracking a shared **reserved byte count**
- ensuring each task “claims” its required space before downloading
- releasing the reservation on completion or failure

This makes it safe even when:
- total data size > available disk space
- downloads are very large
- array tasks run concurrently

---

## Logging behaviour

`wget` progress output is suppressed to keep Slurm log files small.

- Slurm logs contain only high-level messages
- Detailed state is recorded in `status.tsv`
- Downloads remain fully resumable

---

## Rerunning and recovery

The script is designed to be **idempotent**:

- Files that already exist are skipped
- Partially downloaded files are resumed
- Failed or skipped URLs can be retried by:
  - filtering `status.tsv`
  - generating a new URL list
  - resubmitting the job

---

## Customisation

Common things you may want to adjust:

- **Concurrency**
  Use `%N` in `--array=1-N%N`

- **Safety margin**
  Edit:

        SAFETY_MARGIN=$((5 * 1024 * 1024 * 1024))

- **URL → directory mapping**
  Edit:

        STRIP_REGEX='^https?://[^/]+/.*?/o/out/[^/]+/'

---

## Why not just use `wget -i`?

Standard `wget -i`:
- has no awareness of Slurm
- cannot coordinate disk usage
- happily fills filesystems
- produces enormous logs
- offers no job-level tracking

This script solves those problems.

---

## License

MIT License — see the `LICENSE` file.

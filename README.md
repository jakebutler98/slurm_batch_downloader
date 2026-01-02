# Slurm Safe Wget Downloader

A robust Slurm array job for downloading large numbers of files in parallel **without filling your filesystem**.

Designed for HPC environments where:
- downloads are large (100+ GB files),
- storage is limited,
- and partial / corrupted downloads are unacceptable.

## Features

- One URL per Slurm array task
- Disk-space reservation to prevent concurrent jobs overfilling storage
- Resumable downloads (`.part` files)
- Optional MD5 verification for `.tar` files
- Minimal Slurm log output
- No special software required

## Requirements

Standard Unix tools only:

- `bash`
- `wget`
- `curl`
- `df`, `awk`, `sed`
- `md5sum` (GNU coreutils)

No Python, Conda, or containers needed.

## Input format

A plain text file with **one URL per line**:

```text
https://example.org/data/sample_1.tar
https://example.org/data/sample_1/MD5.txt
https://example.org/data/sample_2.tar
#!/usr/bin/env bash
# Trusted operator utility for labeled local Squidra PostgreSQL containers.
set -euo pipefail
exec python3 "$(dirname "$0")/database-archive.py" "$@"

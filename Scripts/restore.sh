#!/usr/bin/env bash
# Restore only into a newly generated database; never overwrite an existing one.
set -euo pipefail
exec bash "$(dirname "$0")/backup.sh" --restore "$@"

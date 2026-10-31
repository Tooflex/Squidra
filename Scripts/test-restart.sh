#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec bash Scripts/dev-db.sh test-restart

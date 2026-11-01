#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:---profile=offline-replay}" != --profile=offline-replay || $# -gt 1 ]]; then
  echo 'Only --profile=offline-replay is qualified; no model or cloud call was executed.' >&2
  exit 2
fi
exec python3 Tests/SquidraE2ETests/demo.py

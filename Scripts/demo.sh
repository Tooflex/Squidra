#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 1 || ( "${1:---profile=offline-replay}" != --profile=offline-replay && "${1:---profile=offline-replay}" != --profile=offline-fake-model ) ]]; then
  echo 'Only offline-replay and offline-fake-model profiles are qualified; no model or cloud call was executed.' >&2
  exit 2
fi
exec python3 Tests/SquidraE2ETests/demo.py "${1:---profile=offline-replay}"

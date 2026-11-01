#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 1 || ( "${1:---profile=offline-replay}" != --profile=offline-replay && "${1:---profile=offline-replay}" != --profile=offline-fake-model && "${1:---profile=offline-replay}" != --profile=offline-latency ) ]]; then
  echo 'Only offline-replay, offline-fake-model and offline-latency profiles are qualified; no model or cloud call was executed.' >&2
  exit 2
fi
exec python3 Tests/SquidraE2ETests/demo.py "${1:---profile=offline-replay}"

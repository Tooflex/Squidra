#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 1 || ( "${1:---profile=offline-replay}" != --profile=offline-replay && "${1:---profile=offline-replay}" != --profile=offline-fake-model && "${1:---profile=offline-replay}" != --profile=offline-latency && "${1:---profile=offline-replay}" != --profile=real-meta ) ]]; then
  echo 'Supported profiles: offline-replay, offline-fake-model, offline-latency, real-meta (explicit consent and current budget required).' >&2
  exit 2
fi
exec python3 Tests/SquidraE2ETests/demo.py "${1:---profile=offline-replay}"

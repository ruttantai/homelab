#!/usr/bin/env bash
# Usage: wait-for-health.sh URL [TIMEOUT_SECONDS]. Exits 0 on the first 2xx, 1 on timeout.
set -euo pipefail
url=${1:?usage: wait-for-health.sh URL [TIMEOUT_SECONDS]}
timeout=${2:-120}
for ((i = 1; i <= timeout; i++)); do
  if curl -fsS -o /dev/null "$url"; then
    echo "healthy after ${i}s: $url"
    exit 0
  fi
  sleep 1
done
echo "FAIL: no 2xx from $url within ${timeout}s" >&2
exit 1

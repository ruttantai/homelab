#!/usr/bin/env bash
# Clean build -> idempotent re-run -> assertions -> OOM demo -> teardown.
# KEEP=1 skips the teardown so a failure can be inspected.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${KEEP:-}" ]; then
  trap '"${MAKE:-make}" down' EXIT
fi

"${MAKE:-make}" up
"${MAKE:-make}" idempotency
"${MAKE:-make}" verify
"${MAKE:-make}" oom-demo
echo "make test: PASSED"

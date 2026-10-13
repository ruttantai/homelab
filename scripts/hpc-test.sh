#!/usr/bin/env bash
# Clean build -> verify -> elastic demo -> idempotency from the powered-off state -> teardown (spec §7.3).
# Idempotency runs after the demo on purpose: the nodes are off, so it also proves hold/release (Review Focus 3).
# KEEP=1 skips the teardown so a failure can be inspected.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${KEEP:-}" ]; then
  trap '"${MAKE:-make}" hpc-down' EXIT
fi

"${MAKE:-make}" hpc-down
"${MAKE:-make}" hpc-up
"${MAKE:-make}" hpc-verify
"${MAKE:-make}" elastic-demo
"${MAKE:-make}" hpc-idempotency
echo "make hpc-test: PASSED"

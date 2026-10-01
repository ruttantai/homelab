#!/usr/bin/env bash
# Re-runs the whole playbook and fails if any host reports a change (spec §5).
set -euo pipefail
cd "$(dirname "$0")/../ansible"
out=$(ansible-playbook site.yml 2>&1) || { echo "$out"; exit 1; }
recap=$(echo "$out" | sed -n '/PLAY RECAP/,$p')
echo "$recap"
if echo "$recap" | grep -Eq 'changed=[1-9]'; then
  echo "FAIL: second run changed something; a role is not idempotent" >&2
  echo "$out" | grep -E '^(changed|TASK)' | grep -B1 '^changed' >&2 || true
  exit 1
fi
echo "idempotent: changed=0 on every host"

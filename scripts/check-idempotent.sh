#!/usr/bin/env bash
# Re-runs a playbook and fails if any host reports a change (spec §5).
# PLAYBOOK and INVENTORY default to the k3s stack; the HPC stack passes its own.
set -euo pipefail
cd "$(dirname "$0")/../ansible"
playbook=${PLAYBOOK:-site.yml}
inventory_args=()
[ -n "${INVENTORY:-}" ] && inventory_args=(-i "$INVENTORY")
# ${arr[@]+"${arr[@]}"}: an empty array is "unbound" under set -u in macOS bash 3.2.
out=$(ansible-playbook ${inventory_args[@]+"${inventory_args[@]}"} "$playbook" 2>&1) || { echo "$out"; exit 1; }
recap=$(echo "$out" | sed -n '/PLAY RECAP/,$p')
echo "$recap"
if echo "$recap" | grep -Eq 'changed=[1-9]'; then
  echo "FAIL: second run changed something; a role is not idempotent" >&2
  echo "$out" | grep -E '^(changed|TASK)' | grep -B1 '^changed' >&2 || true
  exit 1
fi
echo "idempotent: changed=0 on every host"

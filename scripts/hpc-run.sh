#!/usr/bin/env bash
# Runs an HPC playbook action against inventory/hpc.yml. Task 6 adds the Slurm power hold around it.
#   configure    -> site-hpc.yml
#   verify       -> verify-hpc.yml
#   idempotency  -> site-hpc.yml twice-run check (scripts/check-idempotent.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
action=${1:?usage: hpc-run.sh configure|verify|idempotency}

case "$action" in
  configure)   (cd ansible && ansible-playbook -i inventory/hpc.yml site-hpc.yml) ;;
  verify)      (cd ansible && ansible-playbook -i inventory/hpc.yml verify-hpc.yml) ;;
  idempotency) PLAYBOOK=site-hpc.yml INVENTORY=inventory/hpc.yml scripts/check-idempotent.sh ;;
  *) echo "unknown action: $action" >&2; exit 2 ;;
esac

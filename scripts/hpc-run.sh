#!/usr/bin/env bash
# Runs an HPC playbook action against inventory/hpc.yml, holding Slurm's power saving around it so
# every compute node is up and reachable (spec §10.4), and releasing it however the run ends.
#   configure    -> site-hpc.yml
#   verify       -> verify-hpc.yml
#   idempotency  -> site-hpc.yml twice-run check (scripts/check-idempotent.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
action=${1:?usage: hpc-run.sh configure|verify|idempotency}

scripts/hpc-hold.sh hold
trap 'scripts/hpc-hold.sh release' EXIT

case "$action" in
  configure)   (cd ansible && ansible-playbook -i inventory/hpc.yml site-hpc.yml) ;;
  verify)      (cd ansible && ansible-playbook -i inventory/hpc.yml verify-hpc.yml) ;;
  idempotency) PLAYBOOK=site-hpc.yml INVENTORY=inventory/hpc.yml scripts/check-idempotent.sh ;;
  *) echo "unknown action: $action" >&2; exit 2 ;;
esac

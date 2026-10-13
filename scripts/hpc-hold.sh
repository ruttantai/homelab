#!/usr/bin/env bash
# hold: stop Slurm powering compute nodes off and wake them, so Ansible can reach every node (spec §10.4).
# release: hand them back to power saving. Both are no-ops before slurmctld exists (first build).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/hpc-lib.sh
. scripts/hpc-lib.sh

if ! on_head systemctl is-active --quiet slurmctld 2>/dev/null; then
  echo "slurmctld not running yet; nothing to ${1:-hold}"
  exit 0
fi
nodes=$(on_head sinfo -h -N -o '%N' | sort -u | paste -sd, -)

case "${1:?hold|release}" in
  hold)
    # The hook must hold the current token before it can wake anything (ansible/hpc-power-hook.yml).
    # Captured, not inherited: Ansible refuses to run if the caller's stderr is non-blocking.
    out=$(cd ansible && ansible-playbook -i inventory/hpc.yml hpc-power-hook.yml 2>&1 </dev/null) || { echo "$out" >&2; exit 1; }
    on_head sudo scontrol update SuspendExcNodes="$nodes"
    for _ in $(seq 1 60); do
      states=$(on_head sinfo -h -N -o '%t' | sort -u | paste -sd' ' -)
      case "$states" in *'~'*|*'#'*|*'%'*|*down*) ;; *) echo "held, nodes up: $states"; exit 0 ;; esac
      # Only nodes that are powered off (~): POWER_UP on a running node starts a power-up cycle that
      # waits for a reboot that never comes. Asked every pass, because Slurm refuses it for a node
      # still powering down (%), so a request made when the hold began can be lost.
      for n in $(on_head sinfo -h -N -o '%N %t' | awk '$2 ~ /~$/ {print $1}' | sort -u); do
        on_head sudo scontrol update NodeName="$n" State=POWER_UP 2>/dev/null || true
      done
      sleep 5
    done
    echo "nodes did not come up within 5 minutes (states: $states)" >&2
    exit 1
    ;;
  release)
    on_head sudo scontrol update SuspendExcNodes=""
    echo "released: power saving applies again"
    ;;
  *) echo "usage: hpc-hold.sh hold|release" >&2; exit 2 ;;
esac

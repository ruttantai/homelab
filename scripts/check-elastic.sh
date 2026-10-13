#!/usr/bin/env bash
# Elastic-node demo (spec §7.2): both nodes off -> a job wakes them -> COMPLETED -> both off again.
# Prints the cold-start wait and the time back to powered-off.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/hpc-lib.sh
. scripts/hpc-lib.sh
nodes=(hpc-node-1 hpc-node-2)

all_off() {
  [ "$(on_head sinfo -h -N -o '%t' | sort -u)" = "idle~" ] || return 1
  for n in "${nodes[@]}"; do
    multipass info "$n" --format json | jq -e --arg n "$n" '.info[$n].state == "Stopped"' >/dev/null || return 1
  done
}
job_state() { on_head scontrol show job "$1" -o | grep -o 'JobState=[A-Z_]*' | cut -d= -f2; }

echo "1/4 waiting for both nodes to be powered off (up to 6 min)"
start=$SECONDS
until all_off; do
  [ $((SECONDS - start)) -lt 360 ] || { echo "FAIL: nodes not powered off after 6 min" >&2; on_head sinfo -N; exit 1; }
  sleep 5
done
echo "    both powered off"

echo "2/4 submitting a two-node job"
job=$(on_head sudo -u ops sbatch --parsable -p short -N2 --chdir=/shared/ops --wrap 'srun hostname; sleep 10')
submitted=$SECONDS

echo "3/4 waiting for it to start and finish"
state=""
until [ "$state" = RUNNING ] || [ "$state" = COMPLETED ]; do
  [ $((SECONDS - submitted)) -lt 330 ] || { echo "FAIL: job $job not running after 330 s (state $state)" >&2; exit 1; }
  sleep 3
  state=$(job_state "$job")
  case "$state" in FAILED|NODE_FAIL|CANCELLED|TIMEOUT|OUT_OF_MEMORY|BOOT_FAIL) echo "FAIL: job $job ended $state" >&2; exit 1 ;; esac
done
cold_start=$((SECONDS - submitted))
until [ "$state" = COMPLETED ]; do
  [ $((SECONDS - submitted)) -lt 480 ] || { echo "FAIL: job $job did not complete (state $state)" >&2; exit 1; }
  sleep 3
  state=$(job_state "$job")
  case "$state" in FAILED|NODE_FAIL|CANCELLED|TIMEOUT|OUT_OF_MEMORY|BOOT_FAIL) echo "FAIL: job $job ended $state" >&2; exit 1 ;; esac
done
echo "    job $job COMPLETED; it waited ${cold_start}s for cold nodes"

echo "4/4 waiting for the nodes to power off again (up to 6 min)"
done_at=$SECONDS
until all_off; do
  [ $((SECONDS - done_at)) -lt 360 ] || { echo "FAIL: nodes not powered off again after 6 min" >&2; exit 1; }
  sleep 5
done
echo "elastic demo passed: cold start ${cold_start}s, back to powered off $((SECONDS - done_at))s after completion"
on_head tail -n 6 /var/log/slurm/power.log

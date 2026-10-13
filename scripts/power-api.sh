#!/usr/bin/env bash
# Starts or stops the power API on the Mac (spec §5.1). It binds to hpc-head's default gateway, which is
# the Mac's address on the Multipass network (spec §10.3), so it needs hpc-head to be running.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/hpc-lib.sh
. scripts/hpc-lib.sh
pidfile=.secrets/power-api.pid
port=${POWER_API_PORT:-8765}

running() { [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; }

case "${1:?start|stop}" in
  start)
    if running; then echo "power-api already running (pid $(cat "$pidfile"))"; exit 0; fi
    gw=$(on_head ip -4 route show default | awk '{print $3; exit}')
    [ -n "$gw" ] || { echo "could not read hpc-head's default gateway" >&2; exit 1; }
    nohup python3 power-api/server.py --bind "$gw" --port "$port" --token-file .secrets/power-api.token \
      >>.secrets/power-api.log 2>&1 &
    echo $! >"$pidfile"
    # Alive and enforcing auth: an unauthenticated call must get 401.
    for _ in $(seq 1 20); do
      code=$(curl -s -o /dev/null -w '%{http_code}' "http://$gw:$port/ip?node=hpc-node-1" || true)
      [ "$code" = 401 ] && { echo "power-api listening on $gw:$port (pid $(cat "$pidfile"))"; exit 0; }
      sleep 0.5
    done
    echo "power-api did not come up; see .secrets/power-api.log" >&2
    exit 1
    ;;
  stop)
    if running; then kill "$(cat "$pidfile")"; echo "power-api stopped"; fi
    rm -f "$pidfile"
    ;;
  *) echo "usage: power-api.sh start|stop" >&2; exit 2 ;;
esac

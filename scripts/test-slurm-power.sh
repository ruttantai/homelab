#!/usr/bin/env bash
# Unit test for the Slurm power hook (spec §5.2) with stub curl and scontrol on PATH. No VMs.
set -euo pipefail
cd "$(dirname "$0")/.."
hook=$PWD/ansible/roles/slurm_power/files/slurm-power

t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin"
ln -s "$hook" "$t/bin/slurm-resume"
ln -s "$hook" "$t/bin/slurm-suspend"

cat >"$t/bin/scontrol" <<'EOF'
#!/usr/bin/env bash
# show hostnames hpc-node-[1-2] -> one per line; update ... -> recorded
if [ "$1 $2" = "show hostnames" ]; then printf 'hpc-node-1\nhpc-node-2\n'; exit 0; fi
echo "scontrol $*" >>"$STUB_LOG"
EOF
cat >"$t/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Records the call; /ip answers with a NEW address for hpc-node-2 (Review Focus 2).
url=${*: -1}
echo "curl $url" >>"$STUB_LOG"
[ -n "${CURL_FAIL:-}" ] && { echo "curl: (7) Failed to connect" >&2; exit 7; }
case "$url" in
  */ip?node=hpc-node-1) echo '{"node":"hpc-node-1","ip":"192.168.64.21"}' ;;
  */ip?node=hpc-node-2) echo '{"node":"hpc-node-2","ip":"192.168.64.99"}' ;;
  *) echo '{}' ;;
esac
EOF
chmod +x "$t/bin/scontrol" "$t/bin/curl"
printf 'POWER_API_URL=http://192.168.64.1:8765\n' >"$t/power-api.env"
printf 'Authorization: Bearer x\n' >"$t/power-api.header"

run() { # name -> runs the hook with stubs, logs in $t
  : >"$t/stub.log"; : >"$t/power.log"
  PATH="$t/bin:$PATH" STUB_LOG="$t/stub.log" POWER_ENV="$t/power-api.env" HEADER_FILE="$t/power-api.header" \
    POWER_LOG="$t/power.log" RESUME_TIMEOUT=40 "$t/bin/$1" 'hpc-node-[1-2]'
}
fail() { echo "FAIL: $*" >&2; echo "--- stub.log"; cat "$t/stub.log"; echo "--- power.log"; cat "$t/power.log"; exit 1; }

# test_resume_updates_node_addr
run slurm-resume || fail "resume exited non-zero"
grep -q 'curl http://192.168.64.1:8765/start?node=hpc-node-1' "$t/stub.log" || fail "resume did not start hpc-node-1"
grep -q 'scontrol update NodeName=hpc-node-2 NodeAddr=192.168.64.99 NodeHostname=hpc-node-2' "$t/stub.log" \
  || fail "resume did not set hpc-node-2's new address"
grep -q 'hpc-node-1 started at 192.168.64.21' "$t/power.log" || fail "resume did not log"

# test_suspend_stops_each_node
run slurm-suspend || fail "suspend exited non-zero"
[ "$(grep -c '/stop?node=' "$t/stub.log")" = 2 ] || fail "suspend should stop two nodes"

# test_unreachable_api_fails_and_logs (Review Focus 1)
if CURL_FAIL=1 run slurm-resume; then fail "resume must fail when the API is unreachable"; fi
grep -q 'hpc-node-1 start FAILED' "$t/power.log" || fail "the failure must be logged"

# test_wrong_name_refuses
ln -s "$hook" "$t/bin/slurm-other"
if run slurm-other 2>/dev/null; then fail "unknown invocation name must exit non-zero"; fi

# The token never appears in any process argument: curl gets it from a header file.
grep -q 'Bearer' "$t/stub.log" && fail "token leaked into curl's arguments"
echo "slurm-power: all tests passed"

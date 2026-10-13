#!/usr/bin/env bash
# Unit test for scripts/hpc-lib.sh's on_head with a stub ssh on PATH. No VMs.
# on_head must hand the remote shell one string that re-splits into exactly the caller's arguments.
set -euo pipefail
cd "$(dirname "$0")/.."
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin"
# The real ssh joins its trailing arguments and runs them with the remote user's shell; so does this stub.
cat >"$t/bin/ssh" <<'STUB'
#!/usr/bin/env bash
while [ $# -gt 1 ]; do
  case "$1" in -i|-o) shift 2 ;; -*) shift ;; *) echo "$1" >"$SSH_LOG"; shift; break ;; esac
done
exec bash -c "$*"
STUB
chmod +x "$t/bin/ssh"

out=$(PATH="$t/bin:$PATH" SSH_LOG="$t/target" HPC_HEAD_IP=192.0.2.20 bash -c \
  '. scripts/hpc-lib.sh; on_head printf "<%s>" "a b" "c;d" "it'\''s" "\$HOME"')
[ "$out" = "<a b><c;d><it's><\$HOME>" ] || { echo "FAIL: arguments not preserved: $out" >&2; exit 1; }
[ "$(cat "$t/target")" = "ops@192.0.2.20" ] || { echo "FAIL: wrong target $(cat "$t/target")" >&2; exit 1; }
echo "hpc-lib: all tests passed"

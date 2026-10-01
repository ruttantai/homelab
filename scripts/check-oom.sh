#!/usr/bin/env bash
# Runs the OOMKilled demo and checks the three things spec §7 promises:
#   1. the pod is killed with reason OOMKilled
#   2. Prometheus fires ContainerOOMKilled for that pod
#   3. Loki still returns the pod's log lines after the pod is deleted
# Prometheus and Loki are reached through the API server's service proxy, so no port-forward is needed.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${KUBECONFIG:=$HOME/.kube/homelab.yaml}"
export KUBECONFIG

prom=/api/v1/namespaces/monitoring/services/kps-prometheus:9090/proxy
loki=/api/v1/namespaces/monitoring/services/loki:3100/proxy

# --cascade=foreground makes this block until the Job's pods are gone too (not just the
# Job object), so a prior run's pod can never still be around when the new Job is applied.
kubectl -n demo delete job oom-demo --ignore-not-found --cascade=foreground --wait=true >/dev/null 2>&1 || true
kubectl -n demo wait --for=delete pod -l app=oom-demo --timeout=60s >/dev/null 2>&1 || true
kubectl apply -f k8s/demo/oom-job.yaml

# Select the pod by this run's Job uid (not just app=oom-demo), so a label query can never
# pick up a pod left over from a previous run.
job_uid=$(kubectl -n demo get job oom-demo -o jsonpath='{.metadata.uid}')

echo "1/3 waiting for the pod to be OOMKilled"
reason=""
for _ in $(seq 1 120); do
  reason=$(kubectl -n demo get pods -l "batch.kubernetes.io/controller-uid=$job_uid" \
    -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || true)
  [ "$reason" = OOMKilled ] && break
  sleep 1
done
[ "$reason" = OOMKilled ] || { echo "FAIL: pod never reached OOMKilled (last reason: '${reason}')" >&2; exit 1; }
pod=$(kubectl -n demo get pods -l "batch.kubernetes.io/controller-uid=$job_uid" -o jsonpath='{.items[0].metadata.name}')
echo "    $pod: OOMKilled"

echo "2/3 waiting for ContainerOOMKilled to fire (up to 3 min)"
fired=0
for _ in $(seq 1 36); do
  if kubectl get --raw "$prom/api/v1/alerts" | jq -e --arg p "$pod" \
      '.data.alerts[] | select(.labels.alertname == "ContainerOOMKilled" and .labels.pod == $p and .state == "firing")' >/dev/null; then
    fired=1
    break
  fi
  sleep 5
done
[ "$fired" = 1 ] || { echo "FAIL: ContainerOOMKilled did not fire for $pod" >&2; exit 1; }
echo "    alert firing"

loki_lines() {
  local q
  q=$(jq -rn --arg q "{namespace=\"demo\", pod=\"$pod\"} |= \"allocated\"" '$q | @uri')
  # Always print an integer: a service-proxy/jq failure (e.g. Loki briefly unreachable, or a
  # response with no .data.result) must fall back to 0 and let the polling loop / final
  # assertion FAIL cleanly, instead of aborting the whole script under `set -euo pipefail`.
  kubectl get --raw "$loki/loki/api/v1/query_range?query=${q}&since=1h&limit=200" 2>/dev/null \
    | jq '[(.data.result // [])[].values[]] | length' 2>/dev/null \
    || echo 0
}

echo "3/3 checking the logs outlive the pod"
n=0
for _ in $(seq 1 24); do
  n=$(loki_lines)
  [ "$n" -gt 0 ] && break
  sleep 5
done
[ "$n" -gt 0 ] || { echo "FAIL: Loki never received logs from $pod" >&2; exit 1; }
kubectl -n demo delete job oom-demo --wait=true >/dev/null
kubectl -n demo wait --for=delete "pod/$pod" --timeout=60s >/dev/null 2>&1 || true
if kubectl -n demo get pod "$pod" >/dev/null 2>&1; then
  echo "FAIL: $pod still exists; cannot prove the logs outlive it" >&2; exit 1
fi
n=$(loki_lines)
[ "$n" -gt 0 ] || { echo "FAIL: Loki lost $pod's logs once the pod was gone" >&2; exit 1; }
echo "OOM demo passed: $pod was OOMKilled, the alert fired, and $n log lines outlive the pod"

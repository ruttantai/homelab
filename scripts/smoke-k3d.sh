#!/usr/bin/env bash
# Applies k8s/ley-khaa to a throwaway k3d cluster and waits for /api/health through
# the ingress. Covers the manifests in CI, where Multipass VMs cannot run.
#
# SMOKE_IMPORT_IMAGES="img:tag ..." imports local images first (for testing before a release).
set -euo pipefail
cd "$(dirname "$0")/.."

cluster=homelab-smoke
port=${SMOKE_PORT:-8081}
KUBECONFIG=$(mktemp)
export KUBECONFIG
trap 'k3d cluster delete "$cluster" >/dev/null 2>&1 || true; rm -f "$KUBECONFIG"' EXIT

k3d cluster create "$cluster" --agents 1 -p "${port}:80@loadbalancer" --wait
for img in ${SMOKE_IMPORT_IMAGES:-}; do
  k3d image import -c "$cluster" "$img"
done

kubectl create namespace ley-khaa
kubectl -n ley-khaa create secret generic ley-khaa-db --from-literal=password="$(openssl rand -hex 16)"
kubectl apply -k k8s/ley-khaa
kubectl -n ley-khaa rollout status statefulset/postgres --timeout=300s
kubectl -n ley-khaa rollout status deploy/backend --timeout=300s
kubectl -n ley-khaa rollout status deploy/frontend --timeout=300s
scripts/wait-for-health.sh "http://localhost:${port}/api/health" 120 || {
  kubectl -n ley-khaa get pods -o wide
  kubectl -n ley-khaa logs deploy/backend --tail=50 || true
  exit 1
}
echo "k3d smoke OK"

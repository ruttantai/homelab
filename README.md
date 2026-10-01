# homelab

One command builds a three-node Kubernetes cluster on a Mac with **Terraform** and **Ansible**, deploys
[ley-khaa](https://github.com/ruttantai/ley-khaa) with **Prometheus, Grafana and Loki**, and tears it all down
again. Everything runs locally, at £0.

```
make up
 ├─ Terraform   → 3 Ubuntu VMs on Multipass (cp-1, worker-1, worker-2), writes the Ansible inventory
 └─ Ansible
     ├─ common       key-only SSH, ufw firewall, unattended upgrades      (every node)
     ├─ k3s_server   k3s control plane, kubeconfig to ~/.kube/homelab.yaml (cp-1)
     ├─ k3s_agent    workers join                                         (worker-1, worker-2)
     ├─ k8s_tooling  Helm + Kubernetes Python client                      (cp-1)
     ├─ monitoring   kube-prometheus-stack, Loki, Alloy (Helm)
     └─ ley_khaa     Postgres, backend, frontend (kustomize), images from GHCR
```

**Terraform owns what exists; Ansible owns what is on it.** The only hand-off is the generated inventory.

## Use it

```bash
brew install multipass ansible ansible-lint yamllint kubectl jq kubeconform k3d hashicorp/tap/terraform
make up         # prints the ley-khaa and Grafana URLs
make oom-demo   # a pod is OOMKilled, an alert fires, and its logs are still in Loki after it's gone
make status
make down       # deletes the lab's three VMs
make test       # all of the above from scratch, plus an idempotency re-run; KEEP=1 keeps the cluster
```

Needs about 9 GB free RAM (three 3 GB VMs).

## Design choices

- **Local Terraform state.** The VMs exist only on this Mac, so a remote backend would have nothing to share.
- **Kubernetes tasks run on cp-1**, using k3s's own kubeconfig, so the Mac needs Ansible but no Kubernetes Python stack.
- **ley-khaa runs with the offline heuristic model and the subprocess sandbox.** No API key lives in the cluster, and
  k3s has no Docker socket. ley-khaa's bundle manifest records `sandbox: subprocess`, so the output stays honest.
- **Every version is pinned:** k3s, Helm, charts, collections, image tags.
- **Host-key checking is off** because the VMs are rebuilt on every `make up`. That is fine for a throwaway local
  lab and wrong for real servers.
- **Nodes are 3 GB, not 2 GB.** 2 GB nodes ran out of memory during a Grafana rolling update.

## Testing

- **CI (every PR):** `terraform fmt/validate/test` (mocked providers), `yamllint`, `ansible-lint` (production
  profile), `kubeconform`, and a k3d smoke test that deploys the real manifests and checks `/api/health`.
- **`make test` (local):** the VM and Ansible layers, which GitHub's runners cannot host, end to end. On this Mac,
  `make test` runs end to end in about 7 minutes: three fresh VMs, the full Ansible run, an idempotency re-run,
  `verify`, the OOM demo, then teardown.

Design spec: `docs/superpowers/specs/2026-10-01-homelab-design.md`.

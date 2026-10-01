# Homelab platform — design

*Approved 2026-10-01.*

## 1. Purpose

One command builds a small Kubernetes cluster on a Mac, deploys a real application with monitoring, and tears it all
down again, at £0. It exists to give honest, demonstrable evidence of Terraform, Ansible and Kubernetes experience.

The application is **ley-khaa** (`github.com/ruttantai/ley-khaa`), an existing, tested project. Reusing it means any
bug met here is an infrastructure bug, which is the skill being shown.

**Success criteria**

1. `make up` on a clean Mac (with the prerequisites in §9) ends with ley-khaa reachable and `/api/health` returning 200.
2. `make oom-demo` produces a pod with reason `OOMKilled`, a firing Prometheus alert, and the pod's last log lines
   still queryable in Loki after the pod is gone.
3. `make down` removes every VM; nothing is left running or billed.
4. `make test` runs 1–3 end to end and exits non-zero on any failure.
5. CI on every PR runs the static checks and a k3d smoke test (§7) and is green.

**Out of scope (v1):** real cloud providers (Oracle Always Free is the plan's optional step 7), GitOps / Argo CD,
TLS and DNS, high availability, the Pipeline Assistant (Project 2), and any ley-khaa backend code change.

## 2. Division of labour

**Terraform owns what exists. Ansible owns what is on it.** Terraform never touches Kubernetes; Ansible never creates
or destroys a machine. The one hand-off between them is a generated inventory file.

```
make up
 ├─ terraform apply       → 3 Multipass VMs; writes ansible/inventory/hosts.yml (generated, git-ignored)
 ├─ ansible-playbook site.yml
 │    ├─ role common      → admin user, key-only SSH, ufw, unattended upgrades
 │    ├─ role k3s_server  → k3s on cp-1, reads back the join token and kubeconfig
 │    ├─ role k3s_agent   → worker-1, worker-2 join using that token
 │    ├─ role monitoring  → kube-prometheus-stack + Loki + Alloy (Helm)
 │    └─ role ley_khaa    → applies k8s/ley-khaa/ (kustomize)
 └─ prints URLs
make down → terraform destroy
```

## 3. Repository layout

```
homelab/
├── Makefile                      up, down, test, oom-demo, lint, kubeconfig, status
├── terraform/
│   ├── versions.tf               required_providers, pinned
│   ├── main.tf                   multipass_instance × 3 + cloud-init
│   ├── variables.tf / outputs.tf
│   ├── cloud-init.yaml.tftpl     injects the admin SSH public key
│   └── inventory.tftpl           renders ansible/inventory/hosts.yml
├── ansible/
│   ├── ansible.cfg
│   ├── site.yml
│   ├── requirements.yml          pinned collections (kubernetes.core, community.general, ansible.posix)
│   ├── group_vars/all.yml        pinned versions (k3s, Helm, charts, kubernetes lib)
│   ├── verify.yml                assertions run by `make verify` / `make test`
│   └── roles/{common,k3s_server,k3s_agent,k8s_tooling,monitoring,ley_khaa}/
├── k8s/
│   ├── ley-khaa/                 kustomization: namespace, postgres, backend, frontend, ingress
│   └── demo/oom-job.yaml
├── scripts/                      wait-for-health.sh, check-oom.sh (used by make test)
├── .github/workflows/ci.yml
└── docs/                         architecture diagram in README, this spec
```

## 4. Machines (Terraform)

- Provider `larstobi/multipass`, pinned `~> 1.4.3`. Multipass ≥ 1.16 on the host.
- Three instances: `cp-1` (control plane), `worker-1`, `worker-2`; Ubuntu 24.04; 2 vCPU, 2 GiB RAM, 15 GiB disk each.
  About 6 GiB RAM total on a 24 GiB Mac. Sizes are variables.
- cloud-init creates user `ops` with the operator's SSH public key (`var.ssh_public_key_path`, default
  `~/.ssh/homelab_ed25519.pub`; `make keys` generates it if missing). Password login disabled.
- Outputs: each node's IP. A `local_file` resource renders the Ansible inventory from those outputs.
- **State stays local** (`terraform.tfstate`, git-ignored). Justification: the VMs exist only on this Mac, so remote
  state would add a backend with nothing to share. Documented as a deliberate choice in the README.

## 5. Configuration (Ansible)

Roles are idempotent: a second `ansible-playbook site.yml` run reports `changed=0`. That is checked in `make test`.

- **common:** apt update + baseline packages; `ops` sudo; sshd `PasswordAuthentication no`, `PermitRootLogin no`;
  ufw default deny incoming, allow 22, 80, 6443, and the k3s inter-node ports (8472/udp flannel, 10250) only from the
  node subnet, plus the k3s pod and service CIDRs (10.42.0.0/16, 10.43.0.0/16) so in-cluster traffic is not
  dropped; unattended-upgrades on.
- **k3s_server:** installs a pinned k3s (`v1.37.1+k3s1`, from group_vars) via the official install script with
  `INSTALL_K3S_VERSION`; keeps the bundled Traefik ingress; fetches the node token and writes the kubeconfig to
  `~/.kube/homelab.yaml` on the Mac, rewriting `127.0.0.1` to cp-1's IP.
- **k3s_agent:** joins with `K3S_URL` + token; waits until the node reports `Ready`.
- **monitoring:** Helm via `kubernetes.core.helm`, pinned chart versions: `kube-prometheus-stack` (Prometheus,
  Alertmanager, Grafana, kube-state-metrics) and `loki` (single-binary mode, filesystem storage) + `alloy` (log shipper;
  replaces Promtail, which Grafana deprecated in 2025). Pinned: kube-prometheus-stack 91.8.2, loki 7.3.0, alloy 1.13.0.
  Grafana served at `/grafana` through Traefik with Loki pre-wired as a datasource. One extra PrometheusRule:
  `ContainerOOMKilled` on `kube_pod_container_status_terminated_reason{reason="OOMKilled"} == 1` OR the
  `last_terminated_reason` variant. Both are needed: a Job pod with `restartPolicy: Never` stays in its first
  terminated state and never gets a "last" state, while a restarting Deployment pod only shows the "last" one.
  Admin password generated once on the Mac (`.secrets/grafana-admin`, git-ignored) and printed by `make up`.
- **k8s_tooling (cp-1 only):** installs what the next two roles need on cp-1.
- **Where the Kubernetes tasks run:** the monitoring and ley_khaa roles run **on cp-1**, not on the Mac, using k3s's
  own kubeconfig. cp-1 gets Helm v3.22.0 (Helm 3, not 4, for `kubernetes.core` compatibility) and a venv at
  `/opt/homelab-venv` with `kubernetes==36.0.3` for the `kubernetes.core` modules. The Mac needs only Ansible, not a
  Kubernetes Python stack. Manifests are copied to cp-1 and applied with `k3s kubectl apply -k`.
- **ley_khaa:** creates the `ley-khaa-db` Secret with `kubernetes.core.k8s`, applies `k8s/ley-khaa/` with
  `k3s kubectl apply -k`, then waits for rollouts.

## 6. ley-khaa on the cluster

**Manifests (`k8s/ley-khaa/`, namespace `ley-khaa`):**

- **postgres:** StatefulSet `postgres:16`, 1 replica, PVC on k3s's built-in `local-path` storage; credentials from a
  Secret `ley-khaa-db` created by the ley_khaa role from Ansible's `password` lookup, which generates it once into
  `.secrets/postgres-password` on the Mac (git-ignored) and reuses it on later runs. The manifests carry no secret
  material; CI creates the same Secret with `kubectl create secret`.
- **backend:** Deployment, image `ghcr.io/ruttantai/ley-khaa-backend:<tag>`; env `DATABASE_URL`,
  `LEY_KHAA_LLM=heuristic`, `LEY_KHAA_SANDBOX=subprocess`, `LEY_KHAA_WORKSPACE_ROOT=/work/task-workspaces`;
  PVC mounted at that path; readiness and liveness on `/health`; requests/limits set.
- **frontend:** Deployment, image `ghcr.io/ruttantai/ley-khaa-frontend:<tag>`; nginx on 8080.
- **ingress (Traefik):** `/` → frontend. The frontend's nginx proxies `/api/` → `backend:8000/`, so the browser
  only ever talks to one origin.
- Image tag is pinned once, in `k8s/ley-khaa/kustomization.yaml` (`images:`), never `latest`; Ansible and the CI smoke
  test both read it from there.

**Why subprocess sandbox and heuristic LLM:** k3s runs containerd, so there is no Docker socket for `DockerSandbox`;
and no API key should live in a demo cluster. ley-khaa's manifest records `sandbox: subprocess` and the heuristic
model name, so the output stays honest about what ran. The subprocess sandbox has weaker isolation; acceptable
because the cluster is local-only and the heuristic LLM writes deterministic, known scripts.

**Changes in the ley-khaa repo (one PR, no backend code change):**

1. `.github/workflows/release.yml`: on tag `v*`, docker buildx builds `backend/Dockerfile` and
   `frontend/Dockerfile.prod` for `linux/amd64,linux/arm64` and pushes both to GHCR, tagged with the version.
   Packages set public so the cluster pulls without credentials.
2. `frontend/Dockerfile.prod` + `frontend/nginx.conf.template`: multi-stage — `npm ci && npm run build` with
   `VITE_API_URL=/api`, then `nginx:alpine` serving `dist/` and proxying `/api/` to `${BACKEND_URL}` (envsubst via the
   nginx image's templates directory; default `http://backend:8000`).
3. CI: build `frontend/Dockerfile.prod` on PRs so it cannot rot.
4. README: a short "Deploying on Kubernetes" pointer to the homelab repo. The existing dev `Dockerfile` and
   `docker compose up` are untouched.
5. Release `v1.0.1` (or next patch) to publish the first images.

## 7. OOMKilled demo

`make oom-demo` applies `k8s/demo/oom-job.yaml`: a Job in namespace `demo`, `python:3.12-alpine`, memory limit
64 MiB, `backoffLimit: 0`, running a script that allocates 8 MiB chunks and logs `allocated N MiB` with a flush after
each. Expected and checked by `scripts/check-oom.sh`:

1. Pod `terminated.reason == OOMKilled` (via kubectl jsonpath).
2. Prometheus alert `ContainerOOMKilled` firing (Prometheus HTTP API, polled up to 3 minutes).
3. After `kubectl delete job`, a Loki query `{namespace="demo"} |= "allocated"` still returns the log lines.

A dedicated Job rather than starving ley-khaa: the demo must behave the same every time.

## 8. CI (homelab, `.github/workflows/ci.yml`, every PR and push to main)

- `terraform fmt -check -recursive`, `terraform init -backend=false && terraform validate`
- `ansible-lint`, `yamllint`
- `kubeconform -strict` on `kustomize build k8s/ley-khaa` and `k8s/demo`
- **k3d smoke test:** create a k3d cluster, apply `k8s/ley-khaa/` with the published images, wait for rollouts,
  curl `/api/health` through the ingress → 200. Multipass cannot run on GitHub runners, so the VM and Ansible layers
  are covered by `make test`, not CI. The README says so.

## 9. Operator prerequisites and Makefile

Prerequisites (`make prereqs` checks, does not install): `multipass`, `terraform`, `ansible`, `kubectl`, `helm`,
`kustomize` (or `kubectl -k`), `jq`. README gives the install line
(`brew install multipass ansible kubectl helm jq hashicorp/tap/terraform`; Terraform left Homebrew core).

| Target | Does |
|---|---|
| `make up` | keys, secrets, `terraform apply`, `ansible-playbook site.yml`, print URLs + Grafana password |
| `make down` | `terraform destroy -auto-approve`; works even if `up` failed half-way |
| `make test` | up → idempotency re-run (`changed=0`) → health → oom-demo checks → down; non-zero on any failure |
| `make oom-demo` | §7 |
| `make lint` | the CI static checks locally |
| `make status` | `multipass list` + `kubectl get nodes,pods -A` |

Every target uses `set -euo pipefail` semantics and stops at the first error.

## 10. Risks

- **Community Multipass provider** may lag Multipass releases. Mitigation: pinned versions; if it breaks, fallback is
  a `terraform_data` + `local-exec` wrapper around the `multipass` CLI, keeping the same outputs and inventory.
- **arm64 images:** VMs on Apple silicon are arm64, so GHCR images must be multi-arch; the release workflow builds both.
- **Memory pressure:** monitoring stack + ley-khaa on 3 × 2 GiB nodes is tight. Resource requests are set on every
  workload; node size is one variable if it needs 3 GiB.
- **Colima + Multipass coexistence:** both use macOS virtualization; they run side by side, but `make up` warns if
  free memory is under 8 GiB.

## 11. Claims this enables

Only what `make test` has verified on this Mac: Terraform-provisioned VMs, Ansible roles for hardening and k3s,
Helm-installed Prometheus/Grafana/Loki, a containerised app deployed to Kubernetes from GHCR, multi-arch image
release via GitHub Actions, and a reproducible OOMKilled-to-logs investigation.

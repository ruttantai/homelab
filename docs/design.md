# Homelab platform — design

*Approved 2026-10-01.*

## 1. Purpose

One command builds a small Kubernetes cluster on a Mac, deploys a real application with monitoring, and tears it all
down again, at £0. It exists to give honest, demonstrable evidence of Terraform, Ansible and Kubernetes experience.

The application is **ley-khaa** (`github.com/ruttantai/ley-khaa`), an existing, tested project. Reusing it means any
bug met here is an infrastructure bug, which is the skill being shown.

**Success criteria**

1. `make up` builds the cluster; `make verify` (run inside `make test`) confirms ley-khaa's `/api/health` returns
   200.
2. `make oom-demo` produces a pod with reason `OOMKilled`, a firing Prometheus alert, and the pod's last log lines
   still queryable in Loki after the pod is gone.
3. `make down` removes every VM; nothing is left running or billed.
4. `make test` runs 1–3 end to end and exits non-zero on any failure.
5. CI on every PR runs the static checks and a k3d smoke test (§8).

**Out of scope (v1):** real cloud providers (Oracle Always Free is the plan's optional step 7), GitOps / Argo CD,
TLS and DNS, high availability, the Pipeline Assistant (Project 2), and any ley-khaa backend code change.

## 2. Division of labour

**Terraform owns what exists. Ansible owns what is on it.** Terraform never touches Kubernetes; Ansible never creates
or destroys a machine. The one hand-off between them is a generated inventory file.

```
make up
 ├─ terraform apply       → 3 Multipass VMs; writes ansible/inventory/hosts.yml (generated, git-ignored)
 ├─ ansible-playbook site.yml
 │    ├─ role common      → key-only SSH, ufw, unattended upgrades (cloud-init creates the `ops` user)
 │    ├─ role k3s_server  → k3s on cp-1, reads back the join token and kubeconfig
 │    ├─ role k3s_agent   → worker-1, worker-2 join using that token
 │    ├─ role k8s_tooling → Helm + the kubernetes Python client on cp-1
 │    ├─ role monitoring  → kube-prometheus-stack + Loki + Alloy (Helm)
 │    └─ role ley_khaa    → applies k8s/ley-khaa/ (kustomize)
 └─ prints URLs + Grafana password
make down → terraform destroy + delete the lab's VMs
```

## 3. Repository layout

```
homelab/
├── Makefile                      up, down, test, oom-demo, lint, status, verify, idempotency, smoke,
│                                  urls, prereqs, keys, infra, configure, collections
├── terraform/
│   ├── versions.tf               required_providers, pinned
│   ├── main.tf                   multipass_instance × 3 + cloud-init
│   ├── variables.tf / outputs.tf
│   ├── cloud-init.yaml.tftpl     injects the admin SSH public key
│   ├── inventory.tftpl           renders ansible/inventory/hosts.yml
│   └── tests/                    terraform test, mocked providers (no real VMs)
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
├── scripts/                      wait-for-health.sh (used by the k3d smoke test), check-idempotent.sh,
│                                  smoke-k3d.sh, check-oom.sh, urls.sh, test.sh
├── .github/workflows/ci.yml
└── docs/design.md                this spec
```

## 4. Machines (Terraform)

- Provider `larstobi/multipass`, pinned `~> 1.4.3`. Multipass ≥ 1.16 on the host.
- Three instances: `cp-1` (control plane), `worker-1`, `worker-2`; Ubuntu 24.04; 2 vCPU, 3 GiB RAM, 15 GiB disk each.
  About 9 GiB RAM total on a 24 GiB Mac. Sizes are variables.
- `terraform apply` runs with `-parallelism=1` so nodes launch one at a time, and each node carries a precondition
  that fails fast if two nodes end up with the same IP — Multipass 1.16 has been observed handing two concurrently
  launched VMs the same MAC address, which then race for the same DHCP lease.
- cloud-init creates user `ops` with the operator's SSH public key (`var.ssh_public_key_path`, default
  `~/.ssh/homelab_ed25519.pub`; `make keys` generates it if missing). Password login disabled.
- Outputs: each node's IP. A `local_file` resource renders the Ansible inventory from those outputs.
- **State stays local** (`terraform.tfstate`, git-ignored). Justification: the VMs exist only on this Mac, so remote
  state would add a backend with nothing to share. Documented as a deliberate choice in the README.
- `terraform/tests/` exercises the inventory-generation logic with `terraform test` against mocked providers, so the
  node-shape validation and inventory rendering are checked without launching any real VM.

## 5. Configuration (Ansible)

Roles are idempotent: a second `ansible-playbook site.yml` run reports `changed=0`. That is checked in `make test`.

- **common:** apt update + baseline packages; `ops` sudo; sshd `PasswordAuthentication no`, `PermitRootLogin no`;
  ufw default deny incoming, allow 22, 80, 6443, and the k3s inter-node ports (8472/udp flannel, 10250) only from the
  node subnet, plus the k3s pod and service CIDRs (10.42.0.0/16, 10.43.0.0/16) so in-cluster traffic is not
  dropped; unattended-upgrades on.
- **k3s_server:** installs a pinned k3s (`v1.37.1+k3s1`, from group_vars) via the official install script with
  `INSTALL_K3S_VERSION`; keeps the bundled Traefik ingress; fetches the node token and writes the kubeconfig to
  `~/.kube/homelab.yaml` on the Mac, rewriting `127.0.0.1` to cp-1's IP.
- **k3s_agent:** writes the join token to a root-only file (`no_log` only on that write, not on the join command
  itself, which needs its output visible on failure) and joins via `K3S_URL` + `K3S_TOKEN_FILE`, never the token on
  the command line; waits until the node reports `Ready`.
- **monitoring:** Helm via `kubernetes.core.helm`, pinned chart versions: `kube-prometheus-stack` (Prometheus,
  Alertmanager, Grafana, kube-state-metrics) and `loki` (single-binary mode, filesystem storage) + `alloy` (log
  shipper; replaces Promtail, which Grafana deprecated in 2025 — already adopted here). Pinned: kube-prometheus-stack
  91.8.2, loki 7.3.0, alloy 1.13.0. Grafana served at `/grafana` through Traefik with Loki pre-wired as a datasource.
  One extra PrometheusRule: `ContainerOOMKilled` on `kube_pod_container_status_terminated_reason{reason="OOMKilled"}
  == 1` OR the `last_terminated_reason` variant. Both are needed: a Job pod with `restartPolicy: Never` stays in its
  first terminated state and never gets a "last" state, while a restarting Deployment pod only shows the "last" one.
  Grafana's admin credentials come from a pre-created Secret `grafana-admin` — the password is generated once on the
  Mac via the `password` lookup into `.secrets/grafana-admin` (git-ignored) and printed by `make up` — wired into the
  chart with `admin.existingSecret` / `admin.userKey` / `admin.passwordKey`. The password never goes into Helm
  values: `kubernetes.core.helm` would otherwise echo it back in `status.values`, and Ansible would echo it in
  `module_args` if the task ever failed.
- **k8s_tooling (cp-1 only):** installs what the next two roles need on cp-1.
- **Where the Kubernetes tasks run:** the monitoring and ley_khaa roles run **on cp-1**, not on the Mac, using k3s's
  own kubeconfig. cp-1 gets Helm v3.22.0 (Helm 3, not 4, for `kubernetes.core` compatibility) and a venv at
  `/opt/homelab-venv` with `kubernetes==36.0.3` for the `kubernetes.core` modules. The Mac needs only Ansible, not a
  Kubernetes Python stack. Manifests are copied to cp-1 and applied with `k3s kubectl apply -k`.
- **ley_khaa:** creates the `ley-khaa` namespace and `ley-khaa-db` Secret with `kubernetes.core.k8s`, then applies
  `k8s/ley-khaa/` with `k3s kubectl apply -k` and waits for rollouts. `changed_when` is gated on `kubectl diff`'s
  exit code rather than `apply`'s own output: the postgres StatefulSet's `volumeClaimTemplates` pick up server-side
  defaulted fields that never appear in the last-applied-configuration annotation `apply` diffs against, so `apply`
  always prints "configured" even with no real change (kubernetes/kubernetes#73743); `kubectl diff` isn't affected.

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
each. Before applying, `scripts/check-oom.sh` deletes any previous run's Job with `--cascade=foreground` (blocks
until its pods are gone too, not just the Job object), so a stale pod can never be mistaken for this run's; the pod
is then selected by the new Job's `controller-uid` label, not just its `app` label, so a label query can't pick up a
leftover pod either. Expected and checked by `scripts/check-oom.sh`:

1. Pod `terminated.reason == OOMKilled` (via kubectl jsonpath).
2. Prometheus alert `ContainerOOMKilled` firing (Prometheus HTTP API, polled up to 3 minutes).
3. After `kubectl delete job`, a Loki query scoped to this run's pod — `{namespace="demo", pod="<pod>"} |=
   "allocated"` — still returns the log lines.

A dedicated Job rather than starving ley-khaa: the demo must behave the same every time.

## 8. CI (homelab, `.github/workflows/ci.yml`, every PR and push to main)

- `terraform fmt -check -recursive`, `terraform init -backend=false && terraform validate`, `terraform test`
- Python 3.12 via `actions/setup-python@v5`, then `pip install yamllint`, `pip install ansible-core ansible-lint`
- Collections installed with `ansible-galaxy collection install -r ansible/requirements.yml`
- `ansible-lint`, `yamllint`
- `kubeconform -strict` on `kubectl kustomize k8s/ley-khaa` and `k8s/demo`
- **k3d smoke test:** create a k3d cluster, apply `k8s/ley-khaa/` with the published images, wait for rollouts,
  curl `/api/health` through the ingress → 200. Multipass cannot run on GitHub runners, so the VM and Ansible layers
  are covered by `make test`, not CI. The README says so.

## 9. Operator prerequisites and Makefile

Prerequisites (`make prereqs` checks, does not install): `multipass`, `terraform`, `ansible-playbook`, `kubectl`,
`jq` — Helm and kustomize are not needed on the Mac (role `k8s_tooling` installs Helm on cp-1, and `kubectl` ships
its own kustomize). README gives the install line
(`brew install multipass ansible ansible-lint yamllint kubectl jq kubeconform k3d hashicorp/tap/terraform`;
Terraform left Homebrew core).

| Target | Does |
|---|---|
| `make up` | keys, prereqs, `terraform apply`, `ansible-playbook site.yml`, print URLs + Grafana password |
| `make down` | `terraform destroy -auto-approve`, then deletes `cp-1`/`worker-1`/`worker-2` directly — removes the lab's VMs even if Terraform's state lost track of them, without touching any other Multipass instance |
| `make verify` | runs `ansible/verify.yml`: node hardening, cluster health, and the `/api/health` / Grafana / Loki / Prometheus assertions behind success criterion 1 |
| `make idempotency` | re-runs `site.yml` and fails if any host reports `changed` (§5) |
| `make test` | up → idempotency → verify → oom-demo → down; non-zero on any failure; `KEEP=1` skips the teardown |
| `make oom-demo` | §7 |
| `make smoke` | runs the k3d smoke test locally (`scripts/smoke-k3d.sh`), the same one CI runs (§8) |
| `make urls` | prints ley-khaa's and Grafana's URLs, plus the Grafana password once generated |
| `make lint` | the CI static checks locally |
| `make status` | `multipass list` + `kubectl get nodes,pods -A` |

Stock GNU make 3.81 (macOS default) has no `.ONESHELL`; every recipe line runs as its own independent shell, so each
line must be self-contained. Multi-line logic lives in `scripts/*.sh` with `set -euo pipefail`; a recipe line
containing a pipe starts with `set -o pipefail;` so a failure upstream of the pipe isn't silently swallowed.

## 10. Risks

- **Community Multipass provider** may lag Multipass releases. Mitigation: pinned versions; if it breaks, fallback is
  a `terraform_data` + `local-exec` wrapper around the `multipass` CLI, keeping the same outputs and inventory.
- **arm64 images:** VMs on Apple silicon are arm64, so GHCR images must be multi-arch; the release workflow builds both.
- **Memory pressure — resolved:** 2 GiB nodes weren't enough headroom. A normal Grafana rolling update briefly runs
  two `kps-grafana` pods (each with 2 extra sidecar containers) side by side, and on a 2 GiB node that tipped cp-1
  into an OOM kill. Node size was raised to 3 GiB (`var.memory`, ~9 GiB total) after that evidenced failure.
- **Multipass MAC/IP collision:** Multipass 1.16 has been observed handing two concurrently launched VMs the same
  MAC address, which then race for the same DHCP lease. Mitigation: `terraform apply -parallelism=1` launches nodes
  one at a time, and each node carries a precondition that fails fast if two nodes still end up with the same IP —
  the fix is to `make down` and retry.
- **Colima + Multipass coexistence:** both use macOS virtualization; they run side by side on this Mac.
- `make down` only ever deletes the lab's three named VMs (`cp-1`, `worker-1`, `worker-2`); it never runs a
  host-wide `multipass purge` and so never touches an unrelated Multipass instance.

## 11. What this demonstrates

Only what `make test` has verified on this Mac: Terraform-provisioned VMs, Ansible roles for hardening and k3s,
Helm-installed Prometheus/Grafana/Loki, a containerised app deployed to Kubernetes from GHCR, multi-arch image
release via GitHub Actions, and a reproducible OOMKilled-to-logs investigation.

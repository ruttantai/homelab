# HPC stack: an elastic Slurm cluster beside the k3s lab — design

*Agreed in conversation 2026-10-12; this file awaits review.*

## 1. Purpose

Add a small, honest HPC cluster to the homelab: Slurm with shared storage, a Spack-built module stack, Prometheus
and Grafana monitoring, and compute nodes that Slurm powers on and off with demand. It is evidence for the
administration side of research computing (scheduler, modules, node lifecycle, monitoring), built and tested the
same way as the k3s lab.

The elastic part mirrors the shape of a cloud Slurm cluster (nodes exist only while there is work), using Slurm's
own power-saving mechanism. The difference is stated plainly in the README: a cloud resume script creates an
instance; this lab starts a stopped VM.

**Success criteria**

1. `make hpc-up` builds the HPC stack from nothing; `make hpc-verify` passes (§7.1).
2. `make elastic-demo` shows both compute nodes powered off, woken by a submitted job, the job `COMPLETED`, and the
   nodes powered off again, and prints the cold-start wait (§7.2).
3. With the k3s stack also up, Prometheus scrapes the Slurm exporter and the Grafana dashboard and two alert rules
   are loaded.
4. `make hpc-test` runs build → idempotency → verify → elastic demo → teardown, exiting non-zero on any failure.
5. CI stays VM-free and green, with the new static checks and power-API unit tests (§7.4).
6. `make hpc-down` leaves no HPC VM and no power-API process behind.

**Out of scope:** GPUs (no NVIDIA hardware on the host), Open OnDemand, slurmdbd / accounting / fair-share,
Apptainer, EasyBuild, LDAP or multi-user accounts, creating instances on demand (nodes are created once, then
stopped and started), real cloud providers.

## 2. Architecture

```
Mac (host)
 ├─ power-api (Python stdlib)   bound to the Multipass bridge IP only; bearer token;
 │                              start | stop | ip for names matching ^hpc-node-\d+$
 ├─ k3s stack (unchanged)       cp-1, worker-1, worker-2 — Prometheus/Grafana/Loki, ley-khaa
 └─ HPC stack (new)
     ├─ hpc-head    slurmctld · NFS server (/home, /opt/spack) · Spack + Lmod · slurm exporter
     │              ResumeProgram / SuspendProgram → curl power-api
     ├─ hpc-node-1  slurmd · NFS client   ┐ created once by Terraform,
     └─ hpc-node-2  slurmd · NFS client   ┘ then stopped / started by Slurm power saving
```

The split from the existing design still holds: **Terraform owns what exists, Ansible owns what is on it.** The
power API is the one new piece on the host; it never creates or destroys a VM, only starts and stops existing ones.

The two stacks are independent. The HPC stack runs alone (~4.5 GiB RAM). Monitoring (§6) needs both stacks up
(~14 GiB of the host's 24 GiB).

## 3. Machines (Terraform)

- A **separate root module, `terraform/hpc/`, with its own local state**, so `make down` (k3s) and `make hpc-down`
  can never destroy each other's VMs. It reuses `../cloud-init.yaml.tftpl`; no change to the existing module.
- Variable `hpc_nodes` (name ⇒ role, roles `head` | `compute`; exactly one `head`), default
  `hpc-head = head`, `hpc-node-1 = compute`, `hpc-node-2 = compute`.
- New variables `hpc_cpus` (2), `hpc_memory` (`1536M`), `hpc_disk` (`15G`). Spack builds on `hpc-head`, which gets
  `hpc_head_memory` (`2G`).
- `multipass_instance.hpc` with the same image, cloud-init and `-parallelism=1` launch as the k3s nodes, and the
  same duplicate-IP precondition on its own inventory output.
- A **second inventory file**, `ansible/inventory/hpc.yml` (generated, git-ignored), with groups `hpc_head` and
  `hpc_compute` under parent `hpc`. The k3s inventory is untouched.
- Targets: `make hpc-infra` runs `terraform -chdir=terraform/hpc apply`; `make hpc-down` destroys that state, stops
  the power API, and purges the three HPC names (mirroring `make down`). `make lint` and CI also cover
  `terraform/hpc` (fmt, validate, test).

## 4. Configuration (Ansible)

New playbook `ansible/site-hpc.yml`; `site.yml` is not changed. Pinned versions go in `group_vars/all.yml`.

| Role | Hosts | Does |
|---|---|---|
| `common` (reused) | hpc | key-only SSH, unattended upgrades, ufw default-deny |
| `hpc_firewall` | hpc | opens, from HPC node IPs only: slurmctld 6817, slurmd 6818, NFS 2049; from cp-1 only: exporter port |
| `munge` | hpc | key generated once on the controller into `.secrets/munge.key` (git-ignored, 0400), copied to every node |
| `nfs` | hpc | head exports `/home` and `/opt/spack` to HPC node IPs; computes mount them via systemd mount units, ordered before `slurmd` |
| `slurm_head` | hpc_head | `slurm-wlm` (Ubuntu 24.04, Slurm 23.11) slurmctld; `slurm.conf` and `cgroup.conf` templated from the inventory |
| `slurm_node` | hpc_compute | `slurmd`, enabled at boot; same `slurm.conf` |
| `spack` | hpc_head | pinned Spack release cloned into `/opt/spack`; `spack install gsl`; Lmod modules generated; `MODULEPATH` set for login shells on all nodes |
| `slurm_power` | hpc_head | resume/suspend scripts in `/usr/local/sbin`, token in `/etc/slurm/power-api.token` (root 0400), log `/var/log/slurm/power.log` |
| `slurm_exporter` | hpc_head | rivosinc `prometheus-slurm-exporter` v1.8.0 arm64 `.deb`, SHA-256 checked against the release checksums file, as a systemd service |

**`slurm.conf` essentials:** one controller (`hpc-head`); nodes defined from the inventory with real CPU/memory
(`RealMemory` a little under the VM size); partitions `short` (default, `MaxTime=00:15:00`) and `long`
(`MaxTime=02:00:00`); `SelectType=select/cons_tres`, `SelectTypeParameters=CR_Core_Memory`;
`TaskPlugin=task/cgroup,task/affinity` with `ConstrainRAMSpace=yes` so `--mem` is enforced.

**Power-saving settings:** `SuspendProgram`, `ResumeProgram`, `SuspendTime=120`, `SuspendTimeout=60`,
`ResumeTimeout=300`, `ResumeRate=0`, `SuspendRate=0`. Only `hpc-node-*` appear in partitions; the head is never
power-managed.

## 5. Elastic nodes: power API and Slurm scripts

### 5.1 Power API (host)

- `power-api/server.py`, Python standard library only, run by `make power-api-start` in the background with a PID
  file in `.secrets/`; `make power-api-stop` ends it. `hpc-up` starts it **after** Terraform (the bridge interface
  exists only once VMs run) and **before** Ansible.
- Binds to the Multipass bridge address, discovered at start from the host's `bridge100` interface; refuses to start
  if that address is missing. Never binds `0.0.0.0`.
- Endpoints: `POST /start?node=`, `POST /stop?node=`, `GET /ip?node=`. Each needs `Authorization: Bearer <token>`
  (401 otherwise). `node` must match `^hpc-node-\d+$` (400 otherwise).
- Runs only `multipass start|stop|info --format json <node>` via an argument list, never a shell string.
  Returns JSON; `/ip` returns the node's first IPv4 once it has one.
- Token: generated by `make` into `.secrets/power-api.token` (0600) on first run, and copied by Ansible to the head.

### 5.2 Slurm scripts (on `hpc-head`)

- **Resume** (`slurm-resume`, arguments: Slurm host list): expands it with `scontrol show hostnames`; for each node
  calls `/start`, polls `/ip` until an address appears (bounded by the remaining `ResumeTimeout`), then runs
  `scontrol update NodeName=<n> NodeAddr=<ip> NodeHostname=<n>` because Multipass may lease a new address after a
  restart. Logs every step with a timestamp; exits non-zero on any failed call.
- **Suspend** (`slurm-suspend`): expands the host list and calls `/stop` for each node; logs the same way.
- Compute-node boot order (systemd): network → NFS mounts → munge → slurmd. `slurmd` registers itself; Slurm starts
  the job.

### 5.3 Failure behaviour

| Failure | What happens | How it is seen |
|---|---|---|
| Node does not register within `ResumeTimeout` | Slurm marks it `DOWN` and requeues the job | "node down" alert; `power.log` |
| Power API not running | resume script logs the curl error and exits non-zero → same timeout path | same, plus the log line names the cause |
| Recovery | `scontrol update NodeName=<n> State=RESUME` | README runbook |

## 6. Monitoring (extends the existing `monitoring` role)

- kube-prometheus-stack gains an additional scrape job for the exporter on `hpc-head`. The target address comes from
  the HPC inventory when it exists, so the k3s stack still deploys when the HPC stack is absent (the job is simply
  omitted).
- Grafana dashboard as a ConfigMap labelled for the Grafana sidecar: nodes by state (including powered-down), pending
  and running jobs, CPU allocation, job completions vs failures.
- `PrometheusRule` with two alerts:
  - **SlurmNodeUnavailable**: a node is `down` or `drain` for 2 minutes. Powered-down (`idle~`) is a normal state
    and must not fire it.
  - **SlurmJobsFailing**: any failed jobs counted in the last 15 minutes.
- Exact metric names are taken from the pinned exporter's output during implementation and asserted in verify.

## 7. Testing

### 7.1 `make hpc-verify` (`ansible/verify-hpc.yml`)

1. Munge: a credential made on `hpc-head` decodes on each compute node.
2. `sinfo` lists partitions `short` and `long` and both compute nodes.
3. `srun -N2 hostname` returns two distinct hostnames (also exercises resume when nodes are off).
4. NFS: a file written to `/home` on one compute node is read on the other.
5. Modules: on a compute node, `module load gsl` succeeds and a small C program compiled against GSL runs.
6. Memory enforcement: a job that allocates beyond its `--mem` ends in state `OUT_OF_MEMORY`.
7. Exporter: the metrics endpoint answers on `hpc-head`; when k3s is up, the Prometheus target is `up` and both rules
   are loaded.

### 7.2 `make elastic-demo` (`scripts/check-elastic.sh`)

Waits for both nodes to be `idle~` and `Stopped` in `multipass list`; submits a job; asserts the node reaches
running within 300 s and the job ends `COMPLETED`; waits for suspend; asserts both are stopped again. Prints the
cold-start wait and the time to power-down.

### 7.3 `make hpc-test` (`scripts/hpc-test.sh`)

Clean `hpc-up` → second `site-hpc.yml` run must report `changed=0` (reuse `check-idempotent.sh`, parameterised by
playbook) → `hpc-verify` → `elastic-demo` → `hpc-down`. `KEEP=1` skips teardown.

### 7.4 CI (no VMs)

- `terraform test`: mocked-provider cases for `hpc_nodes` validation (exactly one head) and the `hpc.yml` inventory
  render.
- yamllint and ansible-lint over the new roles and playbooks.
- `pytest` for the power API with `multipass` mocked: missing/wrong token → 401; bad names (`cp-1`,
  `hpc-node-1; rm -rf /`, empty) → 400; each endpoint calls the exact argument list expected.
- `shellcheck` on the resume/suspend and new test scripts.
- kubeconform on the dashboard ConfigMap and the `PrometheusRule`.

## 8. Documentation

- README: an HPC section with the diagram, the commands, the RAM note, the runbook (resume a `DOWN` node, read
  `power.log`), and the honest-limits paragraph (§1 out-of-scope list, "starts a stopped VM, does not create one").
- `docs/design.md`: a short HPC section pointing to this spec and recording what shipped.

## 9. Risks

- **Multipass leases a new IP after restart.** Handled by the resume script's `NodeAddr` update (§5.2).
- **Spack build time / memory on a 2 GiB head.** GSL is small; if the build is OOM-killed the head's memory variable
  is raised, as was done for the k3s nodes.
- **Exporter compatibility with Slurm 23.11.** Verified in implementation against real output; if it fails, the
  fallback is the previous exporter release, decided then and recorded here.
- **Bridge interface name** (`bridge100`) differs on some hosts. The start target fails with a clear message rather
  than binding wider.

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

## HPC stack (Slurm)

A second, independent stack: a small **Slurm** cluster whose compute nodes power on when work is queued and off
when idle. It is the same mechanism a cloud HPC cluster uses to add and remove nodes. It uses the same split as above:
Terraform creates the VMs (`terraform/hpc/`, its own state), Ansible configures them (`ansible/site-hpc.yml`).

```
Mac (host)
 ├─ power-api (Python stdlib)   bound to the Multipass network address only; bearer token;
 │                              start | stop | ip, only for names matching hpc-node-<number>
 └─ HPC stack
     ├─ hpc-head    slurmctld · NFS (/shared, /opt/spack) · Spack + Lmod · Slurm exporter
     │              ResumeProgram / SuspendProgram → curl power-api
     ├─ hpc-node-1  slurmd · NFS client   ┐ created once by Terraform,
     └─ hpc-node-2  slurmd · NFS client   ┘ then stopped / started by Slurm power saving
```

```bash
make hpc-up            # VMs, power API, Slurm, munge, NFS, Spack-built GSL module
make hpc-verify        # partitions, a 2-node srun, shared storage, --mem enforced, GSL module compiles and runs
make elastic-demo      # nodes off → a job wakes them → COMPLETED → nodes off again
make hpc-test          # all of the above from scratch, plus an idempotency re-run with the nodes powered off
make hpc-monitoring    # Slurm exporter into the k3s Prometheus/Grafana (needs `make up` too)
make hpc-down          # deletes only the three hpc-* VMs and stops the power API
```

Needs about 4.5 GiB free RAM alone, about 14 GiB with the k3s stack (for monitoring).
Keep the Mac awake while it runs: a sleeping Mac freezes the VMs and Slurm's timers with them.

**How a job wakes a node.** Nodes idle for 120 s are suspended: Slurm runs `slurm-suspend`, which asks the power API
to `multipass stop` them. A job that needs them makes Slurm run `slurm-resume`, which starts each VM through the API,
waits for its address, and tells Slurm that address (`scontrol update NodeAddr=…`), because a restarted VM can lease
a new IP. slurmd registers, and the job runs. On this Mac a 2-node job waited **70–83 s** for cold nodes (two runs), and the
nodes were powered off again about **3 minutes** after it completed. `make hpc-configure` first pins every node on
(`SuspendExcNodes`) so Ansible can reach them, then hands them back to power saving.

**Runbook: a node is `down~`.**
1. `multipass exec hpc-head -- sudo tail /var/log/slurm/power.log`: a `start FAILED` line and a curl error mean the
   power API was not reachable (Mac asleep, process stopped).
2. `make power-api-start`.
3. Wait until `sinfo -N` shows the node as `down~` (Slurm marks it down after `ResumeTimeout`, 300 s; until then it
   refuses the next step), then
   `multipass exec hpc-head -- sudo scontrol update NodeName=<node> State=RESUME`. The node goes back to `idle~`.
   Jobs that were waiting were requeued meanwhile and run on whichever node comes up.
4. A node stuck in `idle#` (powering up) whose VM is already running was started outside Slurm. Slurm waits for a
   boot that happens after its power-up request, so reboot that node.

**Limits, honestly.** No GPUs, no accounting or fair-share (no slurmdbd; finished jobs are in the jobcomp log and
visible for 10 minutes), no Open OnDemand, no Apptainer or EasyBuild, one user. Nodes are started, not created: the
Slurm side is the same as a cloud cluster's, but a cloud resume script creates an instance where this one starts a
stopped VM. HPC spec and plan: `docs/superpowers/specs/2026-10-12-hpc-slurm-design.md`,
`docs/superpowers/plans/2026-10-12-hpc-slurm.md`.

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

Design spec: `docs/design.md`.

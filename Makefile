# Works with GNU make 3.81 (macOS default): no .ONESHELL, no .SHELLFLAGS (3.81 ignores both).
# Recipe lines are independent shells - each line must be self-contained. Anything multi-line
# goes in scripts/*.sh with `set -euo pipefail`; a line containing a pipe starts with
# `set -o pipefail;` so a failure upstream of the pipe isn't swallowed.
SHELL := /bin/bash
.DEFAULT_GOAL := help

TF := terraform -chdir=terraform
TF_HPC := terraform -chdir=terraform/hpc
HPC_VMS := hpc-head hpc-node-1 hpc-node-2
SSH_KEY := $(HOME)/.ssh/homelab_ed25519
export KUBECONFIG := $(HOME)/.kube/homelab.yaml
export ANSIBLE_CONFIG := $(CURDIR)/ansible/ansible.cfg

.PHONY: help prereqs keys lint infra down collections configure verify idempotency smoke urls oom-demo up status test power-api-test hpc-infra hpc-down hpc-configure hpc-verify hpc-idempotency power-api-token power-api-start power-api-stop hpc-hold hpc-release elastic-demo hpc-up hpc-monitoring hpc-monitoring-verify

help:
	@echo "make up | down | test | oom-demo | status | lint | prereqs"

prereqs:
	@for t in multipass terraform ansible-playbook kubectl jq; do command -v $$t >/dev/null || { echo "missing: $$t (see README)"; exit 1; }; done; echo "prereqs ok"

keys:
	test -f $(SSH_KEY) || ssh-keygen -q -t ed25519 -N '' -C homelab -f $(SSH_KEY)

# Multipass 1.16 gave two concurrently launched VMs the same MAC address (-> DHCP IP collision);
# -parallelism=1 launches nodes one at a time to avoid it.
infra: keys
	$(TF) init -input=false
	$(TF) apply -auto-approve -input=false -parallelism=1

# terraform destroy only touches what state records; the loop below also removes
# cp-1/worker-1/worker-2 (names mirror var.nodes in terraform/variables.tf) even
# when Terraform's state lost track of them, without touching any other VM.
down:
	$(TF) init -input=false >/dev/null
	$(TF) destroy -auto-approve -input=false
	for n in cp-1 worker-1 worker-2; do multipass delete --purge $$n >/dev/null 2>&1 || true; done

lint:
	yamllint .
	terraform fmt -check -recursive terraform
	$(TF) init -backend=false -input=false >/dev/null
	$(TF) validate
	$(TF) test
	$(TF_HPC) init -backend=false -input=false >/dev/null
	$(TF_HPC) validate
	$(TF_HPC) test
	cd ansible && ansible-lint
	set -o pipefail; kubectl kustomize k8s/ley-khaa | kubeconform -strict -summary -
	kubeconform -strict -summary k8s/demo
	shellcheck scripts/*.sh ansible/roles/slurm_power/files/slurm-power
	scripts/test-slurm-power.sh
	scripts/test-hpc-lib.sh
	promtool check rules monitoring/slurm/slurm-rules.yaml
	promtool test rules monitoring/slurm/slurm-rules.test.yaml
	python3 -m json.tool monitoring/slurm/slurm-dashboard.json >/dev/null
	$(MAKE) power-api-test

# The power API is stdlib-only; pytest is a test-time dependency, kept in its own venv.
power-api-test:
	test -x .venv/bin/pytest || { python3 -m venv .venv && .venv/bin/pip install -q -r power-api/requirements-dev.txt; }
	.venv/bin/pytest -q power-api/tests

# --force: the full "ansible" package (vs. ansible-core) bundles its own copies of
# community.general/ansible.posix: without --force, ansible-galaxy sees a version-
# satisfying collection already present elsewhere and skips it, so it never lands
# under ansible/collections and ansible-lint can't resolve its modules.
collections:
	cd ansible && ansible-galaxy collection install -r requirements.yml -p collections --force >/dev/null

configure: collections
	cd ansible && ansible-playbook site.yml

verify: collections
	cd ansible && ansible-playbook verify.yml

idempotency:
	scripts/check-idempotent.sh

smoke:
	scripts/smoke-k3d.sh

urls:
	scripts/urls.sh

oom-demo:
	scripts/check-oom.sh

up: prereqs infra configure urls

status:
	multipass list
	kubectl get nodes -o wide
	kubectl get pods -A

# Clean build -> idempotent re-run -> assertions -> OOM demo -> teardown.
# KEEP=1 skips the teardown so a failure can be inspected.
test:
	KEEP=$(KEEP) scripts/test.sh

# Separate state from the k3s module (spec §3), so neither stack's down can destroy the other.
hpc-infra: keys
	$(TF_HPC) init -input=false
	$(TF_HPC) apply -auto-approve -input=false -parallelism=1

hpc-down:
	scripts/power-api.sh stop
	$(TF_HPC) init -input=false >/dev/null
	$(TF_HPC) destroy -auto-approve -input=false
	for n in $(HPC_VMS); do multipass delete --purge $$n >/dev/null 2>&1 || true; done

# The hold step wakes powered-off nodes through the power API, so it must be running (Review Focus 5).
hpc-configure: collections power-api-start
	scripts/hpc-run.sh configure

hpc-verify: collections
	scripts/hpc-run.sh verify

hpc-idempotency: collections
	scripts/hpc-run.sh idempotency

power-api-token:
	test -s .secrets/power-api.token || { umask 077; mkdir -p .secrets; openssl rand -hex 32 > .secrets/power-api.token; }

power-api-start: power-api-token
	scripts/power-api.sh start

power-api-stop:
	scripts/power-api.sh stop

hpc-hold:
	scripts/hpc-hold.sh hold

hpc-release:
	scripts/hpc-hold.sh release

elastic-demo:
	scripts/check-elastic.sh

hpc-up: prereqs hpc-infra power-api-start hpc-configure

# Needs both stacks up (spec §6): about 14 GiB of RAM.
hpc-monitoring: collections
	cd ansible && ansible-playbook -i inventory/hosts.yml -i inventory/hpc.yml monitoring-hpc.yml

hpc-monitoring-verify: collections
	cd ansible && ansible-playbook -i inventory/hosts.yml -i inventory/hpc.yml verify-hpc-monitoring.yml

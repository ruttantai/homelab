# Works with GNU make 3.81 (macOS default): no .ONESHELL, no .SHELLFLAGS (3.81 ignores both).
# Recipe lines are independent shells - each line must be self-contained. Anything multi-line
# goes in scripts/*.sh with `set -euo pipefail`; a line containing a pipe starts with
# `set -o pipefail;` so a failure upstream of the pipe isn't swallowed.
SHELL := /bin/bash
.DEFAULT_GOAL := help

TF := terraform -chdir=terraform
SSH_KEY := $(HOME)/.ssh/homelab_ed25519
export KUBECONFIG := $(HOME)/.kube/homelab.yaml
export ANSIBLE_CONFIG := $(CURDIR)/ansible/ansible.cfg

.PHONY: help prereqs keys lint infra down collections configure verify idempotency smoke urls oom-demo up status test power-api-test

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
	cd ansible && ansible-lint
	set -o pipefail; kubectl kustomize k8s/ley-khaa | kubeconform -strict -summary -
	kubeconform -strict -summary k8s/demo
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

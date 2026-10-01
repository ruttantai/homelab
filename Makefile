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

.PHONY: help prereqs keys lint infra down

help:
	@echo "make up | down | test | oom-demo | status | lint | prereqs"

prereqs:
	@for t in multipass terraform ansible-playbook kubectl jq; do command -v $$t >/dev/null || { echo "missing: $$t (see README)"; exit 1; }; done; echo "prereqs ok"

keys:
	test -f $(SSH_KEY) || ssh-keygen -q -t ed25519 -N '' -C homelab -f $(SSH_KEY)

infra: keys
	$(TF) init -input=false
	$(TF) apply -auto-approve -input=false

# Works even after a half-finished `up`: destroy only touches what state records.
down:
	$(TF) init -input=false >/dev/null
	$(TF) destroy -auto-approve -input=false
	multipass purge

lint:
	yamllint .
	terraform fmt -check -recursive terraform
	$(TF) init -backend=false -input=false >/dev/null
	$(TF) validate
	$(TF) test

# Every recipe runs in bash with -euo pipefail, so a failing step stops the target.
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.ONESHELL:
.DEFAULT_GOAL := help

TF := terraform -chdir=terraform
SSH_KEY := $(HOME)/.ssh/homelab_ed25519
export KUBECONFIG := $(HOME)/.kube/homelab.yaml
export ANSIBLE_CONFIG := $(CURDIR)/ansible/ansible.cfg

.PHONY: help prereqs keys lint

help:
	@echo "make up | down | test | oom-demo | status | lint | prereqs"

prereqs:
	for t in multipass terraform ansible-playbook kubectl jq; do
	  command -v $$t >/dev/null || { echo "missing: $$t (see README)"; exit 1; }
	done
	echo "prereqs ok"

keys:
	test -f $(SSH_KEY) || ssh-keygen -q -t ed25519 -N '' -C homelab -f $(SSH_KEY)

lint:
	yamllint .

# shellcheck shell=bash
# Sourced by the HPC scripts. Runs commands on hpc-head over SSH, as Ansible does.
# Not `multipass exec`: on macOS (Multipass 1.16.4) it can hang for good when its stdout is not a
# terminal or pipe, or when the remote command prints nothing (found while building Task 6).
HPC_SSH_KEY=${HPC_SSH_KEY:-$HOME/.ssh/homelab_ed25519}

hpc_head_ip() {
  if [ -z "${HPC_HEAD_IP:-}" ]; then
    HPC_HEAD_IP=$(terraform -chdir=terraform/hpc output -raw head_ip)
  fi
  echo "$HPC_HEAD_IP"
}

# ssh joins its arguments into one string for the remote shell, so quote each one first.
on_head() {
  local ip
  ip=$(hpc_head_ip)
  # Host keys change on every rebuild (see ansible/ansible.cfg); this is a throwaway local lab.
  ssh -i "$HPC_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "ops@$ip" "$(printf '%q ' "$@")" </dev/null
}

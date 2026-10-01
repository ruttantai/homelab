variable "nodes" {
  description = "Instance name => k3s role. Exactly one 'server'; the rest 'agent'."
  type        = map(string)
  default = {
    "cp-1"     = "server"
    "worker-1" = "agent"
    "worker-2" = "agent"
  }

  validation {
    condition = (
      length([for r in values(var.nodes) : r if r == "server"]) == 1 &&
      alltrue([for r in values(var.nodes) : contains(["server", "agent"], r)])
    )
    error_message = "nodes needs exactly one \"server\"; every other node must be \"agent\"."
  }
}

variable "cpus" {
  description = "vCPUs per node."
  type        = number
  default     = 2
}

variable "memory" {
  # 2G was not enough headroom: a normal Grafana rolling update briefly runs
  # two kps-grafana pods (each with 2 extra sidecar containers) side by side,
  # and on a 2 GiB node that tipped cp-1 into an OOM kill (spec §10 fallback).
  description = "RAM per node, Multipass size syntax."
  type        = string
  default     = "3G"
}

variable "disk" {
  description = "Disk per node, Multipass size syntax."
  type        = string
  default     = "15G"
}

variable "image" {
  description = "Ubuntu release for every node."
  type        = string
  default     = "24.04"
}

variable "ssh_public_key_path" {
  description = "Public key installed for the ops user. `make keys` creates the default."
  type        = string
  default     = "~/.ssh/homelab_ed25519.pub"
}

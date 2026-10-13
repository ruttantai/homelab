variable "hpc_nodes" {
  description = "Instance name => role. Exactly one 'head'; computes must be named hpc-node-<n> (the power API's rule)."
  type        = map(string)
  default = {
    "hpc-head"   = "head"
    "hpc-node-1" = "compute"
    "hpc-node-2" = "compute"
  }

  validation {
    condition = (
      length([for r in values(var.hpc_nodes) : r if r == "head"]) == 1 &&
      alltrue([for r in values(var.hpc_nodes) : contains(["head", "compute"], r)]) &&
      alltrue([for n, r in var.hpc_nodes : can(regex("^hpc-node-[0-9]+$", n)) if r == "compute"])
    )
    error_message = "hpc_nodes needs exactly one \"head\"; every other node must be \"compute\" and named hpc-node-<number>."
  }
}

variable "cpus" {
  description = "vCPUs per HPC node. Slurm's CPUs= in slurm.conf must match (ansible/group_vars/all.yml)."
  type        = number
  default     = 2
}

variable "memory" {
  description = "RAM per compute node. Slurm's RealMemory is set a little below this."
  type        = string
  default     = "1536M"
}

variable "head_memory" {
  description = "RAM for hpc-head, which also builds Spack packages."
  type        = string
  default     = "2G"
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

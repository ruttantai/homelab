output "node_ips" {
  description = "HPC node name => IPv4."
  value       = { for n, i in multipass_instance.hpc : n => i.ipv4 }
}

output "head_ip" {
  description = "hpc-head's IPv4 (slurmctld, NFS, Spack, the Slurm exporter)."
  value       = one([for n, r in var.hpc_nodes : multipass_instance.hpc[n].ipv4 if r == "head"])
}

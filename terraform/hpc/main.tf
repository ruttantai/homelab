locals {
  ssh_public_key  = trimspace(file(pathexpand(var.ssh_public_key_path)))
  ssh_private_key = pathexpand(trimsuffix(var.ssh_public_key_path, ".pub"))
}

# Same cloud-init as the k3s nodes (creates the ops user); rendered here because the provider takes a file path.
resource "local_file" "cloud_init" {
  filename        = "${path.module}/cloud-init.rendered.yaml"
  content         = templatefile("${path.module}/../cloud-init.yaml.tftpl", { ssh_public_key = local.ssh_public_key })
  file_permission = "0600"
}

resource "multipass_instance" "hpc" {
  for_each = var.hpc_nodes

  name           = each.key
  image          = var.image
  cpus           = var.cpus
  memory         = each.value == "head" ? var.head_memory : var.memory
  disk           = var.disk
  cloudinit_file = local_file.cloud_init.filename
}

# The hand-off to Ansible; a separate file so the k3s inventory (hosts.yml) is never touched.
resource "local_file" "inventory" {
  filename        = "${path.module}/../../ansible/inventory/hpc.yml"
  file_permission = "0644"
  content = templatefile("${path.module}/inventory.tftpl", {
    heads           = { for n, r in var.hpc_nodes : n => multipass_instance.hpc[n].ipv4 if r == "head" }
    computes        = { for n, r in var.hpc_nodes : n => multipass_instance.hpc[n].ipv4 if r == "compute" }
    ssh_private_key = local.ssh_private_key
  })

  # Same Multipass 1.16 MAC/IP collision guard as the k3s module.
  lifecycle {
    precondition {
      condition     = length(distinct(values({ for n, i in multipass_instance.hpc : n => i.ipv4 }))) == length(var.hpc_nodes)
      error_message = "Multipass assigned duplicate IPs to two or more HPC nodes; run `make hpc-down` and retry."
    }
  }
}

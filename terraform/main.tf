locals {
  ssh_public_key  = trimspace(file(pathexpand(var.ssh_public_key_path)))
  ssh_private_key = pathexpand(trimsuffix(var.ssh_public_key_path, ".pub"))
}

# The provider takes cloud-init as a file path, so render it to disk first.
resource "local_file" "cloud_init" {
  filename        = "${path.module}/cloud-init.rendered.yaml"
  content         = templatefile("${path.module}/cloud-init.yaml.tftpl", { ssh_public_key = local.ssh_public_key })
  file_permission = "0600"
}

resource "multipass_instance" "node" {
  for_each = var.nodes

  name           = each.key
  image          = var.image
  cpus           = var.cpus
  memory         = var.memory
  disk           = var.disk
  cloudinit_file = local_file.cloud_init.filename
}

# The single hand-off from Terraform to Ansible (spec §2).
resource "local_file" "inventory" {
  filename        = "${path.module}/../ansible/inventory/hosts.yml"
  file_permission = "0644"
  content = templatefile("${path.module}/inventory.tftpl", {
    servers         = { for n, r in var.nodes : n => multipass_instance.node[n].ipv4 if r == "server" }
    agents          = { for n, r in var.nodes : n => multipass_instance.node[n].ipv4 if r == "agent" }
    ssh_private_key = local.ssh_private_key
  })
}

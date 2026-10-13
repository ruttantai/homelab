# Runs with mocked providers: no VMs are created and no files are written.
mock_provider "multipass" {
  mock_resource "multipass_instance" {
    defaults = {
      ipv4 = "192.0.2.20"
    }
  }
}

mock_provider "local" {}

variables {
  ssh_public_key_path = "tests/fixtures/test_key.pub"
}

run "default_hpc_shape" {
  command = apply

  override_resource {
    target = multipass_instance.hpc["hpc-head"]
    values = { ipv4 = "192.0.2.20" }
  }
  override_resource {
    target = multipass_instance.hpc["hpc-node-1"]
    values = { ipv4 = "192.0.2.21" }
  }
  override_resource {
    target = multipass_instance.hpc["hpc-node-2"]
    values = { ipv4 = "192.0.2.22" }
  }

  assert {
    condition     = length(multipass_instance.hpc) == 3
    error_message = "expected a head and two compute nodes"
  }

  assert {
    condition     = join(",", keys(yamldecode(local_file.inventory.content).all.children.hpc.children.hpc_head.hosts)) == "hpc-head"
    error_message = "hpc_head must hold exactly hpc-head"
  }

  assert {
    condition     = join(",", keys(yamldecode(local_file.inventory.content).all.children.hpc.children.hpc_compute.hosts)) == "hpc-node-1,hpc-node-2"
    error_message = "hpc_compute must be hpc-node-1 and hpc-node-2"
  }

  assert {
    condition     = multipass_instance.hpc["hpc-head"].memory == "2G" && multipass_instance.hpc["hpc-node-1"].memory == "1536M"
    error_message = "head gets head_memory, computes get memory"
  }

  assert {
    condition     = endswith(local_file.inventory.filename, "ansible/inventory/hpc.yml")
    error_message = "inventory must be written to ansible/inventory/hpc.yml, never hosts.yml"
  }

  assert {
    condition     = output.head_ip == "192.0.2.20"
    error_message = "head_ip must be hpc-head's address"
  }
}

run "rejects_two_heads" {
  command = plan
  variables {
    hpc_nodes = { "hpc-head" = "head", "hpc-node-1" = "head" }
  }
  expect_failures = [var.hpc_nodes]
}

# The power API only accepts hpc-node-<digits>; a compute named otherwise could never be woken.
run "rejects_compute_names_the_power_api_refuses" {
  command = plan
  variables {
    hpc_nodes = { "hpc-head" = "head", "gpu-1" = "compute" }
  }
  expect_failures = [var.hpc_nodes]
}

run "rejects_duplicate_ips" {
  command         = apply
  state_key       = "rejects_duplicate_ips"
  expect_failures = [local_file.inventory]
}

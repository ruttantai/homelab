# Runs with mocked providers: no VMs are created and no files are written.
mock_provider "multipass" {
  mock_resource "multipass_instance" {
    defaults = {
      ipv4 = "192.0.2.10"
    }
  }
}

mock_provider "local" {}

variables {
  ssh_public_key_path = "tests/fixtures/test_key.pub"
}

run "default_cluster_shape" {
  command = apply

  # The shared mock_provider default gives every instance the same ipv4; override per-node here
  # so the happy path has distinct addresses, the way a real (non-colliding) apply would.
  override_resource {
    target = multipass_instance.node["cp-1"]
    values = {
      ipv4 = "192.0.2.10"
    }
  }

  override_resource {
    target = multipass_instance.node["worker-1"]
    values = {
      ipv4 = "192.0.2.11"
    }
  }

  override_resource {
    target = multipass_instance.node["worker-2"]
    values = {
      ipv4 = "192.0.2.12"
    }
  }

  assert {
    condition     = length(multipass_instance.node) == 3
    error_message = "expected three nodes"
  }

  assert {
    condition     = strcontains(local_file.inventory.content, "k3s_server:") && strcontains(local_file.inventory.content, "k3s_agent:")
    error_message = "inventory must define k3s_server and k3s_agent groups"
  }

  assert {
    condition     = length(yamldecode(local_file.inventory.content).all.children.k3s_server.hosts) == 1
    error_message = "exactly one server in the inventory"
  }

  assert {
    condition     = join(",", keys(yamldecode(local_file.inventory.content).all.children.k3s_agent.hosts)) == "worker-1,worker-2"
    error_message = "workers must be worker-1 and worker-2"
  }

  assert {
    condition     = strcontains(local_file.cloud_init.content, "FakeKeyForTerraformTests")
    error_message = "cloud-init must carry the operator's public key"
  }

  assert {
    condition     = output.server_ip == "192.0.2.10"
    error_message = "server_ip output must be cp-1's address"
  }
}

run "rejects_two_servers" {
  command = plan

  variables {
    nodes = { "a" = "server", "b" = "server" }
  }

  expect_failures = [var.nodes]
}

run "rejects_duplicate_ips" {
  command = apply

  # Its own state, so this doesn't inherit cp-1/worker-1/worker-2's distinct IPs from
  # default_cluster_shape's already-applied state above. No override_resource here: every
  # instance keeps the shared mock_provider default ipv4 (192.0.2.10), reproducing the
  # Multipass 1.16 MAC/IP collision seen in the real apply.
  state_key = "rejects_duplicate_ips"

  expect_failures = [local_file.inventory]
}

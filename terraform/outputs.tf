output "node_ips" {
  description = "Node name => IPv4."
  value       = { for n, i in multipass_instance.node : n => i.ipv4 }
}

output "server_ip" {
  description = "The control-plane node's IPv4; ley-khaa and Grafana are served here."
  value       = one([for n, r in var.nodes : multipass_instance.node[n].ipv4 if r == "server"])
}

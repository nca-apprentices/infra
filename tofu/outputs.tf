output "node_ipv4" {
  description = "Public address of the first node. `mise run bootstrap` reaches Talos and Kubernetes through it."
  value       = hcloud_server.node[0].ipv4_address
}

output "node_ipv4" {
  description = "Public address of the first node. `mise run bootstrap` reaches Talos and Kubernetes through it."
  value       = hcloud_server.node[0].ipv4_address
}

output "cloudflare_name_servers" {
  description = "Name servers to set at Porkbun, the registrar, so Cloudflare answers for the domain."
  value       = cloudflare_zone.main.name_servers
}

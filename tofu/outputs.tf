output "node_ipv4" {
  description = "Public address of the first node. `mise run bootstrap` reaches Talos and Kubernetes through it."
  value       = hcloud_server.node[0].ipv4_address
}

output "cloudflare_name_servers" {
  description = "Name servers to set at Porkbun, the registrar, so Cloudflare answers for the domain."
  value       = cloudflare_zone.main.name_servers
}

output "dnssec_ds" {
  description = "DS record to add at Porkbun, under DNSSEC in the domain's Details."
  value = {
    key_tag     = cloudflare_zone_dnssec.main.key_tag
    algorithm   = cloudflare_zone_dnssec.main.algorithm
    digest_type = cloudflare_zone_dnssec.main.digest_type
    digest      = cloudflare_zone_dnssec.main.digest
  }
}

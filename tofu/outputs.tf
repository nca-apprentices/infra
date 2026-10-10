output "node_ipv4" {
  description = "Public address of the first node. `mise run apply:bootstrap` reaches Talos and Kubernetes through it."
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

output "origin_pull_ca" {
  description = "CA of Cloudflare's client certificate, which Traefik checks. It goes in cluster/platform/manifests/origin-pull-ca.yaml."
  value       = tls_self_signed_cert.origin_pull_ca.cert_pem
}

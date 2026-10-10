# The node's firewall. There is no SSH rule because Talos has no SSH daemon:
# the only management surfaces are the Talos and Kubernetes APIs, reachable
# from the operator's address only. Cloudflare proxies every name on the node,
# see dns.tf, so the web ports take Cloudflare's addresses alone, and port 443
# also wants this zone's client certificate, see origin-pulls.tf.
data "cloudflare_ip_ranges" "main" {}

locals {
  cloudflare_cidrs = concat(
    data.cloudflare_ip_ranges.main.ipv4_cidrs,
    data.cloudflare_ip_ranges.main.ipv6_cidrs,
  )
}

resource "hcloud_firewall" "node" {
  name = "nca"

  # Only ncaleague-prod serves the public. Every other host signs in with
  # GitHub first, see docs/operations.md#apps.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = local.cloudflare_cidrs
  }

  # For Let's Encrypt's HTTP-01 challenges, which arrive through Cloudflare.
  # Traefik serves nothing else on port 80; see cluster/platform/traefik.yaml.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = local.cloudflare_cidrs
  }

  # Talos API and Kubernetes API, until Tailscale is in the image.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "50000"
    source_ips = var.operator_cidrs
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = var.operator_cidrs
  }
}

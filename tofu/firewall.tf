# Phase B: the ruleset for dedicated hardware behind Hetzner Robot. There is no
# SSH rule because Talos has no SSH daemon -- the only management surfaces are
# the Talos and Kubernetes APIs, reachable from the operator's address only.
resource "hcloud_firewall" "node" {
  name = "nca"

  # Open to everyone. Only ncaleague-prod serves the public. Every other host
  # signs in with GitHub first, see docs/operations.md#apps.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # HTTP/3, which Traefik serves on the same port over QUIC.
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # Open to everyone for Let's Encrypt's HTTP-01 challenges. Traefik serves
  # nothing else on port 80; see cluster/platform/traefik.yaml.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "51820"
    source_ips = var.operator_cidrs
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

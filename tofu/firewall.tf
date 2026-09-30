# Phase B: the ruleset for dedicated hardware behind Hetzner Robot. There is no
# SSH rule because Talos has no SSH daemon -- the only management surfaces are
# the Talos and Kubernetes APIs, reachable from the operator's address only.
resource "hcloud_firewall" "node" {
  name = "nca"

  # The apps too, until they are ready for the public. Let's Encrypt can't
  # reach port 80 meanwhile, so certificates don't renew over HTTP-01.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = var.operator_cidrs
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = var.operator_cidrs
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

resource "hcloud_firewall_attachment" "node" {
  firewall_id = hcloud_firewall.node.id
  server_ids  = hcloud_server.node[*].id
}

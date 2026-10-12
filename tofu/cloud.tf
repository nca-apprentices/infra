# Phase A: Hetzner Cloud, official provider, no Robot API. The nodes are cattle
# -- Talos is installed from an image and configured by talosctl, so a node can
# be replaced without anything in this file changing.
resource "hcloud_network" "private" {
  name     = "nca"
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "nodes" {
  network_id   = hcloud_network.private.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.0.1.0/24"
}

# The Talos snapshot that `mise run apply:image` uploads, newest first.
data "hcloud_image" "talos" {
  with_selector     = "os=talos"
  with_architecture = "arm"
  most_recent       = true
}

# The node's public IPv4 address outlives the node, so a replacement keeps the
# address every operator's kubeconfig and talosconfig name.
resource "hcloud_primary_ip" "node" {
  count             = var.node_count
  name              = "nca-${count.index + 1}"
  type              = "ipv4"
  location          = var.location
  auto_delete       = false
  delete_protection = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "hcloud_server" "node" {
  count       = var.node_count
  name        = "nca-${count.index + 1}"
  server_type = var.server_type
  location    = var.location
  image       = data.hcloud_image.talos.id

  # Talos reads its machine configuration from Hetzner user data, so the node
  # boots configured and never sits in maintenance mode. `mise run apply:cloud`
  # generates the file first.
  user_data = file("${path.module}/../talos/clusterconfig/nca-nca-${count.index + 1}.yaml")

  # Attached at creation, so a new node is never reachable without it.
  firewall_ids = [hcloud_firewall.node.id]

  # The node holds etcd and the data volume's only mount, so neither the
  # Console nor a plan may delete or rebuild it. Hetzner wants both alike.
  delete_protection  = true
  rebuild_protection = true

  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.node[count.index].id
    ipv6_enabled = true
  }

  # Fixed, because the talos:config task names this address.
  network {
    network_id = hcloud_network.private.id
    ip         = cidrhost(hcloud_network_subnet.nodes.ip_range, count.index + 2)
  }

  lifecycle {
    # The image is only the installer and the user data only the first
    # configuration. Talos upgrades and config changes go through talosctl, so
    # drift in either must not rebuild a working node. The primary IP counts
    # only when a node is created: reassigning it powers the node off.
    ignore_changes  = [image, user_data, public_net]
    prevent_destroy = true
  }
}

resource "hcloud_volume" "data" {
  count     = var.node_count
  name      = "nca-data-${count.index + 1}"
  size      = 100
  server_id = hcloud_server.node[count.index].id
  format    = "" # Talos formats it; see talos/patch.yaml

  # Every PersistentVolume lives on it.
  delete_protection = true

  lifecycle {
    prevent_destroy = true
  }
}

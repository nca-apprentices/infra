# The apex and a wildcard cover every Ingress host on the one node, so adding a
# service does not mean touching DNS.
resource "porkbun_dns_record" "apex" {
  domain  = var.domain
  name    = ""
  type    = "A"
  content = hcloud_server.node[0].ipv4_address
  ttl     = "600"
}

resource "porkbun_dns_record" "wildcard" {
  domain  = var.domain
  name    = "*"
  type    = "A"
  content = hcloud_server.node[0].ipv4_address
  ttl     = "600"
}

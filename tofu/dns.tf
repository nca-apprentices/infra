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

# jjforge's docs site runs on GitHub Pages, not on the node, so its name
# overrides the wildcard.
resource "porkbun_dns_record" "jjforge_docs" {
  domain  = var.domain
  name    = "jjforge-docs"
  type    = "CNAME"
  content = "nca-apprentices.github.io"
  ttl     = "600"
}

# Proves to GitHub that the org owns the domain, so no other account can
# serve a Pages site under it.
resource "porkbun_dns_record" "github_pages_challenge" {
  domain  = var.domain
  name    = "_github-pages-challenge-nca-apprentices"
  type    = "TXT"
  content = "fd04a41c9035f14e899af6ad3cda94"
  ttl     = "600"
}

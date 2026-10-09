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

# The status page runs on GitHub Pages too, from nca-apprentices/status, so
# it stays up when the node is down.
resource "porkbun_dns_record" "status" {
  domain  = var.domain
  name    = "status"
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

# The same records at Cloudflare, which serves the zone once Porkbun names
# its name servers. Porkbun's go after the switch. Cloudflare proxies the node's
# names, so visitors reach Cloudflare and never the node. GitHub Pages issues
# its certificate only for a name that points at it, so its names aren't
# proxied.
resource "cloudflare_zone" "main" {
  account = { id = var.cloudflare_account_id }
  name    = var.domain
}

locals {
  # TTL 1 means automatic, the only TTL a proxied record takes.
  cloudflare_records = {
    apex = {
      name    = var.domain
      type    = "A"
      proxied = true
      content = hcloud_server.node[0].ipv4_address
    }
    wildcard = {
      name    = "*.${var.domain}"
      type    = "A"
      proxied = true
      content = hcloud_server.node[0].ipv4_address
    }
    jjforge_docs = {
      name    = "jjforge-docs.${var.domain}"
      type    = "CNAME"
      proxied = false
      content = "nca-apprentices.github.io"
    }
    status = {
      name    = "status.${var.domain}"
      type    = "CNAME"
      proxied = false
      content = "nca-apprentices.github.io"
    }
    github_pages_challenge = {
      name    = "_github-pages-challenge-nca-apprentices.${var.domain}"
      type    = "TXT"
      proxied = false
      content = "\"fd04a41c9035f14e899af6ad3cda94\""
    }
  }
}

resource "cloudflare_dns_record" "main" {
  for_each = local.cloudflare_records

  zone_id = cloudflare_zone.main.id
  name    = each.value.name
  type    = each.value.type
  content = each.value.content
  proxied = each.value.proxied
  ttl     = 1
}

# Cloudflare reaches the node over HTTPS and checks its Let's Encrypt
# certificate, as a browser would.
resource "cloudflare_zone_setting" "ssl" {
  zone_id    = cloudflare_zone.main.id
  setting_id = "ssl"
  value      = "strict"
}

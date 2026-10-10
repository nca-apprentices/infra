# Cloudflare serves the zone. Porkbun, the registrar, names its name servers.
# Cloudflare proxies the node's names, so visitors reach Cloudflare and never
# the node. GitHub Pages issues its certificate only for a name that points at
# it, so its names aren't proxied.
resource "cloudflare_zone" "main" {
  account = { id = var.cloudflare_account_id }
  name    = var.domain
}

locals {
  # TTL 1 means automatic, the only TTL a proxied record takes.
  cloudflare_records = {
    # The apex and a wildcard cover every Ingress host on the one node, so
    # adding a service does not mean touching DNS.
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
    # jjforge's docs site runs on GitHub Pages, not on the node, so its name
    # overrides the wildcard.
    jjforge_docs = {
      name    = "jjforge-docs.${var.domain}"
      type    = "CNAME"
      proxied = false
      content = "nca-apprentices.github.io"
    }
    # Proves to GitHub that the org owns the domain, so no other account can
    # serve a Pages site under it.
    github_pages_challenge = {
      name    = "_github-pages-challenge-nca-apprentices.${var.domain}"
      type    = "TXT"
      proxied = false
      content = "\"fd04a41c9035f14e899af6ad3cda94\""
    }
    # The domain sends no mail, so receivers reject any that claims it.
    spf = {
      name    = var.domain
      type    = "TXT"
      proxied = false
      content = "\"v=spf1 -all\""
    }
    dmarc = {
      name    = "_dmarc.${var.domain}"
      type    = "TXT"
      proxied = false
      content = "\"v=DMARC1; p=reject\""
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

# The status page is the Worker from nca-apprentices/status, which runs on
# Cloudflare, so it stays up when the node is down. Cloudflare creates the DNS
# record and the certificate itself.
resource "cloudflare_workers_custom_domain" "status" {
  account_id = var.cloudflare_account_id
  zone_id    = cloudflare_zone.main.id
  hostname   = "status.${var.domain}"
  service    = "status"
}

# Cloudflare reaches the node over HTTPS and checks its Let's Encrypt
# certificate, as a browser would.
resource "cloudflare_zone_setting" "ssl" {
  zone_id    = cloudflare_zone.main.id
  setting_id = "ssl"
  value      = "strict"
}

# Visitors connect with TLS 1.2 or later. Cloudflare's default admits 1.0.
resource "cloudflare_zone_setting" "min_tls_version" {
  zone_id    = cloudflare_zone.main.id
  setting_id = "min_tls_version"
  value      = "1.2"
}

# Browsers that have seen a host once reach it over HTTPS alone, so no
# plaintext request carries a cookie. Without preload, removing the header
# ends this within max_age. Always Use HTTPS stays off: its redirect could take
# Let's Encrypt's HTTP-01 challenges to port 443, where Traefik doesn't serve
# them.
resource "cloudflare_zone_setting" "security_header" {
  zone_id    = cloudflare_zone.main.id
  setting_id = "security_header"
  value = {
    strict_transport_security = {
      enabled            = true
      max_age            = 31536000
      include_subdomains = true
      preload            = false
      nosniff            = true
    }
  }
}

# Blocks an address for 10 seconds once it sends more than 100 requests a
# second, to stop floods before they reach the node. The limit stays high
# because one address can be a whole office behind NAT. The Free plan allows
# this one rule, matched on the path, counted per address in each data center,
# over a fixed 10 second window.
resource "cloudflare_ruleset" "rate_limit" {
  zone_id = cloudflare_zone.main.id
  name    = "Rate limit"
  kind    = "zone"
  phase   = "http_ratelimit"

  rules = [{
    ref         = "flood"
    description = "Block an address that floods the zone"
    expression  = "http.request.uri.path contains \"/\""
    action      = "block"
    ratelimit = {
      characteristics     = ["cf.colo.id", "ip.src"]
      period              = 10
      requests_per_period = 1000
      mitigation_timeout  = 10
    }
  }]
}

# Signs the zone. The DS record that `dnssec_ds` shows goes to Porkbun, which
# hands it to the .dev registry, so resolvers can check the signatures.
resource "cloudflare_zone_dnssec" "main" {
  zone_id = cloudflare_zone.main.id
  status  = "active"
}

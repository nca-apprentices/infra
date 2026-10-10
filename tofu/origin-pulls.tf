# Cloudflare shows this client certificate to the node on every request, and
# Traefik admits no other on port 443, see cluster/platform/traefik.yaml.
# Another Cloudflare account that points a zone at the node's address shows
# none, so it can't reach the node around this zone's rate limit. The CA is
# ours: Cloudflare's shared certificate would admit every account.
resource "tls_private_key" "origin_pull_ca" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "origin_pull_ca" {
  private_key_pem       = tls_private_key.origin_pull_ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 87600
  allowed_uses          = ["cert_signing"]

  subject {
    common_name = "nca-apprentices origin pull CA"
  }
}

resource "tls_private_key" "origin_pull" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "origin_pull" {
  private_key_pem = tls_private_key.origin_pull.private_key_pem

  subject {
    common_name = "Cloudflare origin pull"
  }
}

resource "tls_locally_signed_cert" "origin_pull" {
  cert_request_pem      = tls_cert_request.origin_pull.cert_request_pem
  ca_private_key_pem    = tls_private_key.origin_pull_ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.origin_pull_ca.cert_pem
  validity_period_hours = 87600
  allowed_uses          = ["digital_signature", "key_encipherment", "client_auth"]
}

resource "cloudflare_authenticated_origin_pulls_certificate" "main" {
  zone_id     = cloudflare_zone.main.id
  certificate = tls_locally_signed_cert.origin_pull.cert_pem
  private_key = tls_private_key.origin_pull.private_key_pem
}

resource "cloudflare_authenticated_origin_pulls_settings" "main" {
  zone_id    = cloudflare_zone.main.id
  enabled    = true
  depends_on = [cloudflare_authenticated_origin_pulls_certificate.main]
}

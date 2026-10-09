terraform {
  required_version = ">= 1.10"

  # State lives in Hetzner Object Storage. The bucket is created once by hand,
  # and the credentials come from AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY.
  backend "s3" {
    bucket                      = "nca-tofu"
    key                         = "prod.tfstate"
    region                      = "nbg1"
    endpoints                   = { s3 = "https://nbg1.your-objectstorage.com" }
    use_lockfile                = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "1.69.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.27.0"
    }
    minio = {
      source  = "aminueza/minio"
      version = "3.43.0"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# Hetzner Object Storage speaks S3, and Hetzner documents this provider for
# managing its buckets. The backups live in another location than the node.
provider "minio" {
  minio_server   = "${var.backup_location}.your-objectstorage.com"
  minio_region   = var.backup_location
  minio_user     = var.s3_access_key
  minio_password = var.s3_secret_key
  minio_ssl      = true
  s3_compat_mode = true
}

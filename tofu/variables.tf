variable "hcloud_token" {
  type      = string
  sensitive = true
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

variable "cloudflare_account_id" {
  type        = string
  description = "ID of the Cloudflare account the zone lives in, from the dashboard's Account home."
}

variable "operator_cidrs" {
  type        = list(string)
  description = "Addresses the operators run talosctl and kubectl from, such as [\"203.0.113.7/32\"]."
}

variable "domain" {
  type        = string
  description = "Apex domain the instance is served from."
}

variable "location" {
  type        = string
  default     = "nbg1"
  description = "Hetzner location; keep the nodes together so the network is free and fast."
}

variable "server_type" {
  type        = string
  default     = "cax31"
  description = "Shared arm64 instance. Phase A is one node with 16 GB; phase B adds a second."
}

variable "node_count" {
  type    = number
  default = 1
}

variable "s3_access_key" {
  type        = string
  description = "The Object Storage key tofu runs with, the one that also holds the state."
}

variable "s3_secret_key" {
  type      = string
  sensitive = true
}

variable "object_storage_project_id" {
  type        = string
  description = "Numeric ID of the Hetzner project the buckets live in, as bucket policies name it."
}

variable "backup_keys" {
  type        = map(string)
  description = "Access key per backup bucket, keyed like local.backups. Keys are created in the Console."
}

variable "backup_location" {
  type        = string
  default     = "fsn1"
  description = "Object Storage location of the backups. Not the node's, so one site can't lose both."
}

# One bucket per store the cluster backs up. Each store writes with an S3 key of
# its own, created in the Console since Hetzner has no API for keys. A key is
# valid for every bucket in the project, so each bucket's policy denies all keys
# but its writer's and tofu's: a key leaked from one store can't read or delete
# another store's backups.
locals {
  backups = toset(["jjforge-prod-db", "seaweedfs", "redpanda", "metrics", "logs"])
}

resource "minio_s3_bucket" "backup" {
  for_each = local.backups
  bucket   = "nca-backup-${each.key}"
  acl      = "private"
}

# Every store overwrites or deletes its own backups: the WAL archive by its
# retention policy, the others by mirroring the live data. Versioning keeps
# what they replace for 30 more days.
resource "minio_s3_bucket_versioning" "backup" {
  for_each = minio_s3_bucket.backup
  bucket   = each.value.bucket

  versioning_configuration {
    status = "Enabled"
  }
}

resource "minio_ilm_policy" "backup" {
  for_each = minio_s3_bucket.backup
  bucket   = each.value.bucket

  rule {
    id = "keep-replaced-30-days"

    noncurrent_expiration {
      days = "30d"
    }
  }
}

resource "minio_s3_bucket_policy" "backup" {
  for_each = minio_s3_bucket.backup
  bucket   = each.value.bucket
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "WriterAndTofuOnly"
      Effect   = "Deny"
      Action   = "s3:*"
      Resource = [each.value.arn, "${each.value.arn}/*"]
      NotPrincipal = {
        AWS = [
          for key in [var.backup_keys[each.key], var.s3_access_key] :
          "arn:aws:iam:::user/p${var.object_storage_project_id}:${key}"
        ]
      }
    }]
  })
}

# The state bucket, created by hand, admits tofu's key alone. Every key is
# valid for every bucket in the project, so a key leaked from a store could
# otherwise read or replace the state.
resource "minio_s3_bucket_policy" "state" {
  provider = minio.state
  bucket   = "nca-tofu"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid          = "TofuOnly"
        Effect       = "Deny"
        Action       = "s3:*"
        Resource     = ["arn:aws:s3:::nca-tofu", "arn:aws:s3:::nca-tofu/*"]
        NotPrincipal = { AWS = ["arn:aws:iam:::user/p${var.object_storage_project_id}:${var.s3_access_key}"] }
      },
    ]
  })
}

# A failed or mistaken apply can leave a broken state, so the bucket keeps
# every version tofu replaces.
resource "minio_s3_bucket_versioning" "state" {
  provider = minio.state
  bucket   = "nca-tofu"

  versioning_configuration {
    status = "Enabled"
  }
}

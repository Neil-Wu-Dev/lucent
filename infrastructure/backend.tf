# =========================
# Terraform Remote State
# =========================
# The S3 backend lets the self-hosted runner use the same Terraform state
# as local deployment work. Its bucket is created once by the bootstrap script.
terraform {
  backend "s3" {}
}

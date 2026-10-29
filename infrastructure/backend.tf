# =========================
# Terraform Local State
# =========================
# This absolute path belongs to the lucent-windows self-hosted runner, not to a
# repository checkout. GitHub Actions checkouts may be replaced at any time;
# the Terraform state must not be.
terraform {
  backend "local" {
    path = "D:/TerraformState/lucent/terraform.tfstate"
  }
}

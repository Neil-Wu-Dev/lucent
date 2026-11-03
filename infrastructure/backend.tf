# =========================
# Terraform Local State
# =========================
# This absolute path belongs to the lucent-windows self-hosted runner, not to a
# repository checkout. It is intentionally separate from the retired AWS
# Academy state so the Sandbox starts with a new, independent resource ledger.
terraform {
  backend "local" {
    path = "D:/TerraformState/lucent-sandbox/terraform.tfstate"
  }
}

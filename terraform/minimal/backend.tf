# Remote state for the demo deployment.
#
# Partial configuration: resource_group_name, storage_account_name and
# container_name are supplied at init time via -backend-config, because the
# storage account name is globally unique and therefore derived per
# subscription by scripts/bootstrap.sh.
#
# Remote state matters here even for a demo. With local state, every CI run
# would start empty, try to recreate the resource group, and fail - or worse,
# succeed with a fresh random suffix and orphan the previous deployment.
#
# Locking is handled natively by Azure Blob leases; no separate lock table.
#
# Local use:
#   terraform init \
#     -backend-config="resource_group_name=medivault-tfstate-rg" \
#     -backend-config="storage_account_name=<from bootstrap output>" \
#     -backend-config="container_name=tfstate"

terraform {
  backend "azurerm" {
    key              = "medivault.demo.terraform.tfstate"
    use_oidc         = true
    use_azuread_auth = true
  }
}

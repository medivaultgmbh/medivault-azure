# Azure Storage backend for the reference architecture.
#
# PARTIAL CONFIGURATION — deliberately.
#
# The storage account name is globally unique and therefore derived per
# subscription by scripts/bootstrap.sh (mvtfstate<hash>). Hardcoding a name
# here guarantees a mismatch: an earlier revision of this file named a fixed
# account that bootstrap never creates, and the README documented that fixed
# name in turn. Three sources, none agreeing.
#
# Supply the remaining values at init time. `terraform output` from bootstrap
# prints them, and terraform/minimal/backend.tf uses the same pattern.
#
#   terraform init \
#     -backend-config="resource_group_name=medivault-tfstate-rg" \
#     -backend-config="storage_account_name=<from bootstrap output>" \
#     -backend-config="container_name=tfstate"
#
# The policy gate does not use this backend at all: it writes a local backend
# override and plans against throwaway state, so it can run before the remote
# backend exists and can never write to it.

terraform {
  backend "azurerm" {
    key              = "medivault.healthcare-api.terraform.tfstate"
    use_oidc         = true
    use_azuread_auth = true
  }
}

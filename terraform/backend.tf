# Azure Storage backend — equivalent to an S3 + DynamoDB Terraform backend on AWS.
#
# Pre-requisite: run scripts/bootstrap-terraform-backend.sh to create the
# storage account and container before the first `terraform init`.
#
# State locking is handled natively by the Azure backend using blob leases,
# removing the need for a separate DynamoDB lock table.

terraform {
  backend "azurerm" {
    resource_group_name  = "medivault-tfstate-rg"
    storage_account_name = "medivaulttfstate" # Globally unique; set in bootstrap script
    container_name       = "tfstate"
    key                  = "medivault.healthcare-api.terraform.tfstate"

    # Authentication: the CI/CD pipeline uses OIDC federated credentials.
    # Local developers use `az login` (ARM_USE_AZURE_CLI = true in the pipeline env).
    use_oidc = true
  }
}

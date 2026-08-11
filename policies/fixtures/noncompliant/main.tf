###############################################################################
# NON-COMPLIANT FIXTURE - DO NOT DEPLOY
#
# This configuration deliberately violates every GDPR policy in ../../. It
# exists so CI can prove the policy gate rejects bad infrastructure, rather
# than only showing that good infrastructure passes.
#
# A gate that has never failed is not evidence of control. It is evidence that
# the gate has never been tested.
#
# The grc-gate workflow plans this directory and asserts that Conftest exits
# NON-ZERO. If Conftest ever passes here, the policies have regressed and the
# pipeline fails loudly.
#
# Each resource below is annotated with the rule it is designed to trip.
###############################################################################

terraform {
  required_version = ">= 1.6"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
}

# skip_provider_registration avoids needing real credentials to produce a plan.
provider "azurerm" {
  features {}

  skip_provider_registration = true
}

# Deliberately outside the EU: trips gdpr_eu_data_residency, which was added
# after the demo had to move region. A fixture that does not exercise every
# policy quietly stops proving the gate works.
variable "location" {
  type    = string
  default = "eastus"
}

resource "azurerm_resource_group" "bad" {
  name     = "noncompliant-fixture-rg"
  location = var.location
}

###############################################################################
# VIOLATION 1 + 2 - gdpr_no_public_storage.rego
#   public_network_access_enabled is not false  -> GDPR Art. 25
#   min_tls_version is not TLS1_2               -> GDPR Art. 32
###############################################################################

resource "azurerm_storage_account" "public_and_weak_tls" {
  name                     = "noncompliantfixture01"
  resource_group_name      = azurerm_resource_group.bad.name
  location                 = azurerm_resource_group.bad.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  public_network_access_enabled = true     # VIOLATION: must be false
  min_tls_version               = "TLS1_0" # VIOLATION: must be TLS1_2
}

###############################################################################
# VIOLATION 3 - gdpr_adls_encryption.rego
#   Storage account holding GDPR data without customer-managed key encryption.
###############################################################################

resource "azurerm_storage_account" "no_cmk" {
  name                     = "noncompliantfixture02"
  resource_group_name      = azurerm_resource_group.bad.name
  location                 = azurerm_resource_group.bad.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  # The CMK rule is scoped to ADLS Gen2 accounts only, so hierarchical
  # namespace must be enabled for this fixture to trip it.
  is_hns_enabled = true

  # Deliberately compliant on the public-access and TLS rules, so this resource
  # isolates the CMK failure rather than muddying it with unrelated findings.
  public_network_access_enabled = false
  min_tls_version               = "TLS1_2"

  # VIOLATION: no customer_managed_key block.
}

###############################################################################
# VIOLATION 4 - gdpr_cosmos_pitr.rego
#   Cosmos DB without continuous backup / point-in-time recovery.
###############################################################################

resource "azurerm_cosmosdb_account" "no_pitr" {
  name                = "noncompliant-fixture-cosmos"
  resource_group_name = azurerm_resource_group.bad.name
  location            = azurerm_resource_group.bad.location
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  public_network_access_enabled = true # VIOLATION: should be private only

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = var.location
    failover_priority = 0
  }

  # VIOLATION: backup type Periodic, not Continuous - no PITR.
  backup {
    type = "Periodic"
  }
}

###############################################################################
# VIOLATION 5 - gdpr_keyvault_key_rotation.rego
#   Key Vault key with no rotation policy.
###############################################################################

resource "azurerm_key_vault" "bad" {
  name                = "noncompliant-fixture-kv"
  resource_group_name = azurerm_resource_group.bad.name
  location            = azurerm_resource_group.bad.location
  tenant_id           = "00000000-0000-0000-0000-000000000000"
  sku_name            = "standard"

  purge_protection_enabled = false # VIOLATION: no purge protection
}

resource "azurerm_key_vault_key" "no_rotation" {
  name         = "unrotated-key"
  key_vault_id = azurerm_key_vault.bad.id
  key_type     = "RSA"
  key_size     = 2048

  key_opts = ["decrypt", "encrypt", "sign", "unwrapKey", "verify", "wrapKey"]

  # VIOLATION: no rotation_policy block.
}

###############################################################################
# VIOLATION 6 - gdpr_rbac_no_wildcard.rego
#   Over-broad role assignment - Owner at subscription scope.
###############################################################################

resource "azurerm_role_assignment" "wildcard_owner" {
  scope                = "/subscriptions/00000000-0000-0000-0000-000000000000"
  role_definition_name = "Owner" # VIOLATION: wildcard-equivalent privilege
  principal_id         = "00000000-0000-0000-0000-000000000000"
}

###############################################################################
# VIOLATION 7 - gdpr_api_logging.rego
#   API Management API allowing plaintext HTTP and no subscription requirement.
###############################################################################

resource "azurerm_api_management" "bad" {
  name                = "noncompliant-fixture-apim"
  resource_group_name = azurerm_resource_group.bad.name
  location            = azurerm_resource_group.bad.location
  publisher_name      = "Fixture"
  publisher_email     = "fixture@example.invalid"
  sku_name            = "Developer_1"
}

resource "azurerm_api_management_api" "insecure" {
  name                = "insecure-api"
  resource_group_name = azurerm_resource_group.bad.name
  api_management_name = azurerm_api_management.bad.name
  revision            = "1"
  display_name        = "Insecure API"
  path                = "insecure"

  protocols             = ["http", "https"] # VIOLATION: plaintext HTTP allowed
  subscription_required = false             # VIOLATION: unauthenticated access
}

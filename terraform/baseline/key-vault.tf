######################################################################
# Azure Key Vault — customer-managed key for GDPR-restricted data stores.
#
# AWS equivalent: aws_kms_key + aws_kms_alias
#
# The workload consumes this baseline output as the customer-managed key (CMK)
# for ADLS Gen2 and Cosmos DB encryption, so cryptographic custody is
# centralised in the GRC layer and auditable independently of workload resources.
#
# GDPR controls satisfied:
#   Art. 25  — privacy by design: CMK ensures MediVault retains cryptographic control
#   Art. 32  — appropriate technical measures: AES-256 encryption at rest
#   Art. 5(f) — integrity and confidentiality principle
######################################################################

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "grc" {
  name                = "${var.name_prefix}-kv-${var.suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "premium" # HSM-backed keys required for GDPR Art. 32

  # Soft delete + purge protection: keys cannot be deleted or purged for
  # soft_delete_retention_days, equivalent to aws_kms_key deletion_window_in_days.
  soft_delete_retention_days = 90
  purge_protection_enabled   = true

  # Restrict access to the private subnet only — no public endpoint.
  public_network_access_enabled = false

  network_acls {
    default_action             = "Deny"
    bypass                     = "AzureServices"
    virtual_network_subnet_ids = var.private_subnet_ids
  }

  tags = var.tags
}

# Key Vault access policy for the GRC baseline service principal
# (used by the CI/CD pipeline to verify key existence).
resource "azurerm_key_vault_access_policy" "pipeline" {
  key_vault_id = azurerm_key_vault.grc.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  key_permissions = [
    "Get", "List", "Create", "Delete", "Recover", "Backup", "Restore",
    "GetRotationPolicy", "SetRotationPolicy",
  ]
}

# Access policy for the workload managed identity.
#
# This vault uses the access policy model (enable_rbac_authorization defaults to
# false). In that mode an RBAC role assignment such as "Key Vault Crypto User"
# is silently inert: it appears in the plan, applies without error, and grants
# nothing. Customer-managed key encryption on ADLS Gen2 and the evidence vault
# then fails at apply with a permissions error that points at the storage
# account rather than at the vault.
#
# Get, WrapKey and UnwrapKey are the minimum set Azure Storage requires to use a
# customer-managed key. No write permissions: the identity consumes the key, it
# does not manage it.
resource "azurerm_key_vault_access_policy" "workload" {
  key_vault_id = azurerm_key_vault.grc.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = var.workload_identity_principal_id

  key_permissions = ["Get", "WrapKey", "UnwrapKey"]
}

# Customer-managed key for GDPR-restricted (healthcare-derived) data stores.
# AWS equivalent: aws_kms_key.phi with enable_key_rotation = true.
resource "azurerm_key_vault_key" "gdpr_restricted" {
  name         = "${var.name_prefix}-gdpr-restricted-key"
  key_vault_id = azurerm_key_vault.grc.id
  key_type     = "RSA-HSM" # Hardware-backed, audit-grade
  key_size     = 4096

  key_opts = ["decrypt", "encrypt", "sign", "unwrapKey", "verify", "wrapKey"]

  # Automatic key rotation every 90 days satisfies GDPR Art. 32 and is the
  # Azure equivalent of aws_kms_key enable_key_rotation = true.
  rotation_policy {
    automatic {
      time_before_expiry = "P30D"
    }

    expire_after         = "P90D"
    notify_before_expiry = "P29D"
  }

  depends_on = [azurerm_key_vault_access_policy.pipeline]

  tags = var.tags
}

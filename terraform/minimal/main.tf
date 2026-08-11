###############################################################################
# MediVault - governance plane (demo deployment)
#
# Deploys the controls, not the workload:
#
#   Log Analytics       central log sink              (NIS2 Art. 23)
#   Key Vault + CMK     cryptographic custody         (GDPR Art. 32)
#   Key rotation policy automatic 90-day rotation     (GDPR Art. 32)
#   Evidence vault      versioned, retained storage   (GDPR Art. 32, NIS2 Art. 23)
#   Lifecycle policy    automated tiering + deletion  (GDPR Art. 5(1)(e))
#   Diagnostic settings control-plane audit trail     (GDPR Art. 32)
#
# Deliberately NOT deployed here: Cosmos DB, Functions, API Management, VNet,
# private endpoints. Those carry the cost and are not needed to demonstrate the
# governance controls or produce signed evidence.
#
# Every deviation from the target architecture is recorded in
# docs/EXCEPTIONS.md with a rationale and a remediation path.
###############################################################################

resource "random_id" "suffix" {
  byte_length = 4
}

data "azurerm_client_config" "current" {}

locals {
  suffix = random_id.suffix.hex

  tags = {
    Project     = "medivault-healthcare-api"
    ManagedBy   = "terraform"
    Workload    = "governance-plane"
    DataClass   = "restricted-gdpr"
    Environment = var.environment
    CostCenter  = "cloud-engineering"
    Regulation  = "GDPR-NIS2-ISO27001"

    # Makes the deviation visible in the portal and in cost reports, not just
    # in a document nobody opens.
    Deviation = "see-docs/EXCEPTIONS.md"
  }

  # Empty allowlist means "no IP rules", which with default_action = Allow
  # leaves the service publicly reachable. Recorded as EXC-001 / EXC-002.
  restrict_network = length(var.allowed_ip_ranges) > 0
}

resource "azurerm_resource_group" "demo" {
  name     = "${var.name_prefix}-${var.environment}-rg"
  location = var.location
  tags     = local.tags
}

###############################################################################
# Log Analytics - central log sink
#
# PerGB2018 includes 5 GB/month free. At demo volumes this bills nothing.
###############################################################################

resource "azurerm_log_analytics_workspace" "grc" {
  name                = "${var.name_prefix}-law-${local.suffix}"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days

  # Cap ingest so a runaway diagnostic setting cannot generate a surprise bill.
  daily_quota_gb = 1

  tags = local.tags
}

###############################################################################
# Key Vault - cryptographic custody
#
# Differences from the full configuration, both recorded as exceptions:
#   standard (not premium) SKU  - software-protected keys instead of HSM  EXC-003
#   public network access       - required for data plane from a runner   EXC-001
#
# The rotation policy is identical to production. That control is the one that
# actually demonstrates GDPR Art. 32, and it costs nothing to keep.
###############################################################################

resource "azurerm_key_vault" "grc" {
  name                = "${var.name_prefix}-kv-${local.suffix}"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  # EXC-001: the full configuration sets this to false and reaches the vault
  # over a private endpoint from inside the VNet.
  public_network_access_enabled = true

  network_acls {
    default_action = local.restrict_network ? "Deny" : "Allow"
    bypass         = "AzureServices"
    ip_rules       = var.allowed_ip_ranges
  }

  tags = local.tags
}

# The deploying principal needs key permissions to create and rotate the CMK.
resource "azurerm_key_vault_access_policy" "deployer" {
  key_vault_id = azurerm_key_vault.grc.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  key_permissions = [
    "Get", "List", "Create", "Delete", "Purge", "Recover",
    "GetRotationPolicy", "SetRotationPolicy",
  ]
}

resource "azurerm_key_vault_key" "gdpr_restricted" {
  name         = "${var.name_prefix}-gdpr-restricted-key"
  key_vault_id = azurerm_key_vault.grc.id

  # EXC-003: RSA (software-protected) rather than RSA-HSM. Standard-tier vaults
  # do not offer HSM-backed keys; the rotation control is unaffected.
  key_type = "RSA"
  key_size = 4096

  key_opts = ["decrypt", "encrypt", "sign", "unwrapKey", "verify", "wrapKey"]

  # Identical to the full configuration - 90-day automatic rotation.
  rotation_policy {
    automatic {
      time_before_expiry = "P30D"
    }

    expire_after         = "P90D"
    notify_before_expiry = "P29D"
  }

  depends_on = [azurerm_key_vault_access_policy.deployer]

  tags = local.tags
}

###############################################################################
# Evidence vault - signed CI/CD audit artefacts
#
# Differences from the full configuration:
#   LRS instead of GRS     - single-region redundancy           EXC-004
#   public network access  - runner must upload over internet   EXC-002
#   no CMK encryption      - avoids the identity/key dependency EXC-005
#
# Versioning, retention and lifecycle management are kept, because those are
# the controls the evidence chain actually depends on.
###############################################################################

resource "azurerm_storage_account" "evidence_vault" {
  name                     = "${replace(var.name_prefix, "-", "")}ev${local.suffix}"
  resource_group_name      = azurerm_resource_group.demo.name
  location                 = azurerm_resource_group.demo.location
  account_tier             = "Standard"
  account_replication_type = "LRS" # EXC-004

  public_network_access_enabled   = true # EXC-002
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false # Entra ID auth only - no account keys

  min_tls_version = "TLS1_2"

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = var.evidence_retention_days
    }
  }

  network_rules {
    default_action = local.restrict_network ? "Deny" : "Allow"
    bypass         = ["AzureServices"]
    ip_rules       = var.allowed_ip_ranges
  }

  tags = local.tags
}

# Storage Blob Data Contributor is granted below, but Entra ID role assignments
# are eventually consistent - typically 30 seconds, occasionally several
# minutes. Terraform would otherwise create the container the moment the account
# exists, using a role the data plane has not yet observed.
resource "time_sleep" "wait_for_rbac" {
  depends_on      = [azurerm_role_assignment.deployer_evidence_writer]
  create_duration = "90s"
}

resource "azurerm_storage_container" "evidence" {
  name                  = "evidence-vault"
  storage_account_name  = azurerm_storage_account.evidence_vault.name
  container_access_type = "private"

  depends_on = [time_sleep.wait_for_rbac]
}

# GDPR Art. 5(1)(e) - storage limitation. Evidence is tiered down and then
# deleted automatically; retention is not left to manual discipline.
resource "azurerm_storage_management_policy" "evidence_vault" {
  storage_account_id = azurerm_storage_account.evidence_vault.id

  rule {
    name    = "evidence-retention"
    enabled = true

    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["evidence-vault/runs/"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than = 30
        delete_after_days_since_modification_greater_than       = 365
      }

      version {
        delete_after_days_since_creation = 90
      }
    }
  }
}

# The CI principal writes evidence using its own identity, not an account key.
resource "azurerm_role_assignment" "deployer_evidence_writer" {
  scope                = azurerm_storage_account.evidence_vault.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

###############################################################################
# Diagnostic settings - audit trail into Log Analytics
#
# This is the control that makes every other control auditable. Key Vault
# AuditEvent captures each key operation; storage logs capture every read,
# write and delete against the evidence chain.
###############################################################################

resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "${var.name_prefix}-kv-diag"
  target_resource_id         = azurerm_key_vault.grc.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.grc.id

  enabled_log { category = "AuditEvent" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

resource "azurerm_monitor_diagnostic_setting" "evidence_blob" {
  name = "${var.name_prefix}-evidence-diag"
  # Blob diagnostics attach to the blob sub-resource, not the account itself.
  target_resource_id         = "${azurerm_storage_account.evidence_vault.id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.grc.id

  enabled_log { category = "StorageRead" }
  enabled_log { category = "StorageWrite" }
  enabled_log { category = "StorageDelete" }

  metric {
    category = "Transaction"
    enabled  = true
  }
}

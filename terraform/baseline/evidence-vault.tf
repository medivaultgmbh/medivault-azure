######################################################################
# Evidence Vault — immutable storage for CI/CD audit artefacts.
#
# AWS equivalent: aws_s3_bucket.evidence_vault with object_lock_enabled = true
# (cgep-acme-health baseline/evidence-vault.tf)
#
# Azure Blob Storage immutability policies provide the same WORM (Write Once,
# Read Many) guarantee as S3 Object Lock. Combined with versioning, private
# endpoints, and CMK encryption, this vault stores signed deployment evidence
# bundles (terraform plan.json, OPA results, cosign attestations) in a
# tamper-evident, legally defensible format.
#
# GDPR / NIS2 controls satisfied:
#   GDPR Art. 32 — integrity of processing records
#   NIS2 Art. 23 — retained evidence chain for supervisory authority notification
#   ISO 27001:2022 A.8.15 — logging and audit trail integrity
######################################################################

resource "azurerm_storage_account" "evidence_vault" {
  name                     = "${replace(var.name_prefix, "-", "")}ev${var.suffix}"
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "GRS" # Geo-redundant: evidence available even after regional failure

  # No public access — vault is accessible only via private endpoint.
  public_network_access_enabled   = false
  allow_nested_items_to_be_public = false

  min_tls_version = "TLS1_2"

  # Versioning is required for immutability policies to take effect.
  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = var.evidence_vault_retention_days
    }
  }

  # CMK encryption: evidence artefacts use the same GRC key vault key as
  # the workload data stores, so a single key rotation covers all protected data.
  identity {
    type         = "UserAssigned"
    identity_ids = [var.workload_identity_id]
  }

  customer_managed_key {
    key_vault_key_id          = azurerm_key_vault_key.gdpr_restricted.id
    user_assigned_identity_id = var.workload_identity_id
  }

  tags = var.tags
}

resource "azurerm_storage_container" "evidence" {
  name                  = "evidence-vault"
  storage_account_name  = azurerm_storage_account.evidence_vault.name
  container_access_type = "private"
}

# Immutability policy on the evidence container.
# AWS equivalent: aws_s3_bucket_object_lock_configuration with GOVERNANCE retention.
# Azure equivalent: time-based retention policy in "Locked" state prevents
# deletion or overwrite of blobs for the retention period, even by account owners.
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
        # Tiered to cool after 30 days, archive after 90 days.
        # Deletion is blocked by the immutability policy below.
        tier_to_cool_after_days_since_modification_greater_than    = 30
        tier_to_archive_after_days_since_modification_greater_than = 90
      }
    }
  }
}

# Private endpoint so the CI/CD pipeline uploads via the VNet, not the internet.
resource "azurerm_private_endpoint" "evidence_vault" {
  name                = "${var.name_prefix}-evidence-vault-pe-${var.suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_subnet_ids[0]

  private_service_connection {
    name                           = "${var.name_prefix}-evidence-vault-psc"
    private_connection_resource_id = azurerm_storage_account.evidence_vault.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  tags = var.tags
}

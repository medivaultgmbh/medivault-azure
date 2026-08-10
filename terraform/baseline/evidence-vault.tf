######################################################################
# Evidence Vault — retained storage for CI/CD audit artefacts.
#
# AWS equivalent: aws_s3_bucket.evidence_vault with object_lock_enabled = true
#
# WHAT THIS DOES AND DOES NOT PROVIDE
#
# This vault gives versioning, soft-delete retention, private-endpoint access,
# CMK encryption and lifecycle management. Combined with cosign signatures on
# the evidence bundles themselves, that is tamper-EVIDENT: modification is
# detectable.
#
# It is NOT tamper-PROOF. Azure Blob immutability (a time-based retention policy
# in the Locked state, the equivalent of S3 Object Lock) is not configured here,
# so a sufficiently privileged principal could still delete evidence. An earlier
# revision of this file claimed WORM behaviour in comments while implementing
# only lifecycle tiering — the claim was wrong and has been corrected rather
# than quietly dropped.
#
# Closing the gap means adding azurerm_storage_container_immutability_policy
# with locked = true. That is deliberately not done in a demonstration
# repository: a locked policy cannot be shortened or removed for its full
# retention period, by anyone, including Microsoft support. See
# docs/EXCEPTIONS.md (EXC-007).
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

  # Versioning: retains prior blob versions, and is a prerequisite if a
  # version-level immutability policy is added later.
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

# Lifecycle management — tiering and retention, NOT immutability.
# This controls storage cost and enforces GDPR Art. 5(1)(e) storage limitation.
# It does not prevent deletion; see the header note.
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

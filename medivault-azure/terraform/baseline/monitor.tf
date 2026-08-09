######################################################################
# Azure Monitor + Log Analytics — management audit trail for the governed workload.
#
# AWS equivalent: aws_cloudtrail + aws_s3_bucket.cloudtrail (cgep-acme-health
# baseline/cloudtrail.tf)
#
# CloudTrail captures AWS management-plane events (API calls, config changes).
# The Azure equivalent is a combination of:
#   - azurerm_log_analytics_workspace  — centralised log store
#   - azurerm_monitor_diagnostic_setting (applied per-resource in main.tf)
#   - azurerm_monitor_activity_log_alert — subscription-level management events
#   - Microsoft Sentinel (referenced by main.tf) — SIEM on top of Log Analytics
#
# GDPR / NIS2 controls satisfied:
#   GDPR Art. 32 — logging as a technical measure ensuring data integrity
#   NIS2 Art. 21 — audit records supporting incident detection and response
#   NIS2 Art. 23 — evidence trail for 24h early-warning and 72h full notification
######################################################################

locals {
  log_analytics_name = "${var.name_prefix}-law-${var.suffix}"
}

resource "azurerm_log_analytics_workspace" "grc" {
  name                = local.log_analytics_name
  resource_group_name = var.resource_group_name
  location            = var.location

  # 90-day hot retention + 7-year archive satisfies GDPR Art. 5(1)(e) storage
  # limitation and mirrors CloudTrail log retention best practice.
  retention_in_days = 90

  sku = "PerGB2018"

  # Internet ingestion is disabled; data arrives via Azure Monitor pipeline only.
  internet_ingestion_enabled = false
  internet_query_enabled     = false

  tags = var.tags
}

# Application Insights — sends APIM and Function telemetry into the same
# Log Analytics workspace so all signals are correlated.
resource "azurerm_application_insights" "grc" {
  name                = "${var.name_prefix}-ai-${var.suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  workspace_id        = azurerm_log_analytics_workspace.grc.id
  application_type    = "web"

  tags = var.tags
}

# Subscription-level Activity Log export — equivalent to CloudTrail
# is_multi_region_trail + include_global_service_events.
# Captures all Azure Resource Manager (ARM) control-plane events.
resource "azurerm_monitor_diagnostic_setting" "activity_log" {
  name               = "${var.name_prefix}-activity-log-diag"
  target_resource_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"

  log_analytics_workspace_id = azurerm_log_analytics_workspace.grc.id

  enabled_log {
    category = "Administrative" # ARM management operations (create, update, delete)
  }

  enabled_log {
    category = "Security" # Microsoft Defender alerts
  }

  enabled_log {
    category = "Policy" # Azure Policy compliance events
  }

  enabled_log {
    category = "Alert" # Monitor alert triggers
  }
}

# Activity log alert: alert on Key Vault key deletion (GDPR forensic trigger).
# AWS equivalent: CloudTrail + CloudWatch alarm on KMS DisableKey events.
resource "azurerm_monitor_activity_log_alert" "key_vault_key_deletion" {
  name                = "${var.name_prefix}-kv-key-deletion-alert"
  resource_group_name = var.resource_group_name
  location            = "Global"
  scopes              = ["/subscriptions/${data.azurerm_client_config.current.subscription_id}"]

  criteria {
    resource_type  = "Microsoft.KeyVault/vaults"
    operation_name = "Microsoft.KeyVault/vaults/keys/delete"
    status         = "Succeeded"
  }

  action {
    action_group_id = azurerm_monitor_action_group.security_ops.id
  }

  tags = var.tags
}

# Activity log alert: alert on storage account public access re-enablement.
# Detects GDPR-Gap-02 regression (public network access enabled).
resource "azurerm_monitor_activity_log_alert" "storage_public_access" {
  name                = "${var.name_prefix}-storage-public-access-alert"
  resource_group_name = var.resource_group_name
  location            = "Global"
  scopes              = ["/subscriptions/${data.azurerm_client_config.current.subscription_id}"]

  criteria {
    resource_type  = "Microsoft.Storage/storageAccounts"
    operation_name = "Microsoft.Storage/storageAccounts/write"
    status         = "Succeeded"
  }

  action {
    action_group_id = azurerm_monitor_action_group.security_ops.id
  }

  tags = var.tags
}

# Action group — Security Operations team notification on triggered alerts.
resource "azurerm_monitor_action_group" "security_ops" {
  name                = "${var.name_prefix}-secops-ag"
  resource_group_name = var.resource_group_name
  short_name          = "secops"

  email_receiver {
    name          = "SecurityOps"
    email_address = var.security_ops_email
  }

  tags = var.tags
}

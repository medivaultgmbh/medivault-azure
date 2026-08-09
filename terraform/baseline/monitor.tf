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

######################################################################
# Break Glass (Emergency Access) Account Monitoring
#
# Two cloud-only Entra ID accounts are permanently assigned Global Admin
# and excluded from all Conditional Access policies (including MFA).
# They exist solely to restore tenant access when PIM or Conditional
# Access itself is broken.
#
# The accounts are NOT created here — they must be provisioned manually
# (credentials stored physically in separate secure locations, never in
# any digital system).  Terraform only wires the Sentinel/Monitor alert
# that fires the instant EITHER account signs in.
#
# Any sign-in = P1 incident: either a genuine emergency OR an attacker
# who obtained the credentials.
#
# GDPR / NIS2 controls satisfied:
#   NIS2 Art. 21 — ensures continuity of security administration during
#                  an incident (IR plan remains executable even if normal
#                  auth is broken)
#   GDPR Art. 32 — administrative resilience as a technical measure
######################################################################

# Object IDs of the two break glass accounts.
# Set these via terraform.tfvars or a GitHub Actions variable after
# manually creating the accounts in Entra ID.
variable "break_glass_account_object_ids" {
  description = "Object IDs of the two break glass (emergency access) Entra ID accounts. Used only to scope the sign-in alert — never used for automation."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.break_glass_account_object_ids) == 0 || length(var.break_glass_account_object_ids) == 2
    error_message = "Provide exactly 0 (not yet created) or 2 break glass account object IDs."
  }
}

# Scheduled Query Rule (Log Analytics → Sentinel) that fires on any sign-in
# by either break glass account.
# Queries the SigninLogs table which is populated by Entra ID → Log Analytics
# diagnostic settings (enabled separately in Entra ID portal or via
# azurerm_monitor_aad_diagnostic_setting).
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "break_glass_signin" {
  count = length(var.break_glass_account_object_ids) == 2 ? 1 : 0

  name                = "${var.name_prefix}-break-glass-signin-alert"
  resource_group_name = var.resource_group_name
  location            = var.location

  # P1 severity — any sign-in must trigger an immediate response
  severity  = 0
  frequency = "PT5M"  # evaluate every 5 minutes
  window_duration = "PT5M"

  scopes = [azurerm_log_analytics_workspace.grc.id]

  criteria {
    query = <<-KQL
      SigninLogs
      | where UserId in (
          "${var.break_glass_account_object_ids[0]}",
          "${var.break_glass_account_object_ids[1]}"
        )
      | where ResultType == "0"  // successful sign-in only
      | project TimeGenerated, UserDisplayName, UserId, IPAddress, Location, AppDisplayName
    KQL

    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.security_ops.id]
    custom_properties = {
      severity    = "P1"
      description = "BREAK GLASS SIGN-IN DETECTED. This is either a genuine emergency or a credential compromise. Escalate immediately to the CISO and DPO."
    }
  }

  auto_mitigation_enabled = false

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

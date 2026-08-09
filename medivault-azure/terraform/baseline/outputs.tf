# AWS equivalent: baseline/outputs.tf in cgep-acme-health
# phi_kms_key_arn → gdpr_key_vault_key_id
# cloudtrail_name → log_analytics_workspace_id
# evidence_vault_bucket_name → evidence_vault_storage_account_name

output "gdpr_key_vault_id" {
  value       = azurerm_key_vault.grc.id
  description = "Resource ID of the GRC Key Vault. Used by workload resources for CMK references."
}

output "gdpr_key_vault_key_id" {
  value       = azurerm_key_vault_key.gdpr_restricted.id
  description = "Versioned key ID of the GDPR-restricted CMK. Pass to ADLS Gen2 and Cosmos DB."
}

output "gdpr_key_vault_uri" {
  value       = azurerm_key_vault.grc.vault_uri
  description = "URI of the GRC Key Vault."
}

output "log_analytics_workspace_id" {
  value       = azurerm_log_analytics_workspace.grc.id
  description = "Log Analytics workspace resource ID. Used by Diagnostic Settings in the workload layer."
}

output "log_analytics_workspace_name" {
  value       = azurerm_log_analytics_workspace.grc.name
  description = "Log Analytics workspace name."
}

output "app_insights_instrumentation_key" {
  value       = azurerm_application_insights.grc.instrumentation_key
  description = "Application Insights instrumentation key. Used by APIM Logger and Function App."
  sensitive   = true
}

output "app_insights_connection_string" {
  value       = azurerm_application_insights.grc.connection_string
  description = "Application Insights connection string."
  sensitive   = true
}

output "evidence_vault_storage_account_name" {
  value       = azurerm_storage_account.evidence_vault.name
  description = "Storage account name for the evidence vault. Use as the EVIDENCE_VAULT_STORAGE_ACCOUNT GitHub variable."
}

output "evidence_vault_container_name" {
  value       = azurerm_storage_container.evidence.name
  description = "Container name inside the evidence vault storage account."
}

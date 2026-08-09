# AWS equivalent: cgep-acme-health/terraform/outputs.tf

output "api_endpoint" {
  value       = "https://${azurerm_api_management.main.gateway_url}/intake"
  description = "APIM gateway URL for the MediVault intake API. POST /intake."
}

output "adls_account_name" {
  value       = azurerm_storage_account.datasets.name
  description = "ADLS Gen2 storage account name for healthcare datasets."
}

output "adls_container_name" {
  value       = azurerm_storage_container.healthcare_datasets.name
  description = "Container name for healthcare datasets within the ADLS Gen2 account."
}

output "cosmos_endpoint" {
  value       = azurerm_cosmosdb_account.intake.endpoint
  description = "Cosmos DB SQL API endpoint for intake submissions."
}

output "cosmos_database_name" {
  value       = azurerm_cosmosdb_sql_database.intake.name
  description = "Cosmos DB database name for intake submissions."
}

output "function_app_name" {
  value       = azurerm_linux_function_app.intake.name
  description = "Azure Function App name for the intake handler."
}

output "vnet_id" {
  value       = azurerm_virtual_network.main.id
  description = "VNet resource ID."
}

output "private_subnet_id" {
  value       = azurerm_subnet.private.id
  description = "Private subnet ID for private endpoint placement."
}

output "workload_identity_principal_id" {
  value       = azurerm_user_assigned_identity.workload.principal_id
  description = "Object ID of the workload managed identity. Use for additional role assignments."
}

output "evidence_vault_storage_account_name" {
  value       = module.grc_baseline.evidence_vault_storage_account_name
  description = "Storage account for signed CI/CD evidence bundles. Set as EVIDENCE_VAULT_STORAGE_ACCOUNT GitHub variable."
}

output "log_analytics_workspace_id" {
  value       = module.grc_baseline.log_analytics_workspace_id
  description = "Log Analytics workspace resource ID. Used by Microsoft Sentinel onboarding."
}

output "resource_group_name" {
  value       = azurerm_resource_group.main.name
  description = "Resource group containing all workload and baseline resources."
}

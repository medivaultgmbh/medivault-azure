output "resource_group_name" {
  value       = azurerm_resource_group.demo.name
  description = "Resource group holding the demo governance plane. Delete this to remove everything."
}

output "evidence_vault_storage_account" {
  value       = azurerm_storage_account.evidence_vault.name
  description = "Set as the EVIDENCE_VAULT_STORAGE_ACCOUNT GitHub variable so the pipeline can upload signed evidence."
}

output "evidence_vault_container" {
  value       = azurerm_storage_container.evidence.name
  description = "Container that receives signed evidence bundles."
}

output "key_vault_name" {
  value       = azurerm_key_vault.grc.name
  description = "GRC Key Vault holding the GDPR customer-managed key."
}

output "key_vault_key_id" {
  value       = azurerm_key_vault_key.gdpr_restricted.id
  description = "Versioned CMK ID. Rotation policy: 90-day expiry, auto-rotate 30 days before."
}

output "log_analytics_workspace" {
  value       = azurerm_log_analytics_workspace.grc.name
  description = "Central log sink receiving Key Vault and evidence-vault audit events."
}

output "budget" {
  description = "FinOps guardrail summary. Alerting only - Azure budgets do not cap spend."
  value = {
    name            = azurerm_consumption_budget_subscription.demo_ceiling.name
    amount          = var.budget_amount
    scope           = "subscription"
    period_start    = local.budget_start
    alert_thresholds = "50% / 80% / 100% actual, 90% forecasted"
    recipients      = var.budget_alert_emails
    enforcement     = "DETECTIVE ONLY - alerts do not stop spending. See docs/FINOPS.md"
  }
}

output "deployment_note" {
  description = "Reminder that this is not the target architecture."
  value       = <<-EOT
    This is the DEMO governance plane, not the MediVault target architecture.
    Public network access is enabled and redundancy is reduced so the stack is
    reachable from a GitHub-hosted runner and costs under EUR 2/month.
    Deviations are recorded in docs/EXCEPTIONS.md (EXC-001 to EXC-005).
  EOT
}

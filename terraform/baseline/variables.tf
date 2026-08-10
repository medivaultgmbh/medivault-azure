variable "resource_group_name" {
  type        = string
  description = "Resource group that owns all baseline resources."
}

variable "location" {
  type        = string
  description = "Azure region for baseline resources (must be EU for GDPR data residency)."
}

variable "name_prefix" {
  type        = string
  description = "Stable resource name prefix shared with the workload layer."
}

variable "suffix" {
  type        = string
  description = "Unique random suffix shared with workload resources to avoid name collisions."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Subnet IDs permitted to reach the Key Vault and Evidence Vault private endpoints."
}

variable "workload_identity_id" {
  type        = string
  description = "Resource ID of the User-Assigned Managed Identity that holds CMK access to Key Vault."
}

variable "workload_identity_principal_id" {
  type        = string
  description = <<-EOT
    Principal (object) ID of the workload managed identity.

    Required because this vault uses the ACCESS POLICY permission model, not
    RBAC. An azurerm_role_assignment granting "Key Vault Crypto User" has no
    effect on an access-policy vault, so the identity must be granted key
    permissions here or customer-managed key encryption fails at apply time.
  EOT
}

variable "security_ops_email" {
  type        = string
  description = "Email address for the Security Operations team to receive monitoring alerts."
  default     = "secops@medivault.eu"
}

variable "evidence_vault_retention_days" {
  type        = number
  description = "Soft-delete retention period (days) for evidence artefacts. Minimum 1, recommended 90."
  default     = 90

  validation {
    condition     = var.evidence_vault_retention_days >= 1 && var.evidence_vault_retention_days <= 365
    error_message = "Evidence vault retention must be between 1 and 365 days."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all baseline resources."
  default     = {}
}

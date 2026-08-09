variable "location" {
  type        = string
  description = "Azure region. Must be an EU region to satisfy GDPR data residency, exactly as in the full configuration."
  default     = "westeurope"

  validation {
    condition     = contains(["westeurope", "northeurope", "swedencentral", "germanywestcentral", "francecentral"], var.location)
    error_message = "Location must be an EU Azure region to satisfy GDPR data residency requirements."
  }
}

variable "name_prefix" {
  type        = string
  description = "Short prefix applied to all resource names."
  default     = "medivlt"
}

variable "environment" {
  type        = string
  description = "Environment label. Fixed to 'demo' to keep this deployment clearly distinguishable from the target architecture."
  default     = "demo"
}

variable "log_retention_days" {
  type        = number
  description = "Log Analytics retention. 30 days is the free-tier default; the full configuration uses longer retention for NIS2 Art. 23 evidence."
  default     = 30

  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "Log Analytics retention must be between 30 and 730 days."
  }
}

variable "evidence_retention_days" {
  type        = number
  description = "Soft-delete retention for evidence blobs."
  default     = 30
}

###############################################################################
# FinOps
###############################################################################

variable "budget_amount" {
  type        = number
  description = <<-EOT
    Monthly subscription spending ceiling.

    Denominated in the BILLING CURRENCY of the subscription, not a currency you
    choose here. A EUR-billed subscription reads this as EUR 20, not USD 20 -
    Azure budgets have no currency field.

    This is an alert threshold, not a hard cap. See budget.tf.
  EOT
  default     = 20

  validation {
    condition     = var.budget_amount > 0 && var.budget_amount <= 1000
    error_message = "budget_amount must be between 1 and 1000. A demo environment should never need more."
  }
}

variable "budget_alert_emails" {
  type        = list(string)
  description = "Addresses that receive budget threshold alerts. At least one is required, or the budget is unmonitored and therefore pointless."

  validation {
    condition     = length(var.budget_alert_emails) > 0
    error_message = "Provide at least one alert email. A budget nobody is notified about is not a control."
  }
}

variable "budget_start_date" {
  type        = string
  description = <<-EOT
    Budget period start, RFC3339, first day of a month (e.g. 2026-08-01T00:00:00Z).
    Leave null to use the current month.

    Pin this once the budget exists: the default derives from timestamp(), and
    although time_period is in ignore_changes, a pinned value keeps plans
    deterministic and readable.
  EOT
  default     = null

  validation {
    condition     = var.budget_start_date == null || can(regex("^[0-9]{4}-[0-9]{2}-01T00:00:00Z$", var.budget_start_date))
    error_message = "budget_start_date must be the first day of a month in RFC3339 form, e.g. 2026-08-01T00:00:00Z."
  }
}

variable "allowed_ip_ranges" {
  type        = list(string)
  description = <<-EOT
    Optional CIDR allowlist for Key Vault and storage. Leave empty to allow any
    source, which is what a GitHub-hosted runner requires - its egress IP is not
    stable and the published ranges are large and change frequently.

    Restricting this is the single highest-value hardening step if you later
    move to a self-hosted runner with a fixed egress address.
  EOT
  default     = []
}

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

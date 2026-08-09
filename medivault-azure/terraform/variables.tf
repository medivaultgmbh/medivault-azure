variable "location" {
  type        = string
  description = "Azure region for all resources. Must be an EU region to satisfy GDPR data residency."
  default     = "westeurope" # Amsterdam — primary EU region for MediVault

  validation {
    condition     = contains(["westeurope", "northeurope", "swedencentral", "germanywestcentral", "francecentral"], var.location)
    error_message = "Location must be an EU Azure region to satisfy GDPR data residency requirements."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment (production, staging, development)."
  default     = "production"

  validation {
    condition     = contains(["production", "staging", "development"], var.environment)
    error_message = "Environment must be one of: production, staging, development."
  }
}

variable "name_prefix" {
  type        = string
  description = "Short prefix applied to all resource names. Keep under 8 characters to avoid name length limits."
  default     = "medivlt"
}

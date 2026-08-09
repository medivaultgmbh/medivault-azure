###############################################################################
# Demo deployment - governance plane only.
#
# WHY THIS EXISTS
#
# The reference architecture in ../ (the "full" configuration) describes the
# MediVault target state from Parts 1 and 2: private endpoints everywhere, no
# public network access, HSM-backed keys, geo-redundant storage, Elastic
# Premium Functions, and API Management.
#
# That architecture costs roughly EUR 240/month and - more importantly - cannot
# be deployed or reached from a GitHub-hosted runner, because every data plane
# endpoint is private. Creating a Key Vault key or uploading an evidence blob
# are data plane operations; from a public runner they fail at the network
# layer before authentication is even attempted.
#
# This configuration deploys the subset that is both affordable and reachable:
# the governance and evidence plane, with public endpoints. It is explicitly
# NOT the target architecture, and the deviations are recorded in
# docs/EXCEPTIONS.md rather than silently absorbed.
#
# Approximate cost: under EUR 2/month.
#   Log Analytics    - free tier covers 5 GB/month ingest
#   Key Vault        - standard tier, priced per operation (negligible)
#   Storage (LRS)    - a few cents at demo volumes
#
# State is local. The full configuration uses a remote azurerm backend; this
# one does not, so that the demo can be destroyed and rebuilt without
# bootstrapping shared infrastructure first.
###############################################################################

terraform {
  required_version = ">= 1.6"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      # Demo environment: allow full teardown so the resource group can be
      # destroyed cleanly. The full configuration sets this to false, because
      # forensic recovery must remain possible in production.
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }

    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

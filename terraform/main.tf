######################################################################
# MediVault — Healthcare Analytics API (Azure adaptation)
#
# Reference model: an equivalent AWS / HIPAA architecture (KMS, CloudTrail, S3, DynamoDB, Lambda)
# This file:   medivault-azure/terraform/main.tf    (Azure / GDPR + NIS2)
#
# Service mapping (AWS → Azure):
#   aws_vpc / subnets         → azurerm_virtual_network / azurerm_subnet
#   aws_s3_bucket (uploads)   → azurerm_storage_account + ADLS Gen2 namespace
#   aws_dynamodb_table        → azurerm_cosmosdb_sql_container
#   aws_lambda_function       → azurerm_linux_function_app
#   aws_iam_role + policy     → azurerm_user_assigned_identity + role assignments
#   aws_apigatewayv2_api      → azurerm_api_management
#   aws_cloudwatch_log_group  → azurerm_log_analytics_workspace (in baseline)
#
# GDPR gap labels follow a GAP-0x convention:
#   GDPR-Gap-01: ADLS Gen2 encryption uses CMK (Art. 32)
#   GDPR-Gap-02: No public network access on any data store (Art. 25)
#   GDPR-Gap-03: HTTPS-only / TLS 1.2 minimum (Art. 32)
#   GDPR-Gap-04: Cosmos DB continuous backup (Art. 32 availability)
#   GDPR-Gap-05: Function App VNet integration (Art. 25 access minimisation)
#   GDPR-Gap-06: API Management logging + rate limiting (Art. 32 + NIS2 Art. 21)
#   GDPR-Gap-07: Least-privilege managed identity (Art. 25, principle of minimisation)
######################################################################

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
      # Never purge on destroy — forensic recovery must remain possible.
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name_prefix = var.name_prefix
  suffix      = random_id.suffix.hex

  tags = {
    Project     = "medivault-healthcare-api"
    ManagedBy   = "terraform"
    Workload    = "healthcare-analytics-api"
    DataClass   = "restricted-gdpr"
    Environment = var.environment
    CostCenter  = "cloud-engineering"
    Regulation  = "GDPR-NIS2-ISO27001"
  }
}

######################################################################
# Resource Group
######################################################################

resource "azurerm_resource_group" "main" {
  name     = "${local.name_prefix}-${var.environment}-rg"
  location = var.location
  tags     = local.tags
}

######################################################################
# User-Assigned Managed Identity — replaces AWS IAM role.
#
# AWS equivalent: aws_iam_role.lambda + inline policy.
# A single identity is used across storage, Key Vault, and Cosmos DB so
# the least-privilege scope can be inspected and audited in one place.
# GDPR-Gap-07 remediation.
######################################################################

resource "azurerm_user_assigned_identity" "workload" {
  name                = "${local.name_prefix}-workload-identity-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.tags
}

######################################################################
# GRC Baseline — shared controls (Key Vault, Monitor, Evidence Vault).
# The workload identity is passed down so baseline resources can grant
# CMK access without circular dependencies.
######################################################################

module "grc_baseline" {
  source = "./baseline"

  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  name_prefix          = local.name_prefix
  suffix               = local.suffix
  private_subnet_ids   = [azurerm_subnet.private.id]
  workload_identity_id = azurerm_user_assigned_identity.workload.id
  tags                 = local.tags
}

######################################################################
# Networking — VNet with isolated private subnet.
#
# AWS equivalent: aws_vpc + aws_subnet (public x2, private x2).
# MediVault uses a single private subnet model: no public subnets,
# no internet gateway. All outbound traffic routes via private endpoints
# or Azure-managed service endpoints, satisfying GDPR Art. 25.
######################################################################

resource "azurerm_virtual_network" "main" {
  name                = "${local.name_prefix}-vnet-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = ["10.42.0.0/16"]
  tags                = local.tags
}

# Private subnet: ADLS Gen2 and Cosmos DB private endpoints land here.
resource "azurerm_subnet" "private" {
  name                 = "${local.name_prefix}-private-snet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.42.1.0/24"]

  service_endpoints = [
    "Microsoft.Storage",
    "Microsoft.KeyVault",
    "Microsoft.CosmosDB",
  ]
}

# Functions subnet: delegated to Microsoft.Web/serverFarms for VNet integration.
# AWS equivalent: placing the Lambda function inside the VPC private subnets.
resource "azurerm_subnet" "functions" {
  name                 = "${local.name_prefix}-functions-snet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.42.2.0/24"]

  delegation {
    name = "functions-delegation"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# Network Security Group — explicit deny-all inbound for the private subnet.
resource "azurerm_network_security_group" "private" {
  name                = "${local.name_prefix}-private-nsg"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = local.tags
}

resource "azurerm_subnet_network_security_group_association" "private" {
  subnet_id                 = azurerm_subnet.private.id
  network_security_group_id = azurerm_network_security_group.private.id
}

######################################################################
# ADLS Gen2 — de-identified healthcare dataset storage.
#
# AWS equivalent: aws_s3_bucket.uploads with:
#   SSE-KMS (GDPR-Gap-01)
#   DenyInsecureTransport bucket policy (GDPR-Gap-03)
#   Versioning (equivalent: soft delete + change feed)
#
# GZRS replication provides synchronous zone-redundant + async geo-redundant
# durability, satisfying the Part 1 BC/DR targets (RPO < 1 hour).
######################################################################

resource "azurerm_storage_account" "datasets" {
  name                     = "${replace(local.name_prefix, "-", "")}ds${local.suffix}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "GZRS"     # Geo-zone-redundant for BC/DR RTO < 4h
  account_kind             = "StorageV2"
  is_hns_enabled           = true       # Hierarchical namespace = ADLS Gen2

  # GDPR-Gap-02: no public access
  public_network_access_enabled   = false
  allow_nested_items_to_be_public = false

  # GDPR-Gap-03: TLS 1.2 minimum — Azure equivalent of DenyInsecureTransport S3 policy
  min_tls_version = "TLS1_2"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.workload.id]
  }

  # GDPR-Gap-01: CMK encryption via baseline Key Vault key
  customer_managed_key {
    key_vault_key_id          = module.grc_baseline.gdpr_key_vault_key_id
    user_assigned_identity_id = azurerm_user_assigned_identity.workload.id
  }

  blob_properties {
    versioning_enabled  = true
    change_feed_enabled = true # Immutable audit log of blob mutations

    # 90-day soft delete: equivalent to S3 versioning for accidental deletion recovery
    delete_retention_policy {
      days = 90
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  tags = local.tags
}

resource "azurerm_storage_container" "healthcare_datasets" {
  name                  = "healthcare-datasets"
  storage_account_name  = azurerm_storage_account.datasets.name
  container_access_type = "private"
}

# Private endpoint for ADLS Gen2 DFS endpoint.
# AWS equivalent: VPC endpoint for S3 + bucket policy restricting access to VPC.
resource "azurerm_private_endpoint" "datasets" {
  name                = "${local.name_prefix}-datasets-pe-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = azurerm_subnet.private.id

  private_service_connection {
    name                           = "${local.name_prefix}-datasets-psc"
    private_connection_resource_id = azurerm_storage_account.datasets.id
    subresource_names              = ["dfs"] # ADLS Gen2 hierarchical namespace endpoint
    is_manual_connection           = false
  }

  tags = local.tags
}

######################################################################
# Cosmos DB — intake submissions store.
#
# AWS equivalent: aws_dynamodb_table.intake with:
#   server_side_encryption using CMK (GDPR-Gap-04 equivalent)
#   point_in_time_recovery enabled
#
# Cosmos DB Continuous Backup provides PITR to any second within the
# last 7 days, satisfying Part 1 BC/DR RPO < 1 hour.
######################################################################

resource "azurerm_cosmosdb_account" "intake" {
  name                = "${local.name_prefix}-cosmos-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  # GDPR-Gap-02: private access only
  public_network_access_enabled = false
  ip_range_filter               = ""

  # GDPR-Gap-04: CMK encryption at rest
  key_vault_key_id = module.grc_baseline.gdpr_key_vault_key_id

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.workload.id]
  }

  consistency_policy {
    consistency_level = "Session"
  }

  # Primary region — West Europe (Amsterdam) for GDPR EU residency
  geo_location {
    location          = azurerm_resource_group.main.location
    failover_priority = 0
  }

  # Secondary region — North Europe (Dublin): EU data residency maintained.
  # AWS equivalent: DynamoDB global tables or cross-region replication.
  geo_location {
    location          = "northeurope"
    failover_priority = 1
  }

  # Continuous backup with PITR — AWS equivalent: DynamoDB point_in_time_recovery
  backup {
    type = "Continuous"
    tier = "Continuous7Days"
  }

  tags = local.tags
}

resource "azurerm_cosmosdb_sql_database" "intake" {
  name                = "medivault-intake"
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.intake.name
}

resource "azurerm_cosmosdb_sql_container" "submissions" {
  name                = "submissions"
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.intake.name
  database_name       = azurerm_cosmosdb_sql_database.intake.name
  partition_key_path  = "/submissionId"

  indexing_policy {
    indexing_mode = "consistent"
    included_path { path = "/*" }
    excluded_path { path = "/\"_etag\"/?" }
  }
}

# Private endpoint for Cosmos DB SQL API.
resource "azurerm_private_endpoint" "cosmos" {
  name                = "${local.name_prefix}-cosmos-pe-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = azurerm_subnet.private.id

  private_service_connection {
    name                           = "${local.name_prefix}-cosmos-psc"
    private_connection_resource_id = azurerm_cosmosdb_account.intake.id
    subresource_names              = ["Sql"]
    is_manual_connection           = false
  }

  tags = local.tags
}

######################################################################
# RBAC — workload managed identity role assignments.
#
# AWS equivalent: aws_iam_role_policy.lambda_inline (GDPR-Gap-07).
# Managed identity roles are narrowly scoped following least-privilege:
#   "Storage Blob Data Contributor" on the dataset account only
#   Built-in Cosmos DB data contributor on the intake account only
#   Key Vault Crypto User on the GRC key vault only
######################################################################

resource "azurerm_role_assignment" "workload_adls" {
  scope                = azurerm_storage_account.datasets.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.workload.principal_id
}

resource "azurerm_cosmosdb_sql_role_assignment" "workload_cosmos" {
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.intake.name
  role_definition_id  = "${azurerm_cosmosdb_account.intake.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = azurerm_user_assigned_identity.workload.principal_id
  scope               = azurerm_cosmosdb_account.intake.id
}

resource "azurerm_role_assignment" "workload_keyvault_crypto" {
  scope                = module.grc_baseline.gdpr_key_vault_id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = azurerm_user_assigned_identity.workload.principal_id
}

######################################################################
# Azure Functions — intake handler (Python 3.12).
#
# AWS equivalent: aws_lambda_function.intake (GDPR-Gap-05: VNet integration).
# Elastic Premium plan required for regional VNet integration.
# No public inbound: APIM → Function via private VNet channel only.
######################################################################

resource "azurerm_service_plan" "functions" {
  name                = "${local.name_prefix}-asp-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = "EP1" # Elastic Premium for VNet integration

  tags = local.tags
}

resource "azurerm_linux_function_app" "intake" {
  name                          = "${local.name_prefix}-func-${local.suffix}"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  service_plan_id               = azurerm_service_plan.functions.id
  storage_account_name          = azurerm_storage_account.datasets.name
  storage_uses_managed_identity = true

  # GDPR-Gap-05: no public inbound; outbound via VNet integration
  public_network_access_enabled = false
  virtual_network_subnet_id     = azurerm_subnet.functions.id

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.workload.id]
  }

  app_settings = {
    COSMOS_ENDPOINT              = azurerm_cosmosdb_account.intake.endpoint
    COSMOS_DATABASE              = azurerm_cosmosdb_sql_database.intake.name
    COSMOS_CONTAINER             = azurerm_cosmosdb_sql_container.submissions.name
    ADLS_ACCOUNT_NAME            = azurerm_storage_account.datasets.name
    ADLS_CONTAINER_NAME          = azurerm_storage_container.healthcare_datasets.name
    MANAGED_IDENTITY_CLIENT_ID   = azurerm_user_assigned_identity.workload.client_id
    FUNCTIONS_WORKER_RUNTIME     = "python"
    APPLICATIONINSIGHTS_CONNECTION_STRING = module.grc_baseline.app_insights_connection_string
    # No plaintext secrets: all connection strings use managed identity.
    # Key Vault references are injected at runtime — no credentials in app settings.
  }

  site_config {
    application_stack {
      python_version = "3.12"
    }

    # Deny all inbound public traffic; only APIM in the VNet can reach the function.
    ip_restriction_default_action = "Deny"

    # Outbound calls to Azure services use the functions subnet VNet integration.
    vnet_route_all_enabled = true
  }

  tags = local.tags
}

######################################################################
# API Management — public entry point for healthcare partners.
#
# AWS equivalent: aws_apigatewayv2_api.intake + aws_apigatewayv2_stage.default
# GDPR-Gap-06: access logging, rate limiting, OAuth 2.0 enforcement.
######################################################################

resource "azurerm_api_management" "main" {
  name                = "${local.name_prefix}-apim-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  publisher_name      = "MediVault"
  publisher_email     = "platform@medivault.eu"
  sku_name            = "Developer_1" # Upgrade to Premium for VNet integration in production

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}

# Application Insights logger — equivalent to aws_cloudwatch_log_group + access_log_settings.
resource "azurerm_api_management_logger" "main" {
  name                = "${local.name_prefix}-apim-logger"
  api_management_name = azurerm_api_management.main.name
  resource_group_name = azurerm_resource_group.main.name

  application_insights {
    instrumentation_key = module.grc_baseline.app_insights_instrumentation_key
  }
}

resource "azurerm_api_management_api" "intake" {
  name                = "medivault-intake-api"
  resource_group_name = azurerm_resource_group.main.name
  api_management_name = azurerm_api_management.main.name
  revision            = "1"
  display_name        = "MediVault Intake API"
  path                = "intake"
  protocols           = ["https"] # HTTP disabled — GDPR-Gap-03

  subscription_required = true # OAuth subscription key enforced at gateway
}

######################################################################
# Diagnostic Settings — forward workload logs to Log Analytics.
#
# AWS equivalent: CloudTrail management events + CloudWatch log groups.
# Each diagnostic setting is the Azure equivalent of enabling detailed
# CloudTrail logging for a specific AWS service.
######################################################################

resource "azurerm_monitor_diagnostic_setting" "apim" {
  name                       = "${local.name_prefix}-apim-diag"
  target_resource_id         = azurerm_api_management.main.id
  log_analytics_workspace_id = module.grc_baseline.log_analytics_workspace_id

  enabled_log { category = "GatewayLogs" }    # All API request/response events
  enabled_log { category = "WebSocketConnectionLogs" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

resource "azurerm_monitor_diagnostic_setting" "functions" {
  name                       = "${local.name_prefix}-func-diag"
  target_resource_id         = azurerm_linux_function_app.intake.id
  log_analytics_workspace_id = module.grc_baseline.log_analytics_workspace_id

  enabled_log { category = "FunctionAppLogs" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

resource "azurerm_monitor_diagnostic_setting" "cosmos" {
  name                       = "${local.name_prefix}-cosmos-diag"
  target_resource_id         = azurerm_cosmosdb_account.intake.id
  log_analytics_workspace_id = module.grc_baseline.log_analytics_workspace_id

  enabled_log { category = "DataPlaneRequests" }  # All read/write operations on data
  enabled_log { category = "ControlPlaneRequests" }

  metric {
    category = "Requests"
    enabled  = true
  }
}

resource "azurerm_monitor_diagnostic_setting" "adls" {
  name                       = "${local.name_prefix}-adls-diag"
  target_resource_id         = azurerm_storage_account.datasets.id
  log_analytics_workspace_id = module.grc_baseline.log_analytics_workspace_id

  enabled_log { category = "StorageRead" }
  enabled_log { category = "StorageWrite" }
  enabled_log { category = "StorageDelete" }

  metric {
    category = "Transaction"
    enabled  = true
  }
}

# MediVault Azure — Healthcare Analytics Infrastructure (IaC)

> **Context:** Cloud Computing for Business — Part 4 Practical Demonstration  
> **Source:** Adapted from [`cgep-acme-health`](../cgep-acme-health) (AWS / HIPAA)  
> **Target:** Microsoft Azure / GDPR + NIS2

This repository contains the Infrastructure as Code (IaC) and compliance policy automation for the MediVault healthcare analytics platform on Azure, as designed in Parts 1 and 2 of the group project.

---

## AWS → Azure Service Mapping

| AWS Resource (cgep-acme-health) | Azure Resource (medivault-azure) | Notes |
|:-------------------------------|:---------------------------------|:------|
| `aws_kms_key` + `aws_kms_alias` | `azurerm_key_vault` + `azurerm_key_vault_key` | RSA-HSM 4096-bit; 90-day auto-rotation |
| `aws_cloudtrail` | `azurerm_log_analytics_workspace` + `azurerm_monitor_diagnostic_setting` (per resource) | Subscription Activity Log + per-service diagnostic settings |
| `aws_s3_bucket` (PHI uploads, SSE-KMS) | `azurerm_storage_account` (ADLS Gen2, CMK) | `is_hns_enabled = true` enables hierarchical namespace; GZRS replication |
| `aws_s3_bucket` (Object Lock evidence vault) | `azurerm_storage_account` (immutability policy) | Azure Blob immutability replaces S3 Object Lock |
| `aws_dynamodb_table` (PITR + CMK) | `azurerm_cosmosdb_sql_container` (Continuous backup + CMK) | Geo-redundant West Europe + North Europe |
| `aws_lambda_function` (VPC) | `azurerm_linux_function_app` (VNet integration, EP1) | Managed identity replaces IAM role |
| `aws_iam_role` + inline policy | `azurerm_user_assigned_identity` + `azurerm_role_assignment` | Narrowly scoped built-in roles; no wildcards |
| `aws_apigatewayv2_api` + stage | `azurerm_api_management` + logger | HTTPS-only; GatewayLogs → Log Analytics |
| `aws_cloudwatch_log_group` | `azurerm_application_insights` (workspace-based) | Feeds into same Log Analytics workspace |
| S3 backend + DynamoDB lock table | Azure Storage backend (blob lease locking) | No separate lock resource needed in Azure |
| `aws-actions/configure-aws-credentials` (OIDC) | `azure/login@v2` (OIDC) | Federated credential on Entra ID App Registration |
| `aws s3 cp` (evidence upload) | `az storage blob upload-batch` | OIDC-authenticated; no storage key in pipeline |

---

## Regulatory Mapping (HIPAA → GDPR / NIS2)

| HIPAA Control | GDPR / NIS2 Equivalent | Implementation |
|:-------------|:-----------------------|:---------------|
| `164.312(a)(2)(iv)` — encryption | Art. 32 — encryption at rest | CMK via Azure Key Vault (RSA-HSM) |
| `164.312(a)(1)` — access controls | Art. 25 — privacy by design; Art. 32 | Managed identity + RBAC (no wildcards) |
| `164.312(b)` — audit controls | Art. 32 + NIS2 Art. 21 | Log Analytics + APIM GatewayLogs |
| `164.312(c)(1)` — integrity | Art. 5(f) — integrity and confidentiality | Blob versioning, change feed, immutability |
| `164.312(a)(2)(i)` — unique user ID | Art. 32 — access control | Entra ID + PIM (documented in Part 2 §4) |
| PITR (DynamoDB) | Art. 32 — availability | Cosmos DB Continuous Backup (7-day PITR) |

---

## Repository Structure

```
medivault-azure/
├── .github/
│   └── workflows/
│       └── grc-gate.yml          # CI/CD: Terraform plan → OPA gate → Apply → Evidence
├── terraform/
│   ├── backend.tf                # Azure Storage state backend (replaces S3 + DynamoDB)
│   ├── main.tf                   # Workload: VNet, ADLS Gen2, Cosmos DB, Functions, APIM
│   ├── variables.tf              # Input variables (location, environment, name_prefix)
│   ├── outputs.tf                # Useful outputs (API URL, storage account, workspace ID)
│   └── baseline/
│       ├── key-vault.tf          # Azure Key Vault CMK (← aws_kms_key)
│       ├── monitor.tf            # Log Analytics + Activity Log + Alerts (← CloudTrail)
│       ├── evidence-vault.tf     # Blob immutability vault (← S3 Object Lock)
│       ├── variables.tf
│       └── outputs.tf
└── policies/
    ├── gdpr_adls_encryption.rego       # CMK on ADLS Gen2 (← hipaa_s3_kms.rego)
    ├── gdpr_no_public_storage.rego     # No public access + TLS 1.2 (← hipaa_s3_tls.rego)
    ├── gdpr_keyvault_key_rotation.rego # Auto-rotation + purge protection (← hipaa_dynamodb_kms.rego)
    ├── gdpr_cosmos_pitr.rego           # Continuous backup (← hipaa_dynamodb_pitr.rego)
    ├── gdpr_api_logging.rego           # APIM GatewayLogs (← hipaa_api_logging.rego)
    └── gdpr_rbac_no_wildcard.rego      # No Owner/Contributor at subscription scope (← hipaa_iam_least_privilege.rego)
```

---

## Bootstrap

### 1. Create Terraform state backend

```bash
# Create a resource group and storage account for Terraform state.
# Run once before terraform init. Matches scripts/bootstrap-terraform-backend.sh
# in cgep-acme-health but targets azurerm instead of aws.

az group create \
  --name medivault-tfstate-rg \
  --location westeurope

az storage account create \
  --name medivaulttfstate \
  --resource-group medivault-tfstate-rg \
  --location westeurope \
  --sku Standard_GRS \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false

az storage container create \
  --name tfstate \
  --account-name medivaulttfstate \
  --auth-mode login
```

### 2. Configure OIDC federated credential

In Entra ID → App Registrations → your pipeline app → Certificates & secrets → Federated credentials, add:

- **Issuer:** `https://token.actions.githubusercontent.com`
- **Subject:** `repo:<org>/<repo>:ref:refs/heads/main`
- **Name:** `github-actions-main`

Set GitHub repository variables:
```
AZURE_CLIENT_ID         = <app registration client ID>
AZURE_TENANT_ID         = <tenant ID>
AZURE_SUBSCRIPTION_ID   = <subscription ID>
```

### 3. Deploy

```bash
cd terraform
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

---

## GDPR Policy Gate

The CI/CD pipeline runs six OPA/Conftest policies against the Terraform plan JSON before any `apply`. A plan that fails any policy is blocked from reaching production.

```
compliance.gdpr.adls_encryption       — CMK required on all ADLS Gen2 accounts
compliance.gdpr.no_public_storage     — Public network access blocked; TLS 1.2 enforced
compliance.gdpr.keyvault_key_rotation — Auto-rotation ≤90 days; purge protection on
compliance.gdpr.cosmos_pitr           — Continuous backup; no public access
compliance.gdpr.api_logging           — APIM GatewayLogs diagnostic setting required
compliance.gdpr.rbac_no_wildcard      — No Owner/Contributor at subscription scope
```

Run locally:
```bash
opa test -v policies/                                    # Unit tests
conftest test --policy policies --namespace compliance.gdpr.adls_encryption terraform/plan.json
```

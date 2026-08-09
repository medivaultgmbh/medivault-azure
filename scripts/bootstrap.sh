#!/usr/bin/env bash
#
# Bootstrap the deploy identity for the GRC gate.
#
# Creates one Entra ID application with:
#   - Contributor on the subscription (needed to create resource groups)
#   - User Access Administrator (needed for the role assignment in minimal/)
#   - federated credentials for GitHub Actions OIDC - no client secret
#
# Run once, as a subscription Owner. Idempotent: safe to re-run.
#
# Usage:
#   ./scripts/bootstrap.sh <github-org> <github-repo>
#
set -euo pipefail

ORG="${1:?usage: bootstrap.sh <github-org> <github-repo>}"
REPO="${2:?usage: bootstrap.sh <github-org> <github-repo>}"

APP_NAME="TF.MediVaultDeploy.ServicePrincipal"
ENVIRONMENT="medivault-demo"

echo "==> Checking Azure CLI login"
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
ACCOUNT=$(az account show --query user.name -o tsv)
echo "    subscription : $SUBSCRIPTION_ID"
echo "    tenant       : $TENANT_ID"
echo "    signed in as : $ACCOUNT"

# Pin the CLI to this subscription explicitly. Without this, a multi-tenant or
# multi-subscription login can leave the default context pointing elsewhere.
az account set --subscription "$SUBSCRIPTION_ID"

# Preflight: identity operations (app registration, role assignment) hit Entra
# and Authorization endpoints, which can succeed while the ARM resource plane
# is still unavailable - typically on a newly created subscription, or one that
# is disabled or expired. Fail here with a useful message rather than midway.
echo
echo "==> Preflight: checking ARM access to the subscription"
STATE=$(az account show --query state -o tsv 2>/dev/null || echo "Unknown")
echo "    subscription state : $STATE"

if ! az group list --subscription "$SUBSCRIPTION_ID" --query "[0].name" -o tsv >/dev/null 2>&1; then
  cat <<EOF

ERROR: Azure Resource Manager cannot reach subscription $SUBSCRIPTION_ID.

Identity objects may already have been created - this script is idempotent, so
re-run it once the cause below is resolved.

Diagnose:
  az account list --refresh --all --output table
  az account show --query "{name:name, state:state, tenant:tenantId}" -o jsonc

Common causes:
  - Subscription state is not "Enabled" (expired free trial, disabled, or
    still provisioning). A brand-new subscription can take a few minutes
    before ARM operations succeed.
  - Stale CLI token cache. Fix:  az account clear && az login
  - Resource providers not yet registered. Fix:
      az provider register --namespace Microsoft.Storage --wait

EOF
  exit 1
fi
echo "    ARM access         : OK"

###############################################################################
# GitHub numeric IDs.
#
# Organisations using immutable OIDC subject claims emit
#   repo:<org>@<orgId>/<repo>@<repoId>:environment:<env>
# rather than the classic name-only form. We create BOTH federated credentials
# so the pipeline authenticates either way - Entra matches the subject exactly
# and simply ignores the one that does not apply.
###############################################################################
echo
echo "==> Resolving GitHub numeric IDs"
ORG_ID=$(curl -fsSL "https://api.github.com/orgs/${ORG}" | jq -r .id 2>/dev/null || echo "")
REPO_ID=$(curl -fsSL "https://api.github.com/repos/${ORG}/${REPO}" | jq -r .id 2>/dev/null || echo "")

if [[ -n "$ORG_ID" && "$ORG_ID" != "null" ]]; then
  echo "    org id  : $ORG_ID"
  echo "    repo id : $REPO_ID"
else
  echo "    could not resolve (private repo or rate limited) - creating classic subject only"
fi

###############################################################################
# Application + service principal
###############################################################################
echo
echo "==> Creating application: $APP_NAME"
APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)

if [[ -z "$APP_ID" ]]; then
  APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
  echo "    created  : $APP_ID"
else
  echo "    exists   : $APP_ID"
fi

if ! az ad sp show --id "$APP_ID" >/dev/null 2>&1; then
  az ad sp create --id "$APP_ID" >/dev/null
  echo "    service principal created"
fi

SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

###############################################################################
# Azure RBAC
#
# Contributor       - create and manage resources
# User Access Admin - required because terraform/minimal creates a role
#                     assignment (Storage Blob Data Contributor on the evidence
#                     vault). Contributor alone cannot grant roles.
#
# Both are scoped to this subscription only. Note this is intentionally broader
# than the read-only identities in the Entra governance repo: this one deploys
# infrastructure, so it needs write. That asymmetry is the reason the two
# concerns live in separate identities.
###############################################################################
echo
echo "==> Assigning Azure roles (subscription scope)"
for ROLE in "Contributor" "User Access Administrator"; do
  if az role assignment list --assignee "$APP_ID" --role "$ROLE" \
       --scope "/subscriptions/${SUBSCRIPTION_ID}" --query "[0].id" -o tsv | grep -q .; then
    echo "    already assigned : $ROLE"
  else
    az role assignment create \
      --assignee-object-id "$SP_OBJECT_ID" \
      --assignee-principal-type ServicePrincipal \
      --role "$ROLE" \
      --scope "/subscriptions/${SUBSCRIPTION_ID}" >/dev/null
    echo "    assigned         : $ROLE"
  fi
done

###############################################################################
# FinOps guardrail - subscription budget
#
# WHY THIS LIVES IN BOOTSTRAP RATHER THAN IN TERRAFORM
#
# The budget was originally defined in terraform/minimal alongside the demo
# workload. That coupled the guardrail to the thing it guards: the budget only
# existed once the demo was deployed, and `terraform destroy` removed it. A
# spending alarm that disappears when you tear down the workload is backwards -
# the window where you most want it is exactly when resources are being created
# and destroyed.
#
# It belongs with the other subscription-level prerequisites: created once,
# before anything is deployed, and outliving every deployment.
#
# Created via `az rest` rather than `az consumption budget create`, which is
# still flagged preview and has an awkward surface for subscription scope.
#
# IMPORTANT: an Azure budget ALERTS. It does not cap. Pay-as-you-go has no hard
# spending limit. See docs/FINOPS.md.
###############################################################################
BUDGET_NAME="medivault-subscription-ceiling"
BUDGET_AMOUNT="${BUDGET_AMOUNT:-20}"
BUDGET_EMAIL="${COST_ALERT_EMAIL:-$ACCOUNT}"

# Budgets must start on the first of a month; end date is a year out.
BUDGET_START=$(date -u +%Y-%m-01)
BUDGET_END=$(date -u -v+1y +%Y-%m-01 2>/dev/null || date -u -d "+1 year" +%Y-%m-01)

echo
echo "==> Creating subscription budget"
echo "    name    : $BUDGET_NAME"
echo "    amount  : $BUDGET_AMOUNT (subscription billing currency)"
echo "    alerts  : $BUDGET_EMAIL"

BUDGET_BODY=$(cat <<JSON
{
  "properties": {
    "category": "Cost",
    "amount": ${BUDGET_AMOUNT},
    "timeGrain": "Monthly",
    "timePeriod": {
      "startDate": "${BUDGET_START}T00:00:00Z",
      "endDate": "${BUDGET_END}T00:00:00Z"
    },
    "notifications": {
      "actual_50": {
        "enabled": true, "operator": "GreaterThanOrEqualTo", "threshold": 50,
        "contactEmails": ["${BUDGET_EMAIL}"], "thresholdType": "Actual"
      },
      "actual_80": {
        "enabled": true, "operator": "GreaterThanOrEqualTo", "threshold": 80,
        "contactEmails": ["${BUDGET_EMAIL}"], "thresholdType": "Actual"
      },
      "actual_100": {
        "enabled": true, "operator": "GreaterThanOrEqualTo", "threshold": 100,
        "contactEmails": ["${BUDGET_EMAIL}"], "thresholdType": "Actual"
      },
      "forecast_90": {
        "enabled": true, "operator": "GreaterThanOrEqualTo", "threshold": 90,
        "contactEmails": ["${BUDGET_EMAIL}"], "thresholdType": "Forecasted"
      }
    }
  }
}
JSON
)

if az rest --method put \
     --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Consumption/budgets/${BUDGET_NAME}?api-version=2023-05-01" \
     --body "$BUDGET_BODY" \
     --output none 2>/dev/null; then
  echo "    created (alerts at 50%, 80%, 100% actual and 90% forecast)"
else
  echo "    WARNING: budget creation failed - create it in the portal under"
  echo "             Cost Management + Billing > Budgets. Not fatal."
fi

###############################################################################
# Federated credentials
###############################################################################
add_fic() {
  local name="$1" subject="$2"
  if az ad app federated-credential list --id "$APP_ID" \
       --query "[?name=='${name}'] | [0].name" -o tsv | grep -q .; then
    echo "    exists  : $name"
    return
  fi
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"${name}\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"${subject}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" >/dev/null
  echo "    created : $name"
  echo "              -> ${subject}"
}

echo
echo "==> Creating federated credentials"

# Environment-scoped: used by the deploy-demo job.
add_fic "github-env-${ENVIRONMENT}" "repo:${ORG}/${REPO}:environment:${ENVIRONMENT}"

# Branch-scoped: used by the policy-gate jobs, which run on push to main
# without an environment.
add_fic "github-main" "repo:${ORG}/${REPO}:ref:refs/heads/main"

# Pull requests, so the gate runs on PRs too.
add_fic "github-pr" "repo:${ORG}/${REPO}:pull_request"

if [[ -n "$ORG_ID" && "$ORG_ID" != "null" ]]; then
  add_fic "github-env-${ENVIRONMENT}-immutable" "repo:${ORG}@${ORG_ID}/${REPO}@${REPO_ID}:environment:${ENVIRONMENT}"
  add_fic "github-main-immutable"                "repo:${ORG}@${ORG_ID}/${REPO}@${REPO_ID}:ref:refs/heads/main"
  add_fic "github-pr-immutable"                  "repo:${ORG}@${ORG_ID}/${REPO}@${REPO_ID}:pull_request"
fi

###############################################################################
# Terraform state backend (non-fatal)
#
# Ordered AFTER the federated credentials deliberately. The policy gate runs
# `terraform init -backend=false` and needs no remote state at all - only the
# demo deployment does. An earlier version created the backend first, so a
# storage failure left the credentials uncreated and blocked the gate for a
# reason unrelated to it.
#
# Dependencies should be ordered by what depends on them, not by narrative
# convenience. Failures here warn and continue.
###############################################################################
set +e
STATE_RG="medivault-tfstate-rg"
STATE_SA="mvtfstate$(echo -n "$SUBSCRIPTION_ID" | sha256sum | cut -c1-12)"

echo
echo "==> Creating Terraform state backend"
echo "    resource group  : $STATE_RG"
echo "    storage account : $STATE_SA"

az group create --name "$STATE_RG" --location westeurope \
  --subscription "$SUBSCRIPTION_ID" --output none

if az group show --name "$STATE_RG" --subscription "$SUBSCRIPTION_ID" >/dev/null 2>&1; then
  echo "    resource group ready"
else
  echo "    resource group NOT created - skipping backend"
  STATE_RG=""
fi

if ! az storage account show --name "$STATE_SA" --resource-group "$STATE_RG" --subscription "$SUBSCRIPTION_ID" >/dev/null 2>&1; then
  az storage account create \
    --name "$STATE_SA" \
    --resource-group "$STATE_RG" \
    --subscription "$SUBSCRIPTION_ID" \
    --location westeurope \
    --sku Standard_LRS \
    --kind StorageV2 \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    --output none

  # Verify rather than assume. The previous version announced success whenever
  # the create command did not error, which produced "storage account created"
  # immediately followed by ParentResourceNotFound - a status line reporting
  # intent instead of outcome is worse than no status line at all.
  if az storage account show --name "$STATE_SA" --resource-group "$STATE_RG" \
       --subscription "$SUBSCRIPTION_ID" >/dev/null 2>&1; then
    echo "    storage account created"
  else
    echo "    storage account NOT created - see the error above"
  fi
else
  echo "    storage account exists"
fi

# Versioning protects against a corrupted or truncated state write.
az storage account blob-service-properties update \
  --account-name "$STATE_SA" \
  --resource-group "$STATE_RG" \
  --subscription "$SUBSCRIPTION_ID" \
  --enable-versioning true \
  --output none

az storage container create \
  --name tfstate \
  --account-name "$STATE_SA" \
  --auth-mode login \
  --output none 2>/dev/null || true

# The deploy identity needs data-plane access to read and write state.
az role assignment create \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "$(az storage account show --name "$STATE_SA" --resource-group "$STATE_RG" --subscription "$SUBSCRIPTION_ID" --query id -o tsv)" \
  --output none 2>/dev/null || true
echo "    state access granted to deploy identity"

set -e

if ! az storage account show --name "$STATE_SA" --resource-group "$STATE_RG" \
       --subscription "$SUBSCRIPTION_ID" >/dev/null 2>&1; then
  echo
  echo "    WARNING: state backend not available."
  echo "    The POLICY GATE is unaffected - it runs terraform init -backend=false."
  echo "    Only the demo deployment (deploy-demo) needs remote state."
fi


###############################################################################
# Output
###############################################################################
cat <<EOF

════════════════════════════════════════════════════════════════════
 Bootstrap complete
════════════════════════════════════════════════════════════════════

Add these as repository VARIABLES (Settings > Secrets and variables >
Actions > Variables). They are identifiers, not secrets:

  AZURE_CLIENT_ID        ${APP_ID}
  AZURE_TENANT_ID        ${TENANT_ID}
  AZURE_SUBSCRIPTION_ID  ${SUBSCRIPTION_ID}
  TFSTATE_RESOURCE_GROUP ${STATE_RG}
  TFSTATE_STORAGE_ACCOUNT ${STATE_SA}

And these two for the FinOps guardrail:

  COST_ALERT_EMAIL       <your email>   (REQUIRED - deploy refuses without it)
  BUDGET_AMOUNT          20             (optional, defaults to 20)

Then create an environment named:

  ${ENVIRONMENT}

(Settings > Environments > New environment). No variables needed on the
environment itself - the repository-level ones above are inherited.

Run the gate:
  Actions > GRC Gate > Run workflow
  Tick "Apply terraform/minimal" to deploy the governance plane.

Local use of the demo config:
  cd terraform/minimal
  terraform init \\
    -backend-config="resource_group_name=${STATE_RG}" \\
    -backend-config="storage_account_name=${STATE_SA}" \\
    -backend-config="container_name=tfstate"

Teardown when finished (do this - it stops the meter):
  terraform destroy
EOF

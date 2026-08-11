#!/usr/bin/env bash
#
# Create the Terraform state backend, loudly.
#
# bootstrap.sh creates this non-fatally so a storage failure cannot block
# credential creation. That is the right trade-off, but it means the backend
# can be missing while everything else succeeded. This script does only the
# backend, fails hard, and prints the real error.
#
#   ./scripts/create-state-backend.sh
#
# Idempotent. Safe to re-run.
#
set -euo pipefail

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
APP_NAME="TF.MediVaultDeploy.ServicePrincipal"
STATE_RG="medivault-tfstate-rg"

# Region candidates, in preference order.
#
# Azure refuses new resources in regions that are at capacity for new
# customers ("RequestDisallowedByAzure ... not accepting new customers"), and
# which regions those are is not published and changes over time. So the region
# is probed rather than assumed. All candidates are EU, which the GDPR data
# residency requirement makes non-negotiable - the fallback widens the region,
# never the jurisdiction.
#
# Germany West Central (Frankfurt) leads: MediVault is a German entity, so
# German residency is the strongest position, not merely an adequate one.
REGIONS=(germanywestcentral swedencentral francecentral northeurope westeurope)
STATE_SA="mvtfstate$(echo -n "$SUBSCRIPTION_ID" | sha256sum | cut -c1-12)"

echo "==> Target"
echo "    subscription : $SUBSCRIPTION_ID"
echo "    resource grp : $STATE_RG"
echo "    account      : $STATE_SA"

# On a fresh subscription this is the usual reason storage creation fails.
echo
echo "==> Registering Microsoft.Storage (idempotent, may take a minute)"
az provider register --namespace Microsoft.Storage --subscription "$SUBSCRIPTION_ID" --wait
az provider show --namespace Microsoft.Storage --subscription "$SUBSCRIPTION_ID" \
  --query registrationState -o tsv | sed 's/^/    state: /'

echo
echo "==> Finding an EU region that accepts new resources"

LOCATION=""
for r in "${REGIONS[@]}"; do
  printf '    %-22s ' "$r"

  az group create --name "$STATE_RG" --location "$r" \
    --subscription "$SUBSCRIPTION_ID" --output none 2>/dev/null || true

  if az storage account show --name "$STATE_SA" --resource-group "$STATE_RG" \
       --subscription "$SUBSCRIPTION_ID" >/dev/null 2>&1; then
    echo "account already exists here"
    LOCATION="$r"
    break
  fi

  ERR=$(az storage account create \
        --name "$STATE_SA" \
        --resource-group "$STATE_RG" \
        --subscription "$SUBSCRIPTION_ID" \
        --location "$r" \
        --sku Standard_LRS \
        --kind StorageV2 \
        --min-tls-version TLS1_2 \
        --allow-blob-public-access false \
        --output none 2>&1) && { echo "created"; LOCATION="$r"; break; }

  case "$ERR" in
    *RequestDisallowedByAzure*|*locationineligible*|*NotAvailableForSubscription*)
      echo "not accepting new customers - trying next" ;;
    *)
      # Anything else is a real error and must not be retried into silence.
      echo "FAILED"
      echo
      echo "$ERR" >&2
      exit 1 ;;
  esac
done

if [ -z "$LOCATION" ]; then
  echo
  echo "ERROR: no candidate EU region accepted the request." >&2
  echo "Check available regions:  az account list-locations --query \"[?metadata.geography=='Europe'].name\" -o tsv" >&2
  exit 1
fi

echo "    using: $LOCATION"

echo
echo "==> Blob versioning (protects against a truncated state write)"
az storage account blob-service-properties update \
  --account-name "$STATE_SA" --resource-group "$STATE_RG" \
  --subscription "$SUBSCRIPTION_ID" --enable-versioning true --output none
echo "    enabled"

echo
echo "==> Container"
az storage container create --name tfstate --account-name "$STATE_SA" \
  --auth-mode login --output none
echo "    ok"

echo
echo "==> Data-plane access for the deploy identity"
APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)
[ -n "$APP_ID" ] || { echo "ERROR: $APP_NAME not found. Run scripts/bootstrap.sh first." >&2; exit 1; }
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)
SA_ID=$(az storage account show --name "$STATE_SA" --resource-group "$STATE_RG" \
          --subscription "$SUBSCRIPTION_ID" --query id -o tsv)

az role assignment create \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "$SA_ID" --output none 2>/dev/null || echo "    (already assigned)"

az role assignment list --assignee "$APP_ID" --scope "$SA_ID" \
  --query "[].roleDefinitionName" -o tsv | sed 's/^/    role: /'

echo
echo "════════════════════════════════════════════════════════════════════"
echo " State backend ready: $STATE_SA  ($LOCATION)"
echo "════════════════════════════════════════════════════════════════════"
echo
echo "The demo deployment must use the same region. Set it as a repo variable:"
echo "  gh variable set AZURE_LOCATION --repo medivaultgmbh/medivault-azure --body $LOCATION"
echo
echo "Next:"
echo "  gh workflow run 'GRC Gate' --repo medivaultgmbh/medivault-azure -f deploy_demo=true"
echo "  gh run watch --repo medivaultgmbh/medivault-azure"

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
echo "==> Resource group"
az group create --name "$STATE_RG" --location westeurope \
  --subscription "$SUBSCRIPTION_ID" --output none
echo "    ok"

echo
echo "==> Storage account"
if az storage account show --name "$STATE_SA" --resource-group "$STATE_RG" \
     --subscription "$SUBSCRIPTION_ID" >/dev/null 2>&1; then
  echo "    already exists"
else
  # No 2>/dev/null and no || true: if this fails, the error is the whole point.
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
  echo "    created"
fi

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
echo " State backend ready: $STATE_SA"
echo "════════════════════════════════════════════════════════════════════"
echo
echo "Next:"
echo "  gh workflow run 'GRC Gate' --repo medivaultgmbh/medivault-azure -f deploy_demo=true"
echo "  gh run watch --repo medivaultgmbh/medivault-azure"

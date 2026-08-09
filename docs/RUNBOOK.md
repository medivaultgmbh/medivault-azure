# Runbook

Getting the GRC gate running, and deploying the demo governance plane.

Prerequisites: Azure CLI, Terraform ≥ 1.6, `jq`, and subscription **Owner**
(needed to grant roles in step 1).

---

## 1. Bootstrap the deploy identity

```bash
az login
./scripts/bootstrap.sh medivaultgmbh medivault-azure
```

This creates, idempotently:

- an app registration `TF.MediVaultDeploy.ServicePrincipal`
- Contributor + User Access Administrator on the subscription
- a Terraform state storage account (name derived from your subscription ID)
- federated credentials for `main`, pull requests, and the `medivault-demo`
  environment — in **both** the classic and immutable OIDC subject formats

It prints the five variable values you need next.

> **Why User Access Administrator?** `terraform/minimal` creates a role
> assignment (Storage Blob Data Contributor on the evidence vault). Contributor
> alone cannot grant roles. This identity is deliberately more privileged than
> the read-only identities in `medivault-entra-governance` — which is exactly
> why they are separate identities rather than one shared one.

---

## 2. Configure GitHub

**Settings → Secrets and variables → Actions → Variables** — add all five as
repository variables (not secrets; none of them are sensitive):

| Variable | Source |
|---|---|
| `AZURE_CLIENT_ID` | bootstrap output |
| `AZURE_TENANT_ID` | bootstrap output |
| `AZURE_SUBSCRIPTION_ID` | bootstrap output |
| `TFSTATE_RESOURCE_GROUP` | bootstrap output |
| `TFSTATE_STORAGE_ACCOUNT` | bootstrap output |
| `COST_ALERT_EMAIL` | **you choose** — required, deploy aborts without it |
| `BUDGET_AMOUNT` | optional, defaults to `20` |

> The deploy job checks `COST_ALERT_EMAIL` before touching Terraform and fails
> fast if it's empty. A budget with no recipient isn't a control, so it's
> treated as a hard requirement rather than a default.

**Settings → Environments** — create one environment named `medivault-demo`.
Leave it empty; repository variables are inherited.

---

## 3. Run the gate

Push to `main`, or **Actions → GRC Gate → Run workflow**.

Two jobs run and both must pass:

| Job | What it proves | Expected |
|---|---|---|
| `policy-gate` | The reference architecture satisfies all six GDPR policies | Conftest exits 0 |
| `policy-gate-negative` | The gate rejects infrastructure that violates them | Conftest exits **non-zero** |

The second job is the one worth watching. It plans
`policies/fixtures/noncompliant/` — a configuration that trips every rule — and
fails the pipeline if Conftest *accepts* it. An all-green run against compliant
code proves nothing on its own; this is what makes the gate credible.

Expected findings from the fixture: **9 deny messages across 6 policy files.**

---

## 4. Deploy the demo governance plane

**Actions → GRC Gate → Run workflow**, tick **"Apply terraform/minimal"**.

Deploys, for under €2/month:

- Log Analytics workspace (1 GB/day ingest cap)
- Key Vault + 4096-bit CMK with 90-day automatic rotation
- Evidence vault storage — versioned, retained, Entra-ID-auth only
- Lifecycle management policy (GDPR Art. 5(1)(e))
- Diagnostic settings feeding Key Vault and storage audit events to Log Analytics
- Subscription budget with 50/80/100% actual and 90% forecasted alerts

> **The budget alerts; it does not cap.** Azure has no hard spending limit on
> pay-as-you-go. The real protection is architectural — the expensive components
> simply aren't deployed — plus the 1 GB/day Log Analytics ingest cap. See
> `docs/FINOPS.md`.

Then bundles `plan.json`, outputs, and the advisory policy findings, signs them
with cosign keyless, and uploads to the evidence vault.

The apply step also runs Conftest in **advisory** mode and prints every
violation into the run summary. Those are the accepted deviations in
`docs/EXCEPTIONS.md` — visible on every run, deliberately not blocking.

---

## 5. Tear down

Do this when you're finished. It stops the meter.

```bash
cd terraform/minimal
terraform init \
  -backend-config="resource_group_name=medivault-tfstate-rg" \
  -backend-config="storage_account_name=<from bootstrap>" \
  -backend-config="container_name=tfstate"
terraform destroy
```

The state storage account persists (it costs pennies). To remove it too:

```bash
az group delete --name medivault-tfstate-rg --yes
```

---

## Troubleshooting

**`AADSTS700213` on azure/login**
Subject mismatch. `bootstrap.sh` creates credentials for both the classic and
immutable formats, so this usually means the job is running on a branch other
than `main`, or the environment name does not match `medivault-demo`. Check the
subject printed in the failed step against
`az ad app federated-credential list --id <AZURE_CLIENT_ID>`.

**`Error acquiring the state lock`**
A previous run was cancelled mid-apply. Break the lease:
`az storage blob lease break --blob-name medivault.demo.terraform.tfstate --container-name tfstate --account-name <sa> --auth-mode login`

**`AuthorizationFailed` creating the role assignment**
The deploy identity is missing User Access Administrator. Re-run
`scripts/bootstrap.sh`; role propagation can take a few minutes.

**Key Vault name already exists**
Key Vault names are globally unique and soft-deleted vaults hold their name for
7 days. Either purge it (`az keyvault purge --name <name>`) or change
`name_prefix`.

**`policy-gate` fails on `terraform fmt -check`**
Run `terraform fmt -recursive` locally and commit.

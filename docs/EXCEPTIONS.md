# Control Exception Register

**Scope:** `terraform/minimal` (demo governance plane)
**Does not apply to:** `terraform/` (reference architecture — no exceptions; must pass the gate unmodified)

---

## Why this document exists

The demo deployment cannot satisfy the GDPR policies in `policies/`. That is not
a defect in the policies and not an oversight in the deployment — it is a real
constraint, and the correct governance response is to record it rather than to
weaken the policy or suppress the finding.

Two mechanisms are deliberately avoided here:

- **Weakening the rule.** Editing `gdpr_no_public_storage.rego` to permit public
  access would silently degrade the control for the production architecture too.
- **Suppressing the finding.** Adding an ignore annotation hides the deviation
  from anyone reading the pipeline output later.

Instead the deviations are accepted explicitly, with an owner, a rationale, a
compensating control, and a remediation path. This is what an exception process
looks like in ISO 27001 A.5.36 and what a DPO would expect to see before signing
off a non-conforming environment.

The pipeline reflects this: `deploy-demo` runs Conftest in **advisory** mode
against the demo plan and prints every finding into the run summary. The
findings are visible on every deployment; they are simply not blocking.

---

## Root cause

One constraint drives almost all of these.

The MediVault architecture specifies private endpoints and
`public_network_access_enabled = false` on every data store. Creating a Key
Vault key and uploading an evidence blob are **data plane** operations. A
GitHub-hosted runner sits on the public internet with a rotating egress IP, so
those calls fail at the network layer before authentication is attempted.

Resolving this properly requires a runner inside the VNet — a self-hosted runner
on an Azure VM, or an Azure Container Apps / Container Instance job with VNet
integration. That is the correct production answer and is out of scope for an
academic demonstration, both on cost and on setup time.

**The architecture is not wrong. The build agent is in the wrong place.**

---

## Register

| ID | Control deviated from | Deviation | Rationale | Compensating control | Remediation |
|---|---|---|---|---|---|
| **EXC-001** | GDPR Art. 25 — Key Vault private access (`gdpr_no_public_storage` equivalent) | `public_network_access_enabled = true` on Key Vault | Data plane key creation from a hosted runner | Entra ID auth required; `AuditEvent` diagnostics to Log Analytics capture every key operation; `allowed_ip_ranges` variable ready for allowlisting | Self-hosted runner in VNet, then set to `false` and add a private endpoint |
| **EXC-002** | GDPR Art. 25 — evidence vault private access | `public_network_access_enabled = true` on evidence storage | Evidence upload from a hosted runner | `shared_access_key_enabled = false` (Entra ID only, no account keys); RBAC-scoped writer role; read/write/delete logged | As EXC-001 |
| **EXC-003** | GDPR Art. 32 — HSM-backed CMK | Key Vault `standard` SKU, `RSA` key instead of `premium` / `RSA-HSM` | Premium tier adds cost for no demonstrable difference in an academic demo | 4096-bit key size retained; 90-day automatic rotation policy **identical to production** | Change `sku_name` to `premium` and `key_type` to `RSA-HSM` |
| **EXC-004** | Part 1 BC/DR — geo-redundancy | Evidence storage `LRS` instead of `GRS` | GRS roughly doubles storage cost; no DR test is in scope | Versioning + 30-day soft delete retained; evidence also held as a GitHub artifact for 90 days, giving an independent second copy | Change `account_replication_type` to `GRS` |
| **EXC-005** | GDPR Art. 32 — CMK encryption of evidence at rest | Evidence storage uses Microsoft-managed keys | CMK on storage requires a managed identity with key access plus a private-endpoint-reachable vault; circular with EXC-001 | Platform encryption (AES-256) still applies at rest; the CMK itself is still deployed and rotating, so the control is demonstrated on the Key Vault | Add `customer_managed_key` block once EXC-001 is closed |
| **EXC-006** | Part 2 — workload isolation | Cosmos DB, Functions, API Management, VNet and private endpoints not deployed | ~EUR 235/month of the ~EUR 240 total; not required to demonstrate governance controls | Full definitions remain in `terraform/` and are planned and policy-gated on every commit — the code is verified even though it is not run | Deploy `terraform/` with a funded subscription |

---

## Risk acceptance

| | |
|---|---|
| **Accepted by** | Fabrizio Di Carlo |
| **Role** | Cloud & security architect (module: Cloud Computing for Business) |
| **Environment** | Demo / academic. No personal data, no production traffic. |
| **Data classification** | None. The demo processes no data of any kind — it deploys empty controls. |
| **Expiry** | End of module assessment period |
| **Review trigger** | Any deployment of real or synthetic patient-derived data, or any use beyond assessment |

The residual risk is assessed as **low**: the environment contains no data, is
isolated in its own subscription, and is scheduled for teardown. The same
deviations in a production MediVault tenant would be **high** risk and would not
be accepted.

---

## Policy limitations discovered in operation

Two limitations surfaced only once the gate ran against a real plan. Both are
inherent to evaluating `terraform plan` output, and worth recording because they
bound what the gate can honestly claim.

**Unknown values at plan time.** Terraform marks any attribute it cannot resolve
before apply as *(known after apply)* and omits it from `planned_values`. A
policy asserting on such a value cannot distinguish "not configured" from "not
yet computed".

This produced a false positive on `azurerm_storage_account.datasets`: the
`customer_managed_key` block is present and correct, but `key_vault_key_id`
references a Key Vault key that does not exist yet, so the rule saw nothing and
denied compliant infrastructure. Fixed by falling back to the `configuration`
section, which records the expression whether or not it resolves.

A false positive is more corrosive than a false negative here. A gate that
blocks correct code gets bypassed, and once bypassing is normal the gate is
decoration.

**Unresolvable scopes weaken the RBAC rule.** `gdpr_rbac_no_wildcard` inspects
`scope` on role assignments, but in this configuration `scope` is a reference to
a resource created in the same plan, so it is also unknown. The rule therefore
passes vacuously rather than evaluating. It would still catch a hardcoded
subscription-scope assignment — which is the case it was written for — but it
cannot see computed ones. Recorded rather than fixed: the configuration fallback
would need to resolve references transitively, which is beyond what Conftest
does well.

## What this demonstrates

Worth saying plainly, because it is the substantive governance point of the
whole exercise.

A policy gate is only as credible as its handling of the cases it cannot
satisfy. The failure modes are well known: teams weaken the rule until it
passes, add a blanket suppression, or stop running the gate. All three destroy
the control while leaving the appearance of one.

The path taken here — keep the rule strict, deploy the non-conforming
environment anyway, and carry a documented time-bound exception with a named
owner and a remediation path — is the only one that preserves the control's
meaning. It also produces exactly the artefact an auditor asks for first.

This connects directly to the Part 3 governance assessment, which rated
MediVault's **compliance culture** as its weakest dimension. Policy-as-code is
the strong half; an exception process with real ownership is the half that
organisations usually lack.

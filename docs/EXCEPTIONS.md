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
| **EXC-007** | GDPR Art. 32 / ISO A.8.15 — tamper-proof evidence *(also asserted in Part 2 §6)* | Evidence vault has versioning, soft delete and signed bundles, but no locked immutability policy | A locked time-based retention policy cannot be shortened or removed for its full duration by anyone, including Microsoft support. Not appropriate in a demonstration repository that will be torn down | Cosign signatures make modification detectable; versioning and 90-day soft delete retain prior copies; all access logged to Log Analytics | Add `azurerm_storage_container_immutability_policy` with `locked = true` once retention requirements are contractually fixed |
| **EXC-006** | Part 2 — workload isolation | Cosmos DB, Functions, API Management, VNet and private endpoints not deployed | ~EUR 235/month of the ~EUR 240 total; not required to demonstrate governance controls | Full definitions remain in `terraform/` and are planned and policy-gated on every commit — the code is verified even though it is not run | Deploy `terraform/` with a funded subscription |
| **EXC-008** | Parts 1-2 — West Europe primary region | The demo governance plane deploys to Germany West Central (Frankfurt), not West Europe | Azure refused new resources in West Europe for this subscription: `RequestDisallowedByAzure - the selected region is currently not accepting new customers`. Region eligibility is set by Microsoft per subscription and is not published | Germany West Central is EU/EEA and is MediVault's own jurisdiction, so data residency is narrowed rather than weakened. The reference architecture in `terraform/` is unchanged and still targets West Europe with North Europe paired | None required. `scripts/create-state-backend.sh` probes EU regions in preference order and reports which was used |
| **EXC-009** | Policy gate coverage | The Rego policies read `planned_values.root_module.resources` only, so the 15 resources inside the `./baseline` child module are not evaluated | Written before the configuration was modularised, and never revisited when `baseline/` was extracted. The 26 workload resources at root — Cosmos DB, storage, API Management, Functions — are evaluated normally | Inspected manually: all 15 baseline resources satisfy all seven policies (public access disabled, TLS 1.2, 90-day key rotation, CMK, no wildcard roles). The gap is coverage, not a concealed violation | Traverse `child_modules` recursively via `walk()` in a shared helper package, then re-run the negative test to confirm no regression |

---

### Note on EXC-009 — how this was found

EXC-009 surfaced while adding `gdpr_eu_data_residency.rego`, which itself
surfaced while working around EXC-008. Three of the six original policies target
resource types that exist in `baseline/`, which means those rules have been
reporting success against a set of resources they never actually read.

This is the same failure mode recorded in the Part 3 reflection: a control that
emits a signal without the signal being connected to what it claims to measure.
It is listed here rather than fixed immediately because the fix changes every
policy at once, and doing that between a working gate and a recording deadline
trades a known-good state for an unverified one.

### Note on EXC-007 and the Part 2 brief

Part 2 §6 describes the evidence vault as an "immutable vault" with an
"immutability policy". That control is not implemented: the storage account has
versioning, soft delete and lifecycle management, but no locked time-based
retention policy.

The brief has been submitted and is not being retrospectively edited — the
version in `pdf/` is the record of what was assessed. This entry exists so the
repository reconciles rather than contradicts itself: the Terraform comments,
this register and the report now tell a consistent story, with the gap named in
the two places that remain editable.

Worth stating plainly, because it is the same error twice. A control asserted in
a compliance document and absent from the implementation is precisely the failure
the policy gate exists to prevent — and the gate could not catch it, because the
claim lived in prose rather than in code.

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

**Access-policy vaults silently ignore RBAC grants.** The reference architecture
granted the workload identity `Key Vault Crypto User` as a role assignment, on a
Key Vault that uses the access-policy permission model. In that mode the
assignment is inert: it plans, applies without error, and grants nothing.
Customer-managed key encryption would have failed at apply with an error naming
the storage account rather than the vault.

Neither `validate` nor `plan` can catch this — authorisation is only evaluated at
apply, and the resource itself is syntactically valid. It was found by review,
not by the pipeline, which bounds what a plan-time gate can claim: it verifies
that resources are well-formed and policy-compliant, not that they will
successfully authorise one another.

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

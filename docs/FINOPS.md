# FinOps — Cost Governance

How cost is controlled in this deployment, what the controls actually do, and
where the gap between "budget" and "cap" sits.

---

## The finding worth leading with

**An Azure budget does not cap spending.** It sends an email.

Crossing 100% of a budget triggers a notification and nothing else. No resource
is stopped, throttled, or deleted. Pay-as-you-go subscriptions have no hard
spending limit available — only the legacy free trial and certain
MSDN/Visual Studio offers do, and those suspend the *entire subscription*
rather than shedding load selectively.

This is a detective control presented in an interface that reads like a
preventive one. The word "budget", the currency field, and the progress bar all
imply enforcement. The common failure is predictable: a team sets a €20 budget,
believes it is protected, and finds out otherwise on the invoice.

Everything below follows from taking that distinction seriously.

---

## Control taxonomy

| Control | Type | In force here | Effect |
|---|---|---|---|
| Architectural scoping — omit Cosmos DB, Functions, APIM, private endpoints | **Preventive** | Yes | Removes ~€235/month of the ~€240 reference architecture |
| Log Analytics `daily_quota_gb = 1` | **Preventive** | Yes | Hard-stops ingest, the largest variable cost |
| LRS instead of GRS on evidence storage | **Preventive** | Yes | Halves storage replication cost |
| Standard instead of Premium Key Vault | **Preventive** | Yes | Avoids HSM pricing |
| Storage lifecycle policy — tier to cool at 30d, delete at 365d | **Preventive** | Yes | Bounds unbounded growth |
| Subscription budget, 4 thresholds | **Detective** | Yes — created at bootstrap, survives teardown | Alerts only |
| Resource tagging for allocation | **Informative** | Yes | Attribution, not restriction |
| Budget webhook → automated teardown | **Corrective** | **No** — documented below | Would enforce |

The important row is the first one. **The architecture is cheap by
construction; the budget is only the backstop for what design did not
anticipate.** A budget is a poor primary control precisely because it acts after
the money is committed.

---

## Where the guardrail lives, and why it moved

The budget was originally defined in `terraform/minimal`, alongside the demo
workload. That was wrong, and the reason is lifecycle rather than correctness.

Coupling the guardrail to the workload meant the budget only existed **after**
the demo was deployed, and `terraform destroy` removed it. So the spending
alarm was absent during exactly the two windows where it matters most: before
the first deployment, when a misconfiguration could provision something
expensive, and after teardown, when orphaned resources are the classic source
of a surprise invoice.

A guardrail should be established before the thing it guards and should outlive
it. The budget is now created by `scripts/bootstrap.sh`, with the other
subscription-level prerequisites — RBAC and the Terraform state backend — that
exist once and persist across every deployment.

The trade-off is that it is no longer Terraform-managed, so there is no state
tracking drift on it. `bootstrap.sh` is idempotent and re-running reasserts the
budget, which is an acceptable substitute at this scale. A larger estate would
put subscription guardrails in their own long-lived Terraform workspace rather
than in a script.

## What is deployed

Created by `scripts/bootstrap.sh`:

- **Scope:** the whole subscription, not the demo resource group. A
  resource-group budget would miss the Terraform state storage account and
  anything created outside this configuration — which is exactly the spend most
  likely to be forgotten.
- **Amount:** 20, in the subscription's billing currency. Azure budgets have no
  currency field; a EUR-billed subscription reads this as €20.
- **Thresholds:** 50% / 80% / 100% actual, plus **90% forecasted**.

The forecast threshold is the most useful of the four. Actual-spend alerts are
retrospective by definition — at 100% actual the money is already gone. The
forecast alert fires on Azure's projection of month-end spend, typically days
earlier, while there is still time to act.

Verify it exists:

```bash
az consumption budget list --output table
```

An empty result means the budget was never created — most likely `bootstrap.sh`
did not complete. Note this command is flagged preview; the portal view under
**Cost Management + Billing → Budgets** is authoritative.

---

## The enforcement gap

The corrective control that would make the ceiling real:

```
Budget threshold breached
  → Action Group webhook
    → Azure Automation runbook (or Logic App)
      → Remove-AzResourceGroup -Name medivlt-demo-rg -Force
```

Azure Automation's free tier covers 500 job-minutes per month, so this costs
nothing to run.

**Why it is documented rather than deployed:** an automation with rights to
delete resource groups is a destructive capability triggered by a billing
signal. Billing data is delayed — typically 8 to 24 hours — so the trigger fires
against stale information. In a production environment that combination
(destructive action, delayed trigger, no human in the loop) is how a cost
control becomes an availability incident.

The defensible production pattern is graduated and reversible:

1. Alert only, for the first threshold
2. Scale down or deallocate non-production compute, for the second
3. Delete only in an environment explicitly tagged as ephemeral, and only with
   an approval gate

For this demo the same outcome is achieved with `terraform destroy` and a
calendar reminder. That is a legitimate answer at this scale — the honest
version of "we did not automate it" is better than an automation nobody tested.

---

## Cost allocation through tags

Every resource carries:

```hcl
Project     = "medivault-healthcare-api"
Environment = "demo"
CostCenter  = "cloud-engineering"
Workload    = "governance-plane"
DataClass   = "restricted-gdpr"
Deviation   = "see-docs/EXCEPTIONS.md"
```

`CostCenter` and `Project` make Cost Analysis group spend by owner rather than
by resource type, which is the difference between "storage cost €4" and
"MediVault governance plane cost €4". Only the second can be shown to a budget
holder.

Tagging is applied at creation through Terraform rather than retrofitted. Azure
Policy can enforce required tags at deployment with a `deny` effect — the
natural next step, and the same policy-as-code pattern the GDPR gate already
uses. Retrofitted tags are close to worthless for cost history, because
historical usage records keep the tags they had at the time.

---

## Mapping to the FinOps Framework

The FinOps Foundation defines three iterative phases. Where this deployment
sits:

**Inform** — visibility and allocation. *Implemented.* Tagging supports
allocation; Cost Analysis gives per-resource and per-tag breakdown; the budget
provides a reference point to measure against.

**Optimize** — reduce waste and rightsize. *Partially implemented.* The
architectural decisions in `EXCEPTIONS.md` are optimisation decisions with their
security trade-offs made explicit — LRS over GRS, Standard over Premium,
consumption over provisioned. Each is recorded with what was given up, not just
what was saved. Not implemented: reserved instances or savings plans, which need
a stable 1–3 year baseline this environment does not have.

**Operate** — continuous governance. *Weakest.* The budget alerts, but nothing
acts on the alert automatically, and there is no showback or chargeback
reporting cycle. This mirrors the Part 3 governance assessment almost exactly:
the technical controls are strong, the *organisational* process around them is
thin.

That parallel is not a coincidence. Both failures share a root cause — a control
that produces a signal nobody owns is not a control.

---

## Relevance to MediVault

For MediVault specifically, cost governance is not separable from data
governance.

The most expensive components in the reference architecture are the ones the
GDPR analysis requires: geo-zone-redundant storage for the BC/DR RPO target,
private endpoints for Art. 25 network isolation, Premium Key Vault for
HSM-backed keys under Art. 32, and long log retention for NIS2 Art. 23 evidence.

Each is a compliance requirement first and a cost line second. That inverts the
usual FinOps posture: the answer to "why is storage expensive" is "because
Article 32 requires it", and the optimisation conversation has to happen inside
the regulatory constraint rather than across it.

The practical implication for an SME is that a naive cost-reduction exercise —
the kind that drops replication tiers or shortens retention to hit a number — is
a compliance regression wearing a savings badge. Cost decisions touching
regulated workloads need the same review path as security decisions, which is a
governance requirement, not a tooling one.

---

## Verifying it works

```bash
# Confirm the budget exists and its current consumption
az consumption budget list --output table

# Current month spend
az consumption usage list --start-date 2026-08-01 --end-date 2026-08-31 \
  --query "sum(@[].pretaxCost)"

# Cost by tag (Cost Management API; portal is easier for ad-hoc)
az costmanagement query \
  --type ActualCost --timeframe MonthToDate \
  --scope "/subscriptions/<sub-id>" \
  --dataset-grouping name=CostCenter type=TagKey
```

In the portal: **Cost Management + Billing → Cost analysis**, group by tag
`CostCenter`. Note that cost data lags actual usage by 8–24 hours, so a
freshly-deployed resource will not appear immediately. That lag is the same one
that makes automated budget enforcement risky.

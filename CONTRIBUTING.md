# Contributing

## Branching

`main` is protected. Work happens on short-lived branches and lands via pull
request.

```
feat/short-description     new capability
fix/short-description      bug fix
docs/short-description     documentation only
chore/short-description    dependencies, tooling, formatting
```

## Commits

[Conventional Commits](https://www.conventionalcommits.org/):

```
feat(terraform): add subscription budget with forecast alerting
fix(workflow): correct OIDC subject for immutable org identifiers
docs(exceptions): record EXC-006 for omitted workload components
chore(deps): bump azure/login from 2.1.0 to 2.2.0
```

## Before opening a pull request

```bash
terraform fmt -recursive
terraform validate
```

If you changed a policy, also run the negative test locally — it is the one
that actually matters:

```bash
cd policies/fixtures/noncompliant
terraform init -backend=false && terraform plan -out=tfplan
terraform show -json tfplan > plan.json
conftest test plan.json --policy ../../. --all-namespaces
# MUST exit non-zero. If this passes, the policies have regressed.
```

## Pull request requirements

Branch protection on `main` enforces:

| Rule | Why |
|---|---|
| 1 approving review, from a Code Owner | No unreviewed infrastructure changes |
| `policy-gate` must pass | Reference architecture stays compliant |
| `policy-gate-negative` must pass | The gate is proven to reject bad config |
| Branch up to date before merge | Prevents semantic conflicts between IaC changes |
| Conversations resolved | Review comments are not silently dropped |
| Linear history | Bisecting infrastructure regressions stays practical |
| No force push, no deletion | Audit trail integrity |

Administrators are **not** exempt. On a solo project that self-restriction is
the entire point: it is what makes the audit trail credible to anyone who did
not write the code.

## Changing a security policy

Policies in `policies/*.rego` encode regulatory requirements. Weakening one is a
compliance decision, not a technical one.

If a policy blocks legitimate work, the order of preference is:

1. **Fix the infrastructure** so it complies.
2. **Record an exception** in `docs/EXCEPTIONS.md` — with an owner, rationale,
   compensating control, expiry, and remediation path.
3. **Change the policy** — only if the rule is genuinely wrong, and the commit
   must explain which regulatory requirement changed and why.

Do not add blanket ignore annotations. A suppressed finding is invisible to
whoever reads the pipeline output six months from now; a recorded exception is
not.

## Terraform conventions

- Comments explain **why**, not what. `sku_name = "premium"` is self-evident;
  "HSM-backed keys required for GDPR Art. 32" is not.
- Every deviation from the reference architecture references its exception ID.
- Graph and Azure permissions are declared by **name**, never by GUID — a typo
  should fail at plan time, not grant nothing silently.
- No `terraform apply` from a laptop against shared state. CI owns deployment.

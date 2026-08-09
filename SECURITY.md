# Security Policy

## Scope and status

MediVault is a **fictional organisation** used for an academic cloud
architecture project. No real patient data, no real customers, and no
production systems exist.

The infrastructure code is nonetheless real and deployable, so this policy
describes how security issues in that code are handled.

## Reporting a vulnerability

Report privately — do not open a public issue.

1. **GitHub Security Advisories** (preferred) — the Security tab → *Report a
   vulnerability*. Keeps the report private until a fix is published.
2. **Email** — fabrizio.dicarlo@contrailrisks.com

Please include the affected file or workflow, the impact, and reproduction steps
if you have them.

**Expected response:** acknowledgement within 5 working days. This is a
personal academic project, not a funded product — there is no on-call rotation
and no SLA beyond best effort.

## What is in scope

- Terraform that provisions insecure resources by default
- GDPR policy rules (`policies/*.rego`) that fail to catch what they claim to
- GitHub Actions workflow injection, or privilege escalation via OIDC
- Over-permissive Entra ID application permissions or federated credential
  subjects
- Secrets committed to the repository

## What is out of scope

- The deliberately non-compliant fixtures in
  `policies/fixtures/noncompliant/` — those are **intentionally** insecure and
  exist to prove the policy gate rejects them. See the header comment.
- Documented deviations in `docs/EXCEPTIONS.md` — knowingly accepted, with
  rationale and remediation paths recorded.
- The fictional MediVault scenario itself.

## Security design of this project

Worth stating plainly, because it is the point of the project:

**No long-lived credentials exist anywhere in these repositories.** All Azure
authentication uses Workload Identity Federation — GitHub issues a short-lived
OIDC token, Entra ID validates the subject claim against a federated credential,
and returns an access token valid for roughly an hour. There is no client
secret or certificate to leak, rotate, or expire.

Consequences worth knowing:

- `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` are stored as
  GitHub **variables**, not secrets. They are identifiers, not credentials.
  Treating them as secrets implies a confidentiality property they do not have.
- Assessment identities are **read-only** and scoped per tool. Compromise of one
  does not yield the union of all three.
- The deploy identity holds write access and is therefore **separate** from the
  read-only assessment identities, in a different repository.
- Federated credentials are bound to a specific repository *and* environment or
  branch. A token minted by a different repo will not authenticate.

If you find a way to obtain a token outside those constraints, that is precisely
the kind of finding this policy wants.

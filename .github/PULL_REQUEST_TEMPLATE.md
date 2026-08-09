## What and why

<!-- What changes, and what problem it solves. Link an issue if there is one. -->

## Type

- [ ] Feature
- [ ] Fix
- [ ] Documentation
- [ ] Dependencies / tooling

## Security and compliance impact

<!-- Delete the rows that do not apply. Do not delete the table. -->

| Question | Answer |
|---|---|
| Changes identity, permissions, or federated credentials? | No / Yes — describe |
| Changes a GDPR policy in `policies/`? | No / Yes — which regulatory requirement changed |
| Introduces a deviation from the reference architecture? | No / Yes — exception ID in `docs/EXCEPTIONS.md` |
| Changes what CI is permitted to do? | No / Yes — describe |
| Affects estimated cost? | No / Yes — new monthly estimate |

## Verification

- [ ] `terraform fmt -recursive` clean
- [ ] `terraform validate` passes
- [ ] `policy-gate` passes
- [ ] `policy-gate-negative` still **fails the fixture** (the gate rejects bad config)
- [ ] Plan output reviewed — no unintended destroy or replace

<!--
If this PR adds a permission, state why the workload cannot function without it.
Least privilege is the default; broadening it needs a reason, not an assumption.
-->

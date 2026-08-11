# METADATA
# title: GDPR Art. 32 — ADLS Gen2 must use customer-managed key encryption
# description: >
#   Healthcare-derived datasets carry residual re-identification risk under GDPR
#   Recital 26. ADLS Gen2 storage accounts holding such data must use a
#   customer-managed key (CMK) from the GRC Key Vault, not a Microsoft-managed key.
#   This ensures MediVault retains cryptographic custody and can demonstrate
#   Art. 32 'appropriate technical measures'.
# custom:
#   framework: gdpr
#   controls:
#     - "Art.25 — privacy by design"
#     - "Art.32 — encryption at rest"
#   severity: critical
#   aws_equivalent: compliance.hipaa.s3_kms
#   remediation: >
#     Add a customer_managed_key block to azurerm_storage_account referencing the
#     baseline Key Vault key ID. Set identity type to UserAssigned and provide the
#     workload managed identity ID.
package compliance.gdpr.adls_encryption

import data.compliance.lib
import rego.v1

deny contains msg if {
	some r in lib.resources
	r.type == "azurerm_storage_account"
	r.values.is_hns_enabled == true # Only enforce CMK on ADLS Gen2 (HNS) accounts
	not has_customer_managed_key(r)
	msg := sprintf(
		"[GDPR Art.32] %s: ADLS Gen2 storage account must use a customer-managed key. Add a customer_managed_key block referencing the GRC Key Vault key.",
		[r.address],
	)
}

has_customer_managed_key(resource) if {
	cmk := resource.values.customer_managed_key[_]
	cmk.key_vault_key_id != ""
	cmk.key_vault_key_id != null
}

# UNKNOWN VALUES AT PLAN TIME
#
# The first rule alone produces a false positive. key_vault_key_id is usually a
# reference to a Key Vault key that does not exist yet, so Terraform marks it
# "(known after apply)" and omits it from planned_values entirely. That is
# indistinguishable from "no customer_managed_key block was configured", and the
# policy denies compliant infrastructure.
#
# The configuration section records the *expression* regardless of whether its
# value can be resolved, so it can confirm the block exists and references
# something. Weaker than asserting on the resolved value, and the honest
# trade-off: the alternative is a gate that blocks correct code, which is how
# policy-as-code gets switched off.
#
# gdpr_api_logging.rego uses the same fallback pattern.
has_customer_managed_key(resource) if {
	some cfg in lib.config_resources
	lib.address_matches(resource.address, cfg.address)
	cfg.expressions.customer_managed_key[_].key_vault_key_id
}

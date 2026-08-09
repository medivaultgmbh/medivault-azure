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

import rego.v1

deny contains msg if {
	some r in input.planned_values.root_module.resources
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

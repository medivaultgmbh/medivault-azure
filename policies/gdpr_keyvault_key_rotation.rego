# METADATA
# title: GDPR Art. 32 — Key Vault keys must have an automatic rotation policy
# description: >
#   Customer-managed keys in Azure Key Vault must have an automatic rotation policy
#   defined. This is the Azure equivalent of aws_kms_key enable_key_rotation = true.
#   Rotating cryptographic keys limits the blast radius of a key compromise and is
#   required as a 'state of the art' technical measure under GDPR Art. 32.
#   Keys must rotate at least every 90 days for GDPR-restricted healthcare data.
# custom:
#   framework: gdpr
#   controls:
#     - "Art.32 — appropriate technical and organisational measures"
#   severity: high
#   aws_equivalent: compliance.hipaa.dynamodb_kms (CMK + rotation)
#   remediation: >
#     Add a rotation_policy block to azurerm_key_vault_key with
#     automatic.time_before_expiry = "P30D" and expire_after = "P90D".
package compliance.gdpr.keyvault_key_rotation

import data.compliance.lib
import rego.v1

deny contains msg if {
	some r in lib.resources
	r.type == "azurerm_key_vault_key"
	not has_rotation_policy(r)
	msg := sprintf(
		"[GDPR Art.32] %s: Key Vault key must have an automatic rotation policy. Add a rotation_policy block with expire_after <= P90D.",
		[r.address],
	)
}

has_rotation_policy(resource) if {
	policy := resource.values.rotation_policy[_]
	auto := policy.automatic[_]
	auto.time_before_expiry != ""
}

deny contains msg if {
	some r in lib.resources
	r.type == "azurerm_key_vault"
	r.values.purge_protection_enabled != true
	msg := sprintf(
		"[GDPR Art.32] %s: Key Vault must have purge protection enabled. Deleted keys must be recoverable for forensic purposes.",
		[r.address],
	)
}

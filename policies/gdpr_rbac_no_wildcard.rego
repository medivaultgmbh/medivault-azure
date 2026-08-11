# METADATA
# title: GDPR Art. 25 — Role assignments must not use Owner or broad Contributor at subscription scope
# description: >
#   azurerm_role_assignment resources must not assign the "Owner" or "Contributor"
#   built-in roles at the subscription scope ("/subscriptions/...").
#   This is the Azure equivalent of the HIPAA iam_least_privilege policy that
#   blocks wildcard IAM actions (":*") on the Lambda execution role.
#   Over-privileged identities are a primary enabler of lateral movement and
#   data exfiltration in cloud environments (CSA Top Threats, 2022).
# custom:
#   framework: gdpr
#   controls:
#     - "Art.25 — principle of data minimisation applied to access rights"
#     - "Art.32 — access control as a security measure"
#     - "ISO 27001:2022 A.8.2 — privileged access rights"
#   severity: critical
#   aws_equivalent: compliance.hipaa.iam_least_privilege
#   remediation: >
#     Replace broad Owner/Contributor assignments with narrowly scoped built-in
#     roles (e.g. "Storage Blob Data Contributor", "Key Vault Crypto User") applied
#     at the resource or resource-group scope, not the subscription scope.
package compliance.gdpr.rbac_no_wildcard

import data.compliance.lib
import rego.v1

# Broad roles that violate least-privilege at any scope
broad_roles := {"Owner", "Contributor"}

# Subscription-scope prefix
subscription_scope_prefix := "/subscriptions/"

deny contains msg if {
	some r in lib.resources
	r.type == "azurerm_role_assignment"
	r.values.role_definition_name in broad_roles
	startswith(r.values.scope, subscription_scope_prefix)
	# Allow only if scope is a resource group or narrower
	not is_resource_group_or_narrower_scope(r.values.scope)
	msg := sprintf(
		"[GDPR Art.25] %s: role '%s' at subscription scope violates least-privilege. Use a narrower built-in role scoped to the target resource or resource group.",
		[r.address, r.values.role_definition_name],
	)
}

is_resource_group_or_narrower_scope(scope) if {
	# A resource group scope contains "/resourceGroups/" after the subscription ID
	contains(scope, "/resourceGroups/")
}

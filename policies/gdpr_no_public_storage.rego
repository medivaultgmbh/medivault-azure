# METADATA
# title: GDPR Art. 25 — Storage accounts must not allow public network access
# description: >
#   All azurerm_storage_account resources holding GDPR-classified data must have
#   public_network_access_enabled set to false. Public access is equivalent to
#   an S3 bucket without a DenyInsecureTransport policy — it widens the attack
#   surface and is incompatible with Art. 25 privacy-by-design requirements.
# custom:
#   framework: gdpr
#   controls:
#     - "Art.25 — privacy by design and by default"
#     - "Art.32 — network security measures"
#   severity: high
#   aws_equivalent: compliance.hipaa.s3_tls (DenyInsecureTransport bucket policy)
#   remediation: >
#     Set public_network_access_enabled = false on all storage accounts. Use
#     private endpoints for data plane access and service endpoints for management.
package compliance.gdpr.no_public_storage

import data.compliance.lib
import rego.v1

deny contains msg if {
	some r in lib.resources
	r.type == "azurerm_storage_account"
	not r.values.public_network_access_enabled == false
	msg := sprintf(
		"[GDPR Art.25] %s: storage account must not allow public network access. Set public_network_access_enabled = false.",
		[r.address],
	)
}

deny contains msg if {
	some r in lib.resources
	r.type == "azurerm_storage_account"
	r.values.min_tls_version != "TLS1_2"
	msg := sprintf(
		"[GDPR Art.32] %s: storage account must enforce TLS 1.2 minimum. Set min_tls_version = \"TLS1_2\".",
		[r.address],
	)
}

# METADATA
# title: GDPR Art. 32 — Cosmos DB must have continuous backup (PITR) enabled
# description: >
#   Cosmos DB accounts holding GDPR-restricted healthcare submissions must use
#   Continuous backup mode, enabling point-in-time restore (PITR) to any second
#   within the last 7 days. This is the Azure equivalent of DynamoDB
#   point_in_time_recovery and satisfies the BC/DR RPO < 1 hour target
#   established in Part 1 of the MediVault migration plan.
# custom:
#   framework: gdpr
#   controls:
#     - "Art.32 — availability and resilience of processing systems"
#   severity: high
#   aws_equivalent: compliance.hipaa.dynamodb_pitr
#   remediation: >
#     Add a backup block to azurerm_cosmosdb_account with type = "Continuous"
#     and tier = "Continuous7Days".
package compliance.gdpr.cosmos_pitr

import data.compliance.lib
import rego.v1

deny contains msg if {
	some r in lib.resources
	r.type == "azurerm_cosmosdb_account"
	not has_continuous_backup(r)
	msg := sprintf(
		"[GDPR Art.32] %s: Cosmos DB account must use Continuous backup for PITR. Add backup { type = \"Continuous\" tier = \"Continuous7Days\" }.",
		[r.address],
	)
}

has_continuous_backup(resource) if {
	backup := resource.values.backup[_]
	backup.type == "Continuous"
}

deny contains msg if {
	some r in lib.resources
	r.type == "azurerm_cosmosdb_account"
	r.values.public_network_access_enabled != false
	msg := sprintf(
		"[GDPR Art.25] %s: Cosmos DB account must not allow public network access. Set public_network_access_enabled = false.",
		[r.address],
	)
}
